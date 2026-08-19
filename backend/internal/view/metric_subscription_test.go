package view

import (
	"context"
	"errors"
	"fmt"
	"math"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	"github.com/charlie0129/kmgr/backend/internal/watcher"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/watch"
)

func TestMetricFanInPublishesOnlyCompleteChildRoundsAndKeepsLatest(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	stream := &metricFanInSubscription{
		scopes:   []string{"a", "b"},
		children: make([]*metrics.Subscription, 2),
		updates:  make(chan metrics.Snapshot, 1),
		incoming: make(chan indexedMetricSnapshot, 8),
		ctx:      ctx,
		cancel:   cancel,
	}
	stream.waitGroup.Add(1)
	go stream.run()
	defer stream.Close()

	t0 := time.Date(2026, 8, 19, 12, 0, 0, 0, time.UTC)
	stream.incoming <- indexedMetricSnapshot{index: 0, value: metricFanInSnapshot("uid-a", 1, t0)}
	stream.incoming <- indexedMetricSnapshot{index: 0, value: metricFanInSnapshot("uid-a", 2, t0.Add(time.Second))}
	assertNoMetricFanInUpdate(t, stream.Updates())
	stream.incoming <- indexedMetricSnapshot{index: 1, value: metricFanInSnapshot("uid-b", 3, t0.Add(2*time.Second))}
	first := receiveMetricFanInUpdate(t, stream.Updates())
	if first.Samples["uid-a"].Resources["cpu"] != 2 || first.Samples["uid-b"].Resources["cpu"] != 3 {
		t.Fatalf("first merged round = %#v", first.Samples)
	}
	if !first.UpdatedAt.Equal(t0.Add(time.Second)) {
		t.Fatalf("first aggregate barrier = %v, want oldest latest child time", first.UpdatedAt)
	}

	stream.incoming <- indexedMetricSnapshot{index: 1, value: metricFanInSnapshot("uid-b", 4, t0.Add(3*time.Second))}
	assertNoMetricFanInUpdate(t, stream.Updates())
	stream.incoming <- indexedMetricSnapshot{index: 0, value: metricFanInSnapshot("uid-a", 5, t0.Add(4*time.Second))}
	second := receiveMetricFanInUpdate(t, stream.Updates())
	if second.Samples["uid-a"].Resources["cpu"] != 5 || second.Samples["uid-b"].Resources["cpu"] != 4 {
		t.Fatalf("second merged round = %#v", second.Samples)
	}
}

func TestMetricFanInForcedBarrierWaitsForEveryPostBarrierChild(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	stream := &metricFanInSubscription{
		scopes:   []string{"a", "b"},
		children: make([]*metrics.Subscription, 2),
		updates:  make(chan metrics.Snapshot, 1),
		incoming: make(chan indexedMetricSnapshot, 8),
		refresh:  make(chan time.Time),
		ctx:      ctx,
		cancel:   cancel,
	}
	stream.waitGroup.Add(1)
	go stream.run()
	defer stream.Close()

	t0 := time.Date(2026, 8, 19, 12, 0, 0, 0, time.UTC)
	stream.incoming <- indexedMetricSnapshot{index: 0, value: metricFanInSnapshot("uid-a", 1, t0)}
	stream.incoming <- indexedMetricSnapshot{index: 1, value: metricFanInSnapshot("uid-b", 1, t0)}
	_ = receiveMetricFanInUpdate(t, stream.Updates())

	// A advances before the base-resource barrier. Once the forced round is
	// installed, neither that value nor a late pre-barrier B value may complete
	// it. A's first post-barrier value must remain eligible while waiting for B;
	// requiring A to update twice can otherwise stall a multi-namespace view.
	stream.incoming <- indexedMetricSnapshot{index: 0, value: metricFanInSnapshot("uid-a", 2, t0.Add(time.Second))}
	barrier := t0.Add(2 * time.Second)
	stream.refresh <- barrier
	stream.incoming <- indexedMetricSnapshot{index: 0, value: metricFanInSnapshot("uid-a", 3, t0.Add(3*time.Second))}
	stream.incoming <- indexedMetricSnapshot{index: 1, value: metricFanInSnapshot("uid-b", 2, t0.Add(time.Second))}
	assertNoMetricFanInUpdate(t, stream.Updates())
	stream.incoming <- indexedMetricSnapshot{index: 1, value: metricFanInSnapshot("uid-b", 4, t0.Add(4*time.Second))}
	merged := receiveMetricFanInUpdate(t, stream.Updates())
	if merged.Samples["uid-a"].Resources["cpu"] != 3 ||
		merged.Samples["uid-b"].Resources["cpu"] != 4 ||
		merged.UpdatedAt.Before(barrier) {
		t.Fatalf("forced aggregate = %#v at %v", merged.Samples, merged.UpdatedAt)
	}
}

