package view

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/watch"
)

func TestMetricInterestFetchesOnlyPinnedViewportPods(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	pods := []*unstructured.Unstructured{
		metricInterestPod(t, "uid-a", "a"),
		metricInterestPod(t, "uid-b", "b"),
		metricInterestPod(t, "uid-c", "c"),
	}
	client.listPages = []*unstructured.UnstructuredList{listPage("rv-1", "", pods...)}
	metricSource := &recordingExactMetricSource{
		calls: make(chan []metrics.PodReference, 2),
		samples: map[string]metrics.Sample{
			"uid-b": {
				MeasuredAt: time.Date(2026, 8, 19, 12, 0, 0, 0, time.UTC),
				Resources:  map[string]int64{"cpu": 250_000_000},
			},
		},
	}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:  &fakeResourceSource{authority: "cluster-a", client: client},
		Metrics: metricSource, BatchDelay: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	request := openView("session", "pods", 1)
	request.Spec.ColumnIds = []string{"name", PodCPUColumn}
	request.Spec.FilterExpression = "field:spec.nodeName==node-a"
	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	waitForRow(t, subscription, "uid-a")
	eventually(t, time.Second, func() bool {
		subscription.mu.Lock()
		defer subscription.mu.Unlock()
		return len(subscription.rows) == 3
	})
	if got := metricSource.listOpens.Load(); got != 0 {
		t.Fatalf("field-selected Pod view opened %d PodMetrics LIST providers", got)
	}

	subscription.mu.Lock()
	indexRevision := subscription.indexRevision
	subscription.mu.Unlock()
	if err := runtime.UpdateMetricInterest(
		"session", "pods", 1, indexRevision, 1, 1,
	); err != nil {
		t.Fatal(err)
	}
	select {
	case references := <-metricSource.calls:
		if len(references) != 1 || references[0].UID != "uid-b" ||
			references[0].Namespace != "ns" || references[0].Name != "b" {
			t.Fatalf("exact metric references = %#v", references)
		}
	case <-time.After(time.Second):
		t.Fatal("viewport metric resolve did not start")
	}
	usage := waitForUsageAvailable(t, subscription, "uid-b", PodCPUColumn).GetUsage()
	if usage.GetUsed() != 0.25 {
		t.Fatalf("viewport CPU usage = %v", usage.GetUsed())
	}
	for _, uid := range []string{"uid-a", "uid-c"} {
		subscription.mu.Lock()
		row := subscription.rows[uid]
		subscription.mu.Unlock()
		if cellByID(row, PodCPUColumn).GetUsage().GetUsageAvailable() {
			t.Fatalf("offscreen Pod %s unexpectedly received metrics", uid)
		}
	}
	if err := runtime.UpdateMetricInterest(
		"session", "pods", 1, indexRevision, 0, 1,
	); err != nil {
		t.Fatal(err)
	}
	_ = receiveExactMetricReferences(t, metricSource.calls)
	eventually(t, time.Second, func() bool {
		subscription.mu.Lock()
		defer subscription.mu.Unlock()
		return len(subscription.projector.spec.Metrics.Samples) == 0
	})
	subscription.mu.Lock()
	retainedCell := cellByID(subscription.rows["uid-b"], PodCPUColumn).GetUsage().GetUsageAvailable()
	subscription.mu.Unlock()
	if !retainedCell {
		t.Fatal("leaving a viewport erased its already-projected immutable metric cell")
	}
}

