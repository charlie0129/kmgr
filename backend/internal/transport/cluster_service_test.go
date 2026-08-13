package transport

import (
	"context"
	"crypto/x509"
	"errors"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/client-go/rest"
)

type serviceFactory struct {
	mu     sync.Mutex
	closes int
}

func (f *serviceFactory) New(*rest.Config) (cluster.BackendClients, error) {
	return cluster.BackendClients{Close: func() {
		f.mu.Lock()
		f.closes++
		f.mu.Unlock()
	}}, nil
}

func (f *serviceFactory) closeCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.closes
}

func TestListContextsIsOfflineAndOpenSessionProbes(t *testing.T) {
	t.Parallel()
	catalog := serviceCatalog(t)
	loadCalls := 0
	probeCalls := 0
	factory := &serviceFactory{}
	sessions := cluster.NewSessionRegistry(factory)
	service := NewClusterService(ClusterServiceOptions{
		Catalogs: NewCatalogRegistry(func([]string) (*cluster.Catalog, error) {
			loadCalls++
			return catalog, nil
		}),
		Sessions: sessions,
		Prober: SessionProbeFunc(func(ctx context.Context, session *cluster.Session) error {
			probeCalls++
			if session.Context().Name != "local" {
				t.Fatalf("probe session context = %q", session.Context().Name)
			}
			return nil
		}),
	})

	contexts, err := service.ListContexts(context.Background(), &kmgrv1.ListContextsRequest{
		Context: requestContext("list"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if probeCalls != 0 || loadCalls != 1 || contexts.GetError() != nil || len(contexts.GetContexts()) != 1 {
		t.Fatalf("offline list: loads=%d probes=%d response=%#v", loadCalls, probeCalls, contexts)
	}
	if contexts.GetContexts()[0].GetAuthenticationHint() != "Bearer token" {
		t.Fatalf("authentication hint = %q", contexts.GetContexts()[0].GetAuthenticationHint())
	}

	opened, err := service.OpenSession(context.Background(), &kmgrv1.OpenSessionRequest{
		Context:     requestContext("open"),
		ContextName: "local",
	})
	if err != nil {
		t.Fatal(err)
	}
	if probeCalls != 1 || opened.GetError() != nil || opened.GetClusterSessionId() == "" {
		t.Fatalf("open: probes=%d response=%#v", probeCalls, opened)
	}
	if _, ok := sessions.Get(opened.GetClusterSessionId()); !ok {
		t.Fatal("successful session was not retained")
	}
}

func TestOpenSessionProbeFailureReturnsStructuredErrorAndRollsBack(t *testing.T) {
	t.Parallel()
	catalog := serviceCatalog(t)
	factory := &serviceFactory{}
	sessions := cluster.NewSessionRegistry(factory)
	service := NewClusterService(ClusterServiceOptions{
		Catalogs: NewCatalogRegistry(func([]string) (*cluster.Catalog, error) { return catalog, nil }),
		Sessions: sessions,
		Prober: SessionProbeFunc(func(ctx context.Context, session *cluster.Session) error {
			return context.DeadlineExceeded
		}),
		ProbeTimeout: time.Second,
	})

	opened, err := service.OpenSession(context.Background(), &kmgrv1.OpenSessionRequest{
		Context: requestContext("open-failed"), ContextName: "local",
	})
	if err != nil {
		t.Fatal(err)
	}
	if opened.GetClusterSessionId() != "" ||
		opened.GetError().GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_TIMEOUT ||
		opened.GetError().GetContextName() != "local" {
		t.Fatalf("failure response = %#v", opened)
	}
	if factory.closeCount() != 1 {
		t.Fatalf("client close count = %d, want rollback close", factory.closeCount())
	}
}

func TestCloseSessionPreservesOnlyPreexistingIndependentLeasesWhenRequested(t *testing.T) {
	t.Parallel()
	catalog := serviceCatalog(t)
	factory := &serviceFactory{}
	sessions := cluster.NewSessionRegistry(factory)
	service := NewClusterService(ClusterServiceOptions{
		Catalogs: NewCatalogRegistry(func([]string) (*cluster.Catalog, error) { return catalog, nil }),
		Sessions: sessions,
		Prober:   SessionProbeFunc(func(context.Context, *cluster.Session) error { return nil }),
	})
	opened, err := service.OpenSession(context.Background(), &kmgrv1.OpenSessionRequest{
		Context: requestContext("open-preserved"), ContextName: "local",
	})
	if err != nil {
		t.Fatal(err)
	}
	sessionID := opened.GetClusterSessionId()
	_, lease, ok := sessions.Acquire(sessionID)
	if !ok {
		t.Fatal("Acquire: session missing")
	}
	ack, err := service.CloseSession(context.Background(), &kmgrv1.CloseSessionRequest{
		Context:                &kmgrv1.RequestContext{RequestId: "close-preserved", ClusterSessionId: sessionID},
		KeepIndependentStreams: true,
	})
	if err != nil || !ack.GetAccepted() {
		t.Fatalf("CloseSession = %#v, %v", ack, err)
	}
	if _, ok := sessions.Get(sessionID); ok || factory.closeCount() != 0 {
		t.Fatal("preserving close did not tombstone the workspace while retaining its leased backend")
	}
	if _, newLease, ok := sessions.Acquire(sessionID); ok || newLease != nil {
		t.Fatal("preserving close accepted a new independent operation")
	}
	lease.Release()
	if _, ok := sessions.Get(sessionID); ok || factory.closeCount() != 1 {
		t.Fatal("final lease did not retire the closed workspace session")
	}
}

func TestCloseSessionWithoutPreservationForceCloses(t *testing.T) {
	t.Parallel()
	catalog := serviceCatalog(t)
	factory := &serviceFactory{}
	sessions := cluster.NewSessionRegistry(factory)
	service := NewClusterService(ClusterServiceOptions{
		Catalogs: NewCatalogRegistry(func([]string) (*cluster.Catalog, error) { return catalog, nil }),
		Sessions: sessions,
		Prober:   SessionProbeFunc(func(context.Context, *cluster.Session) error { return nil }),
	})
	opened, err := service.OpenSession(context.Background(), &kmgrv1.OpenSessionRequest{
		Context: requestContext("open-force"), ContextName: "local",
	})
	if err != nil {
		t.Fatal(err)
	}
	sessionID := opened.GetClusterSessionId()
	_, lease, ok := sessions.Acquire(sessionID)
	if !ok {
		t.Fatal("Acquire: session missing")
	}
	_, err = service.CloseSession(context.Background(), &kmgrv1.CloseSessionRequest{
		Context: &kmgrv1.RequestContext{RequestId: "close-force", ClusterSessionId: sessionID},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := sessions.Get(sessionID); ok || factory.closeCount() != 1 {
		t.Fatal("non-preserving close did not invalidate the leased session")
	}
	lease.Release()
	if factory.closeCount() != 1 {
		t.Fatal("late release closed force-closed backend twice")
	}
}

func TestConnectionErrorDoesNotExposeUnderlyingMessage(t *testing.T) {
	t.Parallel()
	errorValue := connectionError(errors.New("server rejected token super-secret"), "local", "cluster.test")
	if errorValue.GetMessage() == "server rejected token super-secret" {
		t.Fatal("structured error exposed raw connection error")
	}
}

func TestConnectionErrorClassifiesSafeConnectionFailures(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name     string
		err      error
		category kmgrv1.ErrorCategory
		reason   string
	}{
		{name: "authentication", err: apierrors.NewUnauthorized("private server response"), category: kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHENTICATION, reason: "AuthenticationRejected"},
		{name: "tls", err: x509.HostnameError{Certificate: &x509.Certificate{}, Host: "cluster.test"}, category: kmgrv1.ErrorCategory_ERROR_CATEGORY_TLS, reason: "TLSVerificationFailed"},
		{name: "unreachable", err: &net.DNSError{Err: "no such host", Name: "cluster.test"}, category: kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE, reason: "ClusterUnreachable"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			structured := connectionError(test.err, "local", "cluster.test")
			if structured.GetCategory() != test.category || structured.GetReason() != test.reason {
				t.Fatalf("connectionError() = %#v", structured)
			}
		})
	}
}

func serviceCatalog(t *testing.T) *cluster.Catalog {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config")
	contents := []byte(`
apiVersion: v1
kind: Config
clusters:
- name: target
  cluster: {server: https://cluster.test}
users:
- name: static
  user: {token: private-token}
contexts:
- name: local
  context: {cluster: target, user: static}
current-context: local
`)
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	return mustCatalog(t, path)
}

func mustCatalog(t *testing.T, path string) *cluster.Catalog {
	t.Helper()
	catalog, err := cluster.DiscoverPaths([]string{path})
	if err != nil {
		t.Fatal(err)
	}
	return catalog
}
