package view

import (
	"slices"
	"testing"
	"time"

	viewcolumns "github.com/charlie0129/kmgr/backend/internal/view/columns"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestProjectTableSchemaPreservesPriorityAndDeduplicatesIdentityColumns(t *testing.T) {
	t.Parallel()
	columns := []metav1.TableColumnDefinition{
		{Name: "Name", Type: "string", Format: "name"},
		{Name: "Namespace", Type: "string"},
		{Name: "Age", Type: "string"},
		{Name: "Status", Type: "string", Description: "Current state"},
		{Name: "Replicas", Type: "integer", Priority: 1},
		{Name: "Replicas", Type: "integer", Priority: 2},
		{Name: "Capacity", Type: "string", Format: "quantity"},
	}
	schema, projected := projectTableSchema(columns)
	if schema == nil || !schema.GetServerTable() || schema.GetRevision() == "" {
		t.Fatalf("schema = %#v", schema)
	}
	if len(schema.GetColumns()) != 4 || len(projected) != 4 {
		t.Fatalf("projected columns = %d/%d, want four after Name/Namespace/Age deduplication", len(schema.GetColumns()), len(projected))
	}
	titles := make([]string, 0, len(schema.GetColumns()))
	ids := make([]string, 0, len(schema.GetColumns()))
	for _, column := range schema.GetColumns() {
		titles = append(titles, column.GetTitle())
		ids = append(ids, column.GetId())
	}
	if !slices.Equal(titles, []string{"Status", "Replicas", "Replicas", "Capacity"}) {
		t.Fatalf("titles = %v", titles)
	}
	if ids[1] == ids[2] || ids[1] == "" || ids[2] == "" {
		t.Fatalf("duplicate server column IDs = %v", ids)
	}
	if !schema.GetColumns()[0].GetDefaultVisible() || schema.GetColumns()[0].GetPriority() != 0 {
		t.Fatalf("priority-zero column = %#v", schema.GetColumns()[0])
	}
	if schema.GetColumns()[1].GetDefaultVisible() || schema.GetColumns()[1].GetPriority() != 1 ||
		schema.GetColumns()[2].GetDefaultVisible() || schema.GetColumns()[2].GetPriority() != 2 {
		t.Fatalf("secondary columns = %#v", schema.GetColumns()[1:3])
	}
	if schema.GetColumns()[3].GetResultType() != "quantity" || schema.GetColumns()[3].GetAlignment() != "trailing" {
		t.Fatalf("quantity schema = %#v", schema.GetColumns()[3])
	}
}

func TestProjectTableCellsUsesTypedServerValues(t *testing.T) {
	t.Parallel()
	columns := []metav1.TableColumnDefinition{
		{Name: "Count", Type: "integer"},
		{Name: "Ratio", Type: "number"},
		{Name: "Enabled", Type: "boolean"},
		{Name: "Capacity", Type: "string", Format: "quantity"},
		{Name: "Updated", Type: "date"},
	}
	_, projected := projectTableSchema(columns)
	updated := "2026-08-18T08:00:00Z"
	updatedTime := time.Date(2026, 8, 18, 8, 0, 0, 0, time.UTC)
	cells := projectTableCells(projected, []any{float64(7), "0.75", true, "1500m", updated}, updatedTime.Add(90*time.Second))
	if len(cells) != 5 || cells[0].GetIntegerValue() != 7 || cells[1].GetNumberValue() != 0.75 ||
		!cells[2].GetBoolValue() || cells[3].GetQuantityValue().GetExact() != "1500m" ||
		cells[4].GetNumberValue() != 90 {
		t.Fatalf("typed Table cells = %#v", cells)
	}
}

func TestTableObjectPolicyUsesMetadataOnlyForMetadataAndServerDependencies(t *testing.T) {
	t.Parallel()
	resource := ResourceType{
		Group: "example.io", Version: "v1", Resource: "widgets", Kind: "Widget", Namespaced: true,
	}
	metadataProjector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session", Resource: resource,
		ColumnIDs:        []string{"namespace", "name", "labels", "age", "server-U3RhdHVz"},
		FilterExpression: "label:app==api ready",
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := tableObjectPolicy(metadataProjector); got != metav1.IncludeMetadata {
		t.Fatalf("metadata/server projection policy = %q", got)
	}
	nativeMetadataProjector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session", Resource: resource,
		ColumnIDs:        []string{"namespace", "name"},
		FilterExpression: `fieldSelector:"metadata.name=api"`,
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := tableObjectPolicy(nativeMetadataProjector); got != metav1.IncludeMetadata {
		t.Fatalf("metadata native field policy = %q", got)
	}
	localMetadataProjector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session", Resource: resource,
		ColumnIDs:        []string{"namespace", "name"},
		FilterExpression: "field:metadata.name==api",
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := tableObjectPolicy(localMetadataProjector); got != metav1.IncludeMetadata {
		t.Fatalf("metadata local field policy = %q", got)
	}
	compiler, err := viewcolumns.NewCompiler(viewcolumns.DefaultCostLimit)
	if err != nil {
		t.Fatal(err)
	}
	blockProgram, err := compiler.Compile(viewcolumns.Definition{
		ID: "block", Expression: "object.spec.nodeName",
		ResultType: viewcolumns.ResultString,
	})
	if err != nil {
		t.Fatal(err)
	}
	customColumnProjector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session", Resource: resource,
		ColumnIDs: []string{"name", "block"}, FilterExpression: "block:worker",
		CELPrograms: map[string]*viewcolumns.Program{"block": blockProgram},
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := tableObjectPolicy(customColumnProjector); got != metav1.IncludeObject {
		t.Fatalf("CEL column filter policy = %q, want %q", got, metav1.IncludeObject)
	}

	for _, test := range []struct {
		name   string
		column string
		filter string
	}{
		{name: "status column", column: "status"},
		{name: "arbitrary builtin", column: "ready"},
		{name: "status filter", column: "name", filter: "status:Ready"},
		{name: "field filter", column: "name", filter: "field:spec.tier==frontend"},
		{name: "object sort", column: "name"},
	} {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			columns := []string{"name"}
			if test.column != "name" {
				columns = append(columns, test.column)
			}
			spec := ProjectionSpec{
				ClusterSessionID: "session", Resource: resource,
				ColumnIDs: columns, FilterExpression: test.filter,
			}
			if test.name == "object sort" {
				spec.Sort = []SortDescriptor{{ColumnID: "status"}}
			}
			projector, err := NewProjector(spec)
			if err != nil {
				t.Fatal(err)
			}
			if got := tableObjectPolicy(projector); got != metav1.IncludeObject {
				t.Fatalf("full-object projection policy = %q", got)
			}
		})
	}
}
