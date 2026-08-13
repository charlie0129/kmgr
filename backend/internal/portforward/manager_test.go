package portforward

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"k8s.io/apimachinery/pkg/types"
)

func TestStartDefaultsLoopbackAndReportsRaceFreeAllocatedPort(t *testing.T) {
	t.Parallel()
	resolver := &sequenceResolver{results: []resolveResult{{target: podIdentity("pod", "pod-uid")}}}
	forwarder := &fakeForwarder{ports: []uint16{43123}}
	manager := testManager(t, resolver, forwarder)
	defer manager.Close()
	started, err := manager.Start(StartRequest{
		ID: "forward", Target: podIdentity("pod", "pod-uid"), RemotePort: 8080,
	})
	if err != nil {
		t.Fatal(err)
	}
	if started.BindAddress != "127.0.0.1" || started.LocalPort != 0 {
		t.Fatalf("started = %#v", started)
	}
	eventuallyForward(t, func() bool {
		values := manager.List("", false)
		return len(values) == 1 && values[0].State == StateListening && values[0].LocalPort == 43123
	})
	forwarder.mu.Lock()
	defer forwarder.mu.Unlock()
	if len(forwarder.requests) != 1 || forwarder.requests[0].LocalPort != 0 ||
		forwarder.requests[0].BindAddress != "127.0.0.1" {
		t.Fatalf("forward requests = %#v", forwarder.requests)
	}
}

func TestNonLoopbackRequiresApprovalAndRetainsExposureMetadata(t *testing.T) {
	t.Parallel()
	manager := testManager(t, &sequenceResolver{}, &fakeForwarder{})
	defer manager.Close()
	request := StartRequest{
		ID: "public", Target: podIdentity("pod", "uid"), RemotePort: 80, BindAddress: "0.0.0.0",
	}
	if _, err := manager.Start(request); !errors.Is(err, ErrNonLoopbackUnapproved) {
		t.Fatalf("unapproved error = %v", err)
	}
	request.AllowNonLoopback = true
	requestResolver := &sequenceResolver{results: []resolveResult{{target: podIdentity("pod", "uid")}}}
	manager.config.Sessions = staticSessionResolver{session: Session{ContextName: "context", Resolver: requestResolver, Forwarder: &fakeForwarder{ports: []uint16{80}}}}
	started, err := manager.Start(request)
	if err != nil {
		t.Fatal(err)
	}
	if !started.NonLoopbackBind {
		t.Fatalf("started = %#v", started)
	}
}

