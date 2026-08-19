package view

import (
	"context"
	"errors"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/store"
	"github.com/charlie0129/kmgr/backend/internal/watcher"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
)

func TestNewFilterRevisionCancelsStaleProjectionAndPublishesOnlyNewestFilter(t *testing.T) {
	// This test intentionally remains sequential because it occupies the
	// process-wide projection gate to make an in-flight row projection wait at
	// a deterministic, context-cancellable boundary.
	blockedWorkers := cap(projectionWorkerGate)
	releaseBlockedWorkers := make(chan struct{})
	blockedWorkerStarted := make(chan struct{}, blockedWorkers)
	var blockedWorkerDone sync.WaitGroup
	blockedWorkerDone.Add(blockedWorkers)
	workersBlocked := true
	var releaseBlockedWorkersOnce sync.Once
	releaseWorkers := func() {
		if !workersBlocked {
			return
		}
		releaseBlockedWorkersOnce.Do(func() { close(releaseBlockedWorkers) })
		blockedWorkerDone.Wait()
		workersBlocked = false
	}
	defer releaseWorkers()

	for range blockedWorkers {
		go func() {
			defer blockedWorkerDone.Done()
			_ = runProjectionWorker(context.Background(), func() error {
				blockedWorkerStarted <- struct{}{}
				<-releaseBlockedWorkers
				return nil
			})
		}()
	}
	for range blockedWorkers {
		select {
		case <-blockedWorkerStarted:
		case <-time.After(time.Second):
			t.Fatal("could not occupy the projection worker gate")
		}
	}

	client := newScriptedResource()
	firstProjectionStarted := make(chan struct{})
	var projectionCalls atomic.Int64
	runtime, err := NewRuntime(RuntimeConfig{
		Source:              &fakeResourceSource{authority: "cluster-a", client: client},
		ReleaseDelay:        time.Hour,
		OpenProjectionLimit: 2,
		openProjectionHook: func() {
			if projectionCalls.Add(1) == 1 {
				close(firstProjectionStarted)
			}
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	entry := &resourceRuntime{
		key: resourceKey{
			authorityID: "cluster-a", version: "v1", resource: "pods", namespace: "ns",
		},
		store:       store.New(),
		client:      client,
		state:       resourceRunning,
		runNumber:   1,
		subscribers: make(map[*Subscription]struct{}),
		lastStatus: watcher.Status{
			Phase: watcher.PhaseWatching, ResourceVersion: "rv-filter",
		},
		snapshotComplete: true,
	}
	entry.store.Upsert(pod("uid-alpha", "ns", "alpha", "Running", 0, nil, time.Time{}))
	entry.store.Upsert(pod("uid-beta", "ns", "beta", "Running", 0, nil, time.Time{}))
	entry.store.SetResourceVersion("rv-filter")
	runtime.mu.Lock()
	runtime.resources[entry.key] = entry
	runtime.mu.Unlock()

	type openResult struct {
		subscription *Subscription
		err          error
	}
	open := func(request *kmgrv1.OpenViewRequest) <-chan openResult {
		result := make(chan openResult, 1)
		go func() {
			subscription, openErr := runtime.OpenContext(context.Background(), request)
			result <- openResult{subscription: subscription, err: openErr}
		}()
		return result
	}

	staleRequest := openView("session", "pods", 1)
	staleRequest.Spec.FilterExpression = "name:alpha"
	staleRequest.Spec.FilterRevision = 1
	staleResult := open(staleRequest)
	select {
	case <-firstProjectionStarted:
	case <-time.After(time.Second):
		t.Fatal("stale filter projection did not start")
	}

	newestRequest := openView("session", "pods", 2)
	newestRequest.Spec.FilterExpression = "name:beta"
	newestRequest.Spec.FilterRevision = 2
	newestResult := open(newestRequest)

	select {
	case result := <-staleResult:
		if result.subscription != nil || !errors.Is(result.err, context.Canceled) {
			t.Fatalf("superseded filter projection = subscription %#v, error %v; want context cancellation", result.subscription, result.err)
		}
	case <-time.After(time.Second):
		t.Fatal("new filter revision did not cancel the stale projection")
	}

	releaseWorkers()
	var newest *Subscription
	select {
	case result := <-newestResult:
		if result.err != nil {
			t.Fatal(result.err)
		}
		newest = result.subscription
	case <-time.After(time.Second):
		t.Fatal("newest filter projection did not finish")
	}
	defer newest.Close()

	events := drainSubscription(t, newest)
	invalidation := firstInvalidation(events)
	if invalidation == nil {
		t.Fatalf("newest filter omitted invalidation: %#v", events)
	}
	rangeResult, err := runtime.FetchRange(
		"session", "pods", newest.generation,
		invalidation.GetPresentationRevision(), invalidation.GetIndexRevision(),
		0, DefaultViewRangeLength,
	)
	if err != nil {
		// The test's newest open uses a dedicated view generation fence; fetch
		// through the exact active key after the stream has published it.
		runtime.mu.Lock()
		active := runtime.views[viewKey{sessionID: "session", viewID: "pods"}]
		runtime.mu.Unlock()
		if active == nil {
			t.Fatal(err)
		}
		rangeResult, err = runtime.FetchRange(
			"session", "pods", active.generation,
			invalidation.GetPresentationRevision(), invalidation.GetIndexRevision(),
			0, DefaultViewRangeLength,
		)
		if err != nil {
			t.Fatal(err)
		}
	}
	snapshotUIDs := rangeRowUIDs(rangeResult.Rows)
	if !slices.Equal(snapshotUIDs, []string{"uid-beta"}) {
		t.Fatalf("newest filter snapshot UIDs = %v, want only uid-beta", snapshotUIDs)
	}
}

func TestRuntimeRejectsBackwardFilterRevisionWithoutReplacingActiveView(t *testing.T) {
	t.Parallel()
	runtime, err := NewRuntime(RuntimeConfig{
		Source:       &fakeResourceSource{authority: "cluster-a", client: newScriptedResource()},
		ReleaseDelay: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	currentRequest := openView("session", "pods", 1)
	currentRequest.Spec.FilterExpression = "name:alpha"
	currentRequest.Spec.FilterRevision = 3
	current, err := runtime.Open(currentRequest)
	if err != nil {
		t.Fatal(err)
	}

	staleRequest := openView("session", "pods", 2)
	staleRequest.Spec.FilterExpression = "name:beta"
	staleRequest.Spec.FilterRevision = 2
	if _, err := runtime.Open(staleRequest); !errors.Is(err, ErrStaleFilter) {
		t.Fatalf("backward filter revision error = %v, want stale filter", err)
	}
	runtime.mu.Lock()
	active := runtime.views[viewKey{sessionID: "session", viewID: "pods"}]
	latestGeneration := runtime.latestOpen[viewKey{sessionID: "session", viewID: "pods"}]
	latestFilter := runtime.latestFilter[viewKey{sessionID: "session", viewID: "pods"}]
	runtime.mu.Unlock()
	if active != current || latestGeneration != 1 || latestFilter != 3 {
		t.Fatalf(
			"backward revision changed lifecycle: active=%p current=%p generation=%d filter=%d",
			active, current, latestGeneration, latestFilter,
		)
	}

	// Sort and column changes legitimately open a newer stream generation while
	// retaining the same filter revision.
	sameFilterRequest := openView("session", "pods", 2)
	sameFilterRequest.Spec.FilterExpression = "name:alpha"
	sameFilterRequest.Spec.FilterRevision = 3
	replacement, err := runtime.Open(sameFilterRequest)
	if err != nil {
		t.Fatalf("same filter revision with newer generation: %v", err)
	}
	defer replacement.Close()
}