func TestMetricInterestLatestRangeCancelsOlderApply(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-1", "",
		metricInterestPod(t, "uid-a", "a"),
		metricInterestPod(t, "uid-b", "b"),
	)}
	metricSource := &blockingExactMetricSource{
		started: make(chan []metrics.PodReference, 2),
		release: make(chan struct{}),
	}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:  &fakeResourceSource{authority: "cluster-a", client: client},
		Metrics: metricSource, BatchDelay: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	request := openView("session", "pods", 1)
	request.Spec.ColumnIds = []string{"name", PodCPUColumn}
	request.Spec.FilterExpression = "field:spec.nodeName==node-a"
	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	waitForRow(t, subscription, "uid-b")
	subscription.mu.Lock()
	revision := subscription.indexRevision
	subscription.mu.Unlock()

	if err := runtime.UpdateMetricInterest("session", "pods", 1, revision, 0, 1); err != nil {
		t.Fatal(err)
	}
	first := receiveExactMetricReferences(t, metricSource.started)
	if len(first) != 1 || first[0].UID != "uid-a" {
		t.Fatalf("first references = %#v", first)
	}
	if err := runtime.UpdateMetricInterest("session", "pods", 1, revision, 1, 1); err != nil {
		t.Fatal(err)
	}
	second := receiveExactMetricReferences(t, metricSource.started)
	if len(second) != 1 || second[0].UID != "uid-b" {
		t.Fatalf("second references = %#v", second)
	}
	close(metricSource.release)
	usage := waitForUsageAvailable(t, subscription, "uid-b", PodCPUColumn).GetUsage()
	if usage.GetUsed() != 0.2 {
		t.Fatalf("latest viewport CPU usage = %v", usage.GetUsed())
	}
	if metricSource.canceled.Load() == 0 {
		t.Fatal("superseded viewport metric resolve was not canceled")
	}
	subscription.mu.Lock()
	firstAvailable := cellByID(subscription.rows["uid-a"], PodCPUColumn).GetUsage().GetUsageAvailable()
	subscription.mu.Unlock()
	if firstAvailable {
		t.Fatal("superseded viewport metrics were applied")
	}
}

func TestCompleteExactMetricsAtomicallyReconcileGlobalSort(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-1", "",
		metricInterestPod(t, "uid-a", "a"),
		metricInterestPod(t, "uid-b", "b"),
		metricInterestPod(t, "uid-c", "c"),
	)}
	metricSource := &controlledCompleteMetricSource{
		started: make(chan []metrics.PodReference, 2),
		release: make(chan struct{}),
		samples: map[string]metrics.Sample{
			"uid-a": metricCPUSample(100_000_000),
			"uid-b": metricCPUSample(300_000_000),
			"uid-c": metricCPUSample(200_000_000),
		},
	}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:  &fakeResourceSource{authority: "cluster-a", client: client},
		Metrics: metricSource, BatchDelay: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	request := openView("session", "sorted", 1)
	request.StageUntilReconciled = true
	request.Spec.ColumnIds = []string{"name", PodCPUColumn}
	request.Spec.FilterExpression = "field:spec.nodeName==node-a"
	request.Spec.Sort = []*kmgrv1.SortDescriptor{{
		ColumnId: PodCPUColumn, Direction: kmgrv1.SortDirection_SORT_DIRECTION_DESCENDING,
	}}
	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	initial, err := subscription.Next(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := subscription.AcknowledgeDelivery(initial); err != nil {
		t.Fatal(err)
	}
	if !eventsReportMetricsReconciling(initial) || eventsContainReconciled(initial) {
		t.Fatalf("initial complete-metric events = %#v", initial)
	}
	references := receiveExactMetricReferences(t, metricSource.started)
	if len(references) != 3 {
		t.Fatalf("complete metric references = %#v", references)
	}
	close(metricSource.release)
	eventually(t, time.Second, func() bool {
		subscription.mu.Lock()
		defer subscription.mu.Unlock()
		return !subscription.metricsReconciling &&
			equalStrings(subscription.order, []string{"uid-b", "uid-c", "uid-a"})
	})
	completed, err := subscription.Next(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !eventsContainReconciled(completed) {
		t.Fatalf("completion events lack reconciliation barrier: %#v", completed)
	}
	if eventsReportMetricsReconciling(completed) {
		t.Fatalf("completion still reports metrics reconciliation: %#v", completed)
	}
}

func TestCompleteExactMetricsDiscardInvalidatedScanUntilCadence(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	basePod := metricInterestPod(t, "uid-a", "a")
	basePod.SetResourceVersion("rv-1")
	client.listPages = []*unstructured.UnstructuredList{listPage("rv-1", "", basePod)}
	metricSource := &controlledCompleteMetricSource{
		started: make(chan []metrics.PodReference, 2),
		release: make(chan struct{}),
		samples: map[string]metrics.Sample{
			"uid-a": metricCPUSample(100_000_000),
		},
	}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:  &fakeResourceSource{authority: "cluster-a", client: client},
		Metrics: metricSource, BatchDelay: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	request := openView("session", "invalidated", 1)
	request.Spec.ColumnIds = []string{"name", PodCPUColumn}
	request.Spec.FilterExpression = "field:spec.nodeName==node-a"
	request.Spec.Sort = []*kmgrv1.SortDescriptor{{
		ColumnId: PodCPUColumn, Direction: kmgrv1.SortDirection_SORT_DIRECTION_DESCENDING,
	}}
	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	if references := receiveExactMetricReferences(t, metricSource.started); len(references) != 1 {
		t.Fatalf("initial complete references = %#v", references)
	}
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() != 0 })

	modified := basePod.DeepCopy()
	modified.SetResourceVersion("rv-2")
	client.lastWatch().channel <- watch.Event{Type: watch.Modified, Object: modified}
	eventually(t, time.Second, func() bool {
		subscription.mu.Lock()
		defer subscription.mu.Unlock()
		return subscription.metricCoverageDirty && subscription.metricsReconciling
	})
	close(metricSource.release)
	eventually(t, time.Second, func() bool {
		subscription.mu.Lock()
		defer subscription.mu.Unlock()
		return !subscription.metricCoverageRunning && subscription.metricCoverageTimer != nil
	})
	select {
	case references := <-metricSource.started:
		t.Fatalf("invalidated scan restarted before cadence: %#v", references)
	case <-time.After(50 * time.Millisecond):
	}

	subscription.requestCompleteMetricCoverage()
	if references := receiveExactMetricReferences(t, metricSource.started); len(references) != 1 {
		t.Fatalf("cadence complete references = %#v", references)
	}
	eventually(t, time.Second, func() bool {
		subscription.mu.Lock()
		defer subscription.mu.Unlock()
		return !subscription.metricsReconciling
	})
}

