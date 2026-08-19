package operation

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/object"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	"k8s.io/client-go/rest"
)

func TestAcceptedOperationUsesAndReleasesIndependentBackendLease(t *testing.T) {
	observedContext := make(chan context.Context, 1)
	leasedBackend := &fakeYAMLEditor{
		block: make(chan struct{}), applyContext: observedContext, contextName: "leased-context",
	}
	released := make(chan struct{}, 1)
	acquirer := mutationBackendAcquirerFunc(func(sessionID string) (AcquiredMutationBackend, error) {
		if sessionID != "session" {
			t.Fatalf("acquired session ID = %q", sessionID)
		}
		return AcquiredMutationBackend{
			Backend: leasedBackend, ContextName: "leased-context",
			Release: func() { released <- struct{}{} },
		}, nil
	})
	baseBackend := &fakeYAMLEditor{}
	service, err := NewGRPCService(baseBackend, nil, acquirer)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(service.manager.Close)
	response, err := service.ApplyYaml(context.Background(), &kmgrv1.ApplyYamlRequest{
		Context: operationContext("lease-start"), OperationId: "leased-operation",
		Identity: operationIdentity(), YamlUtf8: []byte("kind: ConfigMap"),
		ExpectedResourceVersion: "rv-1", FieldManager: object.YAMLFieldManager,
	})
	if err != nil || !response.GetAccepted() {
		t.Fatalf("start response = %#v, error = %v", response, err)
	}
	select {
	case <-observedContext:
	case <-time.After(time.Second):
		t.Fatal("accepted operation did not use the leased backend")
	}
	select {
	case <-released:
		t.Fatal("backend lease was released before terminal operation state")
	default:
	}
	ack, err := service.CancelOperation(context.Background(), &kmgrv1.CancelOperationRequest{
		Context: operationContext("lease-cancel"), OperationId: "leased-operation",
	})
	if err != nil || !ack.GetAccepted() {
		t.Fatalf("cancel response = %#v, error = %v", ack, err)
	}
	select {
	case <-released:
	case <-time.After(time.Second):
		t.Fatal("terminal operation did not release its backend lease")
	}
	baseBackend.mu.Lock()
	defer baseBackend.mu.Unlock()
	if baseBackend.lastPayload != "" {
		t.Fatal("accepted operation used the unleased workspace backend")
	}
}

type mutationBackendAcquirerFunc func(string) (AcquiredMutationBackend, error)

func (f mutationBackendAcquirerFunc) AcquireMutationBackend(sessionID string) (AcquiredMutationBackend, error) {
	return f(sessionID)
}

func TestClusterMutationBackendLeaseSurvivesWorkspaceClose(t *testing.T) {
	t.Parallel()
	value := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1",
		"kind":       "ConfigMap",
		"metadata": map[string]any{
			"namespace": "ns",
			"name":      "settings",
			"uid":       "uid-settings",
		},
	}}
	factory := &mutationLeaseClientFactory{
		dynamic: dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), value),
	}
	registry := cluster.NewSessionRegistry(factory)
	t.Cleanup(registry.CloseAll)
	catalog := mutationLeaseCatalog(t)
	contextID := mutationLeaseContextID(t, catalog, "local")
	session, err := registry.Open(catalog, contextID)
	if err != nil {
		t.Fatal(err)
	}

	acquired, err := (ClusterMutationBackendAcquirer{Sessions: registry}).AcquireMutationBackend(session.ID())
	if err != nil {
		t.Fatal(err)
	}
	if acquired.ContextName != "local" {
		t.Fatalf("acquired context name = %q", acquired.ContextName)
	}
	if !registry.CloseWorkspace(session.ID()) {
		t.Fatal("workspace close was rejected")
	}
	if _, ok := registry.Get(session.ID()); ok {
		t.Fatal("closed workspace remained available for new work")
	}
	identity := object.Identity{
		SessionID: session.ID(), Version: "v1", Resource: "configmaps", Namespace: "ns",
		Name: "settings", UID: "uid-settings",
	}
	got, err := acquired.Backend.Get(context.Background(), identity)
	if err != nil || got.GetUID() != types.UID(identity.UID) {
		t.Fatalf("leased backend Get = %#v, %v", got, err)
	}
	if factory.closes.Load() != 0 {
		t.Fatal("workspace close released a backend still owned by a mutation")
	}
	if _, err := (ClusterMutationBackendAcquirer{Sessions: registry}).AcquireMutationBackend(session.ID()); !errors.Is(err, object.ErrSessionNotFound) {
		t.Fatalf("new acquisition after workspace close = %v", err)
	}

	acquired.Release()
	acquired.Release()
	if factory.closes.Load() != 1 {
		t.Fatalf("backend close count = %d, want 1", factory.closes.Load())
	}
}

type mutationLeaseClientFactory struct {
	dynamic dynamic.Interface
	closes  atomic.Int32
}

func (f *mutationLeaseClientFactory) New(*rest.Config) (cluster.BackendClients, error) {
	return cluster.BackendClients{
		Dynamic: f.dynamic,
		Close:   func() { f.closes.Add(1) },
	}, nil
}

func mutationLeaseCatalog(t *testing.T) *cluster.Catalog {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config")
	contents := `
apiVersion: v1
kind: Config
clusters:
- name: target
  cluster: {server: https://cluster.example.test}
users:
- name: static
  user: {token: token}
contexts:
- name: local
  context: {cluster: target, user: static, namespace: ns}
current-context: local
`
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	catalog, err := cluster.DiscoverPaths([]string{path})
	if err != nil {
		t.Fatal(err)
	}
	return catalog
}

func mutationLeaseContextID(t *testing.T, catalog *cluster.Catalog, name string) string {
	t.Helper()
	for _, info := range catalog.Contexts() {
		if info.Name == name {
			return info.ID
		}
	}
	t.Fatalf("context %q was not found", name)
	return ""
}
