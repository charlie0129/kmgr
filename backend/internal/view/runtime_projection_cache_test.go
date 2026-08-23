package view

import (
	"context"
	"errors"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/store"
	"github.com/charlie0129/kmgr/backend/internal/watcher"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/watch"
)

func TestRuntimeWarmProjectionReopenBypassesGateAndCatchesUpRawStore(t *testing.T) {
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-1", "",
		pod("uid-a", "ns", "alpha", "Running", 0, nil, time.Time{}),
		pod("uid-b", "ns", "bravo", "Running", 0, nil, time.Time{}),
	)}
	var synchronousProjections atomic.Int64
	runtime, err := NewRuntime(RuntimeConfig{
		Source:              &fakeResourceSource{authority: "cluster-a", client: client},
		ReleaseDelay:        200 * time.Millisecond,
		BatchDelay:          time.Millisecond,
		PipelineTimeout:     time.Second,
		OpenProjectionLimit: 1,
		openProjectionHook:  func() { synchronousProjections.Add(1) },
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	firstRequest := openView("session", "first", 1)
	firstRequest.Spec.Sort = []*kmgrv1.SortDescriptor{{
		ColumnId: "name", Direction: kmgrv1.SortDirection_SORT_DIRECTION_DESCENDING,
	}}
	first, err := runtime.Open(firstRequest)
	if err != nil {
		t.Fatal(err)
	}
	eventually(t, time.Second, func() bool {
		first.mu.Lock()
		defer first.mu.Unlock()
		return first.snapshotComplete && slices.Equal(first.order, []string{"uid-b", "uid-a"})
	})
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })
	entry := first.resource
	key := entry.key
	first.Close()

	// The final-consumer detach freezes the committed rows. A WATCH event that
	// lands during release debounce advances only the raw store, deliberately
	// making the presentation candidate stale before warm admission.
	newest := pod("uid-c", "ns", "charlie", "Running", 0, nil, time.Time{})
	newest.SetResourceVersion("rv-2")
	client.lastWatch().channel <- watch.Event{Type: watch.Added, Object: newest}
	eventually(t, time.Second, func() bool { return entry.store.Len() == 3 })
	eventually(t, 2*time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		cached, warm := runtime.getWarmLocked(key)
		return warm && cached.Value == entry && entry.warmProjection != nil &&
			slices.Equal(projectionUIDs(entry.warmProjection.rows), []string{"uid-b", "uid-a"})
	})

	// Saturating synchronous admission proves a compatible cached first paint
	// does not call ProjectContext or wait behind another large Open. The
	// mandatory background catch-up waits on the same gate instead.
	runtime.openProjectionGate <- struct{}{}
	gateHeld := true
	defer func() {
		if gateHeld {
			runtime.releaseOpenProjection()
		}
	}()
	secondRequest := openView("session", "second", 1)
	secondRequest.Spec.Sort = firstRequest.Spec.Sort
	openCtx, cancelOpen := context.WithTimeout(context.Background(), 300*time.Millisecond)
	second, err := runtime.OpenContext(openCtx, secondRequest)
	cancelOpen()
	if err != nil {
		t.Fatalf("compatible warm Open waited for projection admission: %v", err)
	}
	defer second.Close()
	if got := synchronousProjections.Load(); got != 1 {
		t.Fatalf("synchronous projections = %d, want only the initial cold Open", got)
	}

	initial := drainSubscription(t, second)
	var staleFromWarm bool
	for _, event := range initial {
		if status := event.GetStatus(); status != nil {
			staleFromWarm = staleFromWarm || (status.GetFromWarmCache() &&
				status.GetFreshness() == kmgrv1.ViewFreshness_VIEW_FRESHNESS_STALE)
		}
	}
	invalidation := firstInvalidation(initial)
	if invalidation == nil {
		t.Fatalf("cached first paint omitted invalidation: %#v", initial)
	}
	rangeResult, err := runtime.FetchRange(
		"session", "second", second.generation,
		invalidation.GetPresentationRevision(), invalidation.GetIndexRevision(),
		0, DefaultViewRangeLength,
	)
	if err != nil {
		t.Fatal(err)
	}
	initialUIDs := rangeRowUIDs(rangeResult.Rows)
	if !staleFromWarm || !slices.Equal(initialUIDs, []string{"uid-b", "uid-a"}) {
		t.Fatalf("cached first paint stale=%t UIDs=%v", staleFromWarm, initialUIDs)
	}
	if second.resource.warmProjection != nil {
		t.Fatal("published active resource retained a second compact presentation")
	}

	runtime.releaseOpenProjection()
	gateHeld = false
	waitForUIDWithoutRemoval(t, second, "uid-c", "uid-a", "uid-b")
	if got := synchronousProjections.Load(); got != 1 {
		t.Fatalf("background catch-up invoked synchronous Open hook, calls=%d", got)
	}
}

