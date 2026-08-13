package view

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/store"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"

	"github.com/charlie0129/kmgr/backend/internal/watcher"
)

func TestRuntimeCompatibleReopenAfterCancelRetainsAcknowledgedIdentity(t *testing.T) {
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-1", "", pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{}),
	)}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster-a", client: client}, ReleaseDelay: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, first, "uid-a")
	first.resource.store.Delete("uid-a")
	first.Close()

	second, err := runtime.Open(openView("session", "view", 2))
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	drainSubscription(t, second) // sealed authoritative snapshot
	tombstone := drainSubscription(t, second)
	if !containsRemovedUID(tombstone, "uid-a") {
		t.Fatalf("compatible reopen omitted canceled-stream tombstone: %#v", tombstone)
	}
}

func TestRuntimeUnacknowledgedTombstoneIsRebuiltByReplacement(t *testing.T) {
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-1", "", pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{}),
	)}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster-a", client: client}, ReleaseDelay: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, first, "uid-a")
	first.resource.store.Delete("uid-a")
	first.enqueueWatchBatch(watcher.Batch{RemovedUIDs: []types.UID{"uid-a"}})
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	unacknowledged, err := first.Next(ctx)
	cancel()
	if err != nil {
		t.Fatal(err)
	}
	if !containsRemovedUID(unacknowledged, "uid-a") {
		t.Fatalf("first generation did not drain tombstone: %#v", unacknowledged)
	}
	// Model a failed gRPC Send: the batch is deliberately not acknowledged.
	first.Close()

	second, err := runtime.Open(openView("session", "view", 2))
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	drainSubscription(t, second) // sealed authoritative snapshot
	tombstone := drainSubscription(t, second)
	if !containsRemovedUID(tombstone, "uid-a") {
		t.Fatalf("replacement omitted unacknowledged tombstone: %#v", tombstone)
	}
}

