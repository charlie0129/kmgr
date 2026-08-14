package portforward

import (
	"context"
	"errors"
	"strings"
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
	updates, unsubscribe := manager.subscribe()
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

func TestDirectPodReplacementAtUpgradeSeamFailsWithoutRetry(t *testing.T) {
	t.Parallel()
	resolver := &sequenceResolver{results: []resolveResult{
		{target: podIdentity("pod", "old-uid")},
	}}
	forwarder := &fakeForwarder{startErrors: []error{ErrPodRecreated}}
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
		ID: "upgrade-race", Target: podIdentity("pod", "old-uid"), RemotePort: 8080,
	}); err != nil {
		t.Fatal(err)
	}
	eventuallyForward(t, func() bool {
		values := manager.List("", true)
		return len(values) == 1 && values[0].State == StateFailed
	})
	failed := manager.List("", true)[0]
	if !errors.Is(failed.LastError, ErrPodRecreated) {
		t.Fatalf("terminal error = %v, want ErrPodRecreated", failed.LastError)
	}
	if got := backoff.Calls(); got != 0 {
		t.Fatalf("backoff calls = %d, want no retry after upgrade-seam UID mismatch", got)
	}
	resolver.mu.Lock()
	resolveCalls := resolver.calls
	resolver.mu.Unlock()
	if resolveCalls != 1 {
		t.Fatalf("resolver calls = %d, want 1", resolveCalls)
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
	updates, unsubscribe := manager.subscribe()
	defer unsubscribe()
	_, err := manager.Start(StartRequest{ID: "forward", Target: podIdentity("pod", "uid"), RemotePort: 8080})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-updates.ready:
		batch := updates.drain()
		if batch.resync || len(batch.updates) == 0 || batch.updates[0].snapshot.ID != "forward" {
			t.Fatalf("update batch = %#v", batch)
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

func TestSubscriberOverflowRequestsAuthoritativeResync(t *testing.T) {
	t.Parallel()
	manager, err := NewManager(Config{
		Sessions:               staticSessionResolver{session: Session{}},
		SubscriberPendingLimit: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	updates, unsubscribe := manager.subscribe()
	defer unsubscribe()

	manager.publish(managerUpdate{snapshot: Snapshot{ID: "one", State: StateStarting}})
	manager.publish(managerUpdate{snapshot: Snapshot{ID: "two", State: StateStarting}})
	manager.publish(managerUpdate{snapshot: Snapshot{ID: "three", State: StateStarting}})
	select {
	case <-updates.ready:
	case <-time.After(time.Second):
		t.Fatal("overflowed subscriber was not notified")
	}
	if batch := updates.drain(); !batch.resync || len(batch.updates) != 0 {
		t.Fatalf("overflow batch = %#v, want authoritative resync", batch)
	}

	manager.publish(managerUpdate{snapshot: Snapshot{ID: "after", State: StateListening}})
	select {
	case <-updates.ready:
	case <-time.After(time.Second):
		t.Fatal("subscriber did not recover after resync")
	}
	batch := updates.drain()
	if batch.resync || len(batch.updates) != 1 || batch.updates[0].snapshot.ID != "after" {
		t.Fatalf("post-resync batch = %#v", batch)
	}
}

func TestManagerCloseContextBoundsStubbornForward(t *testing.T) {
	running := &stubbornRunningForward{
		release: make(chan struct{}), closeCalled: make(chan struct{}),
	}
	forwarder := &stubbornForwarder{running: running, started: make(chan struct{})}
	sessions := &leaseSessionResolver{session: Session{
		ContextName: "context",
		Resolver:    &sequenceResolver{results: []resolveResult{{target: podIdentity("pod", "uid")}}},
		Forwarder:   forwarder,
	}}
	manager, err := NewManager(Config{
		Sessions: sessions,
		Backoff:  BackoffFunc(func(context.Context, int) error { return nil }),
	})
	if err != nil {
		t.Fatal(err)
	}
	released := false
	t.Cleanup(func() {
		if !released {
			close(running.release)
		}
		manager.Close()
	})
	if _, err := manager.Start(StartRequest{
		ID: "stubborn", Target: podIdentity("pod", "uid"), RemotePort: 8080,
	}); err != nil {
		t.Fatal(err)
	}
	<-forwarder.started

	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancel()
	begin := time.Now()
	closeResult := make(chan error, 1)
	go func() { closeResult <- manager.CloseContext(ctx) }()
	select {
	case err = <-closeResult:
	case <-time.After(500 * time.Millisecond):
		close(running.release)
		released = true
		<-closeResult
		t.Fatal("CloseContext did not return within a bounded interval")
	}
	elapsed := time.Since(begin)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("CloseContext error = %v, want deadline exceeded", err)
	}
	if elapsed > 500*time.Millisecond {
		t.Fatalf("CloseContext elapsed = %v, want a bounded shutdown", elapsed)
	}
	select {
	case <-running.closeCalled:
	case <-time.After(time.Second):
		t.Fatal("CloseContext did not close the stubborn running forward")
	}
	if got := sessions.Counts(); got != [2]int{1, 0} {
		t.Fatalf("timed-out forward lease counts = %v, want retained lease", got)
	}

	close(running.release)
	released = true
	manager.Close()
	if got := sessions.Counts(); got != [2]int{1, 1} {
		t.Fatalf("eventual forward lease counts = %v, want [1 1]", got)
	}
}

func TestManagerCloseContextBoundsBlockingSessionRelease(t *testing.T) {
	releaseStarted := make(chan struct{})
	releaseUnblock := make(chan struct{})
	releaseFinished := make(chan struct{})
	var releaseGate sync.Once
	var releaseMu sync.Mutex
	releaseCalls := 0
	manager, err := NewManager(Config{
		Sessions: staticSessionResolver{session: Session{
			ContextName: "context",
			Resolver:    &sequenceResolver{results: []resolveResult{{target: podIdentity("pod", "uid")}}},
			Forwarder:   &fakeForwarder{ports: []uint16{12345}},
			Release: func() {
				releaseMu.Lock()
				releaseCalls++
				releaseMu.Unlock()
				close(releaseStarted)
				<-releaseUnblock
				close(releaseFinished)
			},
		}},
		Backoff: BackoffFunc(func(context.Context, int) error { return nil }),
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		releaseGate.Do(func() { close(releaseUnblock) })
		manager.Close()
	})
	if _, err := manager.Start(StartRequest{
		ID: "blocking-release", Target: podIdentity("pod", "uid"), RemotePort: 8080,
	}); err != nil {
		t.Fatal(err)
	}
	eventuallyForward(t, func() bool {
		values := manager.List("", false)
		return len(values) == 1 && values[0].State == StateListening
	})

	ctx, cancel := context.WithCancel(context.Background())
	closeResult := make(chan error, 1)
	go func() { closeResult <- manager.CloseContext(ctx) }()
	select {
	case <-releaseStarted:
	case <-time.After(time.Second):
		t.Fatal("shutdown did not start the retained session release")
	}
	cancel()
	select {
	case err = <-closeResult:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("CloseContext blocked on the session Release callback")
	}
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("CloseContext error = %v, want context canceled", err)
	}
	select {
	case <-releaseFinished:
		t.Fatal("session Release returned while its deterministic gate was closed")
	default:
	}

	// The deadline-bounded call may return while release is still owned by its
	// one-shot task, but the original Close contract remains an unbounded drain.
	normalClose := make(chan struct{})
	go func() {
		manager.Close()
		close(normalClose)
	}()
	select {
	case <-normalClose:
		t.Fatal("Close returned before the retained session release completed")
	case <-time.After(25 * time.Millisecond):
	}
	releaseGate.Do(func() { close(releaseUnblock) })
	select {
	case <-releaseFinished:
	case <-time.After(time.Second):
		t.Fatal("retained session release did not finish after unblocking")
	}
	select {
	case <-normalClose:
	case <-time.After(time.Second):
		t.Fatal("Close did not finish after the retained session release returned")
	}
	releaseMu.Lock()
	defer releaseMu.Unlock()
	if releaseCalls != 1 {
		t.Fatalf("session Release calls = %d, want 1", releaseCalls)
	}
	manager.mu.RLock()
	defer manager.mu.RUnlock()
	if len(manager.retainedSessions) != 0 {
		t.Fatalf("retained sessions after Release returned = %d, want 0", len(manager.retainedSessions))
	}
}

func TestTerminalPortForwardsHaveBoundedAgeAndCountRetention(t *testing.T) {
	t.Parallel()
	clock := &portForwardTestClock{value: time.Date(2026, 8, 14, 10, 0, 0, 0, time.UTC)}
	sessions := &leaseSessionResolver{session: Session{
		ContextName: "context",
		Resolver:    &sequenceResolver{results: []resolveResult{{target: podIdentity("pod", "uid")}}},
		Forwarder:   &fakeForwarder{ports: []uint16{41001, 41002, 41003}},
	}}
	manager, err := NewManager(Config{
		Sessions:              sessions,
		Backoff:               BackoffFunc(func(context.Context, int) error { return nil }),
		Now:                   clock.Now,
		TerminalRetention:     time.Hour,
		RetainedTerminalLimit: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()

	for _, id := range []string{"one", "two", "three"} {
		if _, err := manager.Start(StartRequest{
			ID: id, Target: podIdentity("pod", "uid"), RemotePort: 8080,
		}); err != nil {
			t.Fatalf("start %s: %v", id, err)
		}
		eventuallyForward(t, func() bool {
			current := manager.lookup(id, "session")
			return current != nil && current.Snapshot().State == StateListening
		})
		if !manager.Stop(id, "session") {
			t.Fatalf("stop %s was rejected", id)
		}
		eventuallyForward(t, func() bool {
			current := manager.lookup(id, "session")
			if current == nil || current.Snapshot().State != StateStopped {
				return false
			}
			current.mu.RLock()
			done := current.runDone
			current.mu.RUnlock()
			select {
			case <-done:
				return true
			default:
				return false
			}
		})
		clock.Advance(time.Minute)
	}

	retained := manager.List("", true)
	if len(retained) != 2 || retained[0].ID != "two" || retained[1].ID != "three" {
		t.Fatalf("count-bounded retained forwards = %#v", retained)
	}
	if got := sessions.Counts(); got != [2]int{3, 1} {
		t.Fatalf("count-pruned acquire/release counts = %v, want [3 1]", got)
	}
	clock.Advance(2 * time.Hour)
	if retained = manager.List("", true); len(retained) != 0 {
		t.Fatalf("expired retained forwards = %#v", retained)
	}
	if got := sessions.Counts(); got != [2]int{3, 3} {
		t.Fatalf("age-pruned acquire/release counts = %v, want [3 3]", got)
	}
	manager.Close()
	if got := sessions.Counts(); got != [2]int{3, 3} {
		t.Fatalf("manager close released pruned leases again: %v", got)
	}
}

func TestActiveForwardCapacityRecoversAfterStopAndTerminalRemoval(t *testing.T) {
	t.Parallel()
	sessions := &leaseSessionResolver{session: Session{
		ContextName: "context",
		Resolver:    &sequenceResolver{results: []resolveResult{{target: podIdentity("pod", "uid")}}},
		Forwarder:   &fakeForwarder{ports: []uint16{41001, 41002, 41003}},
	}}
	manager, err := NewManager(Config{
		Sessions: sessions, Backoff: BackoffFunc(func(context.Context, int) error { return nil }),
		MaxActiveForwards: 1, RetainedTerminalLimit: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	start := func(id string) error {
		_, err := manager.Start(StartRequest{
			ID: id, Target: podIdentity("pod", "uid"), RemotePort: 8080,
		})
		return err
	}
	waitForState := func(id string, state State) {
		t.Helper()
		eventuallyForward(t, func() bool {
			current := manager.lookup(id, "session")
			return current != nil && current.Snapshot().State == state
		})
	}

	if err := start("one"); err != nil {
		t.Fatal(err)
	}
	waitForState("one", StateListening)
	if err := start("two"); !errors.Is(err, ErrTooManyPortForwards) {
		t.Fatalf("capacity Start error = %v", err)
	}
	if got := sessions.Counts(); got != [2]int{1, 0} {
		t.Fatalf("capacity rejection acquired a lease: %v", got)
	}

	if !manager.Stop("one", "session") {
		t.Fatal("Stop one rejected")
	}
	waitForState("one", StateStopped)
	if err := start("two"); err != nil {
		t.Fatalf("Start after stop: %v", err)
	}
	waitForState("two", StateListening)
	if manager.lookup("one", "session") == nil {
		t.Fatal("stopped entry was not retained as a terminal tombstone")
	}
	if manager.Restart("one", "session") {
		t.Fatal("Restart exceeded the active forward capacity")
	}

	if !manager.Stop("two", "session") {
		t.Fatal("Stop two rejected")
	}
	waitForState("two", StateStopped)
	eventuallyForward(t, func() bool { return manager.lookup("one", "session") == nil })
	if got := sessions.Counts(); got != [2]int{2, 1} {
		t.Fatalf("terminal removal acquire/release counts = %v, want [2 1]", got)
	}
	if err := start("one"); err != nil {
		t.Fatalf("same-ID Start after terminal removal: %v", err)
	}
}

func TestStartRejectsOversizedRetainedFieldsBeforeSessionResolution(t *testing.T) {
	t.Parallel()
	sessions := &leaseSessionResolver{session: Session{
		ContextName: "context", Resolver: &sequenceResolver{}, Forwarder: &fakeForwarder{},
	}}
	manager, err := NewManager(Config{Sessions: sessions})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	valid := StartRequest{
		ID: "forward", Label: "label", Target: podIdentity("pod", "uid"), RemotePort: 8080,
	}
	tests := []struct {
		name   string
		mutate func(*StartRequest)
	}{
		{"forward ID", func(value *StartRequest) { value.ID = strings.Repeat("i", MaxPortForwardIDBytes+1) }},
		{"label", func(value *StartRequest) { value.Label = strings.Repeat("l", MaxPortForwardLabelBytes+1) }},
		{"session ID", func(value *StartRequest) { value.Target.SessionID = strings.Repeat("s", maxSessionIDBytes+1) }},
		{"API group", func(value *StartRequest) { value.Target.Group = strings.Repeat("g", maxAPIGroupBytes+1) }},
		{"API version", func(value *StartRequest) { value.Target.Version = strings.Repeat("v", maxAPIVersionBytes+1) }},
		{"resource", func(value *StartRequest) { value.Target.Resource = strings.Repeat("r", maxResourceBytes+1) }},
		{"namespace", func(value *StartRequest) { value.Target.Namespace = strings.Repeat("n", maxNamespaceBytes+1) }},
		{"name", func(value *StartRequest) { value.Target.Name = strings.Repeat("n", maxNameBytes+1) }},
		{"UID", func(value *StartRequest) { value.Target.UID = typesUID(strings.Repeat("u", maxUIDBytes+1)) }},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			request := valid
			test.mutate(&request)
			if _, err := manager.Start(request); !errors.Is(err, ErrInvalidRequest) {
				t.Fatalf("Start error = %v, want ErrInvalidRequest", err)
			}
		})
	}
	if got := sessions.Counts(); got != [2]int{} {
		t.Fatalf("invalid requests reached session resolution: %v", got)
	}
}

func TestPortForwardRetainsLeaseAcrossStopAndRestart(t *testing.T) {
	t.Parallel()
	resolver := &sequenceResolver{results: []resolveResult{
		{target: podIdentity("pod", "uid")}, {target: podIdentity("pod", "uid")},
	}}
	forwarder := &fakeForwarder{ports: []uint16{12345, 12345}}
	sessions := &leaseSessionResolver{session: Session{
		ContextName: "context", Resolver: resolver, Forwarder: forwarder,
	}}
	manager, err := NewManager(Config{
		Sessions: sessions,
		Backoff:  BackoffFunc(func(context.Context, int) error { return nil }),
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Start(StartRequest{
		ID: "leased", Target: podIdentity("pod", "uid"), RemotePort: 8080,
	}); err != nil {
		t.Fatal(err)
	}
	eventuallyForward(t, func() bool { return manager.List("", true)[0].State == StateListening })
	if got := sessions.Counts(); got != [2]int{1, 0} {
		t.Fatalf("listening acquire/release counts = %v", got)
	}
	if !manager.Stop("leased", "session") {
		t.Fatal("Stop rejected")
	}
	eventuallyForward(t, func() bool {
		return manager.List("", true)[0].State == StateStopped
	})
	if got := sessions.Counts(); got != [2]int{1, 0} {
		t.Fatalf("stopped acquire/release counts = %v, want retained lease", got)
	}
	// Simulate the originating workspace closing: the registry would reject a
	// new lease, but this app-wide forward still owns its original authority.
	sessions.mu.Lock()
	sessions.err = ErrSessionNotFound
	sessions.mu.Unlock()
	if !manager.Restart("leased", "session") {
		t.Fatal("Restart rejected after originating workspace closed")
	}
	eventuallyForward(t, func() bool {
		return manager.List("", true)[0].State == StateListening
	})
	manager.Close()
	if got := sessions.Counts(); got != [2]int{1, 1} {
		t.Fatalf("final acquire/release counts = %v, want [1 1]", got)
	}
}

func TestTerminalRetentionJanitorRemovesEntryAndReleasesLease(t *testing.T) {
	t.Parallel()
	sessions := &leaseSessionResolver{session: Session{
		ContextName: "context",
		Resolver:    &sequenceResolver{results: []resolveResult{{target: podIdentity("pod", "uid")}}},
		Forwarder:   &fakeForwarder{ports: []uint16{12345}},
	}}
	manager, err := NewManager(Config{
		Sessions: sessions, Backoff: BackoffFunc(func(context.Context, int) error { return nil }),
		TerminalRetention: 25 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	updates, unsubscribe := manager.subscribe()
	defer unsubscribe()
	if _, err := manager.Start(StartRequest{
		ID: "expires", Target: podIdentity("pod", "uid"), RemotePort: 8080,
	}); err != nil {
		t.Fatal(err)
	}
	eventuallyForward(t, func() bool {
		current := manager.lookup("expires", "session")
		return current != nil && current.Snapshot().State == StateListening
	})
	if !manager.Stop("expires", "session") {
		t.Fatal("Stop rejected")
	}
	eventuallyForward(t, func() bool {
		current := manager.lookup("expires", "session")
		if current == nil || current.Snapshot().State != StateStopped {
			return false
		}
		current.mu.RLock()
		done := current.runDone
		current.mu.RUnlock()
		select {
		case <-done:
			return true
		default:
			return false
		}
	})
	if got := sessions.Counts(); got != [2]int{1, 0} {
		t.Fatalf("pre-expiry acquire/release counts = %v", got)
	}

	removed := false
	deadline := time.After(2 * time.Second)
	for !removed {
		select {
		case <-updates.ready:
			for _, update := range updates.drain().updates {
				removed = removed || update.removedID == "expires"
			}
		case <-deadline:
			t.Fatal("retention janitor did not publish terminal removal")
		}
	}
	if current := manager.lookup("expires", "session"); current != nil {
		t.Fatalf("expired terminal entry was retained: %#v", current.Snapshot())
	}
	if got := sessions.Counts(); got != [2]int{1, 1} {
		t.Fatalf("post-expiry acquire/release counts = %v, want [1 1]", got)
	}
	manager.Close()
	if got := sessions.Counts(); got != [2]int{1, 1} {
		t.Fatalf("manager close released pruned lease again: %v", got)
	}
}

func TestPrunedRemovalPrecedesSameIDReplacementSnapshot(t *testing.T) {
	t.Parallel()
	clock := &portForwardTestClock{value: time.Date(2026, 8, 14, 10, 0, 0, 0, time.UTC)}
	sessions := &blockingFirstReleaseSessionResolver{
		session: Session{
			ContextName: "context",
			Resolver: &sequenceResolver{results: []resolveResult{
				{target: podIdentity("pod", "uid")}, {target: podIdentity("pod", "uid")},
			}},
			Forwarder: &fakeForwarder{ports: []uint16{12345, 12346}},
		},
		releaseEntered: make(chan struct{}),
		releaseUnblock: make(chan struct{}),
	}
	manager, err := NewManager(Config{
		Sessions: sessions, Backoff: BackoffFunc(func(context.Context, int) error { return nil }),
		Now: clock.Now, TerminalRetention: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	updates, unsubscribe := manager.subscribe()
	defer unsubscribe()
	request := StartRequest{ID: "reused", Target: podIdentity("pod", "uid"), RemotePort: 8080}
	if _, err := manager.Start(request); err != nil {
		t.Fatal(err)
	}
	eventuallyForward(t, func() bool {
		current := manager.lookup("reused", "session")
		return current != nil && current.Snapshot().State == StateListening
	})
	if !manager.Stop("reused", "session") {
		t.Fatal("Stop rejected")
	}
	eventuallyForward(t, func() bool {
		current := manager.lookup("reused", "session")
		if current == nil || current.Snapshot().State != StateStopped {
			return false
		}
		current.mu.RLock()
		done := current.runDone
		current.mu.RUnlock()
		select {
		case <-done:
			return true
		default:
			return false
		}
	})
	// Discard the original entry's lifecycle updates while leaving the
	// subscriber active for the prune/reuse ordering assertion.
	select {
	case <-updates.ready:
	default:
	}
	_ = updates.drain()

	clock.Advance(2 * time.Hour)
	pruneDone := make(chan struct{})
	go func() {
		_ = manager.List("", true)
		close(pruneDone)
	}()
	select {
	case <-sessions.releaseEntered:
	case <-time.After(2 * time.Second):
		t.Fatal("terminal prune did not reach lease release")
	}
	if _, err := manager.Start(request); err != nil {
		t.Fatalf("same-ID replacement Start: %v", err)
	}
	close(sessions.releaseUnblock)
	select {
	case <-pruneDone:
	case <-time.After(2 * time.Second):
		t.Fatal("terminal prune did not finish")
	}

	batch := updates.drain()
	removalIndex, replacementIndex := -1, -1
	for index, update := range batch.updates {
		if update.removedID == "reused" && removalIndex == -1 {
			removalIndex = index
		}
		if update.snapshot.ID == "reused" && replacementIndex == -1 {
			replacementIndex = index
		}
	}
	if removalIndex == -1 || replacementIndex == -1 || removalIndex >= replacementIndex {
		t.Fatalf("prune/replacement update order = %#v", batch.updates)
	}
}

func TestPortForwardStartFailuresDoNotLeakRetainedLease(t *testing.T) {
	t.Parallel()
	resolver := &sequenceResolver{results: []resolveResult{{target: podIdentity("pod", "uid")}}}
	forwarder := &fakeForwarder{ports: []uint16{12345}}
	sessions := &leaseSessionResolver{session: Session{
		ContextName: "context", Resolver: resolver, Forwarder: forwarder,
	}}
	manager, err := NewManager(Config{
		Sessions: sessions,
		Backoff:  BackoffFunc(func(context.Context, int) error { return nil }),
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Start(StartRequest{
		ID: "same", Target: podIdentity("pod", "uid"), RemotePort: 8080,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Start(StartRequest{
		ID: "same", Target: podIdentity("pod", "uid"), RemotePort: 8080,
	}); !errors.Is(err, ErrDuplicatePortForward) {
		t.Fatalf("duplicate Start error = %v", err)
	}
	if got := sessions.Counts(); got != [2]int{1, 0} {
		t.Fatalf("duplicate Start acquired a lease: %v", got)
	}
	if !manager.Stop("same", "session") {
		t.Fatal("Stop rejected")
	}
	eventuallyForward(t, func() bool {
		return manager.List("", true)[0].State == StateStopped
	})
	if got := sessions.Counts(); got != [2]int{1, 0} {
		t.Fatalf("terminal retained lease counts = %v, want [1 0]", got)
	}
	manager.Close()
	if got := sessions.Counts(); got != [2]int{1, 1} {
		t.Fatalf("manager close did not release retained lease exactly once: %v", got)
	}
}

type staticSessionResolver struct {
	session Session
	err     error
}

func (r staticSessionResolver) ResolveSession(string) (Session, error) { return r.session, r.err }

type leaseSessionResolver struct {
	mu       sync.Mutex
	session  Session
	err      error
	acquires int
	releases int
}

type blockingFirstReleaseSessionResolver struct {
	mu             sync.Mutex
	session        Session
	acquires       int
	releaseEntered chan struct{}
	releaseUnblock chan struct{}
}

func (r *blockingFirstReleaseSessionResolver) ResolveSession(string) (Session, error) {
	r.mu.Lock()
	r.acquires++
	acquisition := r.acquires
	r.mu.Unlock()
	session := r.session
	var once sync.Once
	session.Release = func() {
		once.Do(func() {
			if acquisition == 1 {
				close(r.releaseEntered)
				<-r.releaseUnblock
			}
		})
	}
	return session, nil
}

func (r *leaseSessionResolver) ResolveSession(string) (Session, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.err != nil {
		return Session{}, r.err
	}
	r.acquires++
	session := r.session
	var once sync.Once
	session.Release = func() {
		once.Do(func() {
			r.mu.Lock()
			r.releases++
			r.mu.Unlock()
		})
	}
	return session, nil
}

func (r *leaseSessionResolver) Counts() [2]int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return [2]int{r.acquires, r.releases}
}

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
	mu          sync.Mutex
	requests    []ForwardRequest
	ports       []uint16
	startErrors []error
	waitErrors  []error
	runnings    []*fakeRunning
}

type stubbornForwarder struct {
	running *stubbornRunningForward
	started chan struct{}
	once    sync.Once
}

func (f *stubbornForwarder) Start(context.Context, ForwardRequest) (RunningForward, error) {
	f.once.Do(func() { close(f.started) })
	return f.running, nil
}

type stubbornRunningForward struct {
	release     chan struct{}
	closeCalled chan struct{}
	closeOnce   sync.Once
}

func (*stubbornRunningForward) LocalPort() uint16 { return 12345 }
func (f *stubbornRunningForward) Wait() error {
	<-f.release
	return nil
}
func (f *stubbornRunningForward) Close() error {
	f.closeOnce.Do(func() { close(f.closeCalled) })
	return nil
}

func (f *fakeForwarder) Start(ctx context.Context, request ForwardRequest) (RunningForward, error) {
	f.mu.Lock()
	index := len(f.requests)
	f.requests = append(f.requests, request)
	port := request.LocalPort
	if index < len(f.ports) {
		port = f.ports[index]
	}
	var startError error
	if index < len(f.startErrors) {
		startError = f.startErrors[index]
	}
	var waitError error
	if index < len(f.waitErrors) {
		waitError = f.waitErrors[index]
	}
	if startError != nil {
		f.mu.Unlock()
		return nil, startError
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

type portForwardTestClock struct {
	mu    sync.Mutex
	value time.Time
}

func (c *portForwardTestClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.value
}

func (c *portForwardTestClock) Advance(duration time.Duration) {
	c.mu.Lock()
	c.value = c.value.Add(duration)
	c.mu.Unlock()
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
