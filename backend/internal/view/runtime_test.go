package view

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	"github.com/charlie0129/kmgr/backend/internal/store"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"

	"github.com/charlie0129/kmgr/backend/internal/watcher"
)

func TestRuntimeDeliversPermanentPipelineErrorOnceAsNonRetryable(t *testing.T) {
	t.Parallel()
	var runs atomic.Int32
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{
			authority: "cluster-a",
			client:    newScriptedResource(),
		},
		BatchDelay: time.Millisecond,
		pipelineRunHook: func(context.Context, func(context.Context) error) error {
			runs.Add(1)
			return apierrors.NewBadRequest("unsupported field selector")
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	subscription, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	var failure *kmgrv1.StructuredError
	for failure == nil {
		events, err := subscription.Next(ctx)
		if err != nil {
			t.Fatal(err)
		}
		for _, event := range events {
			if event.GetError() != nil {
				failure = event.GetError()
				break
			}
		}
		if err := subscription.AcknowledgeDelivery(events); err != nil {
			t.Fatal(err)
		}
	}
	if failure.GetRetryable() || failure.GetHttpStatusCode() != 400 ||
		failure.GetReason() != string(metav1.StatusReasonBadRequest) {
		t.Fatalf("permanent failure = %#v", failure)
	}
	time.Sleep(20 * time.Millisecond)
	if got := runs.Load(); got != 1 {
		t.Fatalf("pipeline runs = %d, want one terminal run", got)
	}
}

func TestRuntimeSharesCompatiblePipelineAndDebouncesFinalRelease(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage("rv-1", "", pod("uid-a", "ns", "a", "Running", 0, nil, time.Time{}))}
	source := &fakeResourceSource{authority: "cluster-a", client: client}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: source, ReleaseDelay: 25 * time.Millisecond, BatchDelay: time.Millisecond,
		PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session-1", "view-1", 1))
	if err != nil {
		t.Fatal(err)
	}
	second, err := runtime.Open(openView("session-2", "view-2", 1))
	if err != nil {
		t.Fatal(err)
	}
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })
	if source.opens.Load() != 2 {
		t.Fatalf("source opens = %d, want one resolution per view", source.opens.Load())
	}

	first.Close()
	if client.lastWatch().stopped.Load() {
		t.Fatal("shared watch stopped while second consumer remained")
	}
	second.Close()
	time.Sleep(10 * time.Millisecond)
	third, err := runtime.Open(openView("session-1", "view-3", 1))
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(30 * time.Millisecond)
	if client.lastWatch().stopped.Load() {
		t.Fatal("watch stopped despite reacquire during debounce")
	}
	third.Close()
	eventually(t, time.Second, func() bool { return client.lastWatch().stopped.Load() })
}

func TestRuntimeReturnsWarmSnapshotBeforeResumeAndAvoidsRelist(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage("rv-1", "", pod("uid-a", "ns", "a", "Running", 0, nil, time.Time{}))}
	source := &fakeResourceSource{authority: "cluster-a", client: client}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: source, ReleaseDelay: 5 * time.Millisecond, BatchDelay: time.Millisecond,
		SnapshotChunkSize: 1, PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session-1", "view-1", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, first, "uid-a")
	first.Close()
	eventually(t, time.Second, func() bool { return client.lastWatch().stopped.Load() })

	second, err := runtime.Open(openView("session-1", "view-2", 1))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	events, err := second.Next(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var freshness []kmgrv1.ViewFreshness
	var snapshotUIDs []string
	for _, event := range events {
		if event.GetStatus() != nil {
			freshness = append(freshness, event.GetStatus().GetFreshness())
		}
		for _, row := range event.GetSnapshot().GetRows() {
			snapshotUIDs = append(snapshotUIDs, row.GetIdentity().GetUid())
		}
	}
	if !slices.Contains(freshness, kmgrv1.ViewFreshness_VIEW_FRESHNESS_STALE) {
		t.Fatalf("first warm delivery freshness = %v, missing STALE", freshness)
	}
	if !slices.Contains(snapshotUIDs, "uid-a") {
		t.Fatalf("first warm delivery UIDs = %v", snapshotUIDs)
	}
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() >= 2 })
	if client.listCalls.Load() != 1 {
		t.Fatalf("warm resume LIST calls = %d, want 1 initial LIST only", client.listCalls.Load())
	}
	if got := client.lastWatchResourceVersion(); got != "rv-1" {
		t.Fatalf("resume resourceVersion = %q, want rv-1", got)
	}
}

func TestRuntimeReopenWaitsForStoppedPipelineBeforeRestart(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	firstCanceled := make(chan struct{})
	releaseFirstExit := make(chan struct{})
	secondStarted := make(chan struct{})
	var runs atomic.Int64
	runtime, err := NewRuntime(RuntimeConfig{
		Source:       &fakeResourceSource{authority: "cluster-a", client: client},
		ReleaseDelay: 5 * time.Millisecond, BatchDelay: time.Millisecond,
		pipelineRunHook: func(ctx context.Context, run func(context.Context) error) error {
			number := runs.Add(1)
			if number == 2 {
				close(secondStarted)
			}
			err := run(ctx)
			if number == 1 {
				close(firstCanceled)
				<-releaseFirstExit
			}
			return err
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	first, err := runtime.Open(openView("session", "first", 1))
	if err != nil {
		t.Fatal(err)
	}
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })
	first.Close()
	select {
	case <-firstCanceled:
	case <-time.After(time.Second):
		t.Fatal("released pipeline did not observe cancellation")
	}

	second, err := runtime.Open(openView("session", "second", 1))
	if err != nil {
		close(releaseFirstExit)
		t.Fatal(err)
	}
	defer second.Close()
	select {
	case <-secondStarted:
		close(releaseFirstExit)
		t.Fatal("replacement pipeline started before old Run exited")
	case <-time.After(50 * time.Millisecond):
	}
	if got := runs.Load(); got != 1 {
		close(releaseFirstExit)
		t.Fatalf("pipeline runs while stopping = %d, want 1", got)
	}
	close(releaseFirstExit)
	select {
	case <-secondStarted:
	case <-time.After(time.Second):
		t.Fatal("replacement pipeline did not start after old Run exited")
	}
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 2 })
}

func TestRuntimeDefersWarmAdmissionUntilPipelineExitAcknowledged(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-warm", "", pod("uid-warm", "ns", "warm", "Running", 0, nil, time.Time{}),
	)}
	pipelineCanceled := make(chan struct{})
	releaseExit := make(chan struct{})
	runtime, err := NewRuntime(RuntimeConfig{
		Source:       &fakeResourceSource{authority: "cluster-a", client: client},
		ReleaseDelay: 5 * time.Millisecond, BatchDelay: time.Millisecond,
		pipelineRunHook: func(ctx context.Context, run func(context.Context) error) error {
			err := run(ctx)
			close(pipelineCanceled)
			<-releaseExit
			return err
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	subscription, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, subscription, "uid-warm")
	key := subscription.resource.key
	subscription.Close()
	select {
	case <-pipelineCanceled:
	case <-time.After(time.Second):
		t.Fatal("pipeline did not acknowledge cancellation")
	}
	runtime.mu.Lock()
	state := subscription.resource.state
	runtime.mu.Unlock()
	if state != resourceStopping || runtime.warm.Len() != 0 {
		close(releaseExit)
		t.Fatalf("before Run exit: state=%v warm=%d", state, runtime.warm.Len())
	}

	close(releaseExit)
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		cached, warm := runtime.warm.Get(key)
		return warm && cached.Value == subscription.resource && subscription.resource.state == resourceIdle
	})
}

func TestRuntimeAcceptsMatchingLateBatchWhilePipelineStopping(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster-a", client: client}, BatchDelay: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	projector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session",
		Resource:         ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope:   NamespaceScope{Namespaces: []string{"ns"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	entry := &resourceRuntime{
		key:   resourceKey{authorityID: "cluster-a", version: "v1", resource: "pods", namespace: "ns"},
		store: store.New(), client: client, state: resourceStopping, runNumber: 9,
		subscribers: make(map[*Subscription]struct{}),
	}
	subscription := newSubscription(viewKey{sessionID: "session", viewID: "view"}, 1, projector, time.Hour, 100, 100)
	subscription.resource = entry
	entry.subscribers[subscription] = struct{}{}
	runtime.mu.Lock()
	runtime.resources[entry.key] = entry
	runtime.mu.Unlock()

	late := pod("uid-late", "ns", "late", "Running", 0, nil, time.Time{})
	entry.store.Upsert(late)
	runtime.receiveBatch(entry, 9, watcher.Batch{Upserts: []*unstructured.Unstructured{late}})
	subscription.flushProjection()
	subscription.mu.Lock()
	row := subscription.rows["uid-late"]
	subscription.mu.Unlock()
	runtime.mu.Lock()
	revision := entry.revision
	runtime.mu.Unlock()
	if row == nil || revision != 1 {
		t.Fatalf("late stopping batch: row=%#v revision=%d", row, revision)
	}
}

func TestRuntimeDropsReleasedResourceRejectedByWarmObjectBudget(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-1", "",
		pod("uid-a", "ns", "api-a", "Running", 0, nil, time.Time{}),
		pod("uid-b", "ns", "api-b", "Running", 0, nil, time.Time{}),
	)}
	source := &fakeResourceSource{authority: "cluster-a", client: client}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: source, ReleaseDelay: 5 * time.Millisecond, BatchDelay: time.Millisecond,
		WarmObjectLimit: 1, PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session-1", "view-1", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, first, "uid-b")
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })
	key := first.resource.key
	first.Close()
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		_, retained := runtime.resources[key]
		_, warm := runtime.warm.Get(key)
		return client.lastWatch().stopped.Load() && !retained && !warm
	})

	searchResult, err := runtime.SearchCached(context.Background(), CachedSearchQuery{
		SessionID: "session-1", NamespaceScope: NamespaceScope{All: true},
		Query: "api", ResultLimit: 10, ExaminationLimit: 100,
	})
	if err != nil {
		t.Fatal(err)
	}
	if searchResult.Examined != 0 || len(searchResult.Results) != 0 {
		t.Fatalf("search retained rejected warm objects: %#v", searchResult)
	}

	secondListGate := make(chan struct{})
	client.mu.Lock()
	client.beforeListPage = map[int]chan struct{}{0: secondListGate}
	client.mu.Unlock()
	second, err := runtime.Open(openView("session-1", "view-2", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	eventually(t, time.Second, func() bool { return client.listCalls.Load() == 2 })

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	events, err := second.Next(ctx)
	cancel()
	if err != nil {
		t.Fatal(err)
	}
	if err := second.AcknowledgeDelivery(events); err != nil {
		t.Fatal(err)
	}
	var freshness []kmgrv1.ViewFreshness
	var snapshotRows int
	var sawEmptySnapshot bool
	for _, event := range events {
		if status := event.GetStatus(); status != nil {
			freshness = append(freshness, status.GetFreshness())
			if status.GetFromWarmCache() {
				t.Fatalf("cold reopen reported warm-cache status: %#v", status)
			}
		}
		if snapshot := event.GetSnapshot(); snapshot != nil {
			sawEmptySnapshot = snapshot.GetFirstChunk() && snapshot.GetLastChunk() && len(snapshot.GetRows()) == 0
			snapshotRows += len(snapshot.GetRows())
		}
	}
	if !slices.Contains(freshness, kmgrv1.ViewFreshness_VIEW_FRESHNESS_LOADING) ||
		slices.Contains(freshness, kmgrv1.ViewFreshness_VIEW_FRESHNESS_STALE) ||
		!sawEmptySnapshot || snapshotRows != 0 {
		t.Fatalf("cold initial delivery: freshness=%v, saw empty snapshot=%t, rows=%d", freshness, sawEmptySnapshot, snapshotRows)
	}

	close(secondListGate)
	waitForSnapshotUID(t, second, "uid-a")
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 2 })
	if client.listCalls.Load() != 2 {
		t.Fatalf("cold reopen LIST calls = %d, want 2 total", client.listCalls.Load())
	}
}