func TestRuntimeColdOpenDefersPersistedTombstoneUntilSnapshotComplete(t *testing.T) {
	tests := []struct {
		name         string
		finalObjects []*unstructured.Unstructured
		wantRemoved  bool
	}{
		{name: "identity arrives on final page", finalObjects: []*unstructured.Unstructured{
			pod("uid-late", "ns", "late", "Running", 0, nil, time.Time{}),
		}},
		{name: "identity absent from complete snapshot", wantRemoved: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			client := newScriptedResource()
			finalPageGate := make(chan struct{})
			finalPageReleased := false
			defer func() {
				if !finalPageReleased {
					close(finalPageGate)
				}
			}()
			client.listPages = []*unstructured.UnstructuredList{
				listPage("rv-1", "next", pod("uid-first", "ns", "first", "Running", 0, nil, time.Time{})),
				listPage("rv-1", "", test.finalObjects...),
			}
			client.beforeListPage = map[int]chan struct{}{1: finalPageGate}
			runtime, err := NewRuntime(RuntimeConfig{
				Source: &fakeResourceSource{authority: "cluster-a", client: client}, ReleaseDelay: time.Hour,
			})
			if err != nil {
				t.Fatal(err)
			}
			defer runtime.Close()

			request := openView("session", "view", 1)
			projector, err := projectorFromProto("session", request.GetSpec(), runtime.columns)
			if err != nil {
				t.Fatal(err)
			}
			serverScope, err := serverNamespace(request.GetSpec())
			if err != nil {
				t.Fatal(err)
			}
			key := resourceKey{
				authorityID: "cluster-a",
				group:       request.GetSpec().GetResource().GetGroup(),
				version:     request.GetSpec().GetResource().GetVersion(),
				resource:    request.GetSpec().GetResource().GetResource(),
				namespace:   serverScope,
				labels:      request.GetSpec().GetLabelSelector(),
				fields:      request.GetSpec().GetFieldSelector(),
			}
			state := &logicalViewDeliveryState{
				signature: deliverySignature{
					resource: key,
					namespaceScope: canonicalNamespaceScope(
						projector.spec.Resource, projector.spec.NamespaceScope,
					),
				},
				knownUIDs: map[string]struct{}{"uid-late": {}},
			}
			runtime.mu.Lock()
			runtime.deliveryStates[viewKey{sessionID: "session", viewID: "view"}] = state
			runtime.mu.Unlock()

			subscription, err := runtime.Open(request)
			if err != nil {
				t.Fatal(err)
			}
			defer subscription.Close()
			eventually(t, time.Second, func() bool { return client.listCalls.Load() >= 2 })

			// Page one is only a prefix of the consistent LIST. uid-late may be
			// on a later page, so its absence cannot yet produce a tombstone.
			subscription.mu.Lock()
			pendingBeforeFinal := subscription.knownUIDs["uid-late"]
			_, queuedBeforeFinal := subscription.pendingRemoved["uid-late"]
			completeBeforeFinal := subscription.snapshotComplete
			subscription.mu.Unlock()
			if pendingBeforeFinal || queuedBeforeFinal || completeBeforeFinal {
				t.Fatalf(
					"partial LIST marked retained identity removed: pending=%t queued=%t complete=%t",
					pendingBeforeFinal, queuedBeforeFinal, completeBeforeFinal,
				)
			}

			close(finalPageGate)
			finalPageReleased = true
			eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })
			subscription.mu.Lock()
			pendingAfterFinal := subscription.knownUIDs["uid-late"]
			_, queuedAfterFinal := subscription.pendingRemoved["uid-late"]
			completeAfterFinal := subscription.snapshotComplete
			subscription.mu.Unlock()
			if !completeAfterFinal || pendingAfterFinal != test.wantRemoved || queuedAfterFinal != test.wantRemoved {
				t.Fatalf(
					"complete LIST identity state: pending=%t queued=%t complete=%t, want removed=%t",
					pendingAfterFinal, queuedAfterFinal, completeAfterFinal, test.wantRemoved,
				)
			}
			if test.wantRemoved {
				drainSubscription(t, subscription) // sealed cold snapshot
				if events := drainSubscription(t, subscription); !containsRemovedUID(events, "uid-late") {
					t.Fatalf("complete snapshot omitted retained identity tombstone: %#v", events)
				}
			}
		})
	}
}

func TestRuntimeCompatibleReplacementReconcilesPriorInFlightIdentity(t *testing.T) {
	client := newScriptedResource()
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster-a", client: client}, ReleaseDelay: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	key := resourceKey{authorityID: "cluster-a", version: "v1", resource: "pods", namespace: "ns"}
	entry := &resourceRuntime{
		key: key, store: store.New(), client: client, state: resourceRunning,
		subscribers: make(map[*Subscription]struct{}), dependents: make(map[*Subscription]struct{}),
		accountingReady: true,
	}
	entry.store.SetResourceVersion("rv-1")
	runtime.mu.Lock()
	runtime.resources[key] = entry
	runtime.mu.Unlock()

	first, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	drainSubscription(t, first) // acknowledge the initial empty snapshot
	object := pod("uid-partial", "ns", "partial", "Running", 0, nil, time.Time{})
	entry.store.Upsert(object)
	first.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{object}})
	first.flushProjection()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	inFlight, err := first.Next(ctx)
	cancel()
	if err != nil {
		t.Fatal(err)
	}
	if !containsUpsertUID(inFlight, "uid-partial") {
		t.Fatalf("first generation did not deliver partial-send candidate: %#v", inFlight)
	}
	// Model a transport failure after the upsert may have reached the client.
	// The batch remains unacknowledged while a compatible generation replaces it.
	entry.store.Delete("uid-partial")

	second, err := runtime.Open(openView("session", "view", 2))
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	drainSubscription(t, second) // sealed authoritative snapshot
	tombstone := drainSubscription(t, second)
	if !containsRemovedUID(tombstone, "uid-partial") {
		t.Fatalf("replacement forgot identity from prior in-flight batch: %#v", tombstone)
	}
}