func TestMergeMetricSnapshotsRetainsPartialResultsAndRejectsIdentityCollision(t *testing.T) {
	t.Parallel()
	t0 := time.Date(2026, 8, 19, 12, 0, 0, 0, time.UTC)
	partial := mergeMetricSnapshots([]string{"a", "b"}, []metrics.Snapshot{
		metricFanInSnapshot("uid-a", 1, t0),
		{State: metrics.MeasurementUnavailable, UpdatedAt: t0.Add(time.Second), Err: errors.New("unavailable")},
	})
	if partial.State != metrics.MeasurementStale || partial.Samples["uid-a"].Resources["cpu"] != 1 ||
		partial.Err == nil || !strings.Contains(partial.Err.Error(), `namespace "b"`) {
		t.Fatalf("partial aggregate = %#v / %v", partial, partial.Err)
	}

	collision := mergeMetricSnapshots([]string{"a", "b"}, []metrics.Snapshot{
		metricFanInSnapshot("duplicate", 1, t0),
		metricFanInSnapshot("duplicate", 2, t0.Add(time.Second)),
	})
	if collision.State != metrics.MeasurementStale ||
		collision.Samples["duplicate"].Resources["cpu"] != 1 ||
		collision.Err == nil || !strings.Contains(collision.Err.Error(), "multiple namespace snapshots") {
		t.Fatalf("collision aggregate = %#v / %v", collision, collision.Err)
	}
}

func TestMetricFanInRefreshAndCloseOwnEveryChild(t *testing.T) {
	t.Parallel()
	var calls [2]atomic.Int64
	providers := make([]*metrics.Provider, 2)
	leases := make([]*metrics.ProviderLease, 2)
	for index := range providers {
		index := index
		provider, err := metrics.NewProvider(metricFetcherFunc(func(context.Context) (map[string]metrics.Sample, error) {
			calls[index].Add(1)
			return map[string]metrics.Sample{
				string(rune('a' + index)): {Resources: map[string]int64{"cpu": int64(index + 1)}},
			}, nil
		}), time.Hour)
		if err != nil {
			t.Fatal(err)
		}
		providers[index] = provider
		leases[index], err = provider.Acquire()
		if err != nil {
			t.Fatal(err)
		}
	}

	stream := subscribeMetricProviders([]string{"a", "b"}, leases)
	if stream == nil {
		t.Fatal("fan-in subscription is nil")
	}
	_ = receiveMetricFanInUpdate(t, stream.Updates())
	stream.RequestRefresh()
	eventually(t, time.Second, func() bool { return calls[0].Load() >= 2 && calls[1].Load() >= 2 })
	_ = receiveMetricFanInUpdate(t, stream.Updates())
	stream.Close()
	for _, provider := range providers {
		if provider.ConsumerCount() != 0 {
			t.Fatalf("closed fan-in retained %d provider consumers", provider.ConsumerCount())
		}
	}
	for {
		select {
		case _, open := <-stream.Updates():
			if !open {
				return
			}
		case <-time.After(time.Second):
			t.Fatal("fan-in updates did not close")
		}
	}
}

