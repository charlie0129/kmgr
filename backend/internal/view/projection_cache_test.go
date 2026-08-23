package view

import (
	"errors"
	"math"
	"reflect"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	viewcolumns "github.com/charlie0129/kmgr/backend/internal/view/columns"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
)

func TestProjectionCacheKeyIsStableForEquivalentSpecs(t *testing.T) {
	t.Parallel()

	base := projectionCacheTestSpec(t)
	first := newProjectionCacheKey(base)
	if got := newProjectionCacheKey(base); got != first {
		t.Fatalf("repeated key = %x, want %x", got, first)
	}

	// Recompile the same definitions and insert both maps in the opposite order
	// to prove the key depends on their contents, not pointer or map iteration
	// identity.
	equivalent := cloneProjectionCacheTestSpec(base)
	equivalent.NamespaceScope.Namespaces = []string{"team-a", "team-b"}
	equivalent.ColumnIDs = []string{"name", "custom-a", "custom-b", "native-a", "native-b"}
	equivalent.Sort = []SortDescriptor{
		{ColumnID: "custom-a", Descending: true},
		{ColumnID: "name", NullsFirst: true},
	}
	equivalent.CELPrograms = map[string]*viewcolumns.Program{
		"custom-b": mustProjectionCacheProgram(t, projectionCacheDefinitionB()),
		"custom-a": mustProjectionCacheProgram(t, projectionCacheDefinitionA()),
	}
	equivalent.ColumnExtractors = map[string]viewcolumns.Extractor{
		"native-b": {Source: "metric", Value: "memory"},
		"native-a": {Source: "builtin", Value: "age"},
	}
	if got := newProjectionCacheKey(equivalent); got != first {
		t.Fatalf("equivalent spec key = %x, want %x", got, first)
	}
}

