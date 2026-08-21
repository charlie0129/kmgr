package view

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	"github.com/charlie0129/kmgr/backend/internal/store"
	"github.com/charlie0129/kmgr/backend/internal/watcher"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func TestRuntimeWarmMetricCatchupNeverRegressesUsageToMissing(t *testing.T) {
	tests := []struct {
		name      string
		request   func() *kmgrv1.OpenViewRequest
		warm      func() *unstructured.Unstructured
		current   func() *unstructured.Unstructured
		validate  func(*testing.T, *kmgrv1.Cell) bool
		resource  string
		namespace string
	}{
		{
			name: "Pod",
			request: func() *kmgrv1.OpenViewRequest {
				request := openView("session", "warm-pod", 1)
				request.Spec.ColumnIds = []string{"name", PodCPUColumn}
				return request
			},
			warm: func() *unstructured.Unstructured {
				return warmMetricPod("500m", "1")
			},
			current: func() *unstructured.Unstructured {
				return warmMetricPod("750m", "2")
			},
			validate: func(t *testing.T, cell *kmgrv1.Cell) bool {
				t.Helper()
				usage := cell.GetUsage()
				if usage.GetRequested() != 0.75 || usage.GetLimit() != 2 ||
					!strings.Contains(cell.GetTooltip(), "Effective request: 750m") ||
					!strings.Contains(cell.GetTooltip(), "Effective limit: 2") {
					t.Fatalf("warm measurement hid fresh Pod allocation: %#v", cell)
				}
				return true
			},
			resource:  "pods",
			namespace: "ns",
		},
		{
			name: "Node",
			request: func() *kmgrv1.OpenViewRequest {
				request := openNodeView("session", "warm-node", 1)
				request.Spec.ColumnIds = []string{"name", NodeCPUUsageColumn}
				return request
			},
			warm: func() *unstructured.Unstructured {
				return nodeObject(
					"node-uid", "node-a",
					corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4")},
					corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("8")},
				)
			},
			current: func() *unstructured.Unstructured {
				return nodeObject(
					"node-uid", "node-a",
					corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("6")},
					corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("12")},
				)
			},
			validate: func(t *testing.T, cell *kmgrv1.Cell) bool {
				t.Helper()
				usage := cell.GetUsage()
				if usage.GetCapacity() != 6 ||
					!strings.Contains(cell.GetTooltip(), "Allocatable: 6") ||
					!strings.Contains(cell.GetTooltip(), "Physical capacity: 12") {
					t.Fatalf("warm measurement hid fresh Node capacity: %#v", cell)
				}
				if usage.Requested != nil || usage.Limit != nil {
					t.Fatalf("Node usage included cross-resource accounting: %#v", cell)
				}
				return true
			},
			resource: "nodes",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := test.request()
			warmObject := test.warm()
			currentObject := test.current()
			uid := string(warmObject.GetUID())
			projector, err := projectorFromProto("session", request.GetSpec(), nil, nil, nil)
			if err != nil {
				t.Fatal(err)
			}
			warmMetricState := metrics.Snapshot{
				State:     metrics.MeasurementCurrent,
				UpdatedAt: time.Unix(100, 0),
				Samples: map[string]metrics.Sample{uid: {
					MeasuredAt: time.Unix(100, 0),
					Resources:  map[string]int64{"cpu": 250_000_000},
				}},
			}
			projector = projector.WithMetrics(warmMetricState)
			warmRows := projector.Project([]*unstructured.Unstructured{warmObject})
			if len(warmRows) != 1 || !cellByID(warmRows[0], PodCPUColumn).GetUsage().GetUsageAvailable() {
				t.Fatalf("warm fixture did not contain CPU usage: %#v", warmRows)
			}

			baseClient := newScriptedResource()
			source := &gvrResourceSource{
				authority: "cluster-a",
				clients: map[string]watcher.ListerWatcher{
					test.resource: baseClient,
				},
			}
			fetcher := &runtimeBlockingMetricFetcher{
				started: make(chan struct{}, 1),
				result:  make(chan runtimeMetricResult, 1),
				stopped: make(chan struct{}),
			}
			provider, err := metrics.NewProvider(fetcher, time.Hour)
			if err != nil {
				t.Fatal(err)
			}
			runtime, err := NewRuntime(RuntimeConfig{
				Source:          source,
				Metrics:         &fakeMetricSource{provider: provider},
				BatchDelay:      time.Millisecond,
				ReleaseDelay:    time.Hour,
				PipelineTimeout: time.Second,
			})
			if err != nil {
				t.Fatal(err)
			}
			defer runtime.Close()

			entryStore := store.New()
			entryStore.Upsert(currentObject)
			entryStore.SetResourceVersion("rv-warm")
			key := resourceKey{
				authorityID: "cluster-a",
				version:     "v1",
				resource:    test.resource,
				namespace:   test.namespace,
			}
			entry := &resourceRuntime{
				key: key, store: entryStore, client: baseClient,
				state: resourceIdle, snapshotComplete: true,
				subscribers: make(map[*Subscription]struct{}),
				lastStatus: watcher.Status{
					Phase: watcher.PhaseResuming, Stale: true,
					ResourceVersion: "rv-warm", LastSynchronized: time.Unix(100, 0),
				},
				warmProjection: &warmProjection{
					key: projector.cacheKey, rows: warmRows,
					metricSnapshot: &warmMetricState,
					retainedBytes: saturatingProjectionBytes(
						projectedRowsRetainedBytes(warmRows),
						warmMetricSnapshotRetainedBytes(&warmMetricState),
					),
				},
			}
			runtime.mu.Lock()
			runtime.resources[key] = entry
			admitted := runtime.finalizeWarmLocked(entry)
			runtime.mu.Unlock()
			if !admitted {
				t.Fatal("warm metric fixture was not admitted")
			}

			subscription, err := runtime.Open(request)
			if err != nil {
				t.Fatal(err)
			}
			defer subscription.Close()
			initial := drainSubscription(t, subscription)
			assertMetricRowsAvailable(t, subscription, initial, uid, PodCPUColumn)
			select {
			case <-fetcher.started:
			case <-time.After(time.Second):
				t.Fatal("replacement metrics fetch did not start")
			}

			// The mandatory raw-store resnapshot is deterministic and completes
			// while the independent replacement metrics fetch is still blocked.
			// Every same-UID row emitted in this interval must retain the warm
			// usage presentation.
			observedCatchup := false
			observedFreshObjectState := false
			deadline := time.Now().Add(time.Second)
			for (!observedCatchup || !observedFreshObjectState) && time.Now().Before(deadline) {
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
				for _, row := range invalidationRows(subscription, events) {
					if row.GetIdentity().GetUid() != uid {
						continue
					}
					observedCatchup = true
					cell := cellByID(row, PodCPUColumn)
					if !cell.GetUsage().GetUsageAvailable() || cell.GetUsage().GetUsed() != 0.25 {
						t.Fatalf("same-UID warm catch-up regressed usage: %#v", row)
					}
					observedFreshObjectState = test.validate(t, cell) || observedFreshObjectState
				}
			}
			if !observedCatchup {
				t.Fatal("warm raw-store catch-up did not publish a row")
			}
			if !observedFreshObjectState {
				t.Fatal("fresh object state did not publish while metrics were blocked")
			}

			// An explicit unavailable provider result is authoritative and must
			// release the bridge rather than retaining stale usage indefinitely.
			fetcher.result <- runtimeMetricResult{err: errors.New("metrics unavailable")}
			waitForUsageUnavailable(t, subscription, uid, PodCPUColumn)
		})
	}
}