func TestCompleteExactMetricsCoverFilterHiddenBaseCandidates(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-1", "",
		metricInterestPod(t, "uid-a", "a"),
		metricInterestPod(t, "uid-b", "b"),
	)}
	metricSource := &recordingExactMetricSource{
		calls: make(chan []metrics.PodReference, 2),
		samples: map[string]metrics.Sample{
			"uid-a": metricCPUSample(100_000_000),
			"uid-b": metricCPUSample(250_000_000),
		},
	}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:  &fakeResourceSource{authority: "cluster-a", client: client},
		Metrics: metricSource, BatchDelay: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	request := openView("session", "filtered", 1)
	request.Spec.ColumnIds = []string{"name", PodCPUColumn}
	// Bare text searches rendered cells, so both base Pods are initially hidden
	// and complete coverage must come from the raw store rather than s.order.
	request.Spec.FilterExpression = "0.25"
	request.Spec.FieldSelector = "spec.nodeName=node-a"
	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	references := receiveExactMetricReferences(t, metricSource.calls)
	if len(references) != 2 {
		t.Fatalf("hidden-candidate references = %#v", references)
	}
	eventually(t, time.Second, func() bool {
		subscription.mu.Lock()
		defer subscription.mu.Unlock()
		return !subscription.metricsReconciling &&
			equalStrings(subscription.order, []string{"uid-b"})
	})
}

func TestCompleteExactMetricsCoalesceBaseChurnUntilCadence(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-1", "",
		metricInterestPod(t, "uid-a", "a"),
		metricInterestPod(t, "uid-b", "b"),
	)}
	metricSource := &recordingExactMetricSource{
		calls:           make(chan []metrics.PodReference, 4),
		refreshInterval: time.Hour,
		samples: map[string]metrics.Sample{
			"uid-a": metricCPUSample(100_000_000),
			"uid-b": metricCPUSample(200_000_000),
		},
	}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:  &fakeResourceSource{authority: "cluster-a", client: client},
		Metrics: metricSource, BatchDelay: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	request := openView("session", "changing", 1)
	request.Spec.ColumnIds = []string{"name", PodCPUColumn}
	request.Spec.FilterExpression = "field:spec.nodeName==node-a"
	request.Spec.Sort = []*kmgrv1.SortDescriptor{{
		ColumnId: PodCPUColumn, Direction: kmgrv1.SortDirection_SORT_DIRECTION_DESCENDING,
	}}
	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	if references := receiveExactMetricReferences(t, metricSource.calls); len(references) != 2 {
		t.Fatalf("initial complete references = %#v", references)
	}
	eventually(t, time.Second, func() bool {
		subscription.mu.Lock()
		defer subscription.mu.Unlock()
		return !subscription.metricsReconciling
	})
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() != 0 })
	metricSource.mu.Lock()
	metricSource.samples["uid-c"] = metricCPUSample(300_000_000)
	metricSource.mu.Unlock()
	added := metricInterestPod(t, "uid-c", "c")
	added.SetResourceVersion("rv-2")
	client.lastWatch().channel <- watch.Event{Type: watch.Added, Object: added}
	for index := range 12 {
		modified := added.DeepCopy()
		modified.SetResourceVersion(fmt.Sprintf("rv-%d", index+3))
		client.lastWatch().channel <- watch.Event{Type: watch.Modified, Object: modified}
	}
	eventually(t, time.Second, func() bool {
		subscription.mu.Lock()
		defer subscription.mu.Unlock()
		return subscription.metricsReconciling && subscription.metricCoverageTimer != nil
	})
	select {
	case references := <-metricSource.calls:
		t.Fatalf("WATCH churn started an exact candidate scan before cadence: %#v", references)
	case <-time.After(50 * time.Millisecond):
	}

	// Simulate the configured cadence without waiting an hour. All WATCH
	// batches coalesce into exactly one complete scan of the latest candidates.
	subscription.requestCompleteMetricCoverage()
	references := receiveExactMetricReferences(t, metricSource.calls)
	if len(references) != 3 {
		t.Fatalf("membership-change references = %#v", references)
	}
	select {
	case references := <-metricSource.calls:
		t.Fatalf("one cadence produced multiple exact candidate scans: %#v", references)
	case <-time.After(50 * time.Millisecond):
	}
	eventually(t, time.Second, func() bool {
		subscription.mu.Lock()
		defer subscription.mu.Unlock()
		return !subscription.metricsReconciling &&
			equalStrings(subscription.order, []string{"uid-c", "uid-b", "uid-a"})
	})
}