func TestProjectionCacheKeyMissesOnPresentationSemantics(t *testing.T) {
	t.Parallel()

	base := projectionCacheTestSpec(t)
	baseKey := newProjectionCacheKey(base)
	changedDefinitions := make(map[string]*viewcolumns.Program)
	compileChangedDefinition := func(name string, mutate func(*viewcolumns.Definition)) {
		definition := projectionCacheDefinitionA()
		mutate(&definition)
		changedDefinitions[name] = mustProjectionCacheProgram(t, definition)
	}
	compileChangedDefinition("id", func(definition *viewcolumns.Definition) { definition.ID = "custom-renamed" })
	compileChangedDefinition("title", func(definition *viewcolumns.Definition) { definition.Title = "Renamed" })
	compileChangedDefinition("expression", func(definition *viewcolumns.Definition) { definition.Expression = "object.spec.changed" })
	compileChangedDefinition("result type", func(definition *viewcolumns.Definition) { definition.ResultType = viewcolumns.ResultInteger })
	compileChangedDefinition("missing", func(definition *viewcolumns.Definition) { definition.Missing = "unknown" })
	compileChangedDefinition("list joiner", func(definition *viewcolumns.Definition) { definition.ListJoiner = "; " })

	tests := []struct {
		name   string
		mutate func(*ProjectionSpec)
	}{
		{name: "cluster session", mutate: func(spec *ProjectionSpec) { spec.ClusterSessionID = "session-b" }},
		{name: "resource group", mutate: func(spec *ProjectionSpec) { spec.Resource.Group = "batch" }},
		{name: "resource version", mutate: func(spec *ProjectionSpec) { spec.Resource.Version = "v2" }},
		{name: "resource name", mutate: func(spec *ProjectionSpec) { spec.Resource.Resource = "statefulsets" }},
		{name: "resource kind", mutate: func(spec *ProjectionSpec) { spec.Resource.Kind = "StatefulSet" }},
		{name: "resource namespace shape", mutate: func(spec *ProjectionSpec) { spec.Resource.Namespaced = false }},
		{name: "namespace all flag", mutate: func(spec *ProjectionSpec) { spec.NamespaceScope.All = true }},
		{name: "namespace content", mutate: func(spec *ProjectionSpec) { spec.NamespaceScope.Namespaces[0] = "team-c" }},
		{name: "namespace order", mutate: func(spec *ProjectionSpec) {
			spec.NamespaceScope.Namespaces[0], spec.NamespaceScope.Namespaces[1] = spec.NamespaceScope.Namespaces[1], spec.NamespaceScope.Namespaces[0]
		}},
		{name: "column content", mutate: func(spec *ProjectionSpec) { spec.ColumnIDs[0] = "namespace" }},
		{name: "column order", mutate: func(spec *ProjectionSpec) {
			spec.ColumnIDs[0], spec.ColumnIDs[1] = spec.ColumnIDs[1], spec.ColumnIDs[0]
		}},
		{name: "filter", mutate: func(spec *ProjectionSpec) { spec.FilterExpression = `name:worker` }},
		{name: "sort column", mutate: func(spec *ProjectionSpec) { spec.Sort[0].ColumnID = "name" }},
		{name: "sort direction", mutate: func(spec *ProjectionSpec) { spec.Sort[0].Descending = false }},
		{name: "sort null placement", mutate: func(spec *ProjectionSpec) { spec.Sort[0].NullsFirst = true }},
		{name: "sort order", mutate: func(spec *ProjectionSpec) { spec.Sort[0], spec.Sort[1] = spec.Sort[1], spec.Sort[0] }},
		{name: "requested configuration version", mutate: func(spec *ProjectionSpec) { spec.ColumnConfigurationVersion = "requested-v2" }},
		{name: "resolved configuration version", mutate: func(spec *ProjectionSpec) { spec.ResolvedColumnConfigurationVersion = "resolved-v2" }},
		{name: "accelerator configuration", mutate: func(spec *ProjectionSpec) {
			spec.Accelerators.AutoDetectSuffixes[0] = "/ppu"
		}},
		{name: "CEL definition ID", mutate: func(spec *ProjectionSpec) { spec.CELPrograms["custom-a"] = changedDefinitions["id"] }},
		{name: "CEL definition title", mutate: func(spec *ProjectionSpec) { spec.CELPrograms["custom-a"] = changedDefinitions["title"] }},
		{name: "CEL definition expression", mutate: func(spec *ProjectionSpec) { spec.CELPrograms["custom-a"] = changedDefinitions["expression"] }},
		{name: "CEL definition result type", mutate: func(spec *ProjectionSpec) { spec.CELPrograms["custom-a"] = changedDefinitions["result type"] }},
		{name: "CEL definition missing value", mutate: func(spec *ProjectionSpec) { spec.CELPrograms["custom-a"] = changedDefinitions["missing"] }},
		{name: "CEL definition list joiner", mutate: func(spec *ProjectionSpec) { spec.CELPrograms["custom-a"] = changedDefinitions["list joiner"] }},
		{name: "CEL definition map identity", mutate: func(spec *ProjectionSpec) {
			spec.CELPrograms["custom-renamed"] = spec.CELPrograms["custom-a"]
			delete(spec.CELPrograms, "custom-a")
		}},
		{name: "extractor source", mutate: func(spec *ProjectionSpec) {
			extractor := spec.ColumnExtractors["native-a"]
			extractor.Source = "metric"
			spec.ColumnExtractors["native-a"] = extractor
		}},
		{name: "extractor value", mutate: func(spec *ProjectionSpec) {
			extractor := spec.ColumnExtractors["native-a"]
			extractor.Value = "creationTimestamp"
			spec.ColumnExtractors["native-a"] = extractor
		}},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			changed := cloneProjectionCacheTestSpec(base)
			test.mutate(&changed)
			if got := newProjectionCacheKey(changed); got == baseKey {
				t.Fatalf("changed spec retained cache key %x", got)
			}
		})
	}
}

func TestProjectionCacheKeyIgnoresMandatoryRefreshInputs(t *testing.T) {
	t.Parallel()

	base := projectionCacheTestSpec(t)
	baseKey := newProjectionCacheKey(base)
	tests := []struct {
		name   string
		mutate func(*ProjectionSpec)
	}{
		{name: "metrics", mutate: func(spec *ProjectionSpec) {
			spec.Metrics = metrics.Snapshot{
				Samples: map[string]metrics.Sample{"uid": {Resources: map[string]int64{"cpu": 42}}},
				State:   metrics.MeasurementCurrent, UpdatedAt: time.Unix(100, 0), Err: errors.New("refresh failed"),
			}
		}},
		{name: "now", mutate: func(spec *ProjectionSpec) { spec.Now = time.Unix(200, 0) }},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			changed := cloneProjectionCacheTestSpec(base)
			test.mutate(&changed)
			if got := newProjectionCacheKey(changed); got != baseKey {
				t.Fatalf("refresh-only input changed cache key: got %x, want %x", got, baseKey)
			}
		})
	}
}