func TestRuntimeWarmProjectionReopensDuringReleaseDebounce(t *testing.T) {
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-1", "", pod("uid", "ns", "pod", "Running", 0, nil, time.Time{}),
	)}
	var projectionCalls atomic.Int64
	runtime, err := NewRuntime(RuntimeConfig{
		Source:              &fakeResourceSource{authority: "cluster-a", client: client},
		ReleaseDelay:        time.Hour,
		BatchDelay:          time.Millisecond,
		OpenProjectionLimit: 1,
		openProjectionHook:  func() { projectionCalls.Add(1) },
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session", "first", 1))
	if err != nil {
		t.Fatal(err)
	}
	eventually(t, time.Second, func() bool {
		first.mu.Lock()
		defer first.mu.Unlock()
		return first.snapshotComplete && len(first.rows) == 1
	})
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		return first.resource.state == resourceRunning &&
			first.resource.lastStatus.Phase == watcher.PhaseWatching
	})
	entry := first.resource
	first.Close()
	runtime.mu.Lock()
	candidatePresent := entry.warmProjection != nil
	debouncing := entry.releaseTimer != nil && entry.state == resourceRunning
	_, finalizedWarm := runtime.getWarmLocked(entry.key)
	runtime.mu.Unlock()
	if !candidatePresent || !debouncing || finalizedWarm {
		t.Fatalf("post-close candidate=%t debouncing=%t finalized=%t", candidatePresent, debouncing, finalizedWarm)
	}

	runtime.openProjectionGate <- struct{}{}
	gateHeld := true
	defer func() {
		if gateHeld {
			runtime.releaseOpenProjection()
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	second, err := runtime.OpenContext(ctx, openView("session", "second", 1))
	cancel()
	if err != nil {
		t.Fatalf("debounce reopen waited for projection gate: %v", err)
	}
	defer second.Close()
	events := drainSubscription(t, second)
	if got := snapshotEventUIDs(second, events); !slices.Equal(got, []string{"uid"}) {
		t.Fatalf("debounce cached UIDs = %v, want [uid]", got)
	}
	var staleFromWarm bool
	for _, event := range events {
		status := event.GetStatus()
		staleFromWarm = staleFromWarm || (status.GetFromWarmCache() &&
			status.GetFreshness() == kmgrv1.ViewFreshness_VIEW_FRESHNESS_STALE)
	}
	if !staleFromWarm {
		t.Fatal("debounce reopen did not expose cached rows as stale")
	}
	if got := projectionCalls.Load(); got != 1 {
		t.Fatalf("debounce reopen synchronous projections = %d, want 1 cold projection total", got)
	}
	runtime.releaseOpenProjection()
	gateHeld = false

	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		refreshed, nextErr := second.Next(ctx)
		cancel()
		if nextErr != nil {
			if errors.Is(nextErr, context.DeadlineExceeded) {
				continue
			}
			t.Fatal(nextErr)
		}
		if err := second.AcknowledgeDelivery(refreshed); err != nil {
			t.Fatal(err)
		}
		for _, event := range refreshed {
			status := event.GetStatus()
			if status.GetFreshness() == kmgrv1.ViewFreshness_VIEW_FRESHNESS_WATCHING &&
				!status.GetFromWarmCache() {
				return
			}
		}
	}
	t.Fatal("authoritative debounce catch-up did not restore current watching status")
}

