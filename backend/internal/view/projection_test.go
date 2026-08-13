package view

import (
	"math"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	viewcolumns "github.com/charlie0129/kmgr/backend/internal/view/columns"
)

func TestProjectorFiltersAndSortsTypedValues(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 8, 13, 10, 0, 0, 0, time.UTC)
	projector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session-a",
		Resource:         ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope:   NamespaceScope{Namespaces: []string{"team-a"}},
		ColumnIDs:        []string{"namespace", "name", "restarts", "status", "age"},
		FilterExpression: `label:team=platform status:running`,
		Sort:             []SortDescriptor{{ColumnID: "restarts", Descending: true}},
		Now:              now,
	})
	if err != nil {
		t.Fatal(err)
	}

	objects := []*unstructured.Unstructured{
		pod("uid-a", "team-a", "api", "Running", 2, map[string]string{"team": "platform"}, now.Add(-time.Hour)),
		pod("uid-b", "team-a", "worker", "Running", 9, map[string]string{"team": "platform"}, now.Add(-2*time.Hour)),
		pod("uid-c", "team-b", "hidden-ns", "Running", 100, map[string]string{"team": "platform"}, now),
		pod("uid-d", "team-a", "hidden-label", "Running", 100, map[string]string{"team": "other"}, now),
	}
	rows := projector.Project(objects)
	if len(rows) != 2 {
		t.Fatalf("Project returned %d rows, want 2", len(rows))
	}
	got := []string{rows[0].GetIdentity().GetUid(), rows[1].GetIdentity().GetUid()}
	if !slices.Equal(got, []string{"uid-b", "uid-a"}) {
		t.Fatalf("UID order = %v", got)
	}
	if rows[0].GetCells()[2].GetNumberValue() != 9 {
		t.Fatalf("restart typed value = %v", rows[0].GetCells()[2].GetTypedValue())
	}
	if rows[0].GetCells()[4].GetTimestampUnixMs() == 0 {
		t.Fatal("age has no typed timestamp")
	}
}

func TestProjectorEvaluatesCompiledCELAndSortsByTypedResult(t *testing.T) {
	t.Parallel()
	compiler, err := viewcolumns.NewCompiler(viewcolumns.DefaultCostLimit)
	if err != nil {
		t.Fatal(err)
	}
	program, err := compiler.Compile(viewcolumns.Definition{
		ID: "priority", Title: "Priority", Expression: "object.spec.priority",
		ResultType: viewcolumns.ResultInteger,
	})
	if err != nil {
		t.Fatal(err)
	}
	projector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session-a",
		Resource:         ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope:   NamespaceScope{All: true},
		ColumnIDs:        []string{"name", "priority"},
		CELPrograms:      map[string]*viewcolumns.Program{"priority": program},
		Sort:             []SortDescriptor{{ColumnID: "priority", Descending: true}},
	})
	if err != nil {
		t.Fatal(err)
	}
	low := pod("uid-low", "ns", "low", "Running", 0, nil, time.Time{})
	low.Object["spec"].(map[string]any)["priority"] = int64(2)
	high := pod("uid-high", "ns", "high", "Running", 0, nil, time.Time{})
	high.Object["spec"].(map[string]any)["priority"] = int64(10)
	rows := projector.Project([]*unstructured.Unstructured{low, high})
	if got := []string{rows[0].GetIdentity().GetUid(), rows[1].GetIdentity().GetUid()}; !slices.Equal(got, []string{"uid-high", "uid-low"}) {
		t.Fatalf("typed CEL order = %v", got)
	}
	if rows[0].GetCells()[1].GetNumberValue() != 10 {
		t.Fatalf("typed CEL cell = %#v", rows[0].GetCells()[1])
	}
}

