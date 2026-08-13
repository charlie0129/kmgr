package view

import (
	"slices"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
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
