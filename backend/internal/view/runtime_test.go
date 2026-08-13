package view

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"

	"github.com/charlie0129/kmgr/backend/internal/watcher"
)

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

	searchResult, err := runtime.SearchCached(CachedSearchQuery{
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

func TestSlowSubscriptionFallsBackToBoundedSnapshot(t *testing.T) {
	t.Parallel()
	source := &fakeResourceSource{authority: "cluster-a", client: newScriptedResource()}
	runtime, err := NewRuntime(RuntimeConfig{Source: source, PendingRowLimit: 2, SnapshotChunkSize: 2, BatchDelay: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	subscription, err := runtime.Open(openView("session-1", "view-1", 1))
	if err != nil {
		t.Fatal(err)
	}
	// Drain the initial empty snapshot/status first.
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	_, _ = subscription.Next(ctx)
	cancel()

	objects := []*unstructured.Unstructured{
		pod("uid-1", "ns", "one", "Running", 0, nil, time.Time{}),
		pod("uid-2", "ns", "two", "Running", 0, nil, time.Time{}),
		pod("uid-3", "ns", "three", "Running", 0, nil, time.Time{}),
	}
	subscription.applyBatch(watcher.Batch{Upserts: objects})
	subscription.mu.Lock()
	if !subscription.resnapshot || len(subscription.pendingUpserts) != 0 {
		t.Fatalf("slow mailbox state: resnapshot=%v pending=%d", subscription.resnapshot, len(subscription.pendingUpserts))
	}
	subscription.signalLocked(true)
	subscription.mu.Unlock()

	ctx, cancel = context.WithTimeout(context.Background(), time.Second)
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
	if clockCalls != 1 {
		t.Fatalf("watch batch clock calls = %d, want 1", clockCalls)
	}
}

func TestRuntimeLifecycleMutexIsNotHeldDuringRowProjection(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
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
	subscription.mu.Unlock()

	done := make(chan struct{})
	go func() {
		runtime.receiveBatch(entry, runNumber, watcher.Batch{
			Upserts: []*unstructured.Unstructured{
				pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{}),
			},
		})
		close(done)
	}()
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

func TestRuntimeNodeAccountingIsAsyncSharedAndUpdatesFromPods(t *testing.T) {
	t.Parallel()
	nodes := newScriptedResource()
	node := nodeObject(
		"node-uid", "node-a",
		corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4"), corev1.ResourcePods: resource.MustParse("100")},
		corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("8"), corev1.ResourcePods: resource.MustParse("110")},
	)
	nodes.listPages = []*unstructured.UnstructuredList{listPage("nodes-rv", "", node)}
	pods := newScriptedResource()
	podGate := make(chan struct{})
	pods.beforeListPage = map[int]chan struct{}{0: podGate}
	bound := pod("pod-uid", "ns", "api", "Running", 0, nil, time.Time{})
	bound.Object["spec"].(map[string]any)["nodeName"] = "node-a"
	bound.Object["spec"].(map[string]any)["containers"].([]any)[0].(map[string]any)["resources"] = map[string]any{
		"requests": map[string]any{"cpu": "500m"}, "limits": map[string]any{"cpu": "1"},
	}
	pods.listPages = []*unstructured.UnstructuredList{listPage("pods-rv", "", bound)}
	source := &gvrResourceSource{authority: "cluster-a", clients: map[string]watcher.ListerWatcher{
		"nodes": nodes, "pods": pods,
	}}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: source, ReleaseDelay: 25 * time.Millisecond, BatchDelay: time.Millisecond,
		PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	var computations atomic.Int64
	runtime.nodeAccountingComputer = func(
		nodeObjects, podObjects []*unstructured.Unstructured,
		accelerators metrics.AcceleratorConfig,
		ready bool,
		dependencyErr error,
	) NodeAccountingSnapshot {
		computations.Add(1)
		return computeNodeAccounting(nodeObjects, podObjects, accelerators, ready, dependencyErr)
	}

	first, err := runtime.Open(openNodeView("session-1", "nodes-1", 1))
	if err != nil {
		t.Fatal(err)
	}
	base := waitForRow(t, first, "node-uid")
	if got := cellByID(base, NodeCPURequestsColumn).GetDisplayText(); got != "Calculating…" {
		t.Fatalf("base Node accounting = %q", got)
	}
	second, err := runtime.Open(openNodeView("session-2", "nodes-2", 1))
	if err != nil {
		t.Fatal(err)
	}
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		entry := runtime.resources[resourceKey{authorityID: "cluster-a", version: "v1", resource: "pods"}]
		return pods.listCalls.Load() == 1 && entry != nil && len(entry.dependents) == 2
	})
	close(podGate)
	updated := waitForNodeAccounting(t, first, "node-uid", NodeCPURequestsColumn, 0.5)
	if updated.GetUsage().GetCapacity() != 4 {
		t.Fatalf("CPU accounting = %#v", updated.GetUsage())
	}
	waitForNodeAccounting(t, second, "node-uid", NodeCPURequestsColumn, 0.5)
	if got := computations.Load(); got != 1 {
		t.Fatalf("initial accounting computations = %d, want one shared revision", got)
	}
	if pods.watchCalls.Load() != 1 {
		t.Fatalf("Pod watch calls = %d, want shared watcher", pods.watchCalls.Load())
	}

	added := pod("pod-2", "ns", "worker", "Running", 0, nil, time.Time{})
	added.Object["spec"].(map[string]any)["nodeName"] = "node-a"
	added.Object["spec"].(map[string]any)["containers"].([]any)[0].(map[string]any)["resources"] = map[string]any{
		"requests": map[string]any{"cpu": "250m"},
	}
	added.SetResourceVersion("pods-rv-2")
	pods.lastWatch().channel <- watch.Event{Type: watch.Added, Object: added}
	waitForNodeAccounting(t, first, "node-uid", NodeCPURequestsColumn, 0.75)
	eventually(t, time.Second, func() bool { return computations.Load() == 2 })
	terminal := bound.DeepCopy()
	terminal.SetResourceVersion("pods-rv-3")
	terminal.Object["status"].(map[string]any)["phase"] = "Succeeded"
	pods.lastWatch().channel <- watch.Event{Type: watch.Modified, Object: terminal}
	waitForNodeAccounting(t, first, "node-uid", NodeCPURequestsColumn, 0.25)
	eventually(t, time.Second, func() bool { return computations.Load() == 3 })

	first.Close()
	if pods.lastWatch().stopped.Load() {
		t.Fatal("Pod watcher stopped while another Node view depended on it")
	}
	second.Close()
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		return pods.lastWatch().stopped.Load() && len(runtime.nodeAccounting) == 0
	})
}