func TestProjectorSanitizesSecretActivationBeforeCEL(t *testing.T) {
	t.Parallel()
	compiler, err := viewcolumns.NewCompiler(viewcolumns.DefaultCostLimit)
	if err != nil {
		t.Fatal(err)
	}
	program, err := compiler.Compile(viewcolumns.Definition{
		ID: "leak", Title: "Leak", Expression: `object.?data[?"token"].orValue("redacted")`,
		ResultType: viewcolumns.ResultString,
	})
	if err != nil {
		t.Fatal(err)
	}
	projector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session-a",
		Resource:         ResourceType{Version: "v1", Resource: "secrets", Kind: "Secret", Namespaced: true},
		NamespaceScope:   NamespaceScope{All: true},
		ColumnIDs:        []string{"name", "leak"},
		CELPrograms:      map[string]*viewcolumns.Program{"leak": program},
	})
	if err != nil {
		t.Fatal(err)
	}
	secret := pod("uid-secret", "ns", "credentials", "", 0, nil, time.Time{})
	secret.SetKind("Secret")
	secret.Object["data"] = map[string]any{"token": "must-not-cross-projection"}
	rows := projector.Project([]*unstructured.Unstructured{secret})
	if got := rows[0].GetCells()[1].GetDisplayText(); got != "redacted" {
		t.Fatalf("Secret CEL result = %q", got)
	}
}

func TestProjectorUsesUIDTieBreakerAndNeverIncludesRawObject(t *testing.T) {
	t.Parallel()
	projector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session-a",
		Resource:         ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope:   NamespaceScope{All: true},
		ColumnIDs:        []string{"name"},
	})
	if err != nil {
		t.Fatal(err)
	}
	rows := projector.Project([]*unstructured.Unstructured{
		pod("uid-z", "a", "same", "Running", 0, nil, time.Time{}),
		pod("uid-a", "a", "same", "Running", 0, nil, time.Time{}),
	})
	if got := []string{rows[0].GetIdentity().GetUid(), rows[1].GetIdentity().GetUid()}; !slices.Equal(got, []string{"uid-a", "uid-z"}) {
		t.Fatalf("UID order = %v", got)
	}
	for _, row := range rows {
		if len(row.GetCells()) != 1 || row.GetCells()[0].GetColumnId() != "name" {
			t.Fatalf("row exposed unexpected cells: %#v", row)
		}
	}
}

func TestProjectorRejectsInvalidFilterWithoutTouchingObjects(t *testing.T) {
	t.Parallel()
	_, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session-a",
		Resource:         ResourceType{Version: "v1", Resource: "pods", Namespaced: true},
		FilterExpression: "unknown:value",
	})
	if err == nil {
		t.Fatal("invalid structured filter was accepted")
	}
}

func TestDefaultPodAndNodeColumnsRequestCPUAndMemoryMetrics(t *testing.T) {
	t.Parallel()
	for _, resourceType := range []ResourceType{
		{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		{Version: "v1", Resource: "nodes", Kind: "Node"},
	} {
		projector, err := NewProjector(ProjectionSpec{
			ClusterSessionID: "session-a", Resource: resourceType,
		})
		if err != nil {
			t.Fatal(err)
		}
		if !slices.Contains(projector.spec.ColumnIDs, PodCPUColumn) ||
			!slices.Contains(projector.spec.ColumnIDs, PodMemoryColumn) || !needsMetricProvider(projector) {
			t.Fatalf("default %s columns do not activate CPU/memory metrics: %v", resourceType.Resource, projector.spec.ColumnIDs)
		}
	}
}

func TestFieldFilterReadsOnlyRequestedScalarPath(t *testing.T) {
	t.Parallel()
	projector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session-a",
		Resource:         ResourceType{Version: "v1", Resource: "pods", Namespaced: true},
		NamespaceScope:   NamespaceScope{All: true},
		FilterExpression: "field:spec.nodeName=node-a",
	})
	if err != nil {
		t.Fatal(err)
	}
	value := pod("uid-a", "a", "pod", "Running", 0, nil, time.Time{})
	value.Object["spec"].(map[string]any)["nodeName"] = "node-a"
	if rows := projector.Project([]*unstructured.Unstructured{value}); len(rows) != 1 {
		t.Fatalf("field filter returned %d rows", len(rows))
	}
}

