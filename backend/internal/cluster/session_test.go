package cluster

import (
	"math"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"k8s.io/client-go/rest"
)

type recordingFactory struct {
	mu      sync.Mutex
	configs []*rest.Config
	closes  int
}

func (f *recordingFactory) New(config *rest.Config) (BackendClients, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.configs = append(f.configs, rest.CopyConfig(config))
	return BackendClients{Close: func() {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.closes++
	}}, nil
}

func TestSessionRegistryOpensIndependentSessionsWithSharedClients(t *testing.T) {
	t.Parallel()
	catalog := testCatalog(t, "https://cluster.example.test")
	contextID := requireContextNamed(t, catalog, "local").ID
	factory := &recordingFactory{}
	registry := NewSessionRegistry(factory)
	t.Cleanup(registry.CloseAll)

	first, err := registry.Open(catalog, contextID)
	if err != nil {
		t.Fatalf("Open first: %v", err)
	}
	second, err := registry.Open(catalog, contextID)
	if err != nil {
		t.Fatalf("Open second: %v", err)
	}
	if first.ID() == second.ID() {
		t.Fatal("two workspace windows received the same session ID")
	}
	if first.backend != second.backend {
		t.Fatal("same catalog/context did not share Kubernetes authority")
	}
	if first.APIActivity() == nil || first.APIActivity() != second.APIActivity() {
		t.Fatal("same Kubernetes authority did not share one activity counter")
	}
	if len(factory.configs) != 1 {
		t.Fatalf("client factory calls = %d, want 1", len(factory.configs))
	}
	config := factory.configs[0]
	if config.QPS != DefaultClientQPS || config.Burst != DefaultClientBurst {
		t.Fatalf("rate limit = %v/%d", config.QPS, config.Burst)
	}
	if config.RateLimiter == nil || config.RateLimiter.QPS() != DefaultClientQPS {
		t.Fatalf("shared rate limiter = %#v", config.RateLimiter)
	}
	if first.RESTConfig().RateLimiter != config.RateLimiter ||
		second.RESTConfig().RateLimiter != config.RateLimiter {
		t.Fatal("same authority did not retain one limiter for Table/subresource clients")
	}
	if config.UserAgent != "kmgr-engine" {
		t.Fatalf("user agent = %q", config.UserAgent)
	}

	if !registry.Close(first.ID()) || factory.closes != 0 {
		t.Fatal("closing one session closed shared clients")
	}
	if _, ok := registry.Get(second.ID()); !ok {
		t.Fatal("second session disappeared")
	}
	if !registry.Close(second.ID()) || factory.closes != 1 {
		t.Fatalf("final close count = %d, want 1", factory.closes)
	}
	if registry.Close(second.ID()) {
		t.Fatal("closing an absent session succeeded")
	}
}

func TestDifferentAuthoritiesDoNotShareActivityCounters(t *testing.T) {
	t.Parallel()
	firstCatalog := testCatalog(t, "https://first.example.test")
	secondCatalog := testCatalog(t, "https://second.example.test")
	registry := NewSessionRegistry(&recordingFactory{})
	t.Cleanup(registry.CloseAll)
	first, err := registry.Open(firstCatalog, requireContextNamed(t, firstCatalog, "local").ID)
	if err != nil {
		t.Fatal(err)
	}
	second, err := registry.Open(secondCatalog, requireContextNamed(t, secondCatalog, "local").ID)
	if err != nil {
		t.Fatal(err)
	}
	first.APIActivity().AddReceived(9)
	if first.APIActivity() == second.APIActivity() || second.APIActivity().Snapshot().BytesReceived != 0 {
		t.Fatal("independent Kubernetes authorities shared activity totals")
	}
}