func TestCachedChildrenUsesOnlyMatchingAuthorityAndDeduplicatesViewStores(t *testing.T) {
	t.Parallel()
	ownerUID := types.UID("owner-uid")
	child := pod("child-uid", "ns", "child", "Running", 0, nil, time.Time{})
	child.SetOwnerReferences([]metav1.OwnerReference{{UID: ownerUID}})
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage("rv-1", "", child)}
	source := &fakeResourceSource{
		authority: "cluster-a",
		client:    client,
		sessions: map[string]string{
			"session-a": "cluster-a", "session-shared": "cluster-a", "session-b": "cluster-b",
		},
	}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: source, BatchDelay: time.Millisecond, PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session-a", "first", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	second, err := runtime.Open(openView("session-shared", "second", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	waitForSnapshotUID(t, first, "child-uid")

	children := runtime.CachedChildren("session-shared", string(ownerUID))
	if len(children) != 1 || children[0].Resource != "pods" || children[0].Object.GetUID() != "child-uid" {
		t.Fatalf("cached children = %#v", children)
	}
	if got := runtime.CachedChildren("session-b", string(ownerUID)); len(got) != 0 {
		t.Fatalf("other-authority cached children = %#v", got)
	}
	if got := runtime.CachedChildren("session-a", "different-owner"); len(got) != 0 {
		t.Fatalf("wrong-owner cached children = %#v", got)
	}
}

func TestRuntimeRelistKeepsWarmRowsUntilFinalPage(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{
		listPage("rv-1", "", pod("old-a", "ns", "old-a", "Running", 0, nil, time.Time{}), pod("old-b", "ns", "old-b", "Running", 0, nil, time.Time{})),
	}
	source := &fakeResourceSource{authority: "cluster-a", client: client}
	runtime, err := NewRuntime(RuntimeConfig{Source: source, ReleaseDelay: 5 * time.Millisecond, BatchDelay: time.Millisecond, PipelineTimeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session-1", "view-1", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, first, "old-b")
	first.Close()
	eventually(t, time.Second, func() bool { return client.lastWatch().stopped.Load() })

	pageGate := make(chan struct{})
	client.mu.Lock()
	client.expireNextWatch = true
	client.listPages = []*unstructured.UnstructuredList{
		listPage("rv-2", "next", pod("new-a", "ns", "new-a", "Running", 0, nil, time.Time{})),
		listPage("rv-2", "", pod("old-a", "ns", "old-a", "Running", 0, nil, time.Time{})),
	}
	client.beforeListPage = map[int]chan struct{}{1: pageGate}
	client.mu.Unlock()

	second, err := runtime.Open(openView("session-1", "view-2", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, second, "old-b")
	eventually(t, time.Second, func() bool { return client.listCalls.Load() >= 2 })

	// The first relist page arrived, but old-b must not be removed until the
	// consistent second/final page commits reconciliation.
	time.Sleep(15 * time.Millisecond)
	second.mu.Lock()
	_, retained := second.rows["old-b"]
	second.mu.Unlock()
	if !retained {
		t.Fatal("cached old-b was removed before relist completed")
	}
	close(pageGate)
	eventually(t, time.Second, func() bool {
		second.mu.Lock()
		defer second.mu.Unlock()
		_, oldB := second.rows["old-b"]
		_, oldA := second.rows["old-a"]
		_, newA := second.rows["new-a"]
		return !oldB && oldA && newA
	})
}

func TestRuntimeCancelledWarmRelistReopensWithForcedList(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{
		listPage("rv-initial", "", pod("uid-old", "ns", "old", "Running", 0, nil, time.Time{})),
	}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:       &fakeResourceSource{authority: "cluster-a", client: client},
		ReleaseDelay: 5 * time.Millisecond, BatchDelay: time.Millisecond, PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session", "first", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, first, "uid-old")
	key := first.resource.key
	first.Close()
	eventually(t, time.Second, func() bool { return client.lastWatch().stopped.Load() })

	finalPageGate := make(chan struct{})
	client.mu.Lock()
	client.expireNextWatch = true
	client.listPages = []*unstructured.UnstructuredList{
		listPage("rv-interrupted", "next", pod("uid-partial", "ns", "partial", "Running", 0, nil, time.Time{})),
		listPage("rv-interrupted", "", pod("uid-never", "ns", "never", "Running", 0, nil, time.Time{})),
	}
	client.beforeListPage = map[int]chan struct{}{1: finalPageGate}
	client.mu.Unlock()

	second, err := runtime.Open(openView("session", "second", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, second, "uid-partial")
	eventually(t, time.Second, func() bool { return client.listCalls.Load() >= 3 })
	second.Close()

	var interrupted watcher.WarmEntry[*resourceRuntime]
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		cached, ok := runtime.warm.Get(key)
		if !ok || cached.Value.state != resourceIdle {
			return false
		}
		interrupted = cached
		return true
	})
	if interrupted.Complete || interrupted.ResourceVersion != "" ||
		interrupted.Value.store.ResourceVersion() != "" || interrupted.Value.snapshotComplete {
		t.Fatalf("interrupted relist admitted as complete: %#v, storeRV=%q ready=%t",
			interrupted, interrupted.Value.store.ResourceVersion(), interrupted.Value.snapshotComplete)
	}

	client.mu.Lock()
	client.listPages = []*unstructured.UnstructuredList{
		listPage("rv-reopened", "", pod("uid-final", "ns", "final", "Running", 0, nil, time.Time{})),
	}
	client.beforeListPage = nil
	client.mu.Unlock()

	third, err := runtime.Open(openView("session", "third", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer third.Close()
	waitForSnapshotUID(t, third, "uid-final")
	eventually(t, time.Second, func() bool {
		return client.listCalls.Load() >= 4 && client.lastWatchResourceVersion() == "rv-reopened"
	})
	if got := client.watchCalls.Load(); got != 3 {
		t.Fatalf("watch calls = %d, want initial, expired resume, and post-reopen watch", got)
	}
	eventually(t, time.Second, func() bool {
		third.mu.Lock()
		defer third.mu.Unlock()
		_, old := third.rows["uid-old"]
		_, partial := third.rows["uid-partial"]
		_, final := third.rows["uid-final"]
		return !old && !partial && final
	})
}

func TestRuntimeLastSynchronizedSurvivesWarmResumeRelistAndWatch(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{
		listPage("rv-initial", "", pod("uid-a", "ns", "a", "Running", 0, nil, time.Time{})),
	}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:       &fakeResourceSource{authority: "cluster-a", client: client},
		ReleaseDelay: 5 * time.Millisecond, BatchDelay: time.Millisecond, PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session", "first-timestamp", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, first, "uid-a")
	key := first.resource.key
	var listedAt time.Time
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		listedAt = first.resource.lastStatus.LastSynchronized
		return first.resource.lastStatus.Phase == watcher.PhaseWatching && !listedAt.IsZero()
	})
	first.Close()
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		cached, ok := runtime.warm.Get(key)
		return ok && cached.LastSynchronized.Equal(listedAt)
	})

	second, err := runtime.Open(openView("session", "second-timestamp", 1))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	initial, err := second.Next(ctx)
	cancel()
	if err != nil {
		second.Close()
		t.Fatal(err)
	}
	if err := second.AcknowledgeDelivery(initial); err != nil {
		second.Close()
		t.Fatal(err)
	}
	warmTimestamp := int64(0)
	for _, event := range initial {
		if status := event.GetStatus(); status != nil && status.GetFromWarmCache() {
			warmTimestamp = status.GetLastSynchronizedUnixMs()
			break
		}
	}
	if warmTimestamp != listedAt.UnixMilli() {
		second.Close()
		t.Fatalf("warm resume timestamp = %d, want %d", warmTimestamp, listedAt.UnixMilli())
	}
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 2 })
	time.Sleep(time.Millisecond)
	bookmark := &unstructured.Unstructured{}
	bookmark.SetResourceVersion("rv-bookmark")
	client.lastWatch().channel <- watch.Event{Type: watch.Bookmark, Object: bookmark}
	var watchedAt time.Time
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		watchedAt = second.resource.lastStatus.LastSynchronized
		return second.resource.store.ResourceVersion() == "rv-bookmark" && watchedAt.After(listedAt)
	})
	second.Close()
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		cached, ok := runtime.warm.Get(key)
		return ok && cached.ResourceVersion == "rv-bookmark" && cached.LastSynchronized.Equal(watchedAt)
	})

	relistGate := make(chan struct{})
	client.mu.Lock()
	client.expireNextWatch = true
	client.listPages = []*unstructured.UnstructuredList{
		listPage("rv-relisted", "", pod("uid-b", "ns", "b", "Running", 0, nil, time.Time{})),
	}
	client.beforeListPage = map[int]chan struct{}{0: relistGate}
	client.mu.Unlock()

	third, err := runtime.Open(openView("session", "third-timestamp", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer third.Close()
	ctx, cancel = context.WithTimeout(context.Background(), time.Second)
	initial, err = third.Next(ctx)
	cancel()
	if err != nil {
		t.Fatal(err)
	}
	if err := third.AcknowledgeDelivery(initial); err != nil {
		t.Fatal(err)
	}
	warmTimestamp = 0
	for _, event := range initial {
		if status := event.GetStatus(); status != nil && status.GetFromWarmCache() {
			warmTimestamp = status.GetLastSynchronizedUnixMs()
			break
		}
	}
	if warmTimestamp != watchedAt.UnixMilli() {
		t.Fatalf("second warm timestamp = %d, want %d", warmTimestamp, watchedAt.UnixMilli())
	}
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		return third.resource.lastStatus.Phase == watcher.PhaseListing &&
			third.resource.lastStatus.LastSynchronized.Equal(watchedAt) &&
			third.resource.store.ResourceVersion() == "" && !third.resource.snapshotComplete
	})
	time.Sleep(time.Millisecond)
	close(relistGate)
	var relistedAt time.Time
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		relistedAt = third.resource.lastStatus.LastSynchronized
		return third.resource.lastStatus.Phase == watcher.PhaseWatching &&
			third.resource.store.ResourceVersion() == "rv-relisted" && relistedAt.After(watchedAt)
	})
}