func TestRuntimeVisiblePodViewRetainsNodeAccountingWatcher(t *testing.T) {
	t.Parallel()
	nodes := newScriptedResource()
	nodes.listPages = []*unstructured.UnstructuredList{listPage(
		"nodes-rv", "", nodeObject(
			"node-uid", "node-a", corev1.ResourceList{corev1.ResourcePods: resource.MustParse("100")},
			corev1.ResourceList{corev1.ResourcePods: resource.MustParse("110")},
		),
	)}
	pods := newScriptedResource()
	pods.listPages = []*unstructured.UnstructuredList{listPage("pods-rv", "")}
	source := &gvrResourceSource{authority: "cluster-a", clients: map[string]watcher.ListerWatcher{
		"nodes": nodes, "pods": pods,
	}}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: source, ReleaseDelay: 20 * time.Millisecond, BatchDelay: time.Millisecond,
		PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	nodeView, err := runtime.Open(openNodeView("session", "nodes", 1))
	if err != nil {
		t.Fatal(err)
	}
	eventually(t, time.Second, func() bool { return pods.watchCalls.Load() == 1 })
	podRequest := openView("session", "pods", 1)
	podRequest.Spec.NamespaceScope = &kmgrv1.NamespaceScope{AllNamespaces: true}
	podView, err := runtime.Open(podRequest)
	if err != nil {
		t.Fatal(err)
	}
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		return len(runtime.resources[resourceKey{authorityID: "cluster-a", version: "v1", resource: "pods"}].subscribers) == 1
	})
	if pods.watchCalls.Load() != 1 {
		t.Fatalf("visible Pod view opened a second watch: %d", pods.watchCalls.Load())
	}
	nodeView.Close()
	time.Sleep(30 * time.Millisecond)
	if pods.lastWatch().stopped.Load() {
		t.Fatal("visible Pod view did not retain shared Pod watcher")
	}
	podView.Close()
	eventually(t, time.Second, func() bool { return pods.lastWatch().stopped.Load() })
}

