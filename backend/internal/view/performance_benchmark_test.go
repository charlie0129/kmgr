package view

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/store"
	"github.com/charlie0129/kmgr/backend/internal/watcher"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

const (
	syntheticProjectionRows         = 100_000
	syntheticProjectionUpdates      = 4_000
	syntheticProjectionUpdateBursts = 8
)

var benchmarkProjectionRows []*kmgrv1.ResourceRow

type syntheticProjectionWorkload struct {
	now       time.Time
	objects   []*unstructured.Unstructured
	revisions [2][][]*unstructured.Unstructured
}

func newSyntheticProjectionWorkload(
	rowCount, updateCount, burstCount int,
) (syntheticProjectionWorkload, error) {
	if rowCount <= 0 || updateCount <= 0 || updateCount > rowCount ||
		burstCount <= 0 || updateCount%burstCount != 0 {
		return syntheticProjectionWorkload{}, errors.New(
			"synthetic projection rows and updates must be positive, updates must not exceed rows, and bursts must divide updates",
		)
	}
	now := time.Date(2026, 8, 14, 12, 0, 0, 0, time.UTC)
	workload := syntheticProjectionWorkload{
		now:     now,
		objects: make([]*unstructured.Unstructured, rowCount),
	}
	for index := range rowCount {
		workload.objects[index] = syntheticProjectionPod(index, int64(index%257), "rv-initial", now)
	}
	batchSize := updateCount / burstCount
	for revision := range workload.revisions {
		batches := make([][]*unstructured.Unstructured, burstCount)
		for burst := range burstCount {
			batch := make([]*unstructured.Unstructured, 0, batchSize)
			for offset := range batchSize {
				updateIndex := burst*batchSize + offset
				// rowCount-1 is coprime with rowCount, so this addresses each
				// selected UID once without favoring adjacent table rows.
				rowIndex := (updateIndex * (rowCount - 1)) % rowCount
				reorderRank := updateIndex
				if revision == 1 {
					reorderRank = updateCount - updateIndex
				}
				restarts := int64(rowCount + reorderRank + 1)
				batch = append(batch, syntheticProjectionPod(
					rowIndex, restarts, fmt.Sprintf("rv-%d-%d", revision, updateIndex), now,
				))
			}
			batches[burst] = batch
		}
		workload.revisions[revision] = batches
	}
	return workload, nil
}

func syntheticProjectionPod(
	index int,
	restarts int64,
	resourceVersion string,
	now time.Time,
) *unstructured.Unstructured {
	uid := fmt.Sprintf("uid-%06d", index)
	namespace := fmt.Sprintf("team-%02d", index%32)
	name := fmt.Sprintf("workload-%06d", index)
	phase := "Running"
	if index%19 == 0 {
		phase = "Pending"
	}
	ready := phase == "Running"
	value := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1",
		"kind":       "Pod",
		"metadata": map[string]any{
			"uid":             uid,
			"namespace":       namespace,
			"name":            name,
			"resourceVersion": resourceVersion,
			"labels": map[string]any{
				"app.kubernetes.io/name": "synthetic-workload",
				"kmgr.dev/shard":         fmt.Sprintf("%03d", index%128),
			},
		},
		"spec": map[string]any{
			"nodeName": fmt.Sprintf("node-%04d", index%2_048),
			"containers": []any{
				map[string]any{"name": "main", "image": "registry.invalid/app:v1"},
				map[string]any{"name": "sidecar", "image": "registry.invalid/sidecar:v1"},
			},
		},
		"status": map[string]any{
			"phase": phase,
			"containerStatuses": []any{
				map[string]any{"name": "main", "ready": ready, "restartCount": restarts},
				map[string]any{"name": "sidecar", "ready": ready, "restartCount": int64(0)},
			},
		},
	}}
	value.SetCreationTimestamp(metav1.NewTime(now.Add(-time.Duration(index%86_400) * time.Second)))
	return value
}