func TestSlowSubscriptionFallsBackToBoundedSnapshot(t *testing.T) {
	projector := newRuntimeTestProjector(t, "", nil)
	subscription, _ := newControlledProjectionSubscription(projector)
	subscription.chunkSize = 2
	subscription.pendingLimit = 2
	subscription.resource = &resourceRuntime{store: store.New()}

	objects := []*unstructured.Unstructured{
		pod("uid-1", "ns", "one", "Running", 0, nil, time.Time{}),
		pod("uid-2", "ns", "two", "Running", 0, nil, time.Time{}),
		pod("uid-3", "ns", "three", "Running", 0, nil, time.Time{}),
	}
	// Runtime batches arrive only after watcher has applied them to the
	// authoritative store. This direct unit-test injection must mirror that
	// contract so overflow can fall back to a bounded full resnapshot.
	for _, object := range objects {
		subscription.resource.store.Upsert(object)
	}
	subscription.applyBatch(watcher.Batch{Upserts: objects})
	subscription.flushProjection()
	subscription.mu.Lock()
	if !subscription.resnapshot || len(subscription.pendingUpserts) != 0 {
		t.Fatalf("slow mailbox state: resnapshot=%v pending=%d", subscription.resnapshot, len(subscription.pendingUpserts))
	}
	subscription.signalLocked(true)
	subscription.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	events, err := subscription.Next(ctx)
	if err != nil {
		t.Fatal(err)
	}
	chunks := 0
	rows := 0
	for _, event := range events {
		if event.GetSnapshot() != nil {
			chunks++
			rows += len(event.GetSnapshot().GetRows())
			if len(event.GetSnapshot().GetRows()) > 2 {
				t.Fatal("snapshot chunk exceeded configured bound")
			}
		}
	}
	if chunks != 2 || rows != 3 {
		t.Fatalf("snapshot chunks=%d rows=%d", chunks, rows)
	}
}

func TestStagedSubscriptionEmitsReconciliationAfterCompleteReplacement(t *testing.T) {
	projector := newRuntimeTestProjector(t, "", nil)
	subscription := newSubscription(
		viewKey{sessionID: "session", viewID: "view"},
		1,
		projector,
		time.Hour,
		100,
		100,
	)
	subscription.stageUntilReconciled = true
	subscription.resource = &resourceRuntime{store: store.New()}
	subscription.sealInitial(
		&kmgrv1.ViewStatus{Freshness: kmgrv1.ViewFreshness_VIEW_FRESHNESS_LOADING},
		nil,
		false,
	)

	initial := drainSubscription(t, subscription)
	if len(initial) != 2 || initial[0].GetStatus() == nil || initial[1].GetSnapshot() == nil {
		t.Fatalf("initial staged delivery = %#v, want loading status and empty snapshot", initial)
	}
	for _, event := range initial {
		if event.GetReconciled() != nil {
			t.Fatal("cold placeholder was incorrectly marked reconciled")
		}
	}

	first := pod("uid-a", "ns", "a", "Running", 0, nil, time.Time{})
	subscription.resource.store.Upsert(first)
	subscription.applyBatch(watcher.Batch{
		Upserts:       []*unstructured.Unstructured{first},
		FromList:      true,
		ObjectsListed: 1,
	})
	partial := drainSubscription(t, subscription)
	for _, event := range partial {
		if event.GetReconciled() != nil {
			t.Fatal("partial LIST page was incorrectly marked reconciled")
		}
	}

	second := pod("uid-b", "ns", "b", "Running", 0, nil, time.Time{})
	subscription.resource.store.Upsert(second)
	subscription.applyBatch(watcher.Batch{
		Upserts:          []*unstructured.Unstructured{second},
		FromList:         true,
		ObjectsListed:    2,
		SnapshotComplete: true,
		SynchronizedAt:   time.Unix(100, 0),
	})
	complete := drainSubscription(t, subscription)
	if len(complete) < 2 || complete[len(complete)-1].GetReconciled() == nil {
		t.Fatalf("complete delivery = %#v, want reconciliation marker last", complete)
	}
	if got := complete[len(complete)-1].GetReconciled().GetRowsVisible(); got != 2 {
		t.Fatalf("reconciled rows = %d, want 2", got)
	}
}

func TestSubscriptionCapturesNowOnceForWatchBatch(t *testing.T) {
	t.Parallel()
	projector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session-a",
		Resource:         ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope:   NamespaceScope{All: true},
		ColumnIDs:        []string{"age"},
	})
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 8, 13, 10, 0, 0, 0, time.UTC)
	clockCalls := 0
	projector.now = func() time.Time {
		clockCalls++
		return now
	}
	subscription := newSubscription(
		viewKey{sessionID: "session-a", viewID: "view-a"},
		1,
		projector,
		time.Hour,
		100,
		100,
	)

	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-a", "ns", "api", "Running", 0, nil, now.Add(-time.Minute)),
		pod("uid-b", "ns", "worker", "Running", 0, nil, now.Add(-2*time.Minute)),
	}})
	subscription.flushProjection()
	if clockCalls != 1 {
		t.Fatalf("watch batch clock calls = %d, want 1", clockCalls)
	}
}

func TestSubscriptionCoalescesWatchBurstNewestPerUID(t *testing.T) {
	projector := newRuntimeTestProjector(t, "", nil)
	subscription, scheduled := newControlledProjectionSubscription(projector)

	for index := range 100 {
		subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
			pod("uid-a", "ns", fmt.Sprintf("api-%03d", index), "Running", int64(index), nil, time.Time{}),
		}})
	}

	subscription.mu.Lock()
	if len(subscription.pendingObjects) != 1 || subscription.rows["uid-a"] != nil ||
		subscription.projectionPasses != 0 || subscription.projectedObjects != 0 {
		t.Fatalf("before flush: pending=%d row=%v passes=%d objects=%d",
			len(subscription.pendingObjects), subscription.rows["uid-a"],
			subscription.projectionPasses, subscription.projectedObjects)
	}
	subscription.mu.Unlock()

	flushCapturedProjection(t, scheduled)
	subscription.mu.Lock()
	row := subscription.rows["uid-a"]
	passes, objects := subscription.projectionPasses, subscription.projectedObjects
	subscription.mu.Unlock()
	if row == nil || row.GetIdentity().GetName() != "api-099" {
		t.Fatalf("coalesced row = %#v, want newest api-099", row)
	}
	if passes != 1 || objects != 1 {
		t.Fatalf("projection work: passes=%d objects=%d, want one/one", passes, objects)
	}
}

func TestSubscriptionCoalescesReorderBurstToOneFinalOrder(t *testing.T) {
	projector := newRuntimeTestProjector(t, "", []SortDescriptor{{ColumnID: "restarts", Descending: true}})
	subscription, scheduled := newControlledProjectionSubscription(projector)

	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-a", "ns", "a", "Running", 1, nil, time.Time{}),
		pod("uid-b", "ns", "b", "Running", 2, nil, time.Time{}),
		pod("uid-c", "ns", "c", "Running", 3, nil, time.Time{}),
	}})
	flushCapturedProjection(t, scheduled)
	subscription.mu.Lock()
	subscription.signalLocked(true)
	subscription.mu.Unlock()
	drainSubscription(t, subscription)
	drainNotify(subscription)

	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-a", "ns", "a", "Running", 8, nil, time.Time{}),
		pod("uid-b", "ns", "b", "Running", 7, nil, time.Time{}),
	}})
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-a", "ns", "a", "Running", 4, nil, time.Time{}),
		pod("uid-c", "ns", "c", "Running", 9, nil, time.Time{}),
	}})
	subscription.mu.Lock()
	passesBefore := subscription.projectionPasses
	subscription.mu.Unlock()
	flushCapturedProjection(t, scheduled)
	subscription.mu.Lock()
	subscription.signalLocked(true)
	subscription.mu.Unlock()

	events := drainSubscription(t, subscription)
	var delta *kmgrv1.RowDelta
	for _, event := range events {
		if event.GetDelta() != nil {
			delta = event.GetDelta()
		}
	}
	if delta == nil || !delta.GetOrderIsComplete() ||
		!slices.Equal(delta.GetOrderedUids(), []string{"uid-c", "uid-b", "uid-a"}) {
		t.Fatalf("reorder delta = %#v", delta)
	}
	subscription.mu.Lock()
	passesAfter := subscription.projectionPasses
	subscription.mu.Unlock()
	if passesAfter != passesBefore+1 {
		t.Fatalf("reorder burst projection passes = %d, want %d", passesAfter, passesBefore+1)
	}
}

func TestSubscriptionNonSortUpdateDoesNotRebuildOrResendCompleteOrder(t *testing.T) {
	projector := newRuntimeTestProjector(
		t, "", []SortDescriptor{{ColumnID: "restarts", Descending: true}},
	)
	subscription, scheduled := newControlledProjectionSubscription(projector)

	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-a", "ns", "a", "Pending", 1, nil, time.Time{}),
		pod("uid-b", "ns", "b", "Running", 2, nil, time.Time{}),
		pod("uid-c", "ns", "c", "Running", 3, nil, time.Time{}),
	}})
	flushCapturedProjection(t, scheduled)
	subscription.mu.Lock()
	subscription.signalLocked(true)
	subscription.mu.Unlock()
	drainSubscription(t, subscription)
	drainNotify(subscription)

	// Status is rendered in the row but is not a sort key. Updating it should
	// upsert exactly that row without rebuilding or retransmitting the complete
	// UID order for the unchanged table.
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-a", "ns", "a", "Running", 1, nil, time.Time{}),
	}})
	flushCapturedProjection(t, scheduled)
	subscription.mu.Lock()
	subscription.signalLocked(true)
	subscription.mu.Unlock()

	events := drainSubscription(t, subscription)
	var delta *kmgrv1.RowDelta
	for _, event := range events {
		if event.GetDelta() != nil {
			delta = event.GetDelta()
		}
	}
	if delta == nil || len(delta.GetUpserts()) != 1 ||
		delta.GetUpserts()[0].GetIdentity().GetUid() != "uid-a" {
		t.Fatalf("non-sort update delta = %#v", delta)
	}
	if delta.GetOrderIsComplete() || len(delta.GetOrderedUids()) != 0 {
		t.Fatalf("non-sort update unnecessarily resent complete order = %#v", delta)
	}
	subscription.mu.Lock()
	order := append([]string(nil), subscription.order...)
	subscription.mu.Unlock()
	if !slices.Equal(order, []string{"uid-c", "uid-b", "uid-a"}) {
		t.Fatalf("stable order after non-sort update = %v", order)
	}
}

func TestSubscriptionDeleteInvalidatesInFlightUncommittedProjection(t *testing.T) {
	projector := newRuntimeTestProjector(t, "", nil)
	subscription, scheduled := newControlledProjectionSubscription(projector)
	entryStore := store.New()
	subscription.resource = &resourceRuntime{store: entryStore}
	object := pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{})
	entryStore.Upsert(object)

	started := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	projector.now = func() time.Time {
		once.Do(func() { close(started) })
		<-release
		return time.Unix(100, 0)
	}
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{object}})
	projectionDone := runCapturedProjection(t, scheduled)
	awaitSignal(t, started, "projection start")

	entryStore.Delete("uid-a")
	deleteDone := make(chan struct{})
	go func() {
		subscription.applyBatch(watcher.Batch{RemovedUIDs: []types.UID{"uid-a"}})
		close(deleteDone)
	}()
	awaitSignal(t, deleteDone, "delete ingestion while projection is blocked")
	close(release)
	awaitSignal(t, projectionDone, "projection completion")

	subscription.mu.Lock()
	row := subscription.rows["uid-a"]
	running := subscription.projectionRunning
	subscription.mu.Unlock()
	if row != nil || running {
		t.Fatalf("deleted uncommitted row resurrected: row=%#v running=%t", row, running)
	}
}