func TestRuntimeOpenCatchupUsesSnapshotCompletionThatWonPublicationRace(t *testing.T) {
	client := newScriptedResource()
	projectionStarted := make(chan struct{})
	releaseProjection := make(chan struct{})
	runtime, err := NewRuntime(RuntimeConfig{
		Source:       &fakeResourceSource{authority: "cluster-a", client: client},
		ReleaseDelay: time.Hour,
		openProjectionHook: func() {
			close(projectionStarted)
			<-releaseProjection
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	key := resourceKey{authorityID: "cluster-a", version: "v1", resource: "pods", namespace: "ns"}
	entry := &resourceRuntime{
		key: key, store: store.New(), client: client, state: resourceRunning, runNumber: 7,
		subscribers: make(map[*Subscription]struct{}), dependents: make(map[*Subscription]struct{}),
	}
	runtime.mu.Lock()
	runtime.resources[key] = entry
	runtime.deliveryStates[viewKey{sessionID: "session", viewID: "view"}] = &logicalViewDeliveryState{
		signature: deliverySignature{resource: key, namespaceScope: "namespaces:ns"},
		knownUIDs: map[string]struct{}{"uid-absent": {}},
	}
	runtime.mu.Unlock()

	done := make(chan struct {
		subscription *Subscription
		err          error
	}, 1)
	go func() {
		subscription, openErr := runtime.Open(openView("session", "view", 1))
		done <- struct {
			subscription *Subscription
			err          error
		}{subscription, openErr}
	}()
	<-projectionStarted

	// Complete the empty LIST and its runtime callback before Open publishes.
	// The callback sees no subscriber, so Open must schedule a fresh catch-up
	// using the newer completion state rather than its older empty snapshot bit.
	entry.store.SetResourceVersion("rv-final")
	runtime.receiveBatch(entry, 7, watcher.Batch{FromList: true, SnapshotComplete: true})
	close(releaseProjection)
	result := <-done
	if result.err != nil {
		t.Fatal(result.err)
	}
	defer result.subscription.Close()
	drainSubscription(t, result.subscription)
	if events := drainSubscription(t, result.subscription); !containsRemovedUID(events, "uid-absent") {
		t.Fatalf("authoritative catch-up omitted persisted tombstone: %#v", events)
	}
	result.subscription.mu.Lock()
	complete := result.subscription.snapshotComplete
	result.subscription.mu.Unlock()
	if !complete {
		t.Fatal("catch-up did not retain completed snapshot state")
	}
}

func TestRuntimeAbortedIncompatibleOpenDoesNotReplaceDeliveryIdentity(t *testing.T) {
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-1", "", pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{}),
	)}
	projectionStarted := make(chan struct{})
	releaseProjection := make(chan struct{})
	var projectionCalls int
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster-a", client: client}, ReleaseDelay: time.Hour,
		OpenProjectionLimit: 2,
		openProjectionHook: func() {
			projectionCalls++
			if projectionCalls == 2 {
				close(projectionStarted)
				<-releaseProjection
			}
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, first, "uid-a")
	owner := first.deliveryState

	incompatible := openView("session", "view", 2)
	incompatible.Spec.NamespaceScope = &kmgrv1.NamespaceScope{Namespaces: []string{"other"}}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, openErr := runtime.OpenContext(ctx, incompatible)
		done <- openErr
	}()
	<-projectionStarted
	cancel()
	close(releaseProjection)
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("incompatible open error = %v, want canceled", err)
	}
	runtime.mu.Lock()
	retained := runtime.deliveryStates[viewKey{sessionID: "session", viewID: "view"}]
	runtime.mu.Unlock()
	if retained != owner {
		t.Fatal("aborted incompatible open replaced committed delivery identity")
	}
}

