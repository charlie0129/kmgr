package view

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/store"
	"github.com/charlie0129/kmgr/backend/internal/watcher"
)

func TestRuntimeOpenHistoryRetainsAbortedHigherGenerationWhileLowerGenerationActive(t *testing.T) {
	client := newScriptedResource()
	var projectionCalls int
	higherStarted := make(chan struct{})
	releaseHigher := make(chan struct{})
	runtime, err := NewRuntime(RuntimeConfig{
		Source:                &fakeResourceSource{authority: "cluster-a", client: client},
		ReleaseDelay:          time.Hour,
		OpenProjectionLimit:   2,
		OpenGenerationHistory: 1,
		openProjectionHook: func() {
			projectionCalls++
			if projectionCalls == 2 {
				close(higherStarted)
				<-releaseHigher
			}
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	active, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}

	higherCtx, cancelHigher := context.WithCancel(context.Background())
	higherDone := make(chan error, 1)
	go func() {
		_, openErr := runtime.OpenContext(higherCtx, openView("session", "view", 3))
		higherDone <- openErr
	}()
	<-higherStarted
	cancelHigher()
	close(releaseHigher)
	if err := <-higherDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("aborted higher generation error = %v, want canceled", err)
	}

	runtime.mu.Lock()
	activeGeneration := runtime.views[viewKey{sessionID: "session", viewID: "view"}].generation
	latest := runtime.latestOpen[viewKey{sessionID: "session", viewID: "view"}]
	historyLength := len(runtime.openHistory)
	runtime.mu.Unlock()
	if activeGeneration != 1 || latest != 3 || historyLength <= runtime.openHistoryLimit {
		t.Fatalf("protected history active=%d latest=%d len=%d limit=%d, want active=1 latest=3 len>limit",
			activeGeneration, latest, historyLength, runtime.openHistoryLimit)
	}
	if _, err := runtime.Open(openView("session", "view", 3)); !errors.Is(err, ErrStaleViewOpen) {
		t.Fatalf("duplicate aborted generation error = %v, want stale", err)
	}
	if _, err := runtime.Open(openView("session", "view", 2)); !errors.Is(err, ErrStaleViewOpen) {
		t.Fatalf("lower aborted generation error = %v, want stale", err)
	}

	active.Close()
	runtime.mu.Lock()
	latest, latestRetained := runtime.latestOpen[viewKey{sessionID: "session", viewID: "view"}]
	historyLength = len(runtime.openHistory)
	runtime.mu.Unlock()
	if !latestRetained || latest != 3 || historyLength != runtime.openHistoryLimit {
		t.Fatalf("trimmed inactive history latest=(%d,%t) len=%d limit=%d",
			latest, latestRetained, historyLength, runtime.openHistoryLimit)
	}

	// A protected entry on another key forces the now-inactive ancient fence
	// out of the bounded history. The original key may then reuse an old
	// generation, matching the deliberately bounded anti-replay semantics.
	other, err := runtime.Open(openView("session", "other", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	runtime.mu.Lock()
	_, latestRetained = runtime.latestOpen[viewKey{sessionID: "session", viewID: "view"}]
	runtime.mu.Unlock()
	if latestRetained {
		t.Fatal("inactive ancient generation fence was not trimmed")
	}

	reopened, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatalf("ancient inactive generation should be admissible after trimming: %v", err)
	}
	reopened.Close()
}

func TestRuntimeOpenHistoryEvictionDropsInactiveGenerationFences(t *testing.T) {
	runtime, err := NewRuntime(RuntimeConfig{
		Source:                &fakeResourceSource{authority: "cluster-a", client: newScriptedResource()},
		ReleaseDelay:          time.Hour,
		OpenGenerationHistory: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session", "first", 1))
	if err != nil {
		t.Fatal(err)
	}
	drainSubscription(t, first)
	firstKey := first.key
	first.Close()

	second, err := runtime.Open(openView("session", "second", 1))
	if err != nil {
		t.Fatal(err)
	}
	second.Close()
	runtime.mu.Lock()
	_, generationRetained := runtime.latestOpen[firstKey]
	_, filterRetained := runtime.latestFilter[firstKey]
	runtime.mu.Unlock()
	if generationRetained || filterRetained {
		t.Fatalf(
			"evicted logical view retained generation=%t filter=%t",
			generationRetained, filterRetained,
		)
	}
}

func TestRuntimeCloseDuringInitialProjectionCleansOpenAttempt(t *testing.T) {
	projectionStarted := make(chan struct{})
	releaseProjection := make(chan struct{})
	runtime, err := NewRuntime(RuntimeConfig{
		Source:              &fakeResourceSource{authority: "cluster-a", client: newScriptedResource()},
		ReleaseDelay:        time.Hour,
		OpenProjectionLimit: 1,
		openProjectionHook: func() {
			close(projectionStarted)
			<-releaseProjection
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)
	go func() {
		_, openErr := runtime.OpenContext(context.Background(), openView("session", "view", 1))
		done <- openErr
	}()
	<-projectionStarted

	runtime.Close()
	close(releaseProjection)
	if err := <-done; !errors.Is(err, context.Canceled) && !errors.Is(err, ErrViewClosed) {
		t.Fatalf("Open after Runtime.Close error = %v, want canceled or closed", err)
	}
	assertRuntimeHasNoOpenLifecycleState(t, runtime)
}

func TestRuntimeCloseReleasesWarmStores(t *testing.T) {
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster-a", client: newScriptedResource()},
	})
	if err != nil {
		t.Fatal(err)
	}
	entry := &resourceRuntime{
		key:         resourceKey{authorityID: "cluster-a", version: "v1", resource: "pods"},
		store:       store.New(),
		subscribers: make(map[*Subscription]struct{}),
		state:       resourceIdle,
	}
	entry.store.Upsert(pod("uid-warm", "ns", "warm", "Running", 0, nil, time.Time{}))
	runtime.mu.Lock()
	runtime.resources[entry.key] = entry
	runtime.mu.Unlock()
	if _, admitted := runtime.warm.Put(entry.key, watcher.WarmEntry[*resourceRuntime]{
		Value: entry, ObjectCount: 1,
	}); !admitted {
		t.Fatal("warm fixture was not admitted")
	}

	runtime.Close()
	if got := runtime.warm.Len(); got != 0 {
		t.Fatalf("warm entries after Close = %d, want 0", got)
	}
	if got := runtime.warm.ObjectCount(); got != 0 {
		t.Fatalf("warm objects after Close = %d, want 0", got)
	}
}

func TestRuntimeCancelWhileWaitingForProjectionAdmissionCleansOpenAttempt(t *testing.T) {
	runtime, err := NewRuntime(RuntimeConfig{
		Source:              &fakeResourceSource{authority: "cluster-a", client: newScriptedResource()},
		ReleaseDelay:        time.Hour,
		OpenProjectionLimit: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	// Occupy admission without creating an unrelated open attempt or resource.
	runtime.openProjectionGate <- struct{}{}
	defer runtime.releaseOpenProjection()

	waitingCtx, cancelWaiting := context.WithCancel(context.Background())
	waitingDone := make(chan error, 1)
	go func() {
		_, openErr := runtime.OpenContext(waitingCtx, openView("session", "waiting", 1))
		waitingDone <- openErr
	}()
	waitingKey := viewKey{sessionID: "session", viewID: "waiting"}
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		return runtime.openings[waitingKey] != nil
	})

	cancelWaiting()
	if err := <-waitingDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("waiting Open error = %v, want canceled", err)
	}
	runtime.mu.Lock()
	_, waitingOpening := runtime.openings[waitingKey]
	_, waitingView := runtime.views[waitingKey]
	entries := len(runtime.resources)
	totalOpeners := 0
	for _, entry := range runtime.resources {
		totalOpeners += entry.openers
	}
	runtime.mu.Unlock()
	if waitingOpening || waitingView || entries != 0 || totalOpeners != 0 {
		t.Fatalf("canceled waiter leaked opening=%t view=%t resources=%d openers=%d",
			waitingOpening, waitingView, entries, totalOpeners)
	}
}

func assertRuntimeHasNoOpenLifecycleState(t *testing.T, runtime *Runtime) {
	t.Helper()
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	totalOpeners := 0
	for _, entry := range runtime.resources {
		totalOpeners += entry.openers
	}
	if len(runtime.openings) != 0 || len(runtime.latestOpen) != 0 || len(runtime.latestFilter) != 0 ||
		totalOpeners != 0 || len(runtime.resources) != 0 || len(runtime.views) != 0 {
		t.Fatalf("runtime leaked openings=%d generations=%d filters=%d openers=%d resources=%d views=%d",
			len(runtime.openings), len(runtime.latestOpen), len(runtime.latestFilter),
			totalOpeners, len(runtime.resources), len(runtime.views))
	}
}