func TestWarmProjectionOwnsOnlyImmutablePresentationData(t *testing.T) {
	t.Parallel()
	typeOfProjection := reflect.TypeOf(warmProjection{})
	want := map[string]reflect.Type{
		"key":            reflect.TypeOf(projectionCacheKey{}),
		"rows":           reflect.TypeOf([]*kmgrv1.ResourceRow{}),
		"metricSnapshot": reflect.TypeOf((*metrics.Snapshot)(nil)),
		"retainedBytes":  reflect.TypeOf(int64(0)),
	}
	if typeOfProjection.NumField() != len(want) {
		t.Fatalf("warmProjection fields = %d, want only %d immutable presentation fields",
			typeOfProjection.NumField(), len(want))
	}
	for index := range typeOfProjection.NumField() {
		field := typeOfProjection.Field(index)
		if wantType, ok := want[field.Name]; !ok || field.Type != wantType {
			t.Fatalf("warmProjection unexpectedly retains field %s %v", field.Name, field.Type)
		}
	}
}

func TestProjectedRowsRetainedBytesChargesMinimalCells(t *testing.T) {
	t.Parallel()

	withoutCells := projectedRowsRetainedBytes([]*kmgrv1.ResourceRow{{}})
	cells := make([]*kmgrv1.Cell, 64)
	for index := range cells {
		cells[index] = &kmgrv1.Cell{}
	}
	withCells := projectedRowsRetainedBytes([]*kmgrv1.ResourceRow{{Cells: cells}})
	if structuralWeight := withCells - withoutCells; structuralWeight < 16*1024 {
		t.Fatalf("64 minimal cells added %d bytes, want at least 16 KiB", structuralWeight)
	}
}

func TestProjectedRowsRetainedBytesIncludesSliceCapacity(t *testing.T) {
	t.Parallel()

	row := &kmgrv1.ResourceRow{Cells: []*kmgrv1.Cell{{}}}
	tightRows := []*kmgrv1.ResourceRow{row}
	roomyRows := make([]*kmgrv1.ResourceRow, 1, 8)
	roomyRows[0] = row
	if got, minimum := projectedRowsRetainedBytes(roomyRows)-projectedRowsRetainedBytes(tightRows), int64(7*8); got < minimum {
		t.Fatalf("outer slice spare capacity weight = %d, want at least %d", got, minimum)
	}

	tightCells := &kmgrv1.ResourceRow{Cells: []*kmgrv1.Cell{{}}}
	roomyCells := make([]*kmgrv1.Cell, 1, 8)
	roomyCells[0] = &kmgrv1.Cell{}
	roomyRow := &kmgrv1.ResourceRow{Cells: roomyCells}
	if got, minimum := projectedRowsRetainedBytes([]*kmgrv1.ResourceRow{roomyRow})-projectedRowsRetainedBytes([]*kmgrv1.ResourceRow{tightCells}), int64(7*256); got < minimum {
		t.Fatalf("cell slice spare capacity weight = %d, want at least %d", got, minimum)
	}
}

func TestSaturatingProjectionBytesBoundaries(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		left, right int64
		want        int64
	}{
		{name: "ordinary", left: 20, right: 22, want: 42},
		{name: "exact maximum", left: math.MaxInt64 - 1, right: 1, want: math.MaxInt64},
		{name: "overflow", left: math.MaxInt64, right: 1, want: math.MaxInt64},
		{name: "negative left", left: -1, right: 1, want: math.MaxInt64},
		{name: "negative right", left: 1, right: -1, want: math.MaxInt64},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if got := saturatingProjectionBytes(test.left, test.right); got != test.want {
				t.Fatalf("saturatingProjectionBytes(%d, %d) = %d, want %d", test.left, test.right, got, test.want)
			}
		})
	}
}