func TestRuntimeIncompatibleReplacementStartsFreshDeliveryIdentity(t *testing.T) {
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-1", "", pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{}),
	)}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster-a", client: client}, ReleaseDelay: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, first, "uid-a")
	oldOwner := first.deliveryState

	incompatible := openView("session", "view", 2)
	incompatible.Spec.NamespaceScope = &kmgrv1.NamespaceScope{Namespaces: []string{"other"}}
	second, err := runtime.Open(incompatible)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	if second.deliveryState == oldOwner {
		t.Fatal("incompatible replacement reused prior delivery identity")
	}
	second.deliveryState.mu.Lock()
	_, leaked := second.deliveryState.knownUIDs["uid-a"]
	second.deliveryState.mu.Unlock()
	if leaked {
		t.Fatal("incompatible replacement inherited prior UID")
	}
}

func TestSubscriptionDeleteDuringSendCannotBeAcknowledgedLive(t *testing.T) {
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-1", "", pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{}),
	)}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster-a", client: client}, ReleaseDelay: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, first, "uid-a")
	first.enqueueWatchBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-a", "ns", "updated", "Running", 1, nil, time.Time{}),
	}})
	first.flushProjection()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	inFlight, err := first.Next(ctx)
	cancel()
	if err != nil {
		t.Fatal(err)
	}
	first.resource.store.Delete("uid-a")
	first.enqueueWatchBatch(watcher.Batch{RemovedUIDs: []types.UID{"uid-a"}})
	if err := first.AcknowledgeDelivery(inFlight); err != nil {
		t.Fatal(err)
	}
	first.Close()

	second, err := runtime.Open(openView("session", "view", 2))
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	drainSubscription(t, second)
	tombstone := drainSubscription(t, second)
	if !containsRemovedUID(tombstone, "uid-a") {
		t.Fatalf("delete racing Send was acknowledged live: %#v", tombstone)
	}
}

func TestRuntimeOldDeliveryAcknowledgementMayFinishAfterCompatibleReplacement(t *testing.T) {
	client := newScriptedResource()
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster-a", client: client}, ReleaseDelay: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	inFlight, err := first.Next(ctx)
	cancel()
	if err != nil {
		t.Fatal(err)
	}
	first.deliveryState.mu.Lock()
	deliveryStateLocked := true
	defer func() {
		if deliveryStateLocked {
			first.deliveryState.mu.Unlock()
		}
	}()
	done := make(chan error, 1)
	go func() {
		done <- first.AcknowledgeDelivery(inFlight)
	}()

	// AcknowledgeDelivery takes Subscription.mu before the shared delivery
	// state. Holding the latter here lets the test prove the acknowledgement
	// owns the former before replacement publication tries to retire it.
	deadline := time.Now().Add(time.Second)
	for first.mu.TryLock() {
		first.mu.Unlock()
		if time.Now().After(deadline) {
			t.Fatal("acknowledgement did not acquire subscription lock")
		}
		time.Sleep(time.Millisecond)
	}

	replacementDone := make(chan error, 1)
	go func() {
		second, openErr := runtime.Open(openView("session", "view", 2))
		if second != nil {
			second.Close()
		}
		replacementDone <- openErr
	}()
	first.deliveryState.mu.Unlock()
	deliveryStateLocked = false
	if err := <-done; err != nil {
		t.Fatalf("old acknowledgement error = %v", err)
	}
	if err := <-replacementDone; err != nil {
		t.Fatal(err)
	}
}

func containsRemovedUID(events []*kmgrv1.ViewEvent, uid string) bool {
	for _, event := range events {
		if slices.Contains(event.GetDelta().GetRemovedUids(), uid) {
			return true
		}
	}
	return false
}

func containsUpsertUID(events []*kmgrv1.ViewEvent, uid string) bool {
	for _, event := range events {
		for _, row := range event.GetDelta().GetUpserts() {
			if row.GetIdentity().GetUid() == uid {
				return true
			}
		}
	}
	return false
}