func TestDifferentCatalogSnapshotsDoNotSilentlyReuseCredentials(t *testing.T) {
	t.Parallel()
	firstCatalog := testCatalog(t, "https://cluster.example.test")
	secondCatalog := testCatalog(t, "https://cluster.example.test")
	factory := &recordingFactory{}
	registry := NewSessionRegistry(factory)
	t.Cleanup(registry.CloseAll)
	if _, err := registry.Open(firstCatalog, requireContextNamed(t, firstCatalog, "local").ID); err != nil {
		t.Fatalf("Open first: %v", err)
	}
	if _, err := registry.Open(secondCatalog, requireContextNamed(t, secondCatalog, "local").ID); err != nil {
		t.Fatalf("Open second: %v", err)
	}
	if len(factory.configs) != 2 {
		t.Fatalf("client factory calls = %d, want 2 catalog generations", len(factory.configs))
	}
	if factory.configs[0].RateLimiter == nil || factory.configs[1].RateLimiter == nil ||
		factory.configs[0].RateLimiter == factory.configs[1].RateLimiter {
		t.Fatal("independent Kubernetes authorities did not receive independent limiters")
	}
}

func TestSessionRegistryRejectsUnsupportedAuthenticationBeforeFactory(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "config")
	contents := `
apiVersion: v1
kind: Config
clusters:
- name: target
  cluster: {server: https://cluster.example.test}
users:
- name: plugin
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1
      command: never-run
      interactiveMode: Never
contexts:
- name: local
  context: {cluster: target, user: plugin}
`
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	catalog := discoverExplicit(t, path)
	factory := &recordingFactory{}
	registry := NewSessionRegistry(factory)
	if _, err := registry.Open(catalog, requireContextNamed(t, catalog, "local").ID); err == nil {
		t.Fatal("unsupported authentication was accepted")
	}
	if len(factory.configs) != 0 {
		t.Fatal("client factory ran for unsupported authentication")
	}
}

func TestSessionRegistryRateLimitCanOnlyChangeWhileIdle(t *testing.T) {
	t.Parallel()
	catalog := testCatalog(t, "https://cluster.example.test")
	contextID := requireContextNamed(t, catalog, "local").ID
	registry := NewSessionRegistry(&recordingFactory{})
	if err := registry.SetRateLimit(100, 200); err != nil {
		t.Fatalf("SetRateLimit idle: %v", err)
	}
	session, err := registry.Open(catalog, contextID)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := registry.SetRateLimit(1, 1); err == nil {
		t.Fatal("rate limit changed with an open session")
	}
	registry.Close(session.ID())
	for _, qps := range []float32{0, -1, float32(math.NaN()), float32(math.Inf(1))} {
		if err := registry.SetRateLimit(qps, 1); err == nil {
			t.Errorf("invalid QPS %v was accepted", qps)
		}
	}
	if err := registry.SetRateLimit(1, 0); err == nil {
		t.Fatal("invalid burst was accepted")
	}
}

func TestSessionRegistryUsesConfiguredFractionalRateLimit(t *testing.T) {
	t.Parallel()
	catalog := testCatalog(t, "https://cluster.example.test")
	factory := &recordingFactory{}
	registry := NewSessionRegistry(factory)
	t.Cleanup(registry.CloseAll)
	if err := registry.SetRateLimit(12.5, 37); err != nil {
		t.Fatalf("SetRateLimit: %v", err)
	}
	session, err := registry.Open(catalog, requireContextNamed(t, catalog, "local").ID)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if len(factory.configs) != 1 {
		t.Fatalf("client factory calls = %d, want 1", len(factory.configs))
	}
	config := factory.configs[0]
	if config.QPS != 12.5 || config.Burst != 37 {
		t.Fatalf("configured rate limit = %v/%d", config.QPS, config.Burst)
	}
	if config.RateLimiter == nil || config.RateLimiter.QPS() != 12.5 {
		t.Fatalf("configured shared limiter = %#v", config.RateLimiter)
	}
	if session.RESTConfig().RateLimiter != config.RateLimiter {
		t.Fatal("subresource configuration replaced the authority limiter")
	}
}

