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
		configure func(*Projector) *Projector
		pods      func() []*unstructured.Unstructured
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
			configure: func(projector *Projector) *Projector { return projector },
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
			configure: func(projector *Projector) *Projector {
				return projector.WithNodeAccounting(NodeAccountingSnapshot{
					Active: true, Ready: true,
					Nodes: map[string]metrics.NodeAccounting{"node-a": {
						Name:        "node-a",
						Allocatable: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4")},
						Capacity:    corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("8")},
						Requested:   corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("500m")},
						Limited:     corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("1")},
					}},
				})
			},
			pods: func() []*unstructured.Unstructured {
				bound := warmMetricPod("1500m", "3")
				bound.Object["spec"].(map[string]any)["nodeName"] = "node-a"
				return []*unstructured.Unstructured{bound}
			},
			validate: func(t *testing.T, cell *kmgrv1.Cell) bool {
				t.Helper()
				usage := cell.GetUsage()
				if usage.GetCapacity() != 6 ||
					!strings.Contains(cell.GetTooltip(), "Allocatable: 6") ||
					!strings.Contains(cell.GetTooltip(), "Physical capacity: 12") {
					t.Fatalf("warm measurement hid fresh Node capacity: %#v", cell)
				}
				if usage.Requested == nil || usage.Limit == nil {
					return false
				}
				if usage.GetRequested() != 1.5 || usage.GetLimit() != 3 ||
					!strings.Contains(cell.GetTooltip(), "Effective request: 1500m") ||
					!strings.Contains(cell.GetTooltip(), "Effective limit: 3") {
					t.Fatalf("warm measurement hid fresh Node accounting: %#v", cell)
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
			projector, err := projectorFromProto("session", request.GetSpec(), nil)
			if err != nil {
				t.Fatal(err)
			}
			projector = test.configure(projector.WithMetrics(metrics.Snapshot{
				State:     metrics.MeasurementCurrent,
				UpdatedAt: time.Unix(100, 0),
				Samples: map[string]metrics.Sample{uid: {
					MeasuredAt: time.Unix(100, 0),
					Resources:  map[string]int64{"cpu": 250_000_000},
				}},
			}))
			warmRows := projector.Project([]*unstructured.Unstructured{warmObject})
			if len(warmRows) != 1 || !cellByID(warmRows[0], PodCPUColumn).GetUsage().GetUsageAvailable() {
				t.Fatalf("warm fixture did not contain CPU usage: %#v", warmRows)
			}

			baseClient := newScriptedResource()
			accountingPods := newScriptedResource()
			if test.pods != nil {
				accountingPods.listPages = []*unstructured.UnstructuredList{
					listPage("pods-rv", "", test.pods()...),
				}
			}
			source := &gvrResourceSource{
				authority: "cluster-a",
				clients: map[string]watcher.ListerWatcher{
					test.resource: baseClient,
					"pods":        accountingPods,
				},
			}
			// A Pod view uses the base Pod client rather than the otherwise empty
			// Node-accounting dependency fixture.
			if test.resource == "pods" {
				source.clients["pods"] = baseClient
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
				state: resourceIdle, accountingReady: true,
				subscribers: make(map[*Subscription]struct{}),
				dependents:  make(map[*Subscription]struct{}),
				lastStatus: watcher.Status{
					Phase: watcher.PhaseResuming, Stale: true,
					ResourceVersion: "rv-warm", LastSynchronized: time.Unix(100, 0),
				},
				warmProjection: &warmProjection{
					key: projector.cacheKey, rows: warmRows,
					retainedBytes: projectedRowsRetainedBytes(warmRows),
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
			assertMetricRowsAvailable(t, initial, uid, PodCPUColumn)
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
			observedFreshAccounting := false
			deadline := time.Now().Add(time.Second)
			for (!observedCatchup || !observedFreshAccounting) && time.Now().Before(deadline) {
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
				for _, event := range events {
					rows := append(event.GetSnapshot().GetRows(), event.GetDelta().GetUpserts()...)
					for _, row := range rows {
						if row.GetIdentity().GetUid() != uid {
							continue
						}
						observedCatchup = true
						cell := cellByID(row, PodCPUColumn)
						if !cell.GetUsage().GetUsageAvailable() || cell.GetUsage().GetUsed() != 0.25 {
							t.Fatalf("same-UID warm catch-up regressed usage: %#v", row)
						}
						observedFreshAccounting = test.validate(t, cell) || observedFreshAccounting
					}
				}
			}
			if !observedCatchup {
				t.Fatal("warm raw-store catch-up did not publish a row")
			}
			if !observedFreshAccounting {
				t.Fatal("fresh scheduler accounting did not publish while metrics were blocked")
			}

			// An explicit unavailable provider result is authoritative and must
			// release the bridge rather than retaining stale usage indefinitely.
			fetcher.result <- runtimeMetricResult{err: errors.New("metrics unavailable")}
			waitForUsageUnavailable(t, subscription, uid, PodCPUColumn)
		})
	}
}

func TestWarmMetricSnapshotPreservesRealZeroAndStaleState(t *testing.T) {
	requested := 4.0
	rows := []*kmgrv1.ResourceRow{{
		Identity: &kmgrv1.ResourceIdentity{Uid: "uid-zero"},
		Cells: []*kmgrv1.Cell{{
			ColumnId: "cpu", Severity: kmgrv1.CellSeverity_CELL_SEVERITY_WARNING,
			TypedValue: &kmgrv1.Cell_Usage{Usage: &kmgrv1.ResourceUsageValue{
				Used: 0, Requested: &requested, UsageAvailable: true,
				ResourceName: string(corev1.ResourceCPU),
			}},
		}},
	}}

	snapshot, ok := warmMetricSnapshot(rows)
	if !ok {
		t.Fatal("real zero was mistaken for unavailable usage")
	}
	sample, found := snapshot.Samples["uid-zero"]
	value, resourceFound := sample.Resources[string(corev1.ResourceCPU)]
	if !found || !resourceFound || value != 0 || len(sample.Resources) != 1 ||
		snapshot.State != metrics.MeasurementStale {
		t.Fatalf("warm zero snapshot = %#v", snapshot)
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
	events []*kmgrv1.ViewEvent,
	uid, columnID string,
) bool {
	t.Helper()
	found := false
	for _, event := range events {
		rows := append(event.GetSnapshot().GetRows(), event.GetDelta().GetUpserts()...)
		for _, row := range rows {
			if row.GetIdentity().GetUid() != uid {
				continue
			}
			found = true
			if !cellByID(row, columnID).GetUsage().GetUsageAvailable() {
				t.Fatalf("same-UID warm catch-up regressed usage: %#v", row)
			}
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
		for _, event := range events {
			rows := append(event.GetSnapshot().GetRows(), event.GetDelta().GetUpserts()...)
			for _, row := range rows {
				if row.GetIdentity().GetUid() == uid &&
					!cellByID(row, columnID).GetUsage().GetUsageAvailable() {
					return
				}
			}
		}
	}
	t.Fatalf("authoritative unavailable metrics did not clear warm usage for %q", uid)
}