func TestMetricProviderSubscribeFailureReleasesEveryLease(t *testing.T) {
	t.Parallel()
	provider, err := metrics.NewProvider(metricFetcherFunc(func(context.Context) (map[string]metrics.Sample, error) {
		return nil, nil
	}), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	lease, err := provider.Acquire()
	if err != nil {
		t.Fatal(err)
	}
	if stream := subscribeMetricProviders(
		[]string{"a", "b"}, []*metrics.ProviderLease{lease, nil},
	); stream != nil {
		t.Fatal("invalid lease set produced a subscription")
	}
	if provider.ConsumerCount() != 0 || !provider.ReleaseIdle() {
		t.Fatal("failed fan-in subscription retained a consumer or reservation")
	}
}

func TestExactNamespaceCompleteMetricsUseCanonicalSharedListFanIn(t *testing.T) {
	t.Parallel()
	resources := exactNamespaceMetricResourceSource(t)
	metricSource := newNamespaceMetricSource(t, map[string]map[string]metrics.Sample{
		"a": {"uid-a": metricCPUSample(100_000_000)},
		"b": {"uid-b": metricCPUSample(300_000_000)},
	})
	runtime, err := NewRuntime(RuntimeConfig{
		Source: resources, Metrics: metricSource, BatchDelay: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	request := exactNamespaceMetricRequest("complete")
	request.Spec.Sort = []*kmgrv1.SortDescriptor{{
		ColumnId: PodCPUColumn, Direction: kmgrv1.SortDirection_SORT_DIRECTION_DESCENDING,
	}}
	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()

	if got := metricSource.openedNamespaces(); !slices.Equal(got, []string{"a", "b"}) {
		t.Fatalf("metrics providers = %q, want exact canonical namespace fan-in", got)
	}
	if subscription.metricPlan.strategy != metricFetchSharedList {
		t.Fatalf("complete metric strategy = %d, want shared LIST fan-in", subscription.metricPlan.strategy)
	}
	eventually(t, time.Second, func() bool {
		subscription.mu.Lock()
		defer subscription.mu.Unlock()
		return !subscription.metricsReconciling &&
			math.Abs(cellByID(subscription.rows["uid-a"], PodCPUColumn).GetUsage().GetUsed()-0.1) < 1e-9 &&
			math.Abs(cellByID(subscription.rows["uid-b"], PodCPUColumn).GetUsage().GetUsed()-0.3) < 1e-9 &&
			slices.Equal(subscription.order, []string{"uid-b", "uid-a"})
	})
}

func TestExactNamespaceDisplayMetricsKeepViewportGETs(t *testing.T) {
	t.Parallel()
	resources := exactNamespaceMetricResourceSource(t)
	metricSource := &recordingExactMetricSource{
		calls: make(chan []metrics.PodReference, 1),
		samples: map[string]metrics.Sample{
			"uid-a": metricCPUSample(100_000_000),
			"uid-b": metricCPUSample(300_000_000),
		},
	}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: resources, Metrics: metricSource, BatchDelay: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	subscription, err := runtime.Open(exactNamespaceMetricRequest("display"))
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	eventually(t, time.Second, func() bool {
		return subscriptionHasUID(subscription, "uid-a") && subscriptionHasUID(subscription, "uid-b")
	})
	if subscription.metricPlan.strategy != metricFetchPodObjects || metricSource.listOpens.Load() != 0 {
		t.Fatalf(
			"display strategy/list opens = %d/%d, want viewport exact GETs only",
			subscription.metricPlan.strategy, metricSource.listOpens.Load(),
		)
	}
	subscription.mu.Lock()
	revision := subscription.indexRevision
	subscription.mu.Unlock()
	if err := runtime.UpdateMetricInterest("session", "display", 1, revision, 0, 2); err != nil {
		t.Fatal(err)
	}
	references := receiveExactMetricReferences(t, metricSource.calls)
	if len(references) != 2 || metricSource.listOpens.Load() != 0 {
		t.Fatalf("viewport references/list opens = %#v/%d", references, metricSource.listOpens.Load())
	}
}

func TestSharedMetricCoverageWATCHChurnWaitsForCadence(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	basePod := metricInterestPod(t, "uid-a", "a")
	basePod.SetResourceVersion("rv-1")
	client.listPages = []*unstructured.UnstructuredList{listPage("rv-1", "", basePod)}
	started := make(chan struct{}, 32)
	var calls atomic.Int64
	provider, err := metrics.NewProvider(metricFetcherFunc(func(context.Context) (map[string]metrics.Sample, error) {
		calls.Add(1)
		started <- struct{}{}
		return map[string]metrics.Sample{"uid-a": metricCPUSample(200_000_000)}, nil
	}), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:  &fakeResourceSource{authority: "cluster", client: client},
		Metrics: &fakeMetricSource{provider: provider}, BatchDelay: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	request := openView("session", "churn", 1)
	request.Spec.ColumnIds = []string{"name", PodCPUColumn}
	request.Spec.Sort = []*kmgrv1.SortDescriptor{{
		ColumnId: PodCPUColumn, Direction: kmgrv1.SortDirection_SORT_DIRECTION_DESCENDING,
	}}
	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	eventually(t, time.Second, func() bool {
		subscription.mu.Lock()
		defer subscription.mu.Unlock()
		return subscription.snapshotComplete && !subscription.metricsReconciling && client.watchCalls.Load() != 0
	})
	drainMetricStarts(started)
	baseline := calls.Load()

	for index := range 12 {
		modified := basePod.DeepCopy()
		modified.SetResourceVersion(fmt.Sprintf("rv-%d", index+2))
		client.lastWatch().channel <- watch.Event{Type: watch.Modified, Object: modified}
	}
	eventually(t, time.Second, func() bool {
		subscription.mu.Lock()
		defer subscription.mu.Unlock()
		return subscription.metricsReconciling
	})
	select {
	case <-started:
		t.Fatal("Pod WATCH churn forced a Metrics LIST before the configured cadence")
	case <-time.After(50 * time.Millisecond):
	}
	if got := calls.Load(); got != baseline {
		t.Fatalf("metric fetch calls after WATCH churn = %d, want stable %d", got, baseline)
	}

	// Drive the same refresh hook used by the provider's cadence. The aggregate
	// started after the newest base change satisfies the pending barrier.
	subscription.mu.Lock()
	metricStream := subscription.metrics
	subscription.mu.Unlock()
	metricStream.RequestRefresh()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("cadence metric refresh did not start")
	}
	eventually(t, time.Second, func() bool {
		subscription.mu.Lock()
		defer subscription.mu.Unlock()
		return !subscription.metricsReconciling
	})
}

func metricFanInSnapshot(uid string, cpu int64, updatedAt time.Time) metrics.Snapshot {
	return metrics.Snapshot{
		Samples: map[string]metrics.Sample{uid: {Resources: map[string]int64{"cpu": cpu}}},
		State:   metrics.MeasurementCurrent, UpdatedAt: updatedAt,
	}
}

func assertNoMetricFanInUpdate(t *testing.T, updates <-chan metrics.Snapshot) {
	t.Helper()
	select {
	case value := <-updates:
		t.Fatalf("unexpected partial fan-in update: %#v", value)
	case <-time.After(20 * time.Millisecond):
	}
}

func receiveMetricFanInUpdate(t *testing.T, updates <-chan metrics.Snapshot) metrics.Snapshot {
	t.Helper()
	select {
	case value, open := <-updates:
		if !open {
			t.Fatal("metric fan-in closed before update")
		}
		return value
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for metric fan-in update")
		return metrics.Snapshot{}
	}
}

type namespaceMetricResourceSource struct {
	authority string
	clients   map[string]watcher.ListerWatcher
}

func (s *namespaceMetricResourceSource) OpenResource(
	_ string,
	_ schema.GroupVersionResource,
	namespace string,
) (string, watcher.ListerWatcher, error) {
	return s.authority, s.clients[namespace], nil
}

func exactNamespaceMetricResourceSource(t *testing.T) *namespaceMetricResourceSource {
	t.Helper()
	clients := make(map[string]watcher.ListerWatcher, 2)
	for _, namespace := range []string{"a", "b"} {
		client := newScriptedResource()
		object := metricInterestPod(t, "uid-"+namespace, namespace)
		object.SetNamespace(namespace)
		client.listPages = []*unstructured.UnstructuredList{listPage("rv-"+namespace, "", object)}
		clients[namespace] = client
	}
	return &namespaceMetricResourceSource{authority: "cluster", clients: clients}
}

type namespaceMetricSource struct {
	mu        sync.Mutex
	providers map[string]*metrics.Provider
	opens     []string
}

func newNamespaceMetricSource(
	t *testing.T,
	samples map[string]map[string]metrics.Sample,
) *namespaceMetricSource {
	t.Helper()
	result := &namespaceMetricSource{providers: make(map[string]*metrics.Provider, len(samples))}
	for namespace, values := range samples {
		values := values
		provider, err := metrics.NewProvider(metricFetcherFunc(func(context.Context) (map[string]metrics.Sample, error) {
			return values, nil
		}), time.Hour)
		if err != nil {
			t.Fatal(err)
		}
		result.providers[namespace] = provider
	}
	return result
}

func (s *namespaceMetricSource) OpenMetrics(
	_, _ string,
	_ metrics.APIKind,
	namespace, _ string,
) (*metrics.ProviderLease, error) {
	s.mu.Lock()
	s.opens = append(s.opens, namespace)
	provider := s.providers[namespace]
	s.mu.Unlock()
	if provider == nil {
		return nil, errors.New("unexpected metrics namespace " + namespace)
	}
	return provider.Acquire()
}

func (s *namespaceMetricSource) openedNamespaces() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.opens)
}

func exactNamespaceMetricRequest(viewID string) *kmgrv1.OpenViewRequest {
	request := openView("session", viewID, 1)
	request.Spec.NamespaceScope = &kmgrv1.NamespaceScope{Namespaces: []string{"b", "a"}}
	request.Spec.ColumnIds = []string{"name", PodCPUColumn}
	return request
}

func drainMetricStarts(values <-chan struct{}) {
	for {
		select {
		case <-values:
		default:
			return
		}
	}
}