func TestRuntimeNodeAccountingDoesNotHoldRuntimeLockWhileComputing(t *testing.T) {
	t.Parallel()
	nodes := newScriptedResource()
	nodes.listPages = []*unstructured.UnstructuredList{listPage(
		"nodes-rv", "", nodeObject(
			"node-uid", "node-a",
			corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4")},
			corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4")},
		),
	)}
	pods := newScriptedResource()
	pods.listPages = []*unstructured.UnstructuredList{listPage("pods-rv", "")}
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
	computeStarted := make(chan struct{})
	releaseCompute := make(chan struct{})
	var once sync.Once
	runtime.nodeAccountingComputer = func(
		nodeObjects, podObjects []*unstructured.Unstructured,
		accelerators metrics.AcceleratorConfig,
		ready bool,
		dependencyErr error,
	) NodeAccountingSnapshot {
		once.Do(func() { close(computeStarted) })
		<-releaseCompute
		return computeNodeAccounting(nodeObjects, podObjects, accelerators, ready, dependencyErr)
	}

	subscription, err := runtime.Open(openNodeView("session", "nodes", 1))
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-computeStarted:
	case <-time.After(time.Second):
		t.Fatal("accounting computation did not start")
	}

	canceled := make(chan bool, 1)
	go func() { canceled <- runtime.Cancel("session", "nodes", 1) }()
	select {
	case ok := <-canceled:
		if !ok {
			t.Fatal("Cancel did not find the subscription")
		}
	case <-time.After(100 * time.Millisecond):
		t.Fatal("Cancel blocked behind Node accounting computation")
	}
	close(releaseCompute)
	select {
	case <-subscription.done:
	case <-time.After(time.Second):
		t.Fatal("subscription did not close")
	}
}

func TestRuntimeNodeAccountingCoalescesBurstAcrossManyDependents(t *testing.T) {
	t.Parallel()
	nodes := newScriptedResource()
	nodes.listPages = []*unstructured.UnstructuredList{listPage(
		"nodes-rv", "", nodeObject(
			"node-uid", "node-a",
			corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4")},
			corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4")},
		),
	)}
	pods := newScriptedResource()
	podGate := make(chan struct{})
	pods.beforeListPage = map[int]chan struct{}{0: podGate}
	pods.listPages = []*unstructured.UnstructuredList{listPage("pods-rv", "")}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &gvrResourceSource{authority: "cluster-a", clients: map[string]watcher.ListerWatcher{
			"nodes": nodes, "pods": pods,
		}},
		ReleaseDelay: 10 * time.Millisecond, BatchDelay: time.Millisecond, PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	computeStarted := make(chan struct{})
	releaseFirstCompute := make(chan struct{})
	var computations atomic.Int64
	runtime.nodeAccountingComputer = func(
		nodeObjects, podObjects []*unstructured.Unstructured,
		accelerators metrics.AcceleratorConfig,
		ready bool,
		dependencyErr error,
	) NodeAccountingSnapshot {
		if computations.Add(1) == 1 {
			close(computeStarted)
			<-releaseFirstCompute
		}
		return computeNodeAccounting(nodeObjects, podObjects, accelerators, ready, dependencyErr)
	}

	const dependentCount = 12
	views := make([]*Subscription, 0, dependentCount)
	for index := range dependentCount {
		view, openErr := runtime.Open(openNodeView(fmt.Sprintf("session-%d", index), fmt.Sprintf("nodes-%d", index), 1))
		if openErr != nil {
			t.Fatal(openErr)
		}
		views = append(views, view)
	}
	waitForSnapshotUID(t, views[0], "node-uid")
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		entry := runtime.resources[resourceKey{authorityID: "cluster-a", version: "v1", resource: "pods"}]
		return entry != nil && len(entry.dependents) == dependentCount
	})
	close(podGate)
	select {
	case <-computeStarted:
	case <-time.After(time.Second):
		t.Fatal("initial shared accounting computation did not start")
	}

	const burst = 20
	for index := range burst {
		value := pod(fmt.Sprintf("pod-%d", index), "ns", fmt.Sprintf("pod-%d", index), "Running", 0, nil, time.Time{})
		value.Object["spec"].(map[string]any)["nodeName"] = "node-a"
		value.Object["spec"].(map[string]any)["containers"].([]any)[0].(map[string]any)["resources"] = map[string]any{
			"requests": map[string]any{"cpu": "10m"},
		}
		value.SetResourceVersion(fmt.Sprintf("pods-rv-%d", index+1))
		pods.lastWatch().channel <- watch.Event{Type: watch.Added, Object: value}
	}
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		entry := runtime.resources[resourceKey{authorityID: "cluster-a", version: "v1", resource: "pods"}]
		work := runtime.nodeAccounting[nodeAccountingKey{nodes: views[0].resource, pods: entry}]
		return entry != nil && entry.store.Len() == burst && work != nil && work.revision >= burst+1
	})
	close(releaseFirstCompute)
	for _, view := range views {
		waitForNodeAccounting(t, view, "node-uid", NodeCPURequestsColumn, 0.2)
	}
	if got := computations.Load(); got != 2 {
		t.Fatalf("burst accounting computations = %d, want initial plus one coalesced revision", got)
	}

	for _, view := range views {
		view.Close()
	}
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		return pods.lastWatch().stopped.Load() && len(runtime.nodeAccounting) == 0
	})
}