func newSyntheticProjectionProjector(now time.Time) (*Projector, error) {
	return NewProjector(ProjectionSpec{
		ClusterSessionID: "synthetic-session",
		Resource: ResourceType{
			Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true,
		},
		NamespaceScope: NamespaceScope{All: true},
		ColumnIDs: []string{
			"namespace", "name", "ready", "status", "restarts", "node", "age",
		},
		Sort: []SortDescriptor{
			{ColumnID: "restarts", Descending: true},
			{ColumnID: "name"},
		},
		Now: now,
	})
}

func newSyntheticProjectionSubscription(
	projector *Projector,
	objects []*unstructured.Unstructured,
) (*Subscription, error) {
	rows, err := projector.ProjectContext(context.Background(), objects)
	if err != nil {
		return nil, err
	}
	subscription := newSubscription(
		viewKey{sessionID: "synthetic-session", viewID: "synthetic-view"},
		1,
		projector,
		time.Hour,
		1_024,
		max(len(objects), 1),
	)
	subscription.rows = make(map[string]*kmgrv1.ResourceRow, len(rows))
	subscription.order = make([]string, 0, len(rows))
	for _, row := range rows {
		uid := row.GetIdentity().GetUid()
		subscription.rows[uid] = row
		subscription.order = append(subscription.order, uid)
	}
	return subscription, nil
}

func applySyntheticProjectionBursts(
	subscription *Subscription,
	batches [][]*unstructured.Unstructured,
) {
	for _, objects := range batches {
		subscription.applyBatch(watcher.Batch{Upserts: objects})
		subscription.flushProjection()
	}
}

func validateSyntheticProjectionSubscription(
	subscription *Subscription,
	expectedRows int,
) error {
	subscription.mu.Lock()
	defer subscription.mu.Unlock()
	if len(subscription.rows) != expectedRows || len(subscription.order) != expectedRows {
		return fmt.Errorf(
			"synthetic projection cardinality = rows %d, order %d; want %d",
			len(subscription.rows), len(subscription.order), expectedRows,
		)
	}
	if len(subscription.pendingObjects) != 0 || subscription.projectionRunning ||
		subscription.projectionScheduled || subscription.projectionResnapshot {
		return fmt.Errorf(
			"synthetic projection left work pending: objects=%d running=%t scheduled=%t resnapshot=%t",
			len(subscription.pendingObjects), subscription.projectionRunning,
			subscription.projectionScheduled, subscription.projectionResnapshot,
		)
	}
	for index, uid := range subscription.order {
		row := subscription.rows[uid]
		if row == nil || row.GetIdentity().GetUid() != uid {
			return fmt.Errorf("synthetic order entry %d does not resolve to UID %q", index, uid)
		}
		if index > 0 {
			previous := subscription.rows[subscription.order[index-1]]
			if subscription.projector.compareRows(previous, row) > 0 {
				return fmt.Errorf("synthetic order is not sorted at index %d", index)
			}
		}
	}
	return nil
}

func TestSyntheticProjectionWorkloadAndBursts(t *testing.T) {
	t.Parallel()
	const (
		rowCount    = 128
		updateCount = 32
		burstCount  = 4
	)
	workload, err := newSyntheticProjectionWorkload(rowCount, updateCount, burstCount)
	if err != nil {
		t.Fatal(err)
	}
	projector, err := newSyntheticProjectionProjector(workload.now)
	if err != nil {
		t.Fatal(err)
	}
	subscription, err := newSyntheticProjectionSubscription(projector, workload.objects)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.close()
	initialOrder := slices.Clone(subscription.order)
	applySyntheticProjectionBursts(subscription, workload.revisions[0])
	if err := validateSyntheticProjectionSubscription(subscription, rowCount); err != nil {
		t.Fatal(err)
	}
	if slices.Equal(initialOrder, subscription.order) {
		t.Fatal("sort-key updates did not reorder the synthetic table")
	}
	if subscription.projectionPasses != burstCount || subscription.projectedObjects != updateCount {
		t.Fatalf(
			"projection work = %d passes/%d objects, want %d/%d",
			subscription.projectionPasses, subscription.projectedObjects, burstCount, updateCount,
		)
	}
	seen := make(map[string]struct{}, updateCount)
	for _, batch := range workload.revisions[0] {
		for _, object := range batch {
			uid := string(object.GetUID())
			if _, duplicate := seen[uid]; duplicate {
				t.Fatalf("synthetic updates contain duplicate UID %q", uid)
			}
			seen[uid] = struct{}{}
		}
	}
	if len(seen) != updateCount {
		t.Fatalf("synthetic updates address %d UIDs, want %d", len(seen), updateCount)
	}
}