func TestSubscriptionRemovalIsPromptWhileProjectionBlocked(t *testing.T) {
	projector := newRuntimeTestProjector(t, "", nil)
	subscription, scheduled := newControlledProjectionSubscription(projector)
	baseline, _ := projector.ProjectOne(pod("uid-old", "ns", "old", "Running", 0, nil, time.Time{}))
	subscription.initializeRows([]*kmgrv1.ResourceRow{baseline})
	drainSubscription(t, subscription)

	started := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	projector.now = func() time.Time {
		once.Do(func() { close(started) })
		<-release
		return time.Unix(100, 0)
	}
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-new", "ns", "new", "Running", 0, nil, time.Time{}),
	}})
	projectionDone := runCapturedProjection(t, scheduled)
	awaitSignal(t, started, "projection start")

	subscription.applyBatch(watcher.Batch{RemovedUIDs: []types.UID{"uid-old"}})
	select {
	case <-subscription.notify:
	case <-time.After(time.Second):
		close(release)
		t.Fatal("removal was not signaled while projection was blocked")
	}
	subscription.mu.Lock()
	_, retained := subscription.rows["uid-old"]
	_, pendingRemoval := subscription.pendingRemoved["uid-old"]
	orderDirty := subscription.orderDirty
	subscription.mu.Unlock()
	if retained || pendingRemoval == false || orderDirty {
		close(release)
		t.Fatalf("prompt removal state: retained=%t pending=%t order_dirty=%t",
			retained, pendingRemoval, orderDirty)
	}

	close(release)
	awaitSignal(t, projectionDone, "projection completion")
}

func TestSubscriptionListBarrierInvalidatesInFlightWatchProjection(t *testing.T) {
	projector := newRuntimeTestProjector(t, "", nil)
	subscription, scheduled := newControlledProjectionSubscription(projector)
	entryStore := store.New()
	subscription.resource = &resourceRuntime{store: entryStore}
	watchObject := pod("uid-a", "ns", "from-watch", "Running", 0, nil, time.Time{})
	entryStore.Upsert(watchObject)

	started := make(chan struct{})
	release := make(chan struct{})
	var calls atomic.Int64
	projector.now = func() time.Time {
		if calls.Add(1) == 1 {
			close(started)
			<-release
		}
		return time.Unix(100, 0)
	}
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{watchObject}})
	projectionDone := runCapturedProjection(t, scheduled)
	awaitSignal(t, started, "WATCH projection start")

	listDone := make(chan struct{})
	go func() {
		subscription.applyBatch(watcher.Batch{FromList: true, Upserts: []*unstructured.Unstructured{
			pod("uid-a", "ns", "from-list", "Running", 0, nil, time.Time{}),
		}})
		close(listDone)
	}()
	awaitSignal(t, listDone, "LIST barrier while WATCH projection is blocked")
	close(release)
	awaitSignal(t, projectionDone, "WATCH projection completion")

	subscription.mu.Lock()
	row := subscription.rows["uid-a"]
	subscription.mu.Unlock()
	if row == nil || row.GetIdentity().GetName() != "from-list" {
		t.Fatalf("stale WATCH projection overwrote LIST row: %#v", row)
	}
}

func TestSubscriptionListBarrierDoesNotStrandNewerWatchObject(t *testing.T) {
	projector := newRuntimeTestProjector(t, "", nil)
	subscription, scheduled := newControlledProjectionSubscription(projector)
	started := make(chan struct{})
	release := make(chan struct{})
	var calls atomic.Int64
	projector.now = func() time.Time {
		if calls.Add(1) == 1 {
			close(started)
			<-release
		}
		return time.Unix(100, 0)
	}
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-stale", "ns", "stale", "Running", 0, nil, time.Time{}),
	}})
	projectionDone := runCapturedProjection(t, scheduled)
	awaitSignal(t, started, "stale WATCH projection start")

	subscription.applyBatch(watcher.Batch{FromList: true, Upserts: []*unstructured.Unstructured{
		pod("uid-list", "ns", "listed", "Running", 0, nil, time.Time{}),
	}})
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-new", "ns", "new", "Running", 0, nil, time.Time{}),
	}})
	close(release)
	awaitSignal(t, projectionDone, "post-barrier WATCH projection")

	subscription.mu.Lock()
	row := subscription.rows["uid-new"]
	pending, running := len(subscription.pendingObjects), subscription.projectionRunning
	subscription.mu.Unlock()
	if row == nil || pending != 0 || running {
		t.Fatalf("newer WATCH object stranded: row=%#v pending=%d running=%t", row, pending, running)
	}
}

func TestSubscriptionListBarrierDiscardsOlderQueuedWatchObjects(t *testing.T) {
	projector := newRuntimeTestProjector(t, "", nil)
	subscription, scheduled := newControlledProjectionSubscription(projector)
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-a", "ns", "stale-watch", "Running", 0, nil, time.Time{}),
	}})
	staleFlush := receiveCapturedProjection(t, scheduled)

	subscription.applyBatch(watcher.Batch{FromList: true, Upserts: []*unstructured.Unstructured{
		pod("uid-a", "ns", "authoritative-list", "Running", 0, nil, time.Time{}),
	}})
	staleFlush()
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-b", "ns", "new-watch", "Running", 0, nil, time.Time{}),
	}})
	flushCapturedProjection(t, scheduled)

	subscription.mu.Lock()
	rowA, rowB := subscription.rows["uid-a"], subscription.rows["uid-b"]
	subscription.mu.Unlock()
	if rowA == nil || rowA.GetIdentity().GetName() != "authoritative-list" || rowB == nil {
		t.Fatalf("post-barrier rows: uid-a=%#v uid-b=%#v", rowA, rowB)
	}
}

func TestSubscriptionMetricsRevisionRetriesInFlightProjection(t *testing.T) {
	projector := newRuntimeTestProjector(t, "", nil)
	subscription, scheduled := newControlledProjectionSubscription(projector)
	entryStore := store.New()
	subscription.resource = &resourceRuntime{store: entryStore}
	object := pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{})
	entryStore.Upsert(object)

	started := make(chan struct{})
	release := make(chan struct{})
	var calls atomic.Int64
	projector.now = func() time.Time {
		if calls.Add(1) == 1 {
			close(started)
			<-release
		}
		return time.Unix(100, 0)
	}
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{object}})
	projectionDone := runCapturedProjection(t, scheduled)
	awaitSignal(t, started, "projection start")

	subscription.applyMetrics(metrics.Snapshot{UpdatedAt: time.Unix(200, 0)})
	close(release)
	awaitSignal(t, projectionDone, "projection retry completion")

	subscription.mu.Lock()
	passes := subscription.projectionPasses
	row := subscription.rows["uid-a"]
	running, retryPending := subscription.projectionRunning, subscription.projectionResnapshot
	subscription.mu.Unlock()
	if passes != 2 || row == nil || running || retryPending {
		t.Fatalf("metrics retry state: passes=%d row=%#v running=%t pending=%t",
			passes, row, running, retryPending)
	}
}

func TestSubscriptionFullReprojectionPreservesTrueRemoval(t *testing.T) {
	projector := newRuntimeTestProjector(t, "", nil)
	subscription, scheduled := newControlledProjectionSubscription(projector)
	entryStore := store.New()
	subscription.resource = &resourceRuntime{store: entryStore}
	object := pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{})
	entryStore.Upsert(object)
	row, _ := projector.ProjectOne(object)
	subscription.initializeRows([]*kmgrv1.ResourceRow{row})
	drainSubscription(t, subscription)
	drainNotify(subscription)

	entryStore.Delete("uid-a")
	subscription.applyBatch(watcher.Batch{RemovedUIDs: []types.UID{"uid-a"}})
	subscription.applyMetrics(metrics.Snapshot{UpdatedAt: time.Unix(200, 0)})
	flushCapturedProjection(t, scheduled)
	subscription.mu.Lock()
	subscription.signalLocked(true)
	subscription.mu.Unlock()

	events := drainSubscription(t, subscription)
	sawRemoval := false
	snapshotUIDs := make([]string, 0)
	for _, event := range events {
		sawRemoval = sawRemoval || slices.Contains(event.GetDelta().GetRemovedUids(), "uid-a")
		for _, snapshotRow := range event.GetSnapshot().GetRows() {
			snapshotUIDs = append(snapshotUIDs, snapshotRow.GetIdentity().GetUid())
		}
	}
	if !sawRemoval || slices.Contains(snapshotUIDs, "uid-a") {
		t.Fatalf("full reprojection delivery: removal=%t snapshot_uids=%v events=%#v",
			sawRemoval, snapshotUIDs, events)
	}
}

func TestSubscriptionOverflowPreservesUndrainedTrueRemoval(t *testing.T) {
	projector := newRuntimeTestProjector(t, "", nil)
	subscription, _ := newControlledProjectionSubscription(projector)
	subscription.pendingLimit = 2
	entryStore := store.New()
	subscription.resource = &resourceRuntime{store: entryStore}
	removedObject := pod("uid-old", "ns", "old", "Running", 0, nil, time.Time{})
	removedRow, _ := projector.ProjectOne(removedObject)
	subscription.initializeRows([]*kmgrv1.ResourceRow{removedRow})
	drainSubscription(t, subscription)
	drainNotify(subscription)

	subscription.applyBatch(watcher.Batch{RemovedUIDs: []types.UID{"uid-old"}})
	objects := []*unstructured.Unstructured{
		pod("uid-1", "ns", "one", "Running", 0, nil, time.Time{}),
		pod("uid-2", "ns", "two", "Running", 0, nil, time.Time{}),
		pod("uid-3", "ns", "three", "Running", 0, nil, time.Time{}),
	}
	for _, object := range objects {
		entryStore.Upsert(object)
	}
	subscription.applyBatch(watcher.Batch{Upserts: objects})
	subscription.flushProjection()
	subscription.mu.Lock()
	_, pending := subscription.pendingRemoved["uid-old"]
	subscription.signalLocked(true)
	subscription.mu.Unlock()
	if !pending {
		t.Fatal("overflow fallback discarded an undrained Kubernetes removal")
	}

	events := drainSubscription(t, subscription)
	for _, event := range events {
		if slices.Contains(event.GetDelta().GetRemovedUids(), "uid-old") {
			return
		}
	}
	t.Fatalf("overflow delivery omitted true removal: %#v", events)
}

func TestSubscriptionInvisibleUpdatesUseOrderInsteadOfRemoval(t *testing.T) {
	projector := newRuntimeTestProjector(t, "status:running", nil)
	subscription, scheduled := newControlledProjectionSubscription(projector)
	visible := pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{})
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{visible}})
	flushCapturedProjection(t, scheduled)
	subscription.mu.Lock()
	subscription.signalLocked(true)
	subscription.mu.Unlock()
	drainSubscription(t, subscription)
	drainNotify(subscription)

	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-a", "ns", "api", "Pending", 0, nil, time.Time{}),
	}})
	flushCapturedProjection(t, scheduled)
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-a", "ns", "api", "Failed", 0, nil, time.Time{}),
	}})
	flushCapturedProjection(t, scheduled)
	subscription.mu.Lock()
	subscription.signalLocked(true)
	subscription.mu.Unlock()

	events := drainSubscription(t, subscription)
	var delta *kmgrv1.RowDelta
	for _, event := range events {
		if event.GetDelta() != nil {
			delta = event.GetDelta()
		}
	}
	if delta == nil || !delta.GetOrderIsComplete() ||
		slices.Contains(delta.GetOrderedUids(), "uid-a") ||
		slices.Contains(delta.GetRemovedUids(), "uid-a") {
		t.Fatalf("invisible update delta = %#v", delta)
	}
}