func TestRuntimeNodeAccountingConstructionErrorLeavesCalculating(t *testing.T) {
	t.Parallel()
	nodes := newScriptedResource()
	nodes.listPages = []*unstructured.UnstructuredList{listPage(
		"nodes-rv", "", nodeObject(
			"node-uid", "node-a",
			corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4")},
			corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4")},
		),
	)}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:       &nilPodResourceSource{authority: "cluster-a", nodes: nodes},
		ReleaseDelay: time.Hour, BatchDelay: time.Millisecond, PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	subscription, err := runtime.Open(openNodeView("session", "nodes", 1))
	if err != nil {
		t.Fatal(err)
	}
	row := waitForNodeAccountingUnavailable(t, subscription, "node-uid", NodeCPURequestsColumn)
	cell := cellByID(row, NodeCPURequestsColumn)
	if cell.GetDisplayText() == "Calculating…" || !strings.Contains(cell.GetTooltip(), "unavailable") {
		t.Fatalf("construction failure cell = %#v", cell)
	}
}

func TestRuntimeLateNodeDependentReusesPublishedAccountingRevision(t *testing.T) {
	t.Parallel()
	nodes := newScriptedResource()
	nodes.listPages = []*unstructured.UnstructuredList{listPage(
		"nodes-rv", "", nodeObject(
			"node-uid", "node-a",
			corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4")},
			corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4")},
		),
	)}
	pods := newScriptedResource()
	pods.listPages = []*unstructured.UnstructuredList{listPage("pods-rv", "")}
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
	var computations atomic.Int64
	runtime.nodeAccountingComputer = func(
		nodeObjects, podObjects []*unstructured.Unstructured,
		accelerators metrics.AcceleratorConfig,
		ready bool,
		dependencyErr error,
	) NodeAccountingSnapshot {
		computations.Add(1)
		return computeNodeAccounting(nodeObjects, podObjects, accelerators, ready, dependencyErr)
	}

	first, err := runtime.Open(openNodeView("session-1", "nodes-1", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	waitForNodeAccounting(t, first, "node-uid", NodeCPURequestsColumn, 0)
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		for _, work := range runtime.nodeAccounting {
			if work != nil && !work.running && work.published != nil && work.published.revision == work.revision {
				return true
			}
		}
		return false
	})
	before := computations.Load()

	second, err := runtime.Open(openNodeView("session-2", "nodes-2", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	waitForNodeAccounting(t, second, "node-uid", NodeCPURequestsColumn, 0)
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		entry := runtime.resources[resourceKey{authorityID: "cluster-a", version: "v1", resource: "pods"}]
		return entry != nil && len(entry.dependents) == 2
	})
	if got := computations.Load(); got != before {
		t.Fatalf("late dependent recomputed published accounting revision: before=%d after=%d", before, got)
	}
	if got := pods.watchCalls.Load(); got != 1 {
		t.Fatalf("late dependent Pod watches = %d, want 1", got)
	}
}