func TestCompleteExactMetricsRefreshOnCacheCadence(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-1", "", metricInterestPod(t, "uid-a", "a"),
	)}
	metricSource := &recordingExactMetricSource{
		calls:           make(chan []metrics.PodReference, 4),
		refreshInterval: 15 * time.Millisecond,
		samples: map[string]metrics.Sample{
			"uid-a": metricCPUSample(100_000_000),
		},
	}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:  &fakeResourceSource{authority: "cluster-a", client: client},
		Metrics: metricSource, BatchDelay: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	request := openView("session", "refreshing", 1)
	request.Spec.ColumnIds = []string{"name", PodCPUColumn}
	request.Spec.FilterExpression = "field:spec.nodeName==node-a"
	request.Spec.Sort = []*kmgrv1.SortDescriptor{{
		ColumnId: PodCPUColumn, Direction: kmgrv1.SortDirection_SORT_DIRECTION_DESCENDING,
	}}
	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	_ = receiveExactMetricReferences(t, metricSource.calls)
	// The second resolve is timer-driven with unchanged base membership. In the
	// Kubernetes implementation its per-object cache refreshes only expired
	// entries, while still providing complete order coverage atomically.
	_ = receiveExactMetricReferences(t, metricSource.calls)
}

func TestCompleteSharedMetricsReconcileAfterBaseBarrier(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage(
		"rv-1", "",
		metricInterestPod(t, "uid-a", "a"),
		metricInterestPod(t, "uid-b", "b"),
	)}
	provider, err := metrics.NewProvider(metricFetcherFunc(func(context.Context) (map[string]metrics.Sample, error) {
		return map[string]metrics.Sample{
			"uid-a": metricCPUSample(100_000_000),
			"uid-b": metricCPUSample(300_000_000),
		}, nil
	}), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	metricSource := &fakeMetricSource{provider: provider}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:  &fakeResourceSource{authority: "cluster-a", client: client},
		Metrics: metricSource, BatchDelay: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	request := openView("session", "shared", 1)
	request.StageUntilReconciled = true
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
		return subscription.snapshotComplete && !subscription.metricsReconciling &&
			equalStrings(subscription.order, []string{"uid-b", "uid-a"})
	})
	if metricSource.opens.Load() != 1 {
		t.Fatalf("shared complete view opened %d providers", metricSource.opens.Load())
	}
}

func metricInterestPod(t *testing.T, uid, name string) *unstructured.Unstructured {
	t.Helper()
	object := pod(uid, "ns", name, "Running", 0, nil, time.Time{})
	if err := unstructured.SetNestedField(object.Object, "node-a", "spec", "nodeName"); err != nil {
		t.Fatal(err)
	}
	return object
}

func metricCPUSample(nanocores int64) metrics.Sample {
	return metrics.Sample{
		MeasuredAt: time.Date(2026, 8, 19, 12, 0, 0, 0, time.UTC),
		Resources:  map[string]int64{"cpu": nanocores},
	}
}