func TestProjectorEmitsPodResourceUsageWithEffectiveAccounting(t *testing.T) {
	t.Parallel()
	measuredAt := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	projector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session-a",
		Resource:         ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope:   NamespaceScope{All: true},
		ColumnIDs:        []string{"name", PodCPUColumn, PodMemoryColumn, metricColumnID("nvidia.com/gpu")},
		Sort:             []SortDescriptor{{ColumnID: PodCPUColumn, Descending: true}},
		Metrics: metrics.Snapshot{
			State: metrics.MeasurementCurrent,
			Samples: map[string]metrics.Sample{
				"uid-a": {
					MeasuredAt: measuredAt,
					Resources: map[string]int64{
						string(corev1.ResourceCPU):    420_000_000,
						string(corev1.ResourceMemory): 64 * 1024 * 1024,
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	value := pod("uid-a", "team-a", "api", "Running", 0, nil, time.Time{})
	container := value.Object["spec"].(map[string]any)["containers"].([]any)[0].(map[string]any)
	container["resources"] = map[string]any{
		"requests": map[string]any{"cpu": "500m", "memory": "128Mi", "nvidia.com/gpu": "1"},
		"limits":   map[string]any{"cpu": "1", "memory": "256Mi", "nvidia.com/gpu": "2"},
	}
	row, visible := projector.ProjectOne(value)
	if !visible {
		t.Fatal("Pod row was not visible")
	}
	cpu := cellByID(row, PodCPUColumn).GetUsage()
	if !cpu.GetUsageAvailable() || math.Abs(cpu.GetUsed()-0.42) > 1e-9 || cpu.GetRequested() != 0.5 ||
		cpu.GetLimit() != 1 || cpu.GetProvider() != metrics.MetricsAPIGroupVersion ||
		cpu.GetMeasuredAtUnixMs() != measuredAt.UnixMilli() {
		t.Fatalf("CPU usage = %#v", cpu)
	}
	if got := cellByID(row, PodCPUColumn).GetDisplayText(); got != "420m / 500m / 1" {
		t.Fatalf("CPU display = %q", got)
	}
	memory := cellByID(row, PodMemoryColumn).GetUsage()
	if !memory.GetUsageAvailable() || memory.GetUsed() != 64*1024*1024 || memory.GetRequested() != 128*1024*1024 {
		t.Fatalf("memory usage = %#v", memory)
	}
	accelerator := cellByID(row, metricColumnID("nvidia.com/gpu")).GetUsage()
	if accelerator.GetUsageAvailable() || accelerator.GetRequested() != 1 || accelerator.GetLimit() != 2 ||
		accelerator.GetResourceName() != "nvidia.com/gpu" {
		t.Fatalf("accelerator accounting invented usage or lost identity: %#v", accelerator)
	}
}

func TestProjectorKeepsUnavailableAndRealZeroMetricsDistinct(t *testing.T) {
	t.Parallel()
	base := ProjectionSpec{
		ClusterSessionID: "session-a",
		Resource:         ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope:   NamespaceScope{All: true},
		ColumnIDs:        []string{PodCPUColumn},
	}
	value := pod("uid-zero", "team-a", "idle", "Running", 0, nil, time.Time{})
	projector, err := NewProjector(base)
	if err != nil {
		t.Fatal(err)
	}
	unavailable, _ := projector.ProjectOne(value)
	if usage := unavailable.GetCells()[0].GetUsage(); usage.GetUsageAvailable() || unavailable.GetCells()[0].GetDisplayText() != "— / — / —" {
		t.Fatalf("unavailable usage = %#v", unavailable.GetCells()[0])
	}
	base.Metrics = metrics.Snapshot{
		State: metrics.MeasurementCurrent,
		Samples: map[string]metrics.Sample{
			"uid-zero": {Resources: map[string]int64{"cpu": 0}},
		},
	}
	projector, err = NewProjector(base)
	if err != nil {
		t.Fatal(err)
	}
	zero, _ := projector.ProjectOne(value)
	if usage := zero.GetCells()[0].GetUsage(); !usage.GetUsageAvailable() || usage.GetUsed() != 0 {
		t.Fatalf("real zero usage = %#v", usage)
	}
}

func TestProjectorEmitsNodeUsageOverAllocatableAndSortsRatio(t *testing.T) {
	t.Parallel()
	projector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session-a",
		Resource:         ResourceType{Version: "v1", Resource: "nodes", Kind: "Node"},
		ColumnIDs:        []string{"name", NodeCPUUsageColumn},
		Sort:             []SortDescriptor{{ColumnID: NodeCPUUsageColumn, Descending: true}},
		Metrics: metrics.Snapshot{
			State: metrics.MeasurementCurrent,
			Samples: map[string]metrics.Sample{
				"node-a": {Resources: map[string]int64{"cpu": 1_000_000_000}},
				"node-b": {Resources: map[string]int64{"cpu": 2_000_000_000}},
			},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	node := func(uid, name, allocatable, capacity string) *unstructured.Unstructured {
		value := &unstructured.Unstructured{Object: map[string]any{
			"apiVersion": "v1", "kind": "Node",
			"metadata": map[string]any{"uid": uid, "name": name},
			"status": map[string]any{
				"allocatable": map[string]any{"cpu": allocatable},
				"capacity":    map[string]any{"cpu": capacity},
			},
		}}
		return value
	}
	rows := projector.Project([]*unstructured.Unstructured{
		node("uid-a", "node-a", "2", "4"),
		node("uid-b", "node-b", "8", "16"),
	})
	if got := []string{rows[0].GetIdentity().GetName(), rows[1].GetIdentity().GetName()}; !slices.Equal(got, []string{"node-a", "node-b"}) {
		t.Fatalf("Node CPU ratio sort = %v", got)
	}
	usage := cellByID(rows[0], NodeCPUUsageColumn).GetUsage()
	if usage.GetUsed() != 1 || usage.GetCapacity() != 2 || usage.GetRequested() != 0 {
		t.Fatalf("Node CPU usage/allocatable = %#v", usage)
	}
	if tooltip := cellByID(rows[0], NodeCPUUsageColumn).GetTooltip(); !strings.Contains(tooltip, "Physical capacity: 4") {
		t.Fatalf("Node tooltip = %q", tooltip)
	}
}

func TestCompareUsageCellsUsesTypedValuesNotDisplayText(t *testing.T) {
	t.Parallel()
	left := &kmgrv1.Cell{TypedValue: &kmgrv1.Cell_Usage{Usage: &kmgrv1.ResourceUsageValue{
		Used: 9, Requested: 10, UsageAvailable: true,
	}}, DisplayText: "zzz"}
	right := &kmgrv1.Cell{TypedValue: &kmgrv1.Cell_Usage{Usage: &kmgrv1.ResourceUsageValue{
		Used: 1, Requested: 10, UsageAvailable: true,
	}}, DisplayText: "aaa"}
	if compareCells(left, right, false) <= 0 {
		t.Fatal("resource usage sort reparsed display text")
	}
	zero := resource.MustParse("0")
	if quantityNumeric(corev1.ResourceCPU, zero) != 0 {
		t.Fatal("zero quantity conversion changed value")
	}
}

func pod(uid, namespace, name, phase string, restarts int64, labels map[string]string, created time.Time) *unstructured.Unstructured {
	value := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1",
		"kind":       "Pod",
		"metadata": map[string]any{
			"uid":       uid,
			"namespace": namespace,
			"name":      name,
		},
		"spec": map[string]any{
			"containers": []any{map[string]any{"name": "main"}},
		},
		"status": map[string]any{
			"phase": phase,
			"containerStatuses": []any{map[string]any{
				"name":         "main",
				"ready":        phase == "Running",
				"restartCount": restarts,
			}},
		},
	}}
	value.SetLabels(labels)
	if !created.IsZero() {
		value.SetCreationTimestamp(metav1.NewTime(created))
	}
	return value
}