func TestWorkspaceCloseKeepsSessionUntilIndependentLeasesRelease(t *testing.T) {
	t.Parallel()
	catalog := testCatalog(t, "https://cluster.example.test")
	contextID := requireContextNamed(t, catalog, "local").ID
	factory := &recordingFactory{}
	registry := NewSessionRegistry(factory)
	t.Cleanup(registry.CloseAll)
	session, err := registry.Open(catalog, contextID)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	_, first, ok := registry.Acquire(session.ID())
	if !ok {
		t.Fatal("Acquire first lease failed")
	}
	_, second, ok := registry.Acquire(session.ID())
	if !ok {
		t.Fatal("Acquire second lease failed")
	}
	if !registry.CloseWorkspace(session.ID()) {
		t.Fatal("CloseWorkspace rejected open workspace")
	}
	if _, ok := registry.Get(session.ID()); ok {
		t.Fatal("closed workspace remained available through Get")
	}
	if _, lease, ok := registry.Acquire(session.ID()); ok || lease != nil {
		t.Fatal("closed workspace accepted a new independent lease")
	}
	if factory.closes != 0 {
		t.Fatalf("backend close count = %d before final release", factory.closes)
	}
	if registry.CloseWorkspace(session.ID()) {
		t.Fatal("workspace lease was released twice")
	}
	first.Release()
	first.Release()
	if _, ok := registry.Get(session.ID()); ok || factory.closes != 0 {
		t.Fatal("first idempotent release closed a multiply leased session")
	}
	second.Release()
	if _, ok := registry.Get(session.ID()); ok {
		t.Fatal("session survived its final lease")
	}
	if factory.closes != 1 {
		t.Fatalf("backend close count = %d, want 1", factory.closes)
	}
	if _, lease, ok := registry.Acquire(session.ID()); ok || lease != nil {
		t.Fatal("acquired a removed session")
	}
}

func TestForceCloseInvalidatesSessionWithIndependentLease(t *testing.T) {
	t.Parallel()
	catalog := testCatalog(t, "https://cluster.example.test")
	contextID := requireContextNamed(t, catalog, "local").ID
	factory := &recordingFactory{}
	registry := NewSessionRegistry(factory)
	t.Cleanup(registry.CloseAll)
	session, err := registry.Open(catalog, contextID)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	_, lease, ok := registry.Acquire(session.ID())
	if !ok {
		t.Fatal("Acquire: session missing")
	}
	if !registry.Close(session.ID()) {
		t.Fatal("force close rejected")
	}
	if _, ok := registry.Get(session.ID()); ok {
		t.Fatal("force-closed session remained registered")
	}
	if factory.closes != 1 {
		t.Fatalf("backend close count = %d, want 1", factory.closes)
	}
	lease.Release()
	lease.Release()
	if factory.closes != 1 {
		t.Fatalf("late lease release closed backend again: %d", factory.closes)
	}
}

func TestWorkspaceCloseWithoutIndependentLeaseDoesNotRetainSession(t *testing.T) {
	t.Parallel()
	catalog := testCatalog(t, "https://cluster.example.test")
	contextID := requireContextNamed(t, catalog, "local").ID
	factory := &recordingFactory{}
	registry := NewSessionRegistry(factory)
	session, err := registry.Open(catalog, contextID)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if !registry.CloseWorkspace(session.ID()) {
		t.Fatal("CloseWorkspace rejected")
	}
	if _, ok := registry.Get(session.ID()); ok {
		t.Fatal("closed idle workspace was retained")
	}
	if factory.closes != 1 {
		t.Fatalf("backend close count = %d, want 1", factory.closes)
	}
}

func testCatalog(t *testing.T, server string) *Catalog {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config")
	contents := `
apiVersion: v1
kind: Config
clusters:
- name: target
  cluster:
    server: ` + server + `
users:
- name: static
  user: {token: token}
contexts:
- name: local
  context: {cluster: target, user: static}
current-context: local
`
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	return discoverExplicit(t, path)
}