func TestRuntimeConcurrentCompatibleWarmOpensBothBypassAdmission(t *testing.T) {
	client := newScriptedResource()
	runtime, err := NewRuntime(RuntimeConfig{
		Source:              &fakeResourceSource{authority: "cluster-a", client: client},
		BatchDelay:          time.Millisecond,
		OpenProjectionLimit: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	request := openView("session", "fixture", 1)
	object := pod("uid", "ns", "pod", "Running", 0, nil, time.Time{})
	installWarmProjectionFixture(t, runtime, client, request, true, []*unstructured.Unstructured{object}, nil)

	reachedHandoff := make(chan struct{}, 2)
	releaseHandoff := make(chan struct{})
	runtime.openHandoffHook = func() {
		reachedHandoff <- struct{}{}
		<-releaseHandoff
	}
	runtime.openProjectionGate <- struct{}{}
	gateHeld := true
	defer func() {
		if gateHeld {
			runtime.releaseOpenProjection()
		}
	}()
	type openResult struct {
		subscription *Subscription
		err          error
	}
	results := make(chan openResult, 2)
	for _, viewID := range []string{"first", "second"} {
		viewID := viewID
		go func() {
			openRequest := openView("session", viewID, 1)
			subscription, openErr := runtime.Open(openRequest)
			results <- openResult{subscription: subscription, err: openErr}
		}()
		select {
		case <-reachedHandoff:
		case <-time.After(300 * time.Millisecond):
			close(releaseHandoff)
			t.Fatalf("compatible Open %q waited for saturated projection admission", viewID)
		}
	}
	close(releaseHandoff)
	opened := make([]*Subscription, 0, 2)
	for range 2 {
		result := <-results
		if result.err != nil {
			t.Fatal(result.err)
		}
		opened = append(opened, result.subscription)
	}
	for _, subscription := range opened {
		if got := snapshotEventUIDs(subscription, drainSubscription(t, subscription)); !slices.Equal(got, []string{"uid"}) {
			t.Fatalf("concurrent cached UIDs = %v, want [uid]", got)
		}
	}
	runtime.releaseOpenProjection()
	gateHeld = false
	for _, subscription := range opened {
		subscription.Close()
	}
}

func TestRuntimeIncompatibleWarmProjectionUsesNormalProjection(t *testing.T) {
	client := newScriptedResource()
	var projectionCalls atomic.Int64
	runtime, err := NewRuntime(RuntimeConfig{
		Source:             &fakeResourceSource{authority: "cluster-a", client: client},
		BatchDelay:         time.Hour,
		openProjectionHook: func() { projectionCalls.Add(1) },
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	request := openView("session", "view", 1)
	old := pod("uid-old", "ns", "old", "Running", 0, nil, time.Time{})
	newest := pod("uid-new", "ns", "new", "Running", 0, nil, time.Time{})
	entry := installWarmProjectionFixture(t, runtime, client, request, true, []*unstructured.Unstructured{old, newest}, nil)

	request.Spec.FilterExpression = "new"
	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	if got := projectionCalls.Load(); got != 1 {
		t.Fatalf("incompatible Open projection calls = %d, want 1", got)
	}
	if entry.warmProjection != nil {
		t.Fatal("successful incompatible Open retained unusable compact rows")
	}
	events := drainSubscription(t, subscription)
	if got := snapshotEventUIDs(subscription, events); !slices.Equal(got, []string{"uid-new"}) {
		t.Fatalf("incompatible initial projection UIDs = %v, want [uid-new]", got)
	}
}

func TestRuntimeIncompleteWarmProjectionDoesNotInventRemoval(t *testing.T) {
	client := newScriptedResource()
	listGate := make(chan struct{})
	client.beforeListPage = map[int]chan struct{}{0: listGate}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:              &fakeResourceSource{authority: "cluster-a", client: client},
		BatchDelay:          time.Millisecond,
		OpenProjectionLimit: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	request := openView("session", "view", 1)
	staleObject := pod("uid-stale", "ns", "stale", "Running", 0, nil, time.Time{})
	projector, err := projectorFromProto("session", request.GetSpec(), nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	staleRows, err := projector.ProjectContext(context.Background(), []*unstructured.Unstructured{staleObject})
	if err != nil {
		t.Fatal(err)
	}
	installWarmProjectionFixture(t, runtime, client, request, false, nil, staleRows)

	runtime.openProjectionGate <- struct{}{}
	gateHeld := true
	defer func() {
		if gateHeld {
			runtime.releaseOpenProjection()
		}
	}()
	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	initial := drainSubscription(t, subscription)
	if got := snapshotEventUIDs(subscription, initial); !slices.Equal(got, []string{"uid-stale"}) {
		t.Fatalf("incomplete cached first paint UIDs = %v", got)
	}

	runtime.releaseOpenProjection()
	gateHeld = false
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		events, nextErr := subscription.Next(ctx)
		cancel()
		if nextErr != nil {
			if errors.Is(nextErr, context.DeadlineExceeded) {
				continue
			}
			t.Fatal(nextErr)
		}
		if err := subscription.AcknowledgeDelivery(events); err != nil {
			t.Fatal(err)
		}
		if invalidation := firstInvalidation(events); invalidation != nil && invalidation.GetRowsVisible() == 0 {
			return
		}
	}
	t.Fatal("incomplete authoritative catch-up did not publish its empty visible snapshot")
}

func TestRuntimeCompleteWarmProjectionCatchupInvalidatesMissingUID(t *testing.T) {
	client := newScriptedResource()
	runtime, err := NewRuntime(RuntimeConfig{
		Source:              &fakeResourceSource{authority: "cluster-a", client: client},
		BatchDelay:          time.Millisecond,
		OpenProjectionLimit: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	request := openView("session", "view", 1)
	staleObject := pod("uid-missing", "ns", "missing", "Running", 0, nil, time.Time{})
	projector, err := projectorFromProto("session", request.GetSpec(), nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	staleRows, err := projector.ProjectContext(context.Background(), []*unstructured.Unstructured{staleObject})
	if err != nil {
		t.Fatal(err)
	}
	installWarmProjectionFixture(t, runtime, client, request, true, nil, staleRows)

	runtime.openProjectionGate <- struct{}{}
	gateHeld := true
	defer func() {
		if gateHeld {
			runtime.releaseOpenProjection()
		}
	}()
	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	if got := snapshotEventUIDs(subscription, drainSubscription(t, subscription)); !slices.Equal(got, []string{"uid-missing"}) {
		t.Fatalf("complete cached first paint UIDs = %v", got)
	}
	runtime.releaseOpenProjection()
	gateHeld = false

	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		events, nextErr := subscription.Next(ctx)
		cancel()
		if nextErr != nil {
			if errors.Is(nextErr, context.DeadlineExceeded) {
				continue
			}
			t.Fatal(nextErr)
		}
		if err := subscription.AcknowledgeDelivery(events); err != nil {
			t.Fatal(err)
		}
		if invalidation := firstInvalidation(events); invalidation != nil && invalidation.GetRowsVisible() == 0 {
			return
		}
	}
	t.Fatal("complete authoritative catch-up did not invalidate missing cached UID")
}

func TestRuntimeRetirementCancelsWarmCatchupWaitingForAdmission(t *testing.T) {
	client := newScriptedResource()
	runtime, err := NewRuntime(RuntimeConfig{
		Source:              &fakeResourceSource{authority: "cluster-a", client: client},
		BatchDelay:          time.Millisecond,
		OpenProjectionLimit: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	request := openView("session", "view", 1)
	object := pod("uid", "ns", "pod", "Running", 0, nil, time.Time{})
	installWarmProjectionFixture(t, runtime, client, request, true, []*unstructured.Unstructured{object}, nil)
	runtime.openProjectionGate <- struct{}{}
	gateHeld := true
	defer func() {
		if gateHeld {
			runtime.releaseOpenProjection()
		}
	}()

	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	drainSubscription(t, subscription)
	eventually(t, time.Second, func() bool {
		subscription.mu.Lock()
		defer subscription.mu.Unlock()
		return subscription.projectionRunning
	})
	subscription.Close()
	eventually(t, time.Second, func() bool {
		subscription.mu.Lock()
		defer subscription.mu.Unlock()
		return subscription.closed && !subscription.projectionRunning &&
			errors.Is(subscription.projectionContext.Err(), context.Canceled)
	})
	runtime.releaseOpenProjection()
	gateHeld = false
}

func TestRuntimeClosePreservesProjectionAcrossAbortedSameResourceOpen(t *testing.T) {
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-1", "", pod("uid", "ns", "pod", "Running", 0, nil, time.Time{}),
	)}
	secondProjectionStarted := make(chan struct{})
	releaseSecondProjection := make(chan struct{})
	var projectionCalls atomic.Int64
	runtime, err := NewRuntime(RuntimeConfig{
		Source:       &fakeResourceSource{authority: "cluster-a", client: client},
		ReleaseDelay: time.Hour,
		BatchDelay:   time.Millisecond,
		openProjectionHook: func() {
			if projectionCalls.Add(1) == 2 {
				close(secondProjectionStarted)
				<-releaseSecondProjection
			}
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	active, err := runtime.Open(openView("session", "active", 1))
	if err != nil {
		t.Fatal(err)
	}
	eventually(t, time.Second, func() bool {
		active.mu.Lock()
		defer active.mu.Unlock()
		return active.snapshotComplete && len(active.rows) == 1
	})
	entry := active.resource

	openingCtx, cancelOpening := context.WithCancel(context.Background())
	openingDone := make(chan error, 1)
	go func() {
		_, openErr := runtime.OpenContext(openingCtx, openView("session", "opening", 1))
		openingDone <- openErr
	}()
	select {
	case <-secondProjectionStarted:
	case <-time.After(time.Second):
		t.Fatal("same-resource replacement projection did not start")
	}
	active.Close()
	if entry.warmProjection == nil {
		t.Fatal("sole active close skipped provisional capture while an opener was in flight")
	}
	cancelOpening()
	close(releaseSecondProjection)
	if err := <-openingDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("aborted same-resource Open error = %v, want canceled", err)
	}
	if entry.warmProjection == nil {
		t.Fatal("aborted opener discarded the previous committed presentation")
	}

	runtime.openProjectionGate <- struct{}{}
	gateHeld := true
	defer func() {
		if gateHeld {
			runtime.releaseOpenProjection()
		}
	}()
	reopenCtx, cancelReopen := context.WithTimeout(context.Background(), 300*time.Millisecond)
	reopened, err := runtime.OpenContext(reopenCtx, openView("session", "reopened", 1))
	cancelReopen()
	if err != nil {
		t.Fatalf("reopen after aborted opener did not use provisional rows: %v", err)
	}
	defer reopened.Close()
	if got := snapshotEventUIDs(reopened, drainSubscription(t, reopened)); !slices.Equal(got, []string{"uid"}) {
		t.Fatalf("reopened provisional UIDs = %v, want [uid]", got)
	}
	runtime.releaseOpenProjection()
	gateHeld = false
}

func TestRuntimeConcurrentFinalClosesRetainOneProjection(t *testing.T) {
	runtime, err := NewRuntime(RuntimeConfig{
		Source:       &fakeResourceSource{},
		ReleaseDelay: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	entry, first, second := installTwoManualSubscriptions(t, runtime)

	first.mu.Lock()
	second.mu.Lock()
	firstDone := make(chan struct{})
	secondDone := make(chan struct{})
	go func() {
		first.Close()
		close(firstDone)
	}()
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		_, closing := entry.closing[first]
		return closing
	})
	go func() {
		second.Close()
		close(secondDone)
	}()
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		return len(entry.closing) == 2
	})

	// Let the designated all-closing stream detach first. It must retain its
	// candidate provisionally even though the other stream is still attached.
	second.mu.Unlock()
	select {
	case <-secondDone:
	case <-time.After(time.Second):
		first.mu.Unlock()
		t.Fatal("second concurrent close did not finish")
	}
	if entry.warmProjection == nil {
		first.mu.Unlock()
		t.Fatal("all-closing stream did not retain a provisional projection")
	}
	first.mu.Unlock()
	select {
	case <-firstDone:
	case <-time.After(time.Second):
		t.Fatal("first concurrent close did not finish")
	}
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	if len(entry.subscribers) != 0 || len(entry.closing) != 0 || entry.warmProjection == nil {
		t.Fatalf("concurrent closes left subscribers=%d closing=%d projection=%t",
			len(entry.subscribers), len(entry.closing), entry.warmProjection != nil)
	}
}

func TestRuntimeDuplicateConcurrentCloseLeavesCaptureOwnerInControl(t *testing.T) {
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{}, ReleaseDelay: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	entry, subscription, peer := installTwoManualSubscriptions(t, runtime)
	peer.Close()

	subscription.mu.Lock()
	ownerDone := make(chan struct{})
	duplicateDone := make(chan struct{})
	go func() {
		subscription.Close()
		close(ownerDone)
	}()
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		_, closing := entry.closing[subscription]
		return closing
	})
	go func() {
		subscription.Close()
		close(duplicateDone)
	}()
	select {
	case <-duplicateDone:
	case <-time.After(time.Second):
		subscription.mu.Unlock()
		t.Fatal("duplicate close waited on the capture owner's subscription lock")
	}
	subscription.mu.Unlock()
	select {
	case <-ownerDone:
	case <-time.After(time.Second):
		t.Fatal("capture-owning close did not finish")
	}
	if entry.warmProjection == nil {
		t.Fatal("duplicate close detached before the capture owner retained rows")
	}
}

func TestRuntimeDifferentResourceReplacementCapturesAfterPeerClose(t *testing.T) {
	services := newScriptedResource()
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &gvrResourceSource{
			authority: "cluster-a",
			clients:   map[string]watcher.ListerWatcher{"services": services},
		},
		ReleaseDelay: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	oldEntry, replacing, peer := installTwoManualSubscriptions(t, runtime)
	reachedHandoff := make(chan struct{})
	releaseHandoff := make(chan struct{})
	runtime.openHandoffHook = func() {
		close(reachedHandoff)
		<-releaseHandoff
	}

	replacementRequest := openView("session", replacing.key.viewID, 2)
	replacementRequest.Spec.Resource.Resource = "services"
	replacementRequest.Spec.Resource.Kind = "Service"
	replacementDone := make(chan struct {
		subscription *Subscription
		err          error
	}, 1)
	go func() {
		subscription, openErr := runtime.Open(replacementRequest)
		replacementDone <- struct {
			subscription *Subscription
			err          error
		}{subscription: subscription, err: openErr}
	}()
	select {
	case <-reachedHandoff:
	case <-time.After(time.Second):
		t.Fatal("different-resource replacement did not reach handoff")
	}
	peer.mu.Lock()
	peerCloseDone := make(chan struct{})
	go func() {
		peer.Close()
		close(peerCloseDone)
	}()
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		_, closing := oldEntry.closing[peer]
		return closing
	})
	close(releaseHandoff)
	result := <-replacementDone
	if result.err != nil {
		peer.mu.Unlock()
		t.Fatal(result.err)
	}
	defer result.subscription.Close()
	if oldEntry.warmProjection == nil {
		peer.mu.Unlock()
		t.Fatal("replacement skipped old presentation after its peer detached")
	}
	peer.mu.Unlock()
	select {
	case <-peerCloseDone:
	case <-time.After(time.Second):
		t.Fatal("peer close did not finish after replacement handoff")
	}
}

func TestWarmProjectionCaptureSkipsRawStoreAlreadyAtByteCeiling(t *testing.T) {
	entry := newWarmBudgetEntry("cluster-a", "pods", string(make([]byte, 64<<10)))
	rawBytes := entry.store.RetainedBytes()
	runtime, err := NewRuntime(RuntimeConfig{
		Source:                      &fakeResourceSource{},
		WarmByteLimit:               rawBytes,
		WarmByteLimitPerAuthority:   rawBytes,
		WarmViewLimit:               8,
		WarmObjectLimit:             100,
		WarmViewLimitPerAuthority:   8,
		WarmObjectLimitPerAuthority: 100,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	projector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session",
		Resource:         ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
	})
	if err != nil {
		t.Fatal(err)
	}
	subscription := newSubscription(viewKey{sessionID: "session", viewID: "view"}, 1, projector, time.Hour, 100)
	subscription.runtime = runtime
	subscription.resource = entry
	entry.subscribers[subscription] = struct{}{}
	runtime.mu.Lock()
	runtime.resources[entry.key] = entry
	runtime.views[subscription.key] = subscription
	registered, capture := runtime.prepareSubscriptionCloseLocked(subscription)
	runtime.cancelSubscriptionCloseLocked(subscription)
	runtime.mu.Unlock()
	if !registered || capture {
		t.Fatalf("raw-ceiling close registration=%t capture=%t, want true/false", registered, capture)
	}
}

func TestWarmProjectionBytesParticipateInGlobalAndAuthorityEviction(t *testing.T) {
	for _, test := range []struct {
		name               string
		firstAuthority     string
		secondAuthority    string
		globalLimitFactor  int64
		authorityLimitFact int64
	}{
		{
			name: "global", firstAuthority: "cluster-a", secondAuthority: "cluster-b",
			globalLimitFactor: 1, authorityLimitFact: 2,
		},
		{
			name: "per authority", firstAuthority: "cluster-a", secondAuthority: "cluster-a",
			globalLimitFactor: 2, authorityLimitFact: 1,
		},
	} {
		test := test
		t.Run(test.name, func(t *testing.T) {
			first := warmProjectionBudgetEntry(test.firstAuthority, "pods-a", 4096)
			second := warmProjectionBudgetEntry(test.secondAuthority, "pods-b", 4096)
			firstBytes := saturatingProjectionBytes(first.store.RetainedBytes(), first.warmProjection.retainedBytes)
			secondBytes := saturatingProjectionBytes(second.store.RetainedBytes(), second.warmProjection.retainedBytes)
			if firstBytes != secondBytes {
				t.Fatalf("equal-shaped combined weights = %d and %d", firstBytes, secondBytes)
			}
			runtime, err := NewRuntime(RuntimeConfig{
				Source:                      &fakeResourceSource{},
				WarmViewLimit:               8,
				WarmObjectLimit:             100,
				WarmByteLimit:               test.globalLimitFactor * firstBytes,
				WarmViewLimitPerAuthority:   8,
				WarmObjectLimitPerAuthority: 100,
				WarmByteLimitPerAuthority:   test.authorityLimitFact * firstBytes,
			})
			if err != nil {
				t.Fatal(err)
			}
			defer runtime.Close()

			admitWarmBudgetEntry(runtime, first)
			admitWarmBudgetEntry(runtime, second)
			runtime.mu.Lock()
			defer runtime.mu.Unlock()
			if runtime.resources[first.key] != nil || first.warmProjection != nil {
				t.Fatal("projected-byte pressure retained the evicted compact row graph")
			}
			if runtime.resources[second.key] != second || second.warmProjection == nil {
				t.Fatal("projected-byte pressure did not retain the newest fitting entry")
			}
			if got := runtime.warm.ByteCount(); got != secondBytes {
				t.Fatalf("global warm bytes = %d, want %d", got, secondBytes)
			}
		})
	}
}

func TestWarmProjectionOversizeFallsBackToRawStore(t *testing.T) {
	entry := warmProjectionBudgetEntry("cluster-a", "pods", 64<<10)
	rawBytes := entry.store.RetainedBytes()
	limit := rawBytes + entry.warmProjection.retainedBytes - 1
	runtime, err := NewRuntime(RuntimeConfig{
		Source:                      &fakeResourceSource{},
		WarmViewLimit:               8,
		WarmObjectLimit:             100,
		WarmByteLimit:               limit,
		WarmViewLimitPerAuthority:   8,
		WarmObjectLimitPerAuthority: 100,
		WarmByteLimitPerAuthority:   limit,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	admitWarmBudgetEntry(runtime, entry)
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	cached, warm := runtime.getWarmLocked(entry.key)
	if !warm || cached.Value != entry {
		t.Fatal("oversized optional projection also discarded fitting raw store")
	}
	if entry.warmProjection != nil {
		t.Fatal("oversized optional projection retained its row references")
	}
	if cached.ByteCount != rawBytes {
		t.Fatalf("raw-only warm bytes = %d, want %d", cached.ByteCount, rawBytes)
	}
}

func TestWarmProjectionEvictionForcesNormalOpenProjection(t *testing.T) {
	client := newScriptedResource()
	var projectionCalls atomic.Int64
	runtime, err := NewRuntime(RuntimeConfig{
		Source:                      &fakeResourceSource{authority: "cluster-a", client: client},
		WarmViewLimit:               1,
		WarmObjectLimit:             100,
		WarmViewLimitPerAuthority:   1,
		WarmObjectLimitPerAuthority: 100,
		openProjectionHook:          func() { projectionCalls.Add(1) },
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	request := openView("session", "view", 1)
	entry := installWarmProjectionFixture(t, runtime, client, request, true, []*unstructured.Unstructured{
		pod("uid", "ns", "pod", "Running", 0, nil, time.Time{}),
	}, nil)
	other := warmProjectionBudgetEntry("cluster-a", "nodes", 4096)
	admitWarmBudgetEntry(runtime, other)
	if entry.warmProjection != nil {
		t.Fatal("warm LRU eviction retained compact rows")
	}

	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	if got := projectionCalls.Load(); got != 1 {
		t.Fatalf("cold Open after projection eviction calls = %d, want 1", got)
	}
}

func installWarmProjectionFixture(
	t *testing.T,
	runtime *Runtime,
	client *scriptedResource,
	request *kmgrv1.OpenViewRequest,
	complete bool,
	objects []*unstructured.Unstructured,
	rows []*kmgrv1.ResourceRow,
) *resourceRuntime {
	t.Helper()
	projector, err := projectorFromProto(
		request.GetContext().GetClusterSessionId(), request.GetSpec(), runtime.columns, nil, nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	namespacePlan, err := planNamespaceStream(request.GetSpec())
	if err != nil {
		t.Fatal(err)
	}
	resource := request.GetSpec().GetResource()
	query, err := planViewQuery(request.GetSpec())
	if err != nil {
		t.Fatal(err)
	}
	entry := &resourceRuntime{
		key: resourceKey{
			authorityID: "cluster-a",
			group:       resource.GetGroup(),
			version:     resource.GetVersion(),
			resource:    resource.GetResource(),
			namespace:   namespacePlan.cacheNamespace,
			labels:      query.labelSelector,
			fields:      query.fieldSelector,
		},
		store:            store.New(),
		client:           client,
		state:            resourceIdle,
		snapshotComplete: complete,
		subscribers:      make(map[*Subscription]struct{}),
	}
	for _, object := range objects {
		entry.store.Upsert(object)
	}
	if complete {
		entry.store.SetResourceVersion("rv-warm")
		entry.lastStatus = watcher.Status{
			Phase: watcher.PhaseResuming, Stale: true, ResourceVersion: "rv-warm",
		}
	} else {
		entry.lastStatus = watcher.Status{Phase: watcher.PhaseListing, Stale: true}
	}
	if rows == nil {
		rows, err = projector.ProjectContext(context.Background(), objects)
		if err != nil {
			t.Fatal(err)
		}
	}
	entry.warmProjection = &warmProjection{
		key: projector.cacheKey, rows: rows, retainedBytes: projectedRowsRetainedBytes(rows),
	}
	runtime.mu.Lock()
	runtime.resources[entry.key] = entry
	if !runtime.finalizeWarmLocked(entry) {
		runtime.mu.Unlock()
		t.Fatal("warm projection fixture was not admitted")
	}
	runtime.mu.Unlock()
	return entry
}

func warmProjectionBudgetEntry(authorityID, resourceName string, projectionBytes int64) *resourceRuntime {
	entry := newWarmBudgetEntry(authorityID, resourceName, "")
	entry.warmProjection = &warmProjection{
		rows: []*kmgrv1.ResourceRow{{
			Identity: &kmgrv1.ResourceIdentity{Uid: authorityID + "/" + resourceName},
		}},
		retainedBytes: projectionBytes,
	}
	return entry
}

func installTwoManualSubscriptions(
	t *testing.T,
	runtime *Runtime,
) (*resourceRuntime, *Subscription, *Subscription) {
	t.Helper()
	projector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session",
		Resource: ResourceType{
			Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true,
		},
		NamespaceScope: NamespaceScope{Namespaces: []string{"ns"}},
		ColumnIDs:      []string{"name"},
	})
	if err != nil {
		t.Fatal(err)
	}
	object := pod("uid", "ns", "pod", "Running", 0, nil, time.Time{})
	rows, err := projector.ProjectContext(context.Background(), []*unstructured.Unstructured{object})
	if err != nil {
		t.Fatal(err)
	}
	entry := &resourceRuntime{
		key:              resourceKey{authorityID: "cluster-a", version: "v1", resource: "pods", namespace: "ns"},
		store:            store.New(),
		state:            resourceIdle,
		snapshotComplete: true,
		subscribers:      make(map[*Subscription]struct{}),
	}
	entry.store.Upsert(object)
	entry.store.SetResourceVersion("rv")
	entry.lastStatus = watcher.Status{ResourceVersion: "rv"}
	makeSubscription := func(viewID string) *Subscription {
		subscription := newSubscription(
			viewKey{sessionID: "session", viewID: viewID}, 1, projector, time.Hour, 100,
		)
		subscription.runtime = runtime
		subscription.resource = entry
		subscription.snapshotComplete = true
		subscription.initializeSealedRows(rows)
		return subscription
	}
	first := makeSubscription("first")
	second := makeSubscription("second")
	entry.subscribers[first] = struct{}{}
	entry.subscribers[second] = struct{}{}
	runtime.mu.Lock()
	runtime.resources[entry.key] = entry
	runtime.views[first.key] = first
	runtime.views[second.key] = second
	runtime.mu.Unlock()
	return entry, first, second
}

func projectionUIDs(rows []*kmgrv1.ResourceRow) []string {
	result := make([]string, 0, len(rows))
	for _, row := range rows {
		result = append(result, row.GetIdentity().GetUid())
	}
	return result
}

func snapshotEventUIDs(subscription *Subscription, events []*kmgrv1.ViewEvent) []string {
	return rangeRowUIDs(invalidationRows(subscription, events))
}

func waitForUIDWithoutRemoval(t *testing.T, subscription *Subscription, uid string, preserved ...string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		events, err := subscription.Next(ctx)
		cancel()
		if err != nil {
			if errors.Is(err, context.DeadlineExceeded) {
				continue
			}
			t.Fatal(err)
		}
		if err := subscription.AcknowledgeDelivery(events); err != nil {
			t.Fatal(err)
		}
		for _, row := range invalidationRows(subscription, events) {
			if row.GetIdentity().GetUid() == uid {
				for _, preservedUID := range preserved {
					if !subscriptionHasUID(subscription, preservedUID) {
						t.Fatalf("authoritative catch-up lost raw-present UID %q", preservedUID)
					}
				}
				return
			}
		}
	}
	t.Fatalf("never observed authoritative UID %q", uid)
}