func TestCaptureWarmProjectionTrimsAndPreservesMetricSnapshot(t *testing.T) {
	updatedAt := time.Unix(100, 0)
	zeroMeasuredAt := time.Unix(90, 0)
	fallbackMeasuredAt := time.Unix(95, 0)
	providerErr := errors.New("sanitized provider failure")
	metricState := metrics.Snapshot{
		State: metrics.MeasurementStale, UpdatedAt: updatedAt,
		Err: providerErr,
		Samples: map[string]metrics.Sample{
			"uid-zero": {
				MeasuredAt: zeroMeasuredAt,
				Resources:  map[string]int64{string(corev1.ResourceCPU): 0},
			},
			"ns/fallback": {
				MeasuredAt: fallbackMeasuredAt,
				Resources:  map[string]int64{string(corev1.ResourceMemory): 256},
			},
			"hidden-uid": {
				Resources: map[string]int64{string(corev1.ResourceCPU): 1},
			},
		},
	}
	projector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session",
		Resource: ResourceType{
			Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true,
		},
		NamespaceScope: NamespaceScope{All: true},
		ColumnIDs:      []string{PodCPUColumn},
	})
	if err != nil {
		t.Fatal(err)
	}
	projector = projector.WithMetrics(metricState)
	rows := map[string]*kmgrv1.ResourceRow{
		"uid-zero": {
			Identity: &kmgrv1.ResourceIdentity{
				Uid: "uid-zero", Namespace: "ns", Name: "zero",
			},
		},
		"uid-fallback": {
			Identity: &kmgrv1.ResourceIdentity{
				Uid: "uid-fallback", Namespace: "ns", Name: "fallback",
			},
		},
	}
	subscription := &Subscription{
		resource:           &resourceRuntime{},
		projector:          projector,
		projectionCacheKey: projector.cacheKey,
		rows:               rows,
		order:              []string{"uid-zero", "uid-fallback"},
	}

	projection := subscription.captureWarmProjectionUnlocked()
	if projection == nil || projection.metricSnapshot == nil {
		t.Fatalf("warm metric projection = %#v, want retained snapshot", projection)
	}
	snapshot := projection.metricSnapshot
	if snapshot.State != metrics.MeasurementStale || !snapshot.UpdatedAt.Equal(updatedAt) ||
		!errors.Is(snapshot.Err, providerErr) {
		t.Fatalf("warm snapshot metadata = %#v", snapshot)
	}
	if len(snapshot.Samples) != 2 {
		t.Fatalf("warm snapshot samples = %#v, want only two visible UIDs", snapshot.Samples)
	}
	zero, found := snapshot.Samples["uid-zero"]
	value, resourceFound := zero.Resources[string(corev1.ResourceCPU)]
	if !found || !resourceFound || value != 0 ||
		!zero.MeasuredAt.Equal(zeroMeasuredAt) {
		t.Fatalf("warm zero sample = %#v, found = %t", zero, found)
	}
	fallback, found := snapshot.Samples["uid-fallback"]
	if !found || fallback.Resources[string(corev1.ResourceMemory)] != 256 ||
		!fallback.MeasuredAt.Equal(fallbackMeasuredAt) {
		t.Fatalf("rekeyed fallback sample = %#v, found = %t", fallback, found)
	}
	if _, found := snapshot.Samples["ns/fallback"]; found {
		t.Fatal("name-based fallback key was retained instead of rekeyed to UID")
	}
	if _, found := snapshot.Samples["hidden-uid"]; found {
		t.Fatal("non-visible metrics sample was retained")
	}
	rowBytes := projectedRowsRetainedBytes(projection.rows)
	if projection.retainedBytes <= rowBytes {
		t.Fatalf("retained bytes = %d, want more than row-only %d",
			projection.retainedBytes, rowBytes)
	}
}