func TestSaturatingProjectionProductBoundaries(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		left, right int64
		want        int64
	}{
		{name: "ordinary", left: 6, right: 7, want: 42},
		{name: "zero", left: 0, right: math.MaxInt64, want: 0},
		{name: "exact maximum", left: math.MaxInt64, right: 1, want: math.MaxInt64},
		{name: "largest finite even product", left: math.MaxInt64 / 2, right: 2, want: math.MaxInt64 - 1},
		{name: "overflow", left: math.MaxInt64/2 + 1, right: 2, want: math.MaxInt64},
		{name: "negative left", left: -1, right: 0, want: math.MaxInt64},
		{name: "negative right", left: 1, right: -1, want: math.MaxInt64},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if got := saturatingProjectionProduct(test.left, test.right); got != test.want {
				t.Fatalf("saturatingProjectionProduct(%d, %d) = %d, want %d", test.left, test.right, got, test.want)
			}
		})
	}
}

func projectionCacheTestSpec(t *testing.T) ProjectionSpec {
	t.Helper()
	return ProjectionSpec{
		ClusterSessionID: "session-a",
		Resource: ResourceType{
			Group: "apps", Version: "v1", Resource: "deployments", Kind: "Deployment", Namespaced: true,
		},
		NamespaceScope:   NamespaceScope{Namespaces: []string{"team-a", "team-b"}},
		ColumnIDs:        []string{"name", "custom-a", "custom-b", "native-a", "native-b"},
		FilterExpression: `name:api`,
		Sort: []SortDescriptor{
			{ColumnID: "custom-a", Descending: true},
			{ColumnID: "name", NullsFirst: true},
		},
		ColumnConfigurationVersion:         "requested-v1",
		ResolvedColumnConfigurationVersion: "resolved-v1",
		CELPrograms: map[string]*viewcolumns.Program{
			"custom-a": mustProjectionCacheProgram(t, projectionCacheDefinitionA()),
			"custom-b": mustProjectionCacheProgram(t, projectionCacheDefinitionB()),
		},
		ColumnExtractors: map[string]viewcolumns.Extractor{
			"native-a": {Source: "builtin", Value: "age"},
			"native-b": {Source: "metric", Value: "memory"},
		},
		Accelerators: metrics.AcceleratorConfig{
			AutoDetectSuffixes: []string{"/gpu"},
			Resources: map[string]metrics.AcceleratorResourceConfig{
				"example.com/fpga-card": {DisplayName: "FPGA"},
			},
		},
	}
}

func projectionCacheDefinitionA() viewcolumns.Definition {
	return viewcolumns.Definition{
		ID: "custom-a", Title: "Custom A", Expression: "object.spec.value",
		ResultType: viewcolumns.ResultString, Missing: "n/a", ListJoiner: " | ",
	}
}

func projectionCacheDefinitionB() viewcolumns.Definition {
	return viewcolumns.Definition{
		ID: "custom-b", Title: "Custom B", Expression: `"second"`,
		ResultType: viewcolumns.ResultString, Missing: "missing", ListJoiner: ", ",
	}
}

func mustProjectionCacheProgram(t *testing.T, definition viewcolumns.Definition) *viewcolumns.Program {
	t.Helper()
	compiler, err := viewcolumns.NewCompiler(viewcolumns.DefaultCostLimit)
	if err != nil {
		t.Fatal(err)
	}
	program, err := compiler.Compile(definition)
	if err != nil {
		t.Fatal(err)
	}
	return program
}

func cloneProjectionCacheTestSpec(spec ProjectionSpec) ProjectionSpec {
	clone := spec
	clone.NamespaceScope.Namespaces = append([]string(nil), spec.NamespaceScope.Namespaces...)
	clone.ColumnIDs = append([]string(nil), spec.ColumnIDs...)
	clone.Sort = append([]SortDescriptor(nil), spec.Sort...)
	clone.Accelerators = cloneAcceleratorConfig(spec.Accelerators)
	clone.CELPrograms = make(map[string]*viewcolumns.Program, len(spec.CELPrograms))
	for id, program := range spec.CELPrograms {
		clone.CELPrograms[id] = program
	}
	clone.ColumnExtractors = make(map[string]viewcolumns.Extractor, len(spec.ColumnExtractors))
	for id, extractor := range spec.ColumnExtractors {
		clone.ColumnExtractors[id] = extractor
	}
	return clone
}
