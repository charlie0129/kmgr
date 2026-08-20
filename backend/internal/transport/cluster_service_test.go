package transport

import (
	"context"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/rest"
)

type serviceFactory struct {
	mu     sync.Mutex
	closes int
}

type recordingDefaultServiceFactory struct {
	mu     sync.Mutex
	closes int
}

func (f *recordingDefaultServiceFactory) New(config *rest.Config) (cluster.BackendClients, error) {
	clients, err := (cluster.DefaultClientFactory{}).New(config)
	if err != nil {
		return cluster.BackendClients{}, err
	}
	closeClients := clients.Close
	clients.Close = func() {
		if closeClients != nil {
			closeClients()
		}
		f.mu.Lock()
		f.closes++
		f.mu.Unlock()
	}
	return clients, nil
}

func (f *recordingDefaultServiceFactory) closeCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.closes
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
	if contexts.GetContexts()[0].GetContextId() == "" {
		t.Fatal("offline list omitted the opaque context binding ID")
	}

	opened, err := service.OpenSession(context.Background(), &kmgrv1.OpenSessionRequest{
		Context:     requestContext("open"),
		ContextName: contexts.GetContexts()[0].GetContextId(),
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

func TestOpenSessionDefaultProbeUsesAuthenticatedVersionRequest(t *testing.T) {
	t.Parallel()
	type observedRequest struct {
		path          string
		authorization string
	}
	observed := make(chan observedRequest, 1)
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		observed <- observedRequest{
			path:          request.URL.Path,
			authorization: request.Header.Get("Authorization"),
		}
		response.Header().Set("Content-Type", "application/json")
		_, _ = response.Write([]byte(`{"major":"1","minor":"30","gitVersion":"v1.30.0"}`))
	}))
	defer server.Close()

	catalog := serviceProbeCatalog(t, server.URL, "probe-token")
	contextID := serviceContextID(t, catalog)
	probeConfig, err := catalog.RESTConfig(contextID)
	if err != nil {
		t.Fatal(err)
	}
	if probeConfig.BearerToken != "probe-token" {
		t.Fatalf("probe REST config omitted bearer token")
	}
	factory := &recordingDefaultServiceFactory{}
	sessions := cluster.NewSessionRegistry(factory)
	service := NewClusterService(ClusterServiceOptions{
		Catalogs: NewCatalogRegistry(func([]string) (*cluster.Catalog, error) { return catalog, nil }),
		Sessions: sessions,
	})
	opened, err := service.OpenSession(context.Background(), &kmgrv1.OpenSessionRequest{
		Context: requestContext("authenticated-probe"), ContextName: contextID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if opened.GetError() != nil || opened.GetClusterSessionId() == "" {
		t.Fatalf("open response = %#v", opened)
	}
	request := <-observed
	if request.path != "/version" || request.authorization != "Bearer probe-token" {
		t.Fatalf("probe request = %#v", request)
	}
	if !sessions.Close(opened.GetClusterSessionId()) || factory.closeCount() != 1 {
		t.Fatalf("successful session cleanup: closed=%d response=%#v", factory.closeCount(), opened)
	}
}

func TestOpenSessionDefaultProbeHTTP401RollsBackSession(t *testing.T) {
	t.Parallel()
	observed := make(chan string, 1)
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		observed <- request.Header.Get("Authorization")
		response.Header().Set("Content-Type", "application/json")
		response.WriteHeader(http.StatusUnauthorized)
		_, _ = response.Write([]byte(`{
			"apiVersion":"v1","kind":"Status","status":"Failure",
			"reason":"Unauthorized","code":401,"message":"credentials rejected"
		}`))
	}))
	defer server.Close()

	catalog := serviceProbeCatalog(t, server.URL, "rejected-token")
	contextID := serviceContextID(t, catalog)
	factory := &recordingDefaultServiceFactory{}
	sessions := cluster.NewSessionRegistry(factory)
	service := NewClusterService(ClusterServiceOptions{
		Catalogs: NewCatalogRegistry(func([]string) (*cluster.Catalog, error) { return catalog, nil }),
		Sessions: sessions,
	})
	opened, err := service.OpenSession(context.Background(), &kmgrv1.OpenSessionRequest{
		Context: requestContext("rejected-probe"), ContextName: contextID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if authorization := <-observed; authorization != "Bearer rejected-token" {
		t.Fatalf("probe authorization = %q", authorization)
	}
	if opened.GetClusterSessionId() != "" ||
		opened.GetError().GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHENTICATION ||
		opened.GetError().GetHttpStatusCode() != http.StatusUnauthorized {
		t.Fatalf("401 response = %#v", opened)
	}
	if factory.closeCount() != 1 {
		t.Fatalf("401 rollback close count = %d, want 1", factory.closeCount())
	}
}

func TestOpenSessionProbeFailureReturnsStructuredErrorAndRollsBack(t *testing.T) {
	t.Parallel()
	catalog := serviceCatalog(t)
	contextID := serviceContextID(t, catalog)
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
		Context: requestContext("open-failed"), ContextName: contextID,
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
	contextID := serviceContextID(t, catalog)
	factory := &serviceFactory{}
	sessions := cluster.NewSessionRegistry(factory)
	service := NewClusterService(ClusterServiceOptions{
		Catalogs: NewCatalogRegistry(func([]string) (*cluster.Catalog, error) { return catalog, nil }),
		Sessions: sessions,
		Prober:   SessionProbeFunc(func(context.Context, *cluster.Session) error { return nil }),
	})
	opened, err := service.OpenSession(context.Background(), &kmgrv1.OpenSessionRequest{
		Context: requestContext("open-preserved"), ContextName: contextID,
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
	contextID := serviceContextID(t, catalog)
	factory := &serviceFactory{}
	sessions := cluster.NewSessionRegistry(factory)
	service := NewClusterService(ClusterServiceOptions{
		Catalogs: NewCatalogRegistry(func([]string) (*cluster.Catalog, error) { return catalog, nil }),
		Sessions: sessions,
		Prober:   SessionProbeFunc(func(context.Context, *cluster.Session) error { return nil }),
	})
	opened, err := service.OpenSession(context.Background(), &kmgrv1.OpenSessionRequest{
		Context: requestContext("open-force"), ContextName: contextID,
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

func TestWatchConnectionEmitsInitialAndCoalescedMonotonicTotals(t *testing.T) {
	t.Parallel()
	catalog := serviceCatalog(t)
	sessions := cluster.NewSessionRegistry(&serviceFactory{})
	t.Cleanup(sessions.CloseAll)
	session, err := sessions.Open(catalog, serviceContextID(t, catalog))
	if err != nil {
		t.Fatal(err)
	}
	activity := session.APIActivity()
	activity.AddReceived(10)
	activity.AddSent(4)
	service := NewClusterService(ClusterServiceOptions{Sessions: sessions})
	streamContext, cancel := context.WithCancel(context.Background())
	defer cancel()
	stream := newConnectionTestStream(streamContext)
	result := make(chan error, 1)
	go func() {
		result <- service.WatchConnection(&kmgrv1.WatchConnectionRequest{
			Context: &kmgrv1.RequestContext{
				RequestId: "activity", ClusterSessionId: session.ID(),
			},
			StreamId: "connection-1",
		}, stream)
	}()
	stream.waitForCount(t, 1)
	initial := stream.snapshot()[0]
	if initial.GetCursor().GetStreamId() != "connection-1" ||
		initial.GetCursor().GetGeneration() != 1 || initial.GetCursor().GetSequence() != 1 ||
		initial.GetApiBytesReceived() != 10 || initial.GetApiBytesSent() != 4 ||
		initial.GetState() != kmgrv1.ConnectionState_CONNECTION_STATE_CONNECTED {
		t.Fatalf("initial event = %#v", initial)
	}
	activity.AddReceived(2)
	activity.AddReceived(3)
	activity.AddSent(7)
	stream.waitForCount(t, 2)
	updated := stream.snapshot()[1]
	if updated.GetCursor().GetSequence() != 2 || updated.GetApiBytesReceived() != 15 ||
		updated.GetApiBytesSent() != 11 {
		t.Fatalf("updated event = %#v", updated)
	}
	if count := len(stream.snapshot()); count != 2 {
		t.Fatalf("burst emitted %d events, want coalesced initial + update", count)
	}
	cancel()
	if err := <-result; status.Code(err) != codes.Canceled {
		t.Fatalf("WatchConnection cancellation = %v", err)
	}

	secondContext, secondCancel := context.WithCancel(context.Background())
	secondStream := newConnectionTestStream(secondContext)
	secondResult := make(chan error, 1)
	go func() {
		secondResult <- service.WatchConnection(&kmgrv1.WatchConnectionRequest{
			Context: &kmgrv1.RequestContext{
				RequestId: "activity-2", ClusterSessionId: session.ID(),
			},
			StreamId: "connection-1",
		}, secondStream)
	}()
	secondStream.waitForCount(t, 1)
	if cursor := secondStream.snapshot()[0].GetCursor(); cursor.GetGeneration() <= initial.GetCursor().GetGeneration() || cursor.GetSequence() != 1 {
		t.Fatalf("second cursor = %#v", cursor)
	}
	secondCancel()
	<-secondResult
}

func TestWatchConnectionStopsWithEngineLifecycle(t *testing.T) {
	t.Parallel()
	catalog := serviceCatalog(t)
	sessions := cluster.NewSessionRegistry(&serviceFactory{})
	t.Cleanup(sessions.CloseAll)
	session, err := sessions.Open(catalog, serviceContextID(t, catalog))
	if err != nil {
		t.Fatal(err)
	}
	stopping := make(chan struct{})
	service := NewClusterService(ClusterServiceOptions{
		Sessions: sessions,
		Stopping: stopping,
	})
	stream := newConnectionTestStream(context.Background())
	result := make(chan error, 1)
	go func() {
		result <- service.WatchConnection(&kmgrv1.WatchConnectionRequest{
			Context: &kmgrv1.RequestContext{
				RequestId: "engine-stopping", ClusterSessionId: session.ID(),
			},
			StreamId: "connection-stopping",
		}, stream)
	}()
	stream.waitForCount(t, 1)
	close(stopping)
	select {
	case err := <-result:
		if err != nil {
			t.Fatalf("WatchConnection stopping error = %v", err)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("WatchConnection did not stop with the engine lifecycle")
	}
}

func TestWatchConnectionEmitsObservedTransportAndAuthenticationStates(t *testing.T) {
	t.Parallel()
	catalog := serviceCatalog(t)
	sessions := cluster.NewSessionRegistry(&serviceFactory{})
	t.Cleanup(sessions.CloseAll)
	session, err := sessions.Open(catalog, serviceContextID(t, catalog))
	if err != nil {
		t.Fatal(err)
	}
	service := NewClusterService(ClusterServiceOptions{Sessions: sessions})
	streamContext, cancel := context.WithCancel(context.Background())
	defer cancel()
	stream := newConnectionTestStream(streamContext)
	result := make(chan error, 1)
	go func() {
		result <- service.WatchConnection(&kmgrv1.WatchConnectionRequest{
			Context: &kmgrv1.RequestContext{
				RequestId: "health", ClusterSessionId: session.ID(),
			},
			StreamId: "connection-health",
		}, stream)
	}()
	stream.waitForCount(t, 1)

	activity := session.APIActivity()
	activity.ObserveRoundTrip(0, errors.New("do not expose this transport detail"))
	stream.waitForCount(t, 2)
	reconnecting := stream.snapshot()[1]
	if reconnecting.GetState() != kmgrv1.ConnectionState_CONNECTION_STATE_RECONNECTING ||
		reconnecting.GetError().GetReason() != "APITransportInterrupted" ||
		!reconnecting.GetError().GetRetryable() ||
		strings.Contains(reconnecting.GetError().GetMessage(), "do not expose") {
		t.Fatalf("reconnecting event = %#v", reconnecting)
	}

	activity.ObserveRoundTrip(http.StatusUnauthorized, nil)
	stream.waitForCount(t, 3)
	authentication := stream.snapshot()[2]
	if authentication.GetState() != kmgrv1.ConnectionState_CONNECTION_STATE_FAILED ||
		authentication.GetError().GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHENTICATION ||
		authentication.GetError().GetReason() != "AuthenticationRejected" {
		t.Fatalf("authentication event = %#v", authentication)
	}

	activity.ObserveRoundTrip(http.StatusOK, nil)
	stream.waitForCount(t, 4)
	recovered := stream.snapshot()[3]
	if recovered.GetState() != kmgrv1.ConnectionState_CONNECTION_STATE_CONNECTED || recovered.GetError() != nil {
		t.Fatalf("recovered event = %#v", recovered)
	}
	cancel()
	if err := <-result; status.Code(err) != codes.Canceled {
		t.Fatalf("WatchConnection cancellation = %v", err)
	}
}

func TestWatchConnectionEmitsWarmCacheChangesWithoutNetworkActivity(t *testing.T) {
	t.Parallel()
	catalog := serviceCatalog(t)
	sessions := cluster.NewSessionRegistry(&serviceFactory{})
	t.Cleanup(sessions.CloseAll)
	session, err := sessions.Open(catalog, serviceContextID(t, catalog))
	if err != nil {
		t.Fatal(err)
	}
	service := NewClusterService(ClusterServiceOptions{Sessions: sessions})
	streamContext, cancel := context.WithCancel(context.Background())
	defer cancel()
	stream := newConnectionTestStream(streamContext)
	result := make(chan error, 1)
	go func() {
		result <- service.WatchConnection(&kmgrv1.WatchConnectionRequest{
			Context: &kmgrv1.RequestContext{
				RequestId: "warm-cache", ClusterSessionId: session.ID(),
			},
			StreamId: "connection-warm-cache",
		}, stream)
	}()
	stream.waitForCount(t, 1)

	authority := cluster.WarmCacheUsage{
		RetainedViews: 2, RetainedObjects: 300, RetainedBytes: 4_096,
		ViewLimit: 8, ObjectLimit: 100_000, ByteLimit: 1 << 30,
		BudgetEvictions: 3,
	}
	global := cluster.WarmCacheUsage{
		RetainedViews: 4, RetainedObjects: 900, RetainedBytes: 16_384,
		ViewLimit: 24, ObjectLimit: 250_000, ByteLimit: 2 << 30,
		BudgetEvictions: 5,
	}
	sessions.SetWarmCacheTelemetry(cluster.WarmCacheTelemetry{
		Global: global,
		AuthorityBudget: cluster.WarmCacheUsage{
			ViewLimit: 8, ObjectLimit: 100_000, ByteLimit: 1 << 30,
		},
		Authorities: map[string]cluster.WarmCacheUsage{
			session.AuthorityID(): authority,
		},
	})
	stream.waitForCount(t, 2)
	event := stream.snapshot()[1]
	if event.GetApiBytesReceived() != 0 || event.GetApiBytesSent() != 0 ||
		event.GetAuthorityWarmCache().GetRetainedViews() != 2 ||
		event.GetAuthorityWarmCache().GetRetainedObjects() != 300 ||
		event.GetAuthorityWarmCache().GetRetainedBytes() != 4_096 ||
		event.GetAuthorityWarmCache().GetViewLimit() != 8 ||
		event.GetAuthorityWarmCache().GetBudgetEvictions() != 3 ||
		event.GetGlobalWarmCache().GetRetainedViews() != 4 ||
		event.GetGlobalWarmCache().GetBudgetEvictions() != 5 {
		t.Fatalf("warm-cache connection event = %#v", event)
	}
	cancel()
	if err := <-result; status.Code(err) != codes.Canceled {
		t.Fatalf("WatchConnection cancellation = %v", err)
	}
}

func TestWatchConnectionLeaseSurvivesPreservingWorkspaceClose(t *testing.T) {
	t.Parallel()
	catalog := serviceCatalog(t)
	factory := &serviceFactory{}
	sessions := cluster.NewSessionRegistry(factory)
	session, err := sessions.Open(catalog, serviceContextID(t, catalog))
	if err != nil {
		t.Fatal(err)
	}
	service := NewClusterService(ClusterServiceOptions{Sessions: sessions})
	streamContext, cancel := context.WithCancel(context.Background())
	stream := newConnectionTestStream(streamContext)
	result := make(chan error, 1)
	go func() {
		result <- service.WatchConnection(&kmgrv1.WatchConnectionRequest{
			Context: &kmgrv1.RequestContext{
				RequestId: "activity", ClusterSessionId: session.ID(),
			},
			StreamId: "connection",
		}, stream)
	}()
	stream.waitForCount(t, 1)
	if !sessions.CloseWorkspace(session.ID()) || factory.closeCount() != 0 {
		t.Fatal("workspace close did not preserve the activity stream lease")
	}
	cancel()
	<-result
	deadline := time.Now().Add(time.Second)
	for factory.closeCount() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if factory.closeCount() != 1 {
		t.Fatal("activity stream release did not retire its closed session")
	}
}

func TestWatchConnectionValidatesRequest(t *testing.T) {
	t.Parallel()
	service := NewClusterService(ClusterServiceOptions{Sessions: cluster.NewSessionRegistry(nil)})
	stream := newConnectionTestStream(context.Background())
	if err := service.WatchConnection(nil, stream); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("nil request = %v", err)
	}
	if err := service.WatchConnection(&kmgrv1.WatchConnectionRequest{
		Context: &kmgrv1.RequestContext{RequestId: "request", ClusterSessionId: "missing"},
	}, stream); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("empty stream ID = %v", err)
	}
	if err := service.WatchConnection(&kmgrv1.WatchConnectionRequest{
		Context:  &kmgrv1.RequestContext{RequestId: "request", ClusterSessionId: "missing"},
		StreamId: "connection",
	}, stream); status.Code(err) != codes.NotFound {
		t.Fatalf("missing session = %v", err)
	}
}

type connectionTestStream struct {
	ctx    context.Context
	mu     sync.Mutex
	events []*kmgrv1.ConnectionEvent
}

func newConnectionTestStream(ctx context.Context) *connectionTestStream {
	return &connectionTestStream{ctx: ctx}
}

func (s *connectionTestStream) Send(event *kmgrv1.ConnectionEvent) error {
	s.mu.Lock()
	s.events = append(s.events, event)
	s.mu.Unlock()
	return nil
}

func (s *connectionTestStream) SetHeader(metadata.MD) error  { return nil }
func (s *connectionTestStream) SendHeader(metadata.MD) error { return nil }
func (s *connectionTestStream) SetTrailer(metadata.MD)       {}
func (s *connectionTestStream) Context() context.Context     { return s.ctx }
func (s *connectionTestStream) SendMsg(any) error            { return errors.New("unexpected SendMsg") }
func (s *connectionTestStream) RecvMsg(any) error            { return errors.New("unexpected RecvMsg") }

func (s *connectionTestStream) snapshot() []*kmgrv1.ConnectionEvent {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]*kmgrv1.ConnectionEvent(nil), s.events...)
}

func (s *connectionTestStream) waitForCount(t *testing.T, count int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if len(s.snapshot()) >= count {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("stream received %d events, want at least %d", len(s.snapshot()), count)
}

var _ grpc.ServerStreamingServer[kmgrv1.ConnectionEvent] = (*connectionTestStream)(nil)

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

func TestDiscoveryWarningIsStructuredAndRedactsServerMessages(t *testing.T) {
	t.Parallel()
	secret := "credential=never-forward-this"
	warning := discoveryWarning([]cluster.DiscoveryFailure{{
		Target: "metrics.k8s.io/v1beta1",
		Err: &apierrors.StatusError{ErrStatus: metav1.Status{
			Status:  metav1.StatusFailure,
			Reason:  metav1.StatusReasonServiceUnavailable,
			Message: secret,
			Code:    503,
			Details: &metav1.StatusDetails{Causes: []metav1.StatusCause{{
				Type: metav1.CauseTypeUnexpectedServerResponse, Message: secret,
			}}},
		}},
	}}, "local")

	if warning.GetReason() != "DiscoveryPartiallyFailed" ||
		warning.GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE ||
		warning.GetHttpStatusCode() != 503 || !warning.GetRetryable() {
		t.Fatalf("warning envelope = %#v", warning)
	}
	if warning.GetSafeDetails()["failed_group_versions"] != "metrics.k8s.io/v1beta1" ||
		warning.GetSafeDetails()["failed_group_version_count"] != "1" {
		t.Fatalf("warning details = %#v", warning.GetSafeDetails())
	}
	if strings.Contains(warning.String(), secret) ||
		warning.GetKubernetesStatus().GetMessage() != "" ||
		warning.GetKubernetesStatus().GetCauses()[0].GetMessage() != "" {
		t.Fatalf("warning exposed an arbitrary Kubernetes response message: %#v", warning)
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

func serviceProbeCatalog(t *testing.T, serverURL, token string) *cluster.Catalog {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config")
	contents := []byte(fmt.Sprintf(`
apiVersion: v1
kind: Config
clusters:
- name: target
  cluster:
    server: %s
    insecure-skip-tls-verify: true
users:
- name: static
  user:
    token: %s
contexts:
- name: local
  context: {cluster: target, user: static}
current-context: local
`, serverURL, token))
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

func serviceContextID(t *testing.T, catalog *cluster.Catalog) string {
	t.Helper()
	for _, info := range catalog.Contexts() {
		if info.Name == "local" {
			return info.ID
		}
	}
	t.Fatal("local context was not found")
	return ""
}