func TestSubscriptionInvisibleUpsertRetainsUndrainedTrueRemoval(t *testing.T) {
	projector := newRuntimeTestProjector(t, "status:running", nil)
	subscription, scheduled := newControlledProjectionSubscription(projector)
	visible, _ := projector.ProjectOne(pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{}))
	subscription.initializeRows([]*kmgrv1.ResourceRow{visible})
	drainSubscription(t, subscription)
	drainNotify(subscription)

	subscription.applyBatch(watcher.Batch{RemovedUIDs: []types.UID{"uid-a"}})
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-a", "ns", "api", "Pending", 0, nil, time.Time{}),
	}})
	flushCapturedProjection(t, scheduled)

	subscription.mu.Lock()
	_, pending := subscription.pendingRemoved["uid-a"]
	subscription.mu.Unlock()
	if !pending {
		t.Fatal("invisible same-UID upsert canceled an undrained Kubernetes removal")
	}
}

func TestSubscriptionDeleteAfterFilterHidingStillEmitsRemoval(t *testing.T) {
	projector := newRuntimeTestProjector(t, "status:running", nil)
	subscription, scheduled := newControlledProjectionSubscription(projector)
	visible := pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{})
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{visible}})
	flushCapturedProjection(t, scheduled)
	subscription.mu.Lock()
	subscription.signalLocked(true)
	subscription.mu.Unlock()
	drainSubscription(t, subscription)
	drainNotify(subscription)

	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-a", "ns", "api", "Pending", 0, nil, time.Time{}),
	}})
	flushCapturedProjection(t, scheduled)
	subscription.mu.Lock()
	subscription.signalLocked(true)
	subscription.mu.Unlock()
	drainSubscription(t, subscription)
	drainNotify(subscription)

	subscription.applyBatch(watcher.Batch{RemovedUIDs: []types.UID{"uid-a"}})
	events := drainSubscription(t, subscription)
	for _, event := range events {
		if slices.Contains(event.GetDelta().GetRemovedUids(), "uid-a") {
			return
		}
	}
	t.Fatalf("delete after filter hiding omitted removal: %#v", events)
}

func TestSubscriptionRemovalMailboxIsBoundedByClientKnownUIDs(t *testing.T) {
	projector := newRuntimeTestProjector(t, "", nil)
	subscription, scheduled := newControlledProjectionSubscription(projector)
	subscription.pendingLimit = 2
	visible := pod("uid-known", "ns", "known", "Running", 0, nil, time.Time{})
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{visible}})
	flushCapturedProjection(t, scheduled)
	subscription.mu.Lock()
	subscription.signalLocked(true)
	subscription.mu.Unlock()
	drainSubscription(t, subscription)
	drainNotify(subscription)

	removed := make([]types.UID, 0, 1001)
	removed = append(removed, "uid-known")
	for index := range 1000 {
		removed = append(removed, types.UID(fmt.Sprintf("uid-unseen-%04d", index)))
	}
	subscription.applyBatch(watcher.Batch{RemovedUIDs: removed})

	subscription.mu.Lock()
	pending := len(subscription.pendingRemoved)
	_, retainedKnown := subscription.pendingRemoved["uid-known"]
	known := len(subscription.knownUIDs)
	subscription.mu.Unlock()
	if pending != 1 || !retainedKnown || known != 1 {
		t.Fatalf("bounded removal mailbox: pending=%d retained_known=%t known=%d",
			pending, retainedKnown, known)
	}
	events := drainSubscription(t, subscription)
	found := false
	for _, event := range events {
		found = found || slices.Contains(event.GetDelta().GetRemovedUids(), "uid-known")
	}
	if !found {
		t.Fatalf("bounded mailbox did not deliver known removal: %#v", events)
	}
	subscription.mu.Lock()
	known = len(subscription.knownUIDs)
	subscription.mu.Unlock()
	if known != 0 {
		t.Fatalf("delivered removal retained %d client-known UIDs", known)
	}
	for _, event := range events {
		if delta := event.GetDelta(); delta != nil && len(delta.GetUpserts()) == 0 &&
			len(delta.GetRemovedUids()) == 0 && !delta.GetOrderIsComplete() {
			t.Fatalf("removal-only drain emitted empty delta: %#v", events)
		}
	}
}

func TestSubscriptionRemovalOverflowUsesBoundedKnownUIDSet(t *testing.T) {
	projector := newRuntimeTestProjector(t, "", nil)
	subscription, scheduled := newControlledProjectionSubscription(projector)
	objects := []*unstructured.Unstructured{
		pod("uid-1", "ns", "one", "Running", 0, nil, time.Time{}),
		pod("uid-2", "ns", "two", "Running", 0, nil, time.Time{}),
		pod("uid-3", "ns", "three", "Running", 0, nil, time.Time{}),
	}
	subscription.applyBatch(watcher.Batch{Upserts: objects})
	flushCapturedProjection(t, scheduled)
	subscription.mu.Lock()
	subscription.signalLocked(true)
	subscription.mu.Unlock()
	drainSubscription(t, subscription)
	drainNotify(subscription)
	subscription.pendingLimit = 2

	subscription.applyBatch(watcher.Batch{RemovedUIDs: []types.UID{"uid-1", "uid-2", "uid-3"}})
	subscription.mu.Lock()
	pending, known := len(subscription.pendingRemoved), len(subscription.knownUIDs)
	overflow := subscription.removalOverflow
	resnapshot := subscription.resnapshot
	subscription.mu.Unlock()
	if pending != 2 || known != 3 || !overflow || !resnapshot {
		t.Fatalf("overflow state: pending=%d known=%d overflow=%t resnapshot=%t",
			pending, known, overflow, resnapshot)
	}

	events := drainSubscription(t, subscription)
	var removed []string
	for _, event := range events {
		batch := event.GetDelta().GetRemovedUids()
		if len(batch) > 2 {
			t.Fatalf("removal delta size = %d, want <= 2", len(batch))
		}
		removed = append(removed, batch...)
	}
	slices.Sort(removed)
	if !slices.Equal(removed, []string{"uid-1", "uid-2", "uid-3"}) {
		t.Fatalf("overflow removals = %v", removed)
	}
}

func TestSubscriptionVisibleUpsertCancelsOnlyItsPendingRemoval(t *testing.T) {
	projector := newRuntimeTestProjector(t, "", nil)
	subscription, scheduled := newControlledProjectionSubscription(projector)
	subscription.pendingLimit = 1
	objects := []*unstructured.Unstructured{
		pod("uid-a", "ns", "a", "Running", 0, nil, time.Time{}),
		pod("uid-b", "ns", "b", "Running", 0, nil, time.Time{}),
	}
	subscription.pendingLimit = 100
	subscription.applyBatch(watcher.Batch{Upserts: objects})
	flushCapturedProjection(t, scheduled)
	subscription.mu.Lock()
	subscription.signalLocked(true)
	subscription.mu.Unlock()
	drainSubscription(t, subscription)
	drainNotify(subscription)
	subscription.pendingLimit = 1

	subscription.applyBatch(watcher.Batch{RemovedUIDs: []types.UID{"uid-a", "uid-b"}})
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-a", "ns", "a-revived", "Running", 1, nil, time.Time{}),
	}})
	flushCapturedProjection(t, scheduled)
	subscription.mu.Lock()
	subscription.signalLocked(true)
	subscription.mu.Unlock()

	events := drainSubscription(t, subscription)
	var removed []string
	var upserted []string
	for _, event := range events {
		removed = append(removed, event.GetDelta().GetRemovedUids()...)
		for _, row := range event.GetDelta().GetUpserts() {
			upserted = append(upserted, row.GetIdentity().GetUid())
		}
		for _, row := range event.GetSnapshot().GetRows() {
			upserted = append(upserted, row.GetIdentity().GetUid())
		}
	}
	if !slices.Equal(removed, []string{"uid-b"}) || !slices.Contains(upserted, "uid-a") {
		t.Fatalf("revival delivery: removed=%v upserted=%v events=%#v", removed, upserted, events)
	}
}

func TestSubscriptionListRemovalsAreBoundedByClientKnownUIDs(t *testing.T) {
	projector := newRuntimeTestProjector(t, "", nil)
	subscription, scheduled := newControlledProjectionSubscription(projector)
	subscription.pendingLimit = 2
	visible := pod("uid-known", "ns", "known", "Running", 0, nil, time.Time{})
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{visible}})
	flushCapturedProjection(t, scheduled)
	subscription.mu.Lock()
	subscription.signalLocked(true)
	subscription.mu.Unlock()
	drainSubscription(t, subscription)
	drainNotify(subscription)

	removed := make([]types.UID, 0, 1001)
	removed = append(removed, "uid-known")
	for index := range 1000 {
		removed = append(removed, types.UID(fmt.Sprintf("uid-unseen-%04d", index)))
	}
	subscription.applyBatch(watcher.Batch{FromList: true, RemovedUIDs: removed})

	subscription.mu.Lock()
	pending, known := len(subscription.pendingRemoved), len(subscription.knownUIDs)
	overflow := subscription.removalOverflow
	subscription.mu.Unlock()
	if pending != 1 || known != 1 || overflow {
		t.Fatalf("LIST removal state: pending=%d known=%d overflow=%t", pending, known, overflow)
	}
	events := drainSubscription(t, subscription)
	for _, event := range events {
		if slices.Contains(event.GetDelta().GetRemovedUids(), "uid-known") {
			return
		}
	}
	t.Fatalf("LIST reconciliation omitted known removal: %#v", events)
}

func TestSubscriptionIgnoresStaleScheduledFlushAfterManualFlushAndClose(t *testing.T) {
	projector := newRuntimeTestProjector(t, "", nil)
	subscription, scheduled := newControlledProjectionSubscription(projector)
	subscription.applyBatch(watcher.Batch{Upserts: []*unstructured.Unstructured{
		pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{}),
	}})
	stale := receiveCapturedProjection(t, scheduled)
	subscription.flushProjection()
	stale()
	subscription.close()
	stale()

	subscription.mu.Lock()
	passes := subscription.projectionPasses
	timer := subscription.projectionTimer
	scheduledState := subscription.projectionScheduled
	subscription.mu.Unlock()
	if passes != 1 || timer != nil || scheduledState {
		t.Fatalf("stale callback state: passes=%d timer=%v scheduled=%t", passes, timer, scheduledState)
	}
}

func newRuntimeTestProjector(
	t *testing.T,
	filter string,
	sortOrder []SortDescriptor,
) *Projector {
	t.Helper()
	projector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session-a",
		Resource: ResourceType{
			Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true,
		},
		NamespaceScope:   NamespaceScope{All: true},
		ColumnIDs:        []string{"name", "status", "restarts"},
		FilterExpression: filter,
		Sort:             sortOrder,
	})
	if err != nil {
		t.Fatal(err)
	}
	return projector
}

func newControlledProjectionSubscription(
	projector *Projector,
) (*Subscription, <-chan func()) {
	subscription := newSubscription(
		viewKey{sessionID: "session-a", viewID: "view-a"},
		1,
		projector,
		time.Hour,
		100,
		100,
	)
	scheduled := make(chan func(), 16)
	subscription.scheduleProjection = func(flush func()) *time.Timer {
		scheduled <- flush
		return nil
	}
	return subscription, scheduled
}

func receiveCapturedProjection(t *testing.T, scheduled <-chan func()) func() {
	t.Helper()
	select {
	case flush := <-scheduled:
		return flush
	case <-time.After(time.Second):
		t.Fatal("projection was not scheduled")
		return nil
	}
}

func flushCapturedProjection(t *testing.T, scheduled <-chan func()) {
	t.Helper()
	receiveCapturedProjection(t, scheduled)()
}