func TestSyntheticProjectionWorkloadRejectsInvalidDimensions(t *testing.T) {
	t.Parallel()
	for _, dimensions := range [][3]int{
		{0, 1, 1}, {10, 0, 1}, {10, 11, 1}, {10, 4, 0}, {10, 4, 3},
	} {
		if _, err := newSyntheticProjectionWorkload(
			dimensions[0], dimensions[1], dimensions[2],
		); err == nil {
			t.Fatalf("invalid dimensions %v were accepted", dimensions)
		}
	}
}

// BenchmarkBackendProjection100K exercises the real unstructured-object to
// compact-row projector and the incremental Subscription reorder path without
// a Kubernetes cluster. Use -benchtime=1x for one reproducible synthetic run;
// -cpuprofile and -memprofile work with the standard go test flags.
func BenchmarkBackendProjection100K(b *testing.B) {
	workload, err := newSyntheticProjectionWorkload(
		syntheticProjectionRows,
		syntheticProjectionUpdates,
		syntheticProjectionUpdateBursts,
	)
	if err != nil {
		b.Fatal(err)
	}
	rawStore := store.New()
	for _, object := range workload.objects {
		rawStore.Upsert(object)
	}
	rawRetainedBytes := rawStore.RetainedBytes()
	projector, err := newSyntheticProjectionProjector(workload.now)
	if err != nil {
		b.Fatal(err)
	}

	b.Run("initial_snapshot", func(b *testing.B) {
		b.ReportAllocs()
		b.ResetTimer()
		for range b.N {
			rows, err := projector.ProjectContext(context.Background(), workload.objects)
			if err != nil {
				b.Fatal(err)
			}
			benchmarkProjectionRows = rows
		}
		b.StopTimer()
		b.ReportMetric(syntheticProjectionRows, "rows/op")
		projectedRetainedBytes := projectedRowsRetainedBytes(benchmarkProjectionRows)
		b.ReportMetric(float64(rawRetainedBytes), "raw_retained_bytes/op")
		b.ReportMetric(float64(projectedRetainedBytes), "projected_retained_bytes/op")
		b.ReportMetric(
			float64(saturatingProjectionBytes(rawRetainedBytes, projectedRetainedBytes)),
			"warm_candidate_bytes/op",
		)
		if len(benchmarkProjectionRows) != syntheticProjectionRows {
			b.Fatalf("projected rows = %d, want %d", len(benchmarkProjectionRows), syntheticProjectionRows)
		}
	})

	b.Run("bursty_reorder_updates", func(b *testing.B) {
		subscription, err := newSyntheticProjectionSubscription(projector, workload.objects)
		if err != nil {
			b.Fatal(err)
		}
		defer subscription.close()
		b.ReportAllocs()
		b.ResetTimer()
		for iteration := range b.N {
			applySyntheticProjectionBursts(subscription, workload.revisions[iteration%2])
		}
		b.StopTimer()
		b.ReportMetric(syntheticProjectionUpdates, "updated_rows/op")
		b.ReportMetric(syntheticProjectionUpdateBursts, "bursts/op")
		if err := validateSyntheticProjectionSubscription(subscription, syntheticProjectionRows); err != nil {
			b.Fatal(err)
		}
		expectedPasses := uint64(b.N * syntheticProjectionUpdateBursts)
		expectedObjects := uint64(b.N * syntheticProjectionUpdates)
		if subscription.projectionPasses != expectedPasses ||
			subscription.projectedObjects != expectedObjects {
			b.Fatalf(
				"projection work = %d passes/%d objects, want %d/%d",
				subscription.projectionPasses, subscription.projectedObjects,
				expectedPasses, expectedObjects,
			)
		}
	})
}