func eventsReportMetricsReconciling(events []*kmgrv1.ViewEvent) bool {
	value := false
	for _, event := range events {
		if status := event.GetStatus(); status != nil {
			value = status.GetMetricsReconciling()
		}
	}
	return value
}

func eventsContainReconciled(events []*kmgrv1.ViewEvent) bool {
	for _, event := range events {
		if event.GetReconciled() != nil {
			return true
		}
	}
	return false
}

type recordingExactMetricSource struct {
	listOpens       atomic.Int64
	calls           chan []metrics.PodReference
	refreshInterval time.Duration

	mu      sync.Mutex
	samples map[string]metrics.Sample
}

func (s *recordingExactMetricSource) PodMetricRefreshInterval() time.Duration {
	return s.refreshInterval
}

func (s *recordingExactMetricSource) OpenMetrics(
	string, string, metrics.APIKind, string, string,
) (*metrics.ProviderLease, error) {
	s.listOpens.Add(1)
	return nil, errors.New("unexpected metrics LIST provider")
}

func (s *recordingExactMetricSource) ResolvePodMetrics(
	ctx context.Context,
	_, _ string,
	references []metrics.PodReference,
) (metrics.Snapshot, error) {
	copyReferences := append([]metrics.PodReference(nil), references...)
	select {
	case s.calls <- copyReferences:
	case <-ctx.Done():
		return metrics.Snapshot{}, ctx.Err()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	samples := make(map[string]metrics.Sample, len(references))
	for _, reference := range references {
		if sample, ok := s.samples[string(reference.UID)]; ok {
			samples[string(reference.UID)] = cloneMetricSample(sample)
		}
	}
	return metrics.Snapshot{
		Samples: samples, State: metrics.MeasurementCurrent, UpdatedAt: time.Now(),
	}, nil
}

type blockingExactMetricSource struct {
	started  chan []metrics.PodReference
	release  chan struct{}
	canceled atomic.Int64
}

type controlledCompleteMetricSource struct {
	started chan []metrics.PodReference
	release chan struct{}
	samples map[string]metrics.Sample
}

func (*controlledCompleteMetricSource) OpenMetrics(
	string, string, metrics.APIKind, string, string,
) (*metrics.ProviderLease, error) {
	return nil, errors.New("unexpected metrics LIST provider")
}

func (s *controlledCompleteMetricSource) ResolvePodMetrics(
	ctx context.Context,
	_, _ string,
	references []metrics.PodReference,
) (metrics.Snapshot, error) {
	select {
	case s.started <- append([]metrics.PodReference(nil), references...):
	case <-ctx.Done():
		return metrics.Snapshot{}, ctx.Err()
	}
	select {
	case <-s.release:
	case <-ctx.Done():
		return metrics.Snapshot{}, ctx.Err()
	}
	result := make(map[string]metrics.Sample, len(references))
	for _, reference := range references {
		if sample, ok := s.samples[string(reference.UID)]; ok {
			result[string(reference.UID)] = cloneMetricSample(sample)
		}
	}
	return metrics.Snapshot{
		Samples: result, State: metrics.MeasurementCurrent, UpdatedAt: time.Now(),
	}, nil
}

func (*blockingExactMetricSource) OpenMetrics(
	string, string, metrics.APIKind, string, string,
) (*metrics.ProviderLease, error) {
	return nil, errors.New("unexpected metrics LIST provider")
}

func (s *blockingExactMetricSource) ResolvePodMetrics(
	ctx context.Context,
	_, _ string,
	references []metrics.PodReference,
) (metrics.Snapshot, error) {
	s.started <- append([]metrics.PodReference(nil), references...)
	select {
	case <-ctx.Done():
		s.canceled.Add(1)
		return metrics.Snapshot{}, ctx.Err()
	case <-s.release:
	}
	samples := make(map[string]metrics.Sample, len(references))
	for _, reference := range references {
		samples[string(reference.UID)] = metrics.Sample{
			MeasuredAt: time.Now(), Resources: map[string]int64{"cpu": 200_000_000},
		}
	}
	return metrics.Snapshot{
		Samples: samples, State: metrics.MeasurementCurrent, UpdatedAt: time.Now(),
	}, nil
}

func receiveExactMetricReferences(
	t *testing.T,
	values <-chan []metrics.PodReference,
) []metrics.PodReference {
	t.Helper()
	select {
	case references := <-values:
		return references
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for exact metrics resolve")
		return nil
	}
}