func runCapturedProjection(t *testing.T, scheduled <-chan func()) <-chan struct{} {
	t.Helper()
	flush := receiveCapturedProjection(t, scheduled)
	done := make(chan struct{})
	go func() {
		flush()
		close(done)
	}()
	return done
}

func awaitSignal(t *testing.T, signal <-chan struct{}, description string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(time.Second):
		t.Fatalf("timed out waiting for %s", description)
	}
}

func drainSubscription(t *testing.T, subscription *Subscription) []*kmgrv1.ViewEvent {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	events, err := subscription.Next(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := subscription.AcknowledgeDelivery(events); err != nil {
		t.Fatal(err)
	}
	return events
}

func drainNotify(subscription *Subscription) {
	select {
	case <-subscription.notify:
	default:
	}
}

func TestRuntimeLifecycleMutexIsNotHeldDuringRowProjection(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	watchStarted := make(chan struct{}, 1)
	client.watchStarted = watchStarted
	client.listPages = []*unstructured.UnstructuredList{listPage("rv-1", "")}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:     &fakeResourceSource{authority: "cluster-a", client: client},
		BatchDelay: time.Hour, PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	subscription, err := runtime.Open(openView("session-1", "view-1", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	select {
	case <-watchStarted:
	case <-time.After(time.Second):
		t.Fatal("initial LIST did not advance to WATCH")
	}
	// Watch starts only after the synchronous SnapshotComplete callback has
	// returned. Taking Subscription.mu once makes the test's hook installation
	// ordered after that final LIST projection as well.
	subscription.mu.Lock()
	subscription.mu.Unlock()
	drainNotify(subscription)

	started := make(chan struct{})
	release := make(chan struct{})
	var startOnce sync.Once
	subscription.mu.Lock()
	subscription.projector.now = func() time.Time {
		startOnce.Do(func() { close(started) })
		<-release
		return time.Unix(100, 0)
	}
	entry := subscription.resource
	runtime.mu.Lock()
	runNumber := entry.runNumber
	runtime.mu.Unlock()
	scheduled := make(chan func(), 1)
	subscription.scheduleProjection = func(flush func()) *time.Timer {
		scheduled <- flush
		return nil
	}
	subscription.mu.Unlock()

	runtime.receiveBatch(entry, runNumber, watcher.Batch{
		Upserts: []*unstructured.Unstructured{
			pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{}),
		},
	})
	done := runCapturedProjection(t, scheduled)
	select {
	case <-started:
	case <-time.After(time.Second):
		close(release)
		t.Fatal("row projection did not start")
	}

	lifecycle := make(chan int, 1)
	go func() { lifecycle <- runtime.ActiveResourceCount() }()
	select {
	case count := <-lifecycle:
		if count != 1 {
			close(release)
			t.Fatalf("active resource count = %d, want 1", count)
		}
	case <-time.After(250 * time.Millisecond):
		close(release)
		t.Fatal("runtime lifecycle mutex was held during row projection")
	}
	close(release)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("row projection did not finish")
	}
}

func TestRuntimeWarmOpenProjectionDoesNotHoldLifecycleMutex(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	started := make(chan struct{})
	release := make(chan struct{})
	runtime, err := NewRuntime(RuntimeConfig{
		Source:       &fakeResourceSource{authority: "cluster-a", client: client},
		ReleaseDelay: time.Hour, OpenProjectionLimit: 1,
		openProjectionHook: func() {
			close(started)
			<-release
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	entry := &resourceRuntime{
		key:   resourceKey{authorityID: "cluster-a", version: "v1", resource: "pods", namespace: "ns"},
		store: store.New(), client: client,
		subscribers: make(map[*Subscription]struct{}),
	}
	entry.store.Upsert(pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{}))
	entry.store.SetResourceVersion("rv-warm")
	entry.lastStatus = watcher.Status{Phase: watcher.PhaseResuming, Stale: true, ResourceVersion: "rv-warm"}
	runtime.mu.Lock()
	runtime.resources[entry.key] = entry
	runtime.mu.Unlock()

	done := make(chan error, 1)
	go func() {
		subscription, openErr := runtime.OpenContext(context.Background(), openView("session", "warm", 1))
		if subscription != nil {
			subscription.Close()
		}
		done <- openErr
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("warm projection did not start")
	}
	lifecycle := make(chan int, 1)
	go func() { lifecycle <- runtime.ActiveResourceCount() }()
	select {
	case <-lifecycle:
	case <-time.After(250 * time.Millisecond):
		t.Fatal("runtime lifecycle mutex was held by warm projection")
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestRuntimeOpenSealsInitialSnapshotAndCatchesUpAfterProjectionRace(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	firstStarted := make(chan struct{})
	releaseFirst := make(chan struct{})
	var calls atomic.Int64
	runtime, err := NewRuntime(RuntimeConfig{
		Source:       &fakeResourceSource{authority: "cluster-a", client: client},
		ReleaseDelay: time.Hour,
		openProjectionHook: func() {
			if calls.Add(1) == 1 {
				close(firstStarted)
				<-releaseFirst
			}
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	entry := &resourceRuntime{
		key:   resourceKey{authorityID: "cluster-a", version: "v1", resource: "pods", namespace: "ns"},
		store: store.New(), client: client, state: resourceRunning, runNumber: 7,
		subscribers: make(map[*Subscription]struct{}),
	}
	entry.store.Upsert(pod("uid-old", "ns", "old", "Running", 0, nil, time.Time{}))
	entry.store.SetResourceVersion("rv-old")
	entry.lastStatus = watcher.Status{Phase: watcher.PhaseWatching, ResourceVersion: "rv-old"}
	runtime.mu.Lock()
	runtime.resources[entry.key] = entry
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
	<-firstStarted
	newObject := pod("uid-new", "ns", "new", "Running", 0, nil, time.Time{})
	entry.store.Upsert(newObject)
	runtime.receiveBatch(entry, 7, watcher.Batch{Upserts: []*unstructured.Unstructured{newObject}})
	close(releaseFirst)
	result := <-done
	if result.err != nil {
		t.Fatal(result.err)
	}
	defer result.subscription.Close()
	if calls.Load() != 1 {
		t.Fatalf("initial projection calls = %d, want exactly one", calls.Load())
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	firstEvents, err := result.subscription.Next(ctx)
	cancel()
	if err != nil {
		t.Fatal(err)
	}
	if err := result.subscription.AcknowledgeDelivery(firstEvents); err != nil {
		t.Fatal(err)
	}
	var firstUIDs []string
	for _, event := range firstEvents {
		for _, row := range event.GetSnapshot().GetRows() {
			firstUIDs = append(firstUIDs, row.GetIdentity().GetUid())
		}
	}
	if !slices.Contains(firstUIDs, "uid-old") || slices.Contains(firstUIDs, "uid-new") {
		t.Fatalf("sealed first snapshot UIDs = %v", firstUIDs)
	}
	waitForSnapshotUID(t, result.subscription, "uid-new")
}

func TestRuntimeOpenDeliversDeleteRaceAfterSealedSnapshot(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	projectionStarted := make(chan struct{})
	releaseProjection := make(chan struct{})
	runtime, err := NewRuntime(RuntimeConfig{
		Source:       &fakeResourceSource{authority: "cluster-a", client: client},
		ReleaseDelay: time.Hour, BatchDelay: time.Millisecond,
		openProjectionHook: func() {
			close(projectionStarted)
			<-releaseProjection
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	entry := &resourceRuntime{
		key:   resourceKey{authorityID: "cluster-a", version: "v1", resource: "pods", namespace: "ns"},
		store: store.New(), client: client, state: resourceRunning, runNumber: 5,
		subscribers:      make(map[*Subscription]struct{}),
		snapshotComplete: true,
	}
	entry.store.Upsert(pod("uid-delete", "ns", "delete", "Running", 0, nil, time.Time{}))
	entry.store.SetResourceVersion("rv-before")
	entry.lastStatus = watcher.Status{Phase: watcher.PhaseWatching, ResourceVersion: "rv-before"}
	runtime.mu.Lock()
	runtime.resources[entry.key] = entry
	runtime.mu.Unlock()

	done := make(chan struct {
		subscription *Subscription
		err          error
	}, 1)
	go func() {
		subscription, openErr := runtime.Open(openView("session", "delete-race", 1))
		done <- struct {
			subscription *Subscription
			err          error
		}{subscription, openErr}
	}()
	<-projectionStarted
	entry.store.Delete("uid-delete")
	entry.store.SetResourceVersion("rv-after")
	runtime.receiveBatch(entry, 5, watcher.Batch{RemovedUIDs: []types.UID{"uid-delete"}})
	close(releaseProjection)
	result := <-done
	if result.err != nil {
		t.Fatal(result.err)
	}
	defer result.subscription.Close()

	first := drainSubscription(t, result.subscription)
	var sealed []string
	for _, event := range first {
		for _, row := range event.GetSnapshot().GetRows() {
			sealed = append(sealed, row.GetIdentity().GetUid())
		}
	}
	if !slices.Contains(sealed, "uid-delete") {
		t.Fatalf("sealed initial UIDs = %v", sealed)
	}
	second := drainSubscription(t, result.subscription)
	var removed []string
	for _, event := range second {
		removed = append(removed, event.GetDelta().GetRemovedUids()...)
	}
	if !slices.Contains(removed, "uid-delete") {
		t.Fatalf("authoritative catch-up removals = %v, events=%#v", removed, second)
	}
}

func TestRuntimeOpenCompletesUnderContinuousWatchChurn(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	projectionStarted := make(chan struct{})
	releaseProjection := make(chan struct{})
	var calls atomic.Int64
	runtime, err := NewRuntime(RuntimeConfig{
		Source:       &fakeResourceSource{authority: "cluster-a", client: client},
		ReleaseDelay: time.Hour,
		openProjectionHook: func() {
			calls.Add(1)
			close(projectionStarted)
			<-releaseProjection
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	entry := &resourceRuntime{
		key:   resourceKey{authorityID: "cluster-a", version: "v1", resource: "pods", namespace: "ns"},
		store: store.New(), client: client, state: resourceRunning, runNumber: 11,
		subscribers: make(map[*Subscription]struct{}),
	}
	entry.store.Upsert(pod("uid-base", "ns", "base", "Running", 0, nil, time.Time{}))
	entry.store.SetResourceVersion("rv-base")
	runtime.mu.Lock()
	runtime.resources[entry.key] = entry
	runtime.mu.Unlock()
	done := make(chan struct {
		subscription *Subscription
		err          error
	}, 1)
	go func() {
		subscription, openErr := runtime.Open(openView("session", "churn", 1))
		done <- struct {
			subscription *Subscription
			err          error
		}{subscription, openErr}
	}()
	<-projectionStarted
	for index := range 100 {
		object := pod(fmt.Sprintf("uid-%d", index), "ns", fmt.Sprintf("pod-%d", index), "Running", 0, nil, time.Time{})
		entry.store.Upsert(object)
		runtime.receiveBatch(entry, 11, watcher.Batch{Upserts: []*unstructured.Unstructured{object}})
	}
	close(releaseProjection)
	select {
	case result := <-done:
		if result.err != nil {
			t.Fatal(result.err)
		}
		defer result.subscription.Close()
	case <-time.After(time.Second):
		t.Fatal("Open did not make bounded progress under watch churn")
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("initial projection calls = %d, want one", got)
	}
}

func TestRuntimeOpenStrictGenerationAndPendingCancellation(t *testing.T) {
	t.Parallel()
	started := make(chan struct{})
	release := make(chan struct{})
	runtime, err := NewRuntime(RuntimeConfig{
		Source:              &fakeResourceSource{authority: "cluster-a", client: newScriptedResource()},
		OpenProjectionLimit: 1,
		openProjectionHook: func() {
			close(started)
			<-release
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	done := make(chan error, 1)
	go func() {
		_, openErr := runtime.OpenContext(context.Background(), openView("session", "same", 1))
		done <- openErr
	}()
	<-started
	if _, err := runtime.Open(openView("session", "same", 1)); !errors.Is(err, ErrStaleViewOpen) {
		close(release)
		t.Fatalf("equal generation error = %v", err)
	}
	if !runtime.Cancel("session", "same", 1) {
		close(release)
		t.Fatal("pending generation cancellation was rejected")
	}
	close(release)
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("pending open error = %v, want canceled", err)
	}
	if _, err := runtime.Open(openView("session", "same", 1)); !errors.Is(err, ErrStaleViewOpen) {
		t.Fatalf("canceled generation reopened: %v", err)
	}
}

func TestRuntimeNewerOpenSupersedesPendingAttemptWithoutClosingCommittedView(t *testing.T) {
	t.Parallel()
	var hookCalls atomic.Int64
	firstStarted := make(chan struct{})
	releaseFirst := make(chan struct{})
	runtime, err := NewRuntime(RuntimeConfig{
		Source:       &fakeResourceSource{authority: "cluster-a", client: newScriptedResource()},
		ReleaseDelay: time.Hour, OpenProjectionLimit: 2,
		openProjectionHook: func() {
			if hookCalls.Add(1) == 2 {
				close(firstStarted)
				<-releaseFirst
			}
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	committed, err := runtime.Open(openView("session", "same", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer committed.Close()

	firstDone := make(chan error, 1)
	go func() {
		_, openErr := runtime.OpenContext(context.Background(), openView("session", "same", 2))
		firstDone <- openErr
	}()
	<-firstStarted
	select {
	case <-committed.done:
		close(releaseFirst)
		t.Fatal("pending replacement closed committed generation")
	default:
	}
	third, err := runtime.Open(openView("session", "same", 3))
	if err != nil {
		close(releaseFirst)
		t.Fatal(err)
	}
	defer third.Close()
	close(releaseFirst)
	if err := <-firstDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("superseded generation error = %v, want canceled", err)
	}
	select {
	case <-committed.done:
	case <-time.After(time.Second):
		t.Fatal("committed generation was not closed after replacement committed")
	}
	if _, err := runtime.Open(openView("session", "same", 2)); !errors.Is(err, ErrStaleViewOpen) {
		t.Fatalf("older generation reopened: %v", err)
	}
}

func TestRuntimeReplacementTransfersClientKnownUIDsAndPendingTombstones(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-live", "", pod("uid-live", "ns", "live", "Running", 0, nil, time.Time{}),
	)}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:       &fakeResourceSource{authority: "cluster-a", client: client},
		ReleaseDelay: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	first, err := runtime.Open(openView("session", "same", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, first, "uid-live")
	first.deliveryState.mu.Lock()
	first.deliveryState.knownUIDs["uid-deleted"] = struct{}{}
	first.deliveryState.mu.Unlock()
	first.resource.store.Delete("uid-deleted")

	second, err := runtime.Open(openView("session", "same", 2))
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	second.mu.Lock()
	livePending, liveKnown := second.knownUIDs["uid-live"]
	deletedPending, deletedKnown := second.knownUIDs["uid-deleted"]
	_, removalQueued := second.pendingRemoved["uid-deleted"]
	second.mu.Unlock()
	if !liveKnown || livePending || !deletedKnown || !deletedPending || !removalQueued {
		t.Fatalf("transferred known live=(%t,%t) deleted=(%t,%t) queued=%t",
			liveKnown, livePending, deletedKnown, deletedPending, removalQueued)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	initial, err := second.Next(ctx)
	cancel()
	if err != nil {
		t.Fatal(err)
	}
	if err := second.AcknowledgeDelivery(initial); err != nil {
		t.Fatal(err)
	}
	ctx, cancel = context.WithTimeout(context.Background(), time.Second)
	events, err := second.Next(ctx)
	cancel()
	if err != nil {
		t.Fatal(err)
	}
	removed := make([]string, 0)
	for _, event := range events {
		removed = append(removed, event.GetDelta().GetRemovedUids()...)
	}
	if !slices.Contains(removed, "uid-deleted") {
		t.Fatalf("replacement removal events = %v", removed)
	}
}

func TestRuntimeCanceledOpenReleasesInProgressSearchHandoff(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{listPage("rv-final", "")}
	client.firstPageGate = make(chan struct{})
	projectionStarted := make(chan struct{})
	releaseProjection := make(chan struct{})
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster", client: client},
		openProjectionHook: func() {
			close(projectionStarted)
			<-releaseProjection
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	searchDone := make(chan error, 1)
	go func() {
		searchDone <- runtime.Search(context.Background(), inProgressSearchQuery("api"), func(SearchBatch) error { return nil })
	}()
	eventually(t, time.Second, func() bool { return client.listCalls.Load() == 1 })
	ctx, cancel := context.WithCancel(context.Background())
	openDone := make(chan error, 1)
	go func() {
		_, openErr := runtime.OpenContext(ctx, openView("session", "view", 1))
		openDone <- openErr
	}()
	<-projectionStarted
	cancel()
	close(releaseProjection)
	if err := <-openDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("open error = %v, want canceled", err)
	}
	runtime.mu.Lock()
	transient := runtime.transientSearchLists[searchSnapshotKey{
		resource:       resourceKey{authorityID: "cluster", version: "v1", resource: "pods", namespace: "ns"},
		namespaceScope: "namespaces:ns",
	}]
	if transient == nil || transient.view != nil {
		runtime.mu.Unlock()
		close(client.firstPageGate)
		t.Fatalf("canceled handoff retained view: %#v", transient)
	}
	runtime.mu.Unlock()
	close(client.firstPageGate)
	if err := <-searchDone; err != nil {
		t.Fatal(err)
	}
}

func TestRuntimeOpenProjectionAdmissionIsProcessBounded(t *testing.T) {
	t.Parallel()
	const limit = 2
	release := make(chan struct{})
	started := make(chan struct{}, 8)
	var active atomic.Int64
	var peak atomic.Int64
	hook := func() {
		current := active.Add(1)
		for {
			old := peak.Load()
			if current <= old || peak.CompareAndSwap(old, current) {
				break
			}
		}
		started <- struct{}{}
		<-release
		active.Add(-1)
	}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:              &fakeResourceSource{authority: "cluster-a", client: newScriptedResource()},
		OpenProjectionLimit: limit, openProjectionHook: hook,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	var wait sync.WaitGroup
	errorsCh := make(chan error, 8)
	for index := range 8 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			subscription, openErr := runtime.Open(openView("session", fmt.Sprintf("view-%d", index), 1))
			if subscription != nil {
				subscription.Close()
			}
			errorsCh <- openErr
		}()
	}
	for range limit {
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("projection admission did not fill")
		}
	}
	select {
	case <-started:
		t.Fatal("projection admission exceeded limit")
	case <-time.After(50 * time.Millisecond):
	}
	close(release)
	wait.Wait()
	close(errorsCh)
	for err := range errorsCh {
		if err != nil {
			t.Fatal(err)
		}
	}
	if got := peak.Load(); got != limit {
		t.Fatalf("peak initial projections = %d, want %d", got, limit)
	}
}

func TestStaleCancelCannotCloseReplacementGeneration(t *testing.T) {
	t.Parallel()
	source := &fakeResourceSource{authority: "cluster-a", client: newScriptedResource()}
	runtime, err := NewRuntime(RuntimeConfig{Source: source, ReleaseDelay: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	if _, err := runtime.Open(openView("session-1", "same", 1)); err != nil {
		t.Fatal(err)
	}
	secondRequest := openView("session-1", "same", 2)
	second, err := runtime.Open(secondRequest)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.Cancel("session-1", "same", 1) {
		t.Fatal("stale cancel reported success")
	}
	select {
	case <-second.done:
		t.Fatal("stale cancel closed replacement generation")
	default:
	}
}

func TestRuntimeMetricsAreLazyNonBlockingAndStopWithFinalView(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	podValue := pod("uid-metric", "ns", "api", "Running", 0, nil, time.Time{})
	container := podValue.Object["spec"].(map[string]any)["containers"].([]any)[0].(map[string]any)
	container["resources"] = map[string]any{
		"requests": map[string]any{"cpu": "500m"},
		"limits":   map[string]any{"cpu": "1"},
	}
	client.listPages = []*unstructured.UnstructuredList{listPage("rv-1", "", podValue)}
	fetcher := &runtimeBlockingMetricFetcher{
		started: make(chan struct{}, 1),
		result:  make(chan runtimeMetricResult, 1),
		stopped: make(chan struct{}),
	}
	provider, err := metrics.NewProvider(fetcher, time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	metricSource := &fakeMetricSource{provider: provider}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:  &fakeResourceSource{authority: "cluster-a", client: client},
		Metrics: metricSource, BatchDelay: time.Millisecond, ReleaseDelay: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	plainRequest := openView("session-1", "plain", 1)
	plain, err := runtime.Open(plainRequest)
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, plain, "uid-metric")
	if metricSource.opens.Load() != 0 || fetcher.calls.Load() != 0 {
		t.Fatal("plain resource view woke the metrics provider")
	}
	plain.Close()

	metricRequest := openView("session-1", "metric", 1)
	metricRequest.Spec.ColumnIds = []string{"name", PodCPUColumn}
	metricView, err := runtime.Open(metricRequest)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-fetcher.started:
	case <-time.After(time.Second):
		t.Fatal("metric view did not start lazy fetch")
	}
	// The Metrics API is still blocked, but the Pod row and scheduler
	// accounting must already be available.
	base := waitForRow(t, metricView, "uid-metric")
	baseCPU := cellByID(base, PodCPUColumn).GetUsage()
	if baseCPU.GetUsageAvailable() || baseCPU.GetRequested() != 0.5 || baseCPU.GetLimit() != 1 {
		t.Fatalf("base row before metrics = %#v", baseCPU)
	}

	fetcher.result <- runtimeMetricResult{samples: map[string]metrics.Sample{
		"uid-metric": {
			MeasuredAt: time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC),
			Resources:  map[string]int64{"cpu": 250_000_000},
		},
	}}
	updated := waitForUsageAvailable(t, metricView, "uid-metric", PodCPUColumn)
	if got := updated.GetUsage().GetUsed(); got != 0.25 {
		t.Fatalf("metric delta CPU = %v", got)
	}
	eventually(t, time.Second, func() bool { return fetcher.calls.Load() >= 2 })
	metricView.Close()
	select {
	case <-fetcher.stopped:
	case <-time.After(time.Second):
		t.Fatal("final metric view did not stop provider")
	}
}

func TestRuntimeMetricsFailureKeepsBaseRows(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-1", "", pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{}),
	)}
	provider, err := metrics.NewProvider(metricFetcherFunc(func(context.Context) (map[string]metrics.Sample, error) {
		return nil, metrics.ErrMetricsAPIForbidden
	}), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:  &fakeResourceSource{authority: "cluster-a", client: client},
		Metrics: &fakeMetricSource{provider: provider}, BatchDelay: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	request := openView("session-1", "metric", 1)
	request.Spec.ColumnIds = []string{"name", PodCPUColumn}
	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	row := waitForRow(t, subscription, "uid-a")
	if row.GetIdentity().GetName() != "api" || cellByID(row, PodCPUColumn).GetUsage().GetUsageAvailable() {
		t.Fatalf("base row after forbidden metrics = %#v", row)
	}
}

func TestRuntimeDefaultNodeUsageDoesNotOpenPodResource(t *testing.T) {
	t.Parallel()
	nodes := newScriptedResource()
	nodes.listPages = []*unstructured.UnstructuredList{listPage(
		"nodes-rv", "", nodeObject(
			"node-uid", "node-a",
			corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4")},
			corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("8")},
		),
	)}
	pods := newScriptedResource()
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &gvrResourceSource{authority: "cluster-a", clients: map[string]watcher.ListerWatcher{
			"nodes": nodes, "pods": pods,
		}},
		ReleaseDelay: time.Hour, BatchDelay: time.Millisecond, PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	request := openNodeView("session", "default-nodes", 1)
	request.Spec.ColumnIds = nil
	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()

	base := waitForRow(t, subscription, "node-uid")
	baseCPU := cellByID(base, NodeCPUUsageColumn)
	if baseCPU == nil || baseCPU.GetUsage().GetCapacity() != 4 ||
		baseCPU.GetUsage().Requested != nil || baseCPU.GetUsage().Limit != nil {
		t.Fatalf("default Node CPU included cross-resource accounting: %#v", baseCPU)
	}
	if got := pods.listCalls.Load(); got != 0 {
		t.Fatalf("default Node view opened %d Pod LIST calls", got)
	}
	if got := pods.watchCalls.Load(); got != 0 {
		t.Fatalf("default Node view opened %d Pod WATCH calls", got)
	}
}

type fakeMetricSource struct {
	provider *metrics.Provider
	err      error
	opens    atomic.Int64
}

func (s *fakeMetricSource) OpenMetrics(string, string, metrics.APIKind, string) (*metrics.ProviderLease, error) {
	s.opens.Add(1)
	if s.err != nil || s.provider == nil {
		return nil, s.err
	}
	return s.provider.Acquire()
}

type metricFetcherFunc func(context.Context) (map[string]metrics.Sample, error)

func (f metricFetcherFunc) Fetch(ctx context.Context) (map[string]metrics.Sample, error) {
	return f(ctx)
}

type runtimeMetricResult struct {
	samples map[string]metrics.Sample
	err     error
}

type runtimeBlockingMetricFetcher struct {
	started chan struct{}
	result  chan runtimeMetricResult
	stopped chan struct{}
	once    sync.Once
	calls   atomic.Int64
}

func (f *runtimeBlockingMetricFetcher) Fetch(ctx context.Context) (map[string]metrics.Sample, error) {
	f.calls.Add(1)
	select {
	case f.started <- struct{}{}:
	default:
	}
	select {
	case <-ctx.Done():
		f.once.Do(func() { close(f.stopped) })
		return nil, ctx.Err()
	case result := <-f.result:
		if result.err != nil {
			return nil, result.err
		}
		return result.samples, nil
	}
}

type fakeResourceSource struct {
	authority string
	client    watcher.ListerWatcher
	opens     atomic.Int64
	sessions  map[string]string
}

type gvrResourceSource struct {
	authority string
	clients   map[string]watcher.ListerWatcher
}

func (s *gvrResourceSource) OpenResource(
	_ string,
	resource schema.GroupVersionResource,
	_ string,
) (string, watcher.ListerWatcher, error) {
	client := s.clients[resource.Resource]
	if client == nil {
		return "", nil, fmt.Errorf("no client for %s", resource.Resource)
	}
	return s.authority, client, nil
}

type nilPodResourceSource struct {
	authority string
	nodes     watcher.ListerWatcher
}

func (s *nilPodResourceSource) OpenResource(
	_ string,
	resource schema.GroupVersionResource,
	_ string,
) (string, watcher.ListerWatcher, error) {
	if resource.Resource == "nodes" {
		return s.authority, s.nodes, nil
	}
	if resource.Resource == "pods" {
		return s.authority, nil, nil
	}
	return "", nil, fmt.Errorf("no client for %s", resource.Resource)
}

func (s *fakeResourceSource) OpenResource(string, schema.GroupVersionResource, string) (string, watcher.ListerWatcher, error) {
	s.opens.Add(1)
	return s.authority, s.client, nil
}

func (s *fakeResourceSource) AuthorityID(sessionID string) (string, bool) {
	if s.sessions == nil {
		return s.authority, s.authority != ""
	}
	authority, ok := s.sessions[sessionID]
	return authority, ok
}

type scriptedResource struct {
	mu              sync.Mutex
	listPages       []*unstructured.UnstructuredList
	beforeListPage  map[int]chan struct{}
	listIndex       int
	expireNextWatch bool
	watches         []*controllableWatch
	watchRVs        []string
	watchStarted    chan<- struct{}
	listCalls       atomic.Int64
	watchCalls      atomic.Int64
}

func newScriptedResource() *scriptedResource {
	return &scriptedResource{listPages: []*unstructured.UnstructuredList{listPage("rv-empty", "")}}
}

func (c *scriptedResource) List(ctx context.Context, options metav1.ListOptions) (*unstructured.UnstructuredList, error) {
	call := int(c.listCalls.Add(1)) - 1
	c.mu.Lock()
	if options.Continue == "" {
		c.listIndex = 0
	}
	index := c.listIndex
	if index >= len(c.listPages) {
		index = len(c.listPages) - 1
	}
	page := c.listPages[index].DeepCopy()
	gate := c.beforeListPage[index]
	c.listIndex++
	c.mu.Unlock()
	_ = call
	if gate != nil {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-gate:
		}
	}
	return page, nil
}

func (c *scriptedResource) Watch(_ context.Context, options metav1.ListOptions) (watch.Interface, error) {
	c.watchCalls.Add(1)
	c.mu.Lock()
	defer c.mu.Unlock()
	stream := newControllableWatch()
	c.watches = append(c.watches, stream)
	c.watchRVs = append(c.watchRVs, options.ResourceVersion)
	if c.watchStarted != nil {
		select {
		case c.watchStarted <- struct{}{}:
		default:
		}
	}
	if c.expireNextWatch {
		c.expireNextWatch = false
		stream.channel <- watch.Event{Type: watch.Error, Object: &metav1.Status{
			Status: metav1.StatusFailure, Reason: metav1.StatusReasonExpired, Code: 410,
		}}
	}
	return stream, nil
}

func (c *scriptedResource) lastWatch() *controllableWatch {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.watches) == 0 {
		return &controllableWatch{}
	}
	return c.watches[len(c.watches)-1]
}

func (c *scriptedResource) lastWatchResourceVersion() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.watchRVs) == 0 {
		return ""
	}
	return c.watchRVs[len(c.watchRVs)-1]
}

type controllableWatch struct {
	channel chan watch.Event
	stopped atomic.Bool
	once    sync.Once
}

func newControllableWatch() *controllableWatch {
	return &controllableWatch{channel: make(chan watch.Event, 32)}
}

func (w *controllableWatch) Stop() {
	w.once.Do(func() {
		w.stopped.Store(true)
		close(w.channel)
	})
}

func (w *controllableWatch) ResultChan() <-chan watch.Event { return w.channel }

func openView(sessionID, viewID string, generation uint64) *kmgrv1.OpenViewRequest {
	return &kmgrv1.OpenViewRequest{
		Context:    &kmgrv1.RequestContext{RequestId: "runtime-test", ClusterSessionId: sessionID},
		ViewId:     viewID,
		Generation: generation,
		Spec: &kmgrv1.ViewSpec{
			Resource:       &kmgrv1.ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
			NamespaceScope: &kmgrv1.NamespaceScope{Namespaces: []string{"ns"}},
			ColumnIds:      []string{"namespace", "name", "status"},
		},
	}
}

func openNodeView(sessionID, viewID string, generation uint64) *kmgrv1.OpenViewRequest {
	return &kmgrv1.OpenViewRequest{
		Context:    &kmgrv1.RequestContext{RequestId: "runtime-test", ClusterSessionId: sessionID},
		ViewId:     viewID,
		Generation: generation,
		Spec: &kmgrv1.ViewSpec{
			Resource:  &kmgrv1.ResourceType{Version: "v1", Resource: "nodes", Kind: "Node"},
			ColumnIds: []string{"name", NodeCPUUsageColumn, NodeMemoryUsageColumn},
		},
	}
}

func listPage(resourceVersion, continueToken string, objects ...*unstructured.Unstructured) *unstructured.UnstructuredList {
	list := &unstructured.UnstructuredList{}
	list.SetResourceVersion(resourceVersion)
	list.SetContinue(continueToken)
	for _, object := range objects {
		list.Items = append(list.Items, *object.DeepCopy())
	}
	return list
}

func waitForSnapshotUID(t *testing.T, subscription *Subscription, uid string) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		events, err := subscription.Next(ctx)
		cancel()
		if err != nil && !errors.Is(err, context.DeadlineExceeded) {
			t.Fatal(err)
		}
		if err == nil {
			if acknowledgeErr := subscription.AcknowledgeDelivery(events); acknowledgeErr != nil {
				t.Fatal(acknowledgeErr)
			}
		}
		for _, event := range events {
			for _, row := range event.GetSnapshot().GetRows() {
				if row.GetIdentity().GetUid() == uid {
					return
				}
			}
			for _, row := range event.GetDelta().GetUpserts() {
				if row.GetIdentity().GetUid() == uid {
					return
				}
			}
		}
	}
	t.Fatalf("never observed UID %q", uid)
}

func waitForRow(t *testing.T, subscription *Subscription, uid string) *kmgrv1.ResourceRow {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		events, err := subscription.Next(ctx)
		cancel()
		if err != nil && !errors.Is(err, context.DeadlineExceeded) {
			t.Fatal(err)
		}
		if err == nil {
			if acknowledgeErr := subscription.AcknowledgeDelivery(events); acknowledgeErr != nil {
				t.Fatal(acknowledgeErr)
			}
		}
		for _, event := range events {
			for _, row := range append(event.GetSnapshot().GetRows(), event.GetDelta().GetUpserts()...) {
				if row.GetIdentity().GetUid() == uid {
					return row
				}
			}
		}
	}
	t.Fatalf("never observed row UID %q", uid)
	return nil
}

func waitForUsageAvailable(
	t *testing.T,
	subscription *Subscription,
	uid, columnID string,
) *kmgrv1.Cell {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		events, err := subscription.Next(ctx)
		cancel()
		if err != nil && !errors.Is(err, context.DeadlineExceeded) {
			t.Fatal(err)
		}
		if err == nil {
			if acknowledgeErr := subscription.AcknowledgeDelivery(events); acknowledgeErr != nil {
				t.Fatal(acknowledgeErr)
			}
		}
		for _, event := range events {
			for _, row := range append(event.GetSnapshot().GetRows(), event.GetDelta().GetUpserts()...) {
				if row.GetIdentity().GetUid() != uid {
					continue
				}
				cell := cellByID(row, columnID)
				if cell.GetUsage().GetUsageAvailable() {
					return cell
				}
			}
		}
	}
	t.Fatalf("never observed available usage for %q/%q", uid, columnID)
	return nil
}

func eventually(t *testing.T, timeout time.Duration, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal(fmt.Sprintf("condition was not met within %s", timeout))
}