func TestRuntimeNodeAccountingWorkerDropsLateResultAfterClose(t *testing.T) {
	t.Parallel()
	nodes := newScriptedResource()
	nodes.listPages = []*unstructured.UnstructuredList{listPage(
		"nodes-rv", "", nodeObject(
			"node-uid", "node-a",
			corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4")},
			corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4")},
		),
	)}
	pods := newScriptedResource()
	pods.listPages = []*unstructured.UnstructuredList{listPage("pods-rv", "")}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &gvrResourceSource{authority: "cluster-a", clients: map[string]watcher.ListerWatcher{
			"nodes": nodes, "pods": pods,
		}},
		ReleaseDelay: time.Hour, BatchDelay: time.Millisecond, PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	computeStarted := make(chan struct{})
	releaseCompute := make(chan struct{})
	computeDone := make(chan struct{})
	runtime.nodeAccountingComputer = func(
		nodeObjects, podObjects []*unstructured.Unstructured,
		accelerators metrics.AcceleratorConfig,
		ready bool,
		dependencyErr error,
	) NodeAccountingSnapshot {
		close(computeStarted)
		<-releaseCompute
		defer close(computeDone)
		return computeNodeAccounting(nodeObjects, podObjects, accelerators, ready, dependencyErr)
	}

	if _, err := runtime.Open(openNodeView("session", "nodes", 1)); err != nil {
		t.Fatal(err)
	}
	select {
	case <-computeStarted:
	case <-time.After(time.Second):
		t.Fatal("accounting computation did not start")
	}
	runtime.Close()
	close(releaseCompute)
	select {
	case <-computeDone:
	case <-time.After(time.Second):
		t.Fatal("accounting computation did not finish after runtime close")
	}
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	if len(runtime.nodeAccounting) != 0 || len(runtime.views) != 0 {
		t.Fatalf("late worker repopulated closed runtime: works=%d views=%d", len(runtime.nodeAccounting), len(runtime.views))
	}
}

type fakeMetricSource struct {
	provider *metrics.Provider
	err      error
	opens    atomic.Int64
}

func (s *fakeMetricSource) OpenMetrics(string, string, metrics.APIKind, string) (*metrics.Provider, error) {
	s.opens.Add(1)
	return s.provider, s.err
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
		Context:    &kmgrv1.RequestContext{ClusterSessionId: sessionID},
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
		Context:    &kmgrv1.RequestContext{ClusterSessionId: sessionID},
		ViewId:     viewID,
		Generation: generation,
		Spec: &kmgrv1.ViewSpec{
			Resource:  &kmgrv1.ResourceType{Version: "v1", Resource: "nodes", Kind: "Node"},
			ColumnIds: []string{"name", NodeCPURequestsColumn, NodePodCountColumn},
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

func waitForNodeAccounting(
	t *testing.T,
	subscription *Subscription,
	uid, columnID string,
	want float64,
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
		for _, event := range events {
			for _, row := range append(event.GetSnapshot().GetRows(), event.GetDelta().GetUpserts()...) {
				if row.GetIdentity().GetUid() != uid {
					continue
				}
				cell := cellByID(row, columnID)
				if cell.GetUsage().GetRequested() == want && cell.GetDisplayText() != "Calculating…" {
					return cell
				}
			}
		}
	}
	t.Fatalf("never observed scheduler accounting %q/%q = %v", uid, columnID, want)
	return nil
}

func waitForNodeAccountingUnavailable(
	t *testing.T,
	subscription *Subscription,
	uid, columnID string,
) *kmgrv1.ResourceRow {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		events, err := subscription.Next(ctx)
		cancel()
		if err != nil && !errors.Is(err, context.DeadlineExceeded) {
			t.Fatal(err)
		}
		for _, event := range events {
			for _, row := range append(event.GetSnapshot().GetRows(), event.GetDelta().GetUpserts()...) {
				if row.GetIdentity().GetUid() != uid {
					continue
				}
				cell := cellByID(row, columnID)
				if cell.GetDisplayText() != "Calculating…" &&
					strings.Contains(cell.GetTooltip(), "unavailable") {
					return row
				}
			}
		}
	}
	t.Fatalf("never observed unavailable scheduler accounting for %q/%q", uid, columnID)
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