func TestDirectPodReconnectsAfterTransportFailureButNeverSwitchesUID(t *testing.T) {
	t.Parallel()
	resolver := &sequenceResolver{results: []resolveResult{
		{target: podIdentity("pod", "old-uid")},
		{target: podIdentity("pod", "new-uid")},
	}}
	forwarder := &fakeForwarder{ports: []uint16{8080}, waitErrors: []error{errors.New("connection lost")}}
	backoff := &recordingBackoff{}
	manager, err := NewManager(Config{
		Sessions: staticSessionResolver{session: Session{
			ContextName: "context", Resolver: resolver, Forwarder: forwarder,
		}},
		Backoff: backoff,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	updates, unsubscribe := manager.Subscribe()
	defer unsubscribe()
	_, err = manager.Start(StartRequest{
		ID: "pod-forward", Target: podIdentity("pod", "old-uid"), RemotePort: 8080,
	})
	if err != nil {
		t.Fatal(err)
	}
	states := forwardStatesUntil(t, updates, func(snapshot Snapshot) bool {
		return snapshot.State == StateFailed
	})
	assertForwardStatePresent(t, states, StateReconnecting)
	resolver.mu.Lock()
	calls := resolver.calls
	resolver.mu.Unlock()
	if calls != 2 {
		t.Fatalf("direct Pod resolution calls = %d, want retry to verify UID", calls)
	}
	failed := manager.List("", true)[0]
	if !errors.Is(failed.LastError, ErrPodRecreated) {
		t.Fatalf("terminal error = %v, want ErrPodRecreated", failed.LastError)
	}
	if backoff.Calls() != 1 {
		t.Fatalf("backoff calls = %d, want one before UID verification", backoff.Calls())
	}
	forwarder.mu.Lock()
	startCalls := len(forwarder.requests)
	forwarder.mu.Unlock()
	if startCalls != 1 {
		t.Fatalf("recreated Pod reached forwarder: calls = %d", startCalls)
	}
}

func TestDirectPodTransportFailureReconnectsSameUID(t *testing.T) {
	t.Parallel()
	resolver := &sequenceResolver{results: []resolveResult{
		{target: podIdentity("pod", "pod-uid")},
		{target: podIdentity("pod", "pod-uid")},
	}}
	forwarder := &fakeForwarder{
		ports: []uint16{43123, 43123}, waitErrors: []error{errors.New("connection lost")},
	}
	backoff := &recordingBackoff{}
	manager, err := NewManager(Config{
		Sessions: staticSessionResolver{session: Session{
			ContextName: "context", Resolver: resolver, Forwarder: forwarder,
		}},
		Backoff: backoff,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	if _, err := manager.Start(StartRequest{
		ID: "same-pod", Target: podIdentity("pod", "pod-uid"), RemotePort: 8080,
	}); err != nil {
		t.Fatal(err)
	}
	eventuallyForward(t, func() bool {
		forwarder.mu.Lock()
		defer forwarder.mu.Unlock()
		return len(forwarder.requests) == 2 && manager.List("", true)[0].State == StateListening
	})
	if got := backoff.Calls(); got != 1 {
		t.Fatalf("backoff calls = %d, want 1", got)
	}
	resolver.mu.Lock()
	calls := resolver.calls
	resolver.mu.Unlock()
	if calls != 2 {
		t.Fatalf("resolve calls = %d, want fresh UID verification", calls)
	}
	assertForwardedPodUIDs(t, forwarder, "pod-uid", "pod-uid")
}

func TestDirectPodTransientFailuresRetryPastFormerLimit(t *testing.T) {
	t.Parallel()
	const transientFailures = 12
	results := make([]resolveResult, 0, transientFailures+1)
	for range transientFailures {
		results = append(results, resolveResult{err: errors.New("temporary API failure")})
	}
	results = append(results, resolveResult{target: podIdentity("pod", "pod-uid")})
	resolver := &sequenceResolver{results: results}
	forwarder := &fakeForwarder{ports: []uint16{43123}}
	backoff := &recordingBackoff{}
	manager, err := NewManager(Config{
		Sessions: staticSessionResolver{session: Session{
			ContextName: "context", Resolver: resolver, Forwarder: forwarder,
		}},
		Backoff: backoff,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	if _, err := manager.Start(StartRequest{
		ID: "persistent", Target: podIdentity("pod", "pod-uid"), RemotePort: 8080,
	}); err != nil {
		t.Fatal(err)
	}
	eventuallyForward(t, func() bool {
		values := manager.List("", true)
		return len(values) == 1 && values[0].State == StateListening
	})
	if got := backoff.Calls(); got != transientFailures {
		t.Fatalf("backoff calls = %d, want %d", got, transientFailures)
	}
	resolver.mu.Lock()
	calls := resolver.calls
	resolver.mu.Unlock()
	if calls != transientFailures+1 {
		t.Fatalf("resolve calls = %d, want %d", calls, transientFailures+1)
	}
}

func TestStopCancelsRetryBackoff(t *testing.T) {
	t.Parallel()
	resolver := &sequenceResolver{results: []resolveResult{{err: errors.New("temporary API failure")}}}
	backoff := newBlockingBackoff()
	manager, err := NewManager(Config{
		Sessions: staticSessionResolver{session: Session{
			ContextName: "context", Resolver: resolver, Forwarder: &fakeForwarder{},
		}},
		Backoff: backoff,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	if _, err := manager.Start(StartRequest{
		ID: "cancel-retry", Target: podIdentity("pod", "pod-uid"), RemotePort: 8080,
	}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-backoff.entered:
	case <-time.After(time.Second):
		t.Fatal("retry did not enter backoff")
	}
	if !manager.Stop("cancel-retry", "session") {
		t.Fatal("stop rejected")
	}
	eventuallyForward(t, func() bool {
		return manager.List("", true)[0].State == StateStopped
	})
	resolver.mu.Lock()
	calls := resolver.calls
	resolver.mu.Unlock()
	if calls != 1 {
		t.Fatalf("resolve calls after stop = %d, want no post-cancellation retry", calls)
	}
}

func TestServiceReResolvesNewPodWithBackoff(t *testing.T) {
	t.Parallel()
	resolver := &sequenceResolver{results: []resolveResult{
		{target: podIdentity("pod-a", "uid-a")},
		{target: podIdentity("pod-b", "uid-b")},
	}}
	forwarder := &fakeForwarder{
		ports: []uint16{43210, 43210}, waitErrors: []error{errors.New("lost"), nil},
	}
	backoff := &recordingBackoff{}
	manager, err := NewManager(Config{
		Sessions: staticSessionResolver{session: Session{ContextName: "context", Resolver: resolver, Forwarder: forwarder}},
		Backoff:  backoff,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	_, err = manager.Start(StartRequest{
		ID: "service-forward", Target: serviceIdentity("api", "service-uid"), RemotePort: 80,
	})
	if err != nil {
		t.Fatal(err)
	}
	eventuallyForward(t, func() bool {
		value := manager.List("", true)[0]
		return value.State == StateListening && value.ResolvedPod != nil && value.ResolvedPod.UID == "uid-b"
	})
	if backoff.Calls() != 1 {
		t.Fatalf("backoff calls = %d", backoff.Calls())
	}
	forwarder.mu.Lock()
	defer forwarder.mu.Unlock()
	if len(forwarder.requests) != 2 || forwarder.requests[1].LocalPort != 43210 {
		t.Fatalf("forward requests = %#v", forwarder.requests)
	}
}

func TestStopListWatchAndRestartAreRaceSafe(t *testing.T) {
	t.Parallel()
	resolver := &sequenceResolver{results: []resolveResult{{target: podIdentity("pod", "uid")}, {target: podIdentity("pod", "uid")}}}
	forwarder := &fakeForwarder{ports: []uint16{12345, 12345}}
	manager := testManager(t, resolver, forwarder)
	updates, unsubscribe := manager.Subscribe()
	defer unsubscribe()
	_, err := manager.Start(StartRequest{ID: "forward", Target: podIdentity("pod", "uid"), RemotePort: 8080})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case update := <-updates:
		if update.ID != "forward" {
			t.Fatalf("update = %#v", update)
		}
	case <-time.After(time.Second):
		t.Fatal("watch did not receive start")
	}
	if !manager.Stop("forward", "session") {
		t.Fatal("stop rejected")
	}
	eventuallyForward(t, func() bool { return manager.List("", true)[0].State == StateStopped })
	if len(manager.List("", false)) != 0 {
		t.Fatal("stopped forward included without includeStopped")
	}
	if !manager.Restart("forward", "session") {
		t.Fatal("restart rejected")
	}
	eventuallyForward(t, func() bool { return manager.List("", true)[0].State == StateListening })
	manager.Close()
	if _, err := manager.Start(StartRequest{ID: "late", Target: podIdentity("pod", "uid"), RemotePort: 1}); !errors.Is(err, ErrManagerClosed) {
		t.Fatalf("start after close error = %v", err)
	}
}

type staticSessionResolver struct {
	session Session
	err     error
}

func (r staticSessionResolver) ResolveSession(string) (Session, error) { return r.session, r.err }

type resolveResult struct {
	target Identity
	err    error
	port   uint16
}

type sequenceResolver struct {
	mu      sync.Mutex
	results []resolveResult
	calls   int
}

func (r *sequenceResolver) Resolve(_ context.Context, _ Identity, remotePort uint16) (ResolvedTarget, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	index := min(r.calls, max(0, len(r.results)-1))
	r.calls++
	if len(r.results) == 0 {
		return ResolvedTarget{}, ErrNoEligiblePod
	}
	result := r.results[index]
	if result.port == 0 {
		result.port = remotePort
	}
	return ResolvedTarget{Pod: result.target, RemotePort: result.port}, result.err
}

type fakeForwarder struct {
	mu         sync.Mutex
	requests   []ForwardRequest
	ports      []uint16
	waitErrors []error
	runnings   []*fakeRunning
}

func (f *fakeForwarder) Start(ctx context.Context, request ForwardRequest) (RunningForward, error) {
	f.mu.Lock()
	index := len(f.requests)
	f.requests = append(f.requests, request)
	port := request.LocalPort
	if index < len(f.ports) {
		port = f.ports[index]
	}
	var waitError error
	if index < len(f.waitErrors) {
		waitError = f.waitErrors[index]
	}
	running := &fakeRunning{ctx: ctx, port: port, result: make(chan error, 1)}
	f.runnings = append(f.runnings, running)
	f.mu.Unlock()
	if waitError != nil {
		running.result <- waitError
	} else {
		go func() { <-ctx.Done(); running.result <- context.Cause(ctx) }()
	}
	return running, nil
}

type fakeRunning struct {
	ctx       context.Context
	port      uint16
	result    chan error
	closeOnce sync.Once
}

func (f *fakeRunning) LocalPort() uint16 { return f.port }
func (f *fakeRunning) Wait() error       { return <-f.result }
func (f *fakeRunning) Close() error {
	f.closeOnce.Do(func() {})
	return nil
}

type recordingBackoff struct {
	mu    sync.Mutex
	calls int
}

func (b *recordingBackoff) Wait(ctx context.Context, _ int) error {
	b.mu.Lock()
	b.calls++
	b.mu.Unlock()
	return nil
}

func (b *recordingBackoff) Calls() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.calls
}

type blockingBackoff struct {
	entered chan struct{}
	once    sync.Once
}

func newBlockingBackoff() *blockingBackoff {
	return &blockingBackoff{entered: make(chan struct{})}
}

func (b *blockingBackoff) Wait(ctx context.Context, _ int) error {
	b.once.Do(func() { close(b.entered) })
	<-ctx.Done()
	return ctx.Err()
}

func testManager(t *testing.T, resolver TargetResolver, forwarder Forwarder) *Manager {
	t.Helper()
	manager, err := NewManager(Config{
		Sessions: staticSessionResolver{session: Session{ContextName: "context", Resolver: resolver, Forwarder: forwarder}},
		Backoff: BackoffFunc(func(ctx context.Context, _ int) error {
			return nil
		}),
	})
	if err != nil {
		t.Fatal(err)
	}
	return manager
}

func podIdentity(name, uid string) Identity {
	return Identity{SessionID: "session", Version: "v1", Resource: "pods", Namespace: "ns", Name: name, UID: typesUID(uid)}
}

func serviceIdentity(name, uid string) Identity {
	return Identity{SessionID: "session", Version: "v1", Resource: "services", Namespace: "ns", Name: name, UID: typesUID(uid)}
}

func typesUID(value string) types.UID { return types.UID(value) }

func eventuallyForward(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for port-forward state")
		}
		time.Sleep(time.Millisecond)
	}
}