func TestCaptureWarmProjectionPreservesEmptyCurrentMetricState(t *testing.T) {
	projector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session",
		Resource: ResourceType{
			Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true,
		},
		NamespaceScope: NamespaceScope{All: true},
		ColumnIDs:      []string{PodCPUColumn},
	})
	if err != nil {
		t.Fatal(err)
	}
	updatedAt := time.Unix(100, 0)
	projector = projector.WithMetrics(metrics.Snapshot{
		State: metrics.MeasurementCurrent, UpdatedAt: updatedAt,
	})
	row := &kmgrv1.ResourceRow{Identity: &kmgrv1.ResourceIdentity{
		Uid: "uid-missing", Namespace: "ns", Name: "missing",
	}}
	subscription := &Subscription{
		resource:           &resourceRuntime{},
		projector:          projector,
		projectionCacheKey: projector.cacheKey,
		rows:               map[string]*kmgrv1.ResourceRow{"uid-missing": row},
		order:              []string{"uid-missing"},
	}

	projection := subscription.captureWarmProjectionUnlocked()
	if projection == nil || projection.metricSnapshot == nil {
		t.Fatalf("warm projection = %#v, want empty current metrics state", projection)
	}
	if projection.metricSnapshot.State != metrics.MeasurementCurrent ||
		!projection.metricSnapshot.UpdatedAt.Equal(updatedAt) ||
		len(projection.metricSnapshot.Samples) != 0 {
		t.Fatalf("empty current metric snapshot = %#v", projection.metricSnapshot)
	}
	rowBytes := projectedRowsRetainedBytes(projection.rows)
	if projection.retainedBytes <= rowBytes {
		t.Fatalf("retained bytes = %d, want metadata charged above row-only %d",
			projection.retainedBytes, rowBytes)
	}
}

func warmMetricPod(requestCPU, limitCPU string) *unstructured.Unstructured {
	value := pod("pod-uid", "ns", "api", "Running", 0, nil, time.Time{})
	container := value.Object["spec"].(map[string]any)["containers"].([]any)[0].(map[string]any)
	container["resources"] = map[string]any{
		"requests": map[string]any{"cpu": requestCPU},
		"limits":   map[string]any{"cpu": limitCPU},
	}
	return value
}

func assertMetricRowsAvailable(
	t *testing.T,
	subscription *Subscription,
	events []*kmgrv1.ViewEvent,
	uid, columnID string,
) bool {
	t.Helper()
	found := false
	for _, row := range invalidationRows(subscription, events) {
		if row.GetIdentity().GetUid() != uid {
			continue
		}
		found = true
		if !cellByID(row, columnID).GetUsage().GetUsageAvailable() {
			t.Fatalf("same-UID warm catch-up regressed usage: %#v", row)
		}
	}
	return found
}

func waitForUsageUnavailable(
	t *testing.T,
	subscription *Subscription,
	uid, columnID string,
) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
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
			if row.GetIdentity().GetUid() == uid &&
				!cellByID(row, columnID).GetUsage().GetUsageAvailable() {
				return
			}
		}
	}
	t.Fatalf("authoritative unavailable metrics did not clear warm usage for %q", uid)
}
