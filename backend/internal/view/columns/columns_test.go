package columns

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/cel-go/common/types"
	"github.com/google/cel-go/common/types/ref"
)

func TestCompileOptionalAndTypedEvaluation(t *testing.T) {
	t.Parallel()
	compiler := newCompiler(t, DefaultCostLimit)
	program, err := compiler.Compile(Definition{
		ID:         "node",
		Expression: `object.?spec.?nodeName.orValue("—")`,
		ResultType: ResultString,
	})
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}

	value, err := program.Evaluate(Activation{Object: map[string]any{
		"spec": map[string]any{"nodeName": "worker-1"},
	}})
	if err != nil || value.Display != "worker-1" || value.String == nil || *value.String != "worker-1" {
		t.Fatalf("Evaluate present = %#v, %v", value, err)
	}
	value, err = program.Evaluate(Activation{Object: map[string]any{}})
	if err != nil || value.Display != DefaultMissing {
		t.Fatalf("Evaluate missing = %#v, %v", value, err)
	}
}

func TestIntegerAndQuantityResultsRetainExactTypes(t *testing.T) {
	t.Parallel()
	compiler := newCompiler(t, DefaultCostLimit)
	integerProgram, err := compiler.Compile(Definition{
		ID: "large-integer", Expression: "9007199254740993", ResultType: ResultInteger,
	})
	if err != nil {
		t.Fatal(err)
	}
	integer, err := integerProgram.Evaluate(Activation{})
	if err != nil || integer.Integer == nil || *integer.Integer != 9_007_199_254_740_993 {
		t.Fatalf("integer result = %#v, %v", integer, err)
	}

	quantityProgram, err := compiler.Compile(Definition{
		ID: "memory", Expression: `"1Gi"`, ResultType: ResultQuantity,
	})
	if err != nil {
		t.Fatal(err)
	}
	quantity, err := quantityProgram.Evaluate(Activation{})
	if err != nil || quantity.Quantity == nil || quantity.Quantity.String() != "1Gi" || quantity.String != nil {
		t.Fatalf("quantity result = %#v, %v", quantity, err)
	}

	invalidProgram, err := compiler.Compile(Definition{
		ID: "invalid", Expression: `"not-a-quantity"`, ResultType: ResultQuantity,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := invalidProgram.Evaluate(Activation{}); err == nil || !strings.Contains(err.Error(), "invalid Kubernetes quantity") {
		t.Fatalf("invalid quantity error = %v", err)
	}
	if _, err := compiler.Compile(Definition{
		ID: "list", Expression: `["1Gi"]`, ResultType: ResultQuantity,
	}); err == nil || !strings.Contains(err.Error(), "incompatible") {
		t.Fatalf("quantity list compile error = %v", err)
	}
}

func TestCompileRejectsStaticTypeMismatchAndInvalidExpression(t *testing.T) {
	t.Parallel()
	compiler := newCompiler(t, DefaultCostLimit)
	if _, err := compiler.Compile(Definition{
		ID: "bad", Expression: "1 +", ResultType: ResultInteger,
	}); err == nil {
		t.Fatal("invalid expression compiled")
	}
	if _, err := compiler.Compile(Definition{
		ID: "bad", Expression: `"text"`, ResultType: ResultInteger,
	}); err == nil || !strings.Contains(err.Error(), "incompatible") {
		t.Fatalf("static mismatch error = %v", err)
	}
}

func TestCompilePreviewRetainsRawValueForDeclaredTypeMismatch(t *testing.T) {
	t.Parallel()
	compiler := newCompiler(t, DefaultCostLimit)
	program, err := compiler.CompilePreview(Definition{
		ID: "metadata", Expression: "object.metadata", ResultType: ResultString,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, preview, err := program.EvaluatePreviewContext(context.Background(), Activation{
		Object: map[string]any{
			"metadata": map[string]any{"name": "sample"},
		},
	})
	if err == nil || !strings.Contains(err.Error(), "result type is map") {
		t.Fatalf("preview mismatch error = %v", err)
	}
	if !preview.Available || preview.Type != "map" || preview.Format != "yaml" ||
		!strings.Contains(preview.Display, "name: sample") {
		t.Fatalf("raw preview = %#v", preview)
	}

	if _, err := compiler.Compile(Definition{
		ID: "literal", Expression: "1", ResultType: ResultString,
	}); err == nil {
		t.Fatal("strict compiler accepted the static mismatch")
	}
}

func TestPreviewValueRetainsCompleteYAML(t *testing.T) {
	t.Parallel()
	compiler := newCompiler(t, DefaultCostLimit)
	program, err := compiler.CompilePreview(Definition{
		ID: "large", Expression: "object.value", ResultType: ResultInteger,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, preview, err := program.EvaluatePreviewContext(context.Background(), Activation{
		Object: map[string]any{"value": strings.Repeat("x", MaxDisplayBytes+100)},
	})
	if err == nil || !strings.Contains(err.Error(), "declared integer") {
		t.Fatalf("large preview mismatch error = %v", err)
	}
	if !preview.Available || preview.Format != "yaml" ||
		strings.Count(preview.Display, "x") != MaxDisplayBytes+100 {
		t.Fatalf("complete preview = %#v (len %d)", preview, len(preview.Display))
	}
}

func TestPreviewValueFormatsNestedYAMLWithoutLosingLargeIntegers(t *testing.T) {
	t.Parallel()
	compiler := newCompiler(t, DefaultCostLimit)
	program, err := compiler.CompilePreview(Definition{
		ID: "structured", Expression: "object.value", ResultType: ResultString,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, preview, err := program.EvaluatePreviewContext(context.Background(), Activation{
		Object: map[string]any{"value": map[string]any{
			"generation": int64(9_007_199_254_740_993),
			"owners":     []any{"alpha", "beta"},
		}},
	})
	if err == nil || !strings.Contains(err.Error(), "result type is map") {
		t.Fatalf("structured preview mismatch error = %v", err)
	}
	if !preview.Available || preview.Format != "yaml" ||
		!strings.Contains(preview.Display, "generation: 9007199254740993") ||
		!strings.Contains(preview.Display, "owners:\n- alpha\n- beta") {
		t.Fatalf("structured preview = %#v", preview)
	}
}

func TestDeclaredRuntimeTypeIsEnforcedForDynamicObject(t *testing.T) {
	t.Parallel()
	compiler := newCompiler(t, DefaultCostLimit)
	program, err := compiler.Compile(Definition{
		ID: "replicas", Expression: `object.spec.replicas`, ResultType: ResultInteger,
	})
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	_, err = program.Evaluate(Activation{Object: map[string]any{
		"spec": map[string]any{"replicas": "three"},
	}})
	var runtimeError *RuntimeError
	if !errors.As(err, &runtimeError) || runtimeError.ColumnID != "replicas" {
		t.Fatalf("Evaluate error = %T %v", err, err)
	}
}

func TestScalarListJoinsWithinBounds(t *testing.T) {
	t.Parallel()
	compiler := newCompiler(t, DefaultCostLimit)
	program, err := compiler.Compile(Definition{
		ID: "values", Expression: `["a", 2, true]`, ResultType: ResultString, ListJoiner: " · ",
	})
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	value, err := program.Evaluate(Activation{})
	if err != nil || value.Display != "a · 2 · true" {
		t.Fatalf("Evaluate = %#v, %v", value, err)
	}

	items := make([]string, MaxListElements+1)
	for index := range items {
		items[index] = `"x"`
	}
	tooMany, err := compiler.Compile(Definition{
		ID: "many", Expression: "[" + strings.Join(items, ",") + "]", ResultType: ResultString,
	})
	if err != nil {
		t.Fatalf("Compile many: %v", err)
	}
	if _, err := tooMany.Evaluate(Activation{}); err == nil || !strings.Contains(err.Error(), "maximum") {
		t.Fatalf("oversized list error = %v", err)
	}
}

func TestKmgrSumHelperPreservesHomogeneousNumericTypes(t *testing.T) {
	t.Parallel()
	compiler := newCompiler(t, DefaultCostLimit)
	cases := []struct {
		name       string
		expression string
		resultType ResultType
		want       string
	}{
		{name: "int", expression: `kmgr.sum([1, 2, 3])`, resultType: ResultInteger, want: "6"},
		{name: "uint", expression: `kmgr.sum([uint(2), uint(3)])`, resultType: ResultNumber, want: "5"},
		{name: "double", expression: `kmgr.sum([1.25, 2.75])`, resultType: ResultNumber, want: "4"},
		{name: "empty", expression: `kmgr.sum([])`, resultType: ResultInteger, want: "0"},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			program, err := compiler.Compile(Definition{
				ID: test.name, Expression: test.expression, ResultType: test.resultType,
			})
			if err != nil {
				t.Fatal(err)
			}
			value, err := program.Evaluate(Activation{})
			if err != nil || value.Display != test.want {
				t.Fatalf("Evaluate = %#v, %v", value, err)
			}
		})
	}
}

func TestKmgrSumHelperRejectsStaticAndDynamicTypeErrors(t *testing.T) {
	t.Parallel()
	compiler := newCompiler(t, DefaultCostLimit)
	if _, err := compiler.Compile(Definition{
		ID: "strings", Expression: `kmgr.sum(["1", "2"])`, ResultType: ResultNumber,
	}); err == nil || !strings.Contains(err.Error(), "requires a list of int, uint, or double") {
		t.Fatalf("static type error = %v", err)
	}
	program, err := compiler.Compile(Definition{
		ID: "dynamic", Expression: `kmgr.sum(object.values)`, ResultType: ResultNumber,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := program.Evaluate(Activation{Object: map[string]any{
		"values": []any{int64(1), "two"},
	}}); err == nil || !strings.Contains(err.Error(), "expected int") {
		t.Fatalf("dynamic mixed-type error = %v", err)
	}
}

func TestKmgrHelperBindingsPropagateCELListErrorsWithoutPanicking(t *testing.T) {
	t.Parallel()
	if value := sumDynamicList(nil); !types.IsError(value) {
		t.Fatalf("nil list result = %T %v", value, value)
	}
	if value := sumDynamicList(types.NewRefValList(types.DefaultTypeAdapter, []ref.Val{nil})); !types.IsError(value) {
		t.Fatalf("nil element result = %T %v", value, value)
	}
	sentinel := types.NewErr("sentinel")
	if value := joinScalarList(
		types.NewRefValList(types.DefaultTypeAdapter, []ref.Val{sentinel}), types.String(","),
	); value != sentinel {
		t.Fatalf("error element result = %T %v", value, value)
	}
}

func TestKmgrJoinHelperJoinsMixedScalarsInsideExpressions(t *testing.T) {
	t.Parallel()
	compiler := newCompiler(t, DefaultCostLimit)
	program, err := compiler.Compile(Definition{
		ID: "mixed", Expression: `"values=" + kmgr.join(["a", 2, true, 3.5], "|")`, ResultType: ResultString,
	})
	if err != nil {
		t.Fatal(err)
	}
	value, err := program.Evaluate(Activation{})
	if err != nil || value.Display != "values=a|2|true|3.5" {
		t.Fatalf("Evaluate = %#v, %v", value, err)
	}
	invalid, err := compiler.Compile(Definition{
		ID: "invalid", Expression: `kmgr.join(object.values, ",")`, ResultType: ResultString,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := invalid.Evaluate(Activation{Object: map[string]any{
		"values": []any{"ok", map[string]any{"nested": true}},
	}}); err == nil || !strings.Contains(err.Error(), "non-scalar") {
		t.Fatalf("non-scalar join error = %v", err)
	}
}

func TestKmgrHelpersEnforceListAndOutputBounds(t *testing.T) {
	t.Parallel()
	compiler := newCompiler(t, DefaultCostLimit)
	items := make([]string, MaxListElements+1)
	for index := range items {
		items[index] = "1"
	}
	if _, err := compiler.Compile(Definition{
		ID: "static-many", Expression: "kmgr.sum([" + strings.Join(items, ",") + "])", ResultType: ResultInteger,
	}); err == nil || !strings.Contains(err.Error(), "at most") {
		t.Fatalf("static list bound error = %v", err)
	}
	dynamic, err := compiler.Compile(Definition{
		ID: "dynamic-many", Expression: `kmgr.sum(object.values)`, ResultType: ResultInteger,
	})
	if err != nil {
		t.Fatal(err)
	}
	values := make([]any, MaxListElements+1)
	for index := range values {
		values[index] = int64(1)
	}
	if _, err := dynamic.Evaluate(Activation{Object: map[string]any{"values": values}}); err == nil || !strings.Contains(err.Error(), "maximum") {
		t.Fatalf("dynamic list bound error = %v", err)
	}
	tooLong, err := compiler.Compile(Definition{
		ID: "too-long", Expression: `kmgr.join(object.values, "")`, ResultType: ResultString,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tooLong.Evaluate(Activation{Object: map[string]any{
		"values": []any{strings.Repeat("x", MaxDisplayBytes+1)},
	}}); err == nil || !strings.Contains(err.Error(), "maximum") {
		t.Fatalf("output bound error = %v", err)
	}
}

func TestKmgrHelpersChargeRuntimeCostByWork(t *testing.T) {
	t.Parallel()
	compiler := newCompiler(t, 20)
	sum, err := compiler.Compile(Definition{
		ID: "sum-cost", Expression: `kmgr.sum(object.values)`, ResultType: ResultInteger,
	})
	if err != nil {
		t.Fatal(err)
	}
	values := make([]any, 18)
	for index := range values {
		values[index] = int64(1)
	}
	if _, err := sum.Evaluate(Activation{Object: map[string]any{"values": values}}); err == nil || !strings.Contains(err.Error(), "cost limit") {
		t.Fatalf("sum cost error = %v", err)
	}
	join, err := compiler.Compile(Definition{
		ID: "join-cost", Expression: `kmgr.join(["12345678901234567890"], "")`, ResultType: ResultString,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := join.Evaluate(Activation{}); err == nil || !strings.Contains(err.Error(), "cost limit") {
		t.Fatalf("join cost error = %v", err)
	}
}

func TestRuntimeCostLimitStopsExpensiveExpression(t *testing.T) {
	t.Parallel()
	compiler := newCompiler(t, 20)
	program, err := compiler.Compile(Definition{
		ID:         "costly",
		Expression: `object.values.exists(v, v == "missing")`,
		ResultType: ResultBoolean,
	})
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	values := make([]any, 1_000)
	for index := range values {
		values[index] = "value"
	}
	_, err = program.Evaluate(Activation{Object: map[string]any{"values": values}})
	if err == nil || !strings.Contains(err.Error(), "cost limit") {
		t.Fatalf("cost-limited Evaluate error = %v", err)
	}
}

func TestEvaluateContextRejectsPreCanceledEvaluation(t *testing.T) {
	t.Parallel()
	compiler := newCompiler(t, DefaultCostLimit)
	program, err := compiler.Compile(Definition{
		ID: "name", Expression: `object.metadata.name`, ResultType: ResultString,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = program.EvaluateContext(ctx, Activation{Object: map[string]any{
		"metadata": map[string]any{"name": "must-not-evaluate"},
	}})
	var runtimeError *RuntimeError
	if !errors.Is(err, context.Canceled) || !errors.As(err, &runtimeError) || runtimeError.ColumnID != "name" {
		t.Fatalf("EvaluateContext error = %T %v", err, err)
	}
}

func TestEvaluateContextInterruptsRunningComprehension(t *testing.T) {
	compiler := newCompiler(t, 1_000_000_000)
	program, err := compiler.Compile(Definition{
		ID:         "scan",
		Expression: `object.values.exists(value, value == -1)`,
		ResultType: ResultBoolean,
	})
	if err != nil {
		t.Fatal(err)
	}
	values := make([]any, 1_000_000)
	for index := range values {
		values[index] = int64(index)
	}
	ctx := newControlledCancelContext()
	done := make(chan error, 1)
	go func() {
		_, err := program.EvaluateContext(ctx, Activation{Object: map[string]any{"values": values}})
		done <- err
	}()
	<-ctx.observed
	ctx.cancel()
	err = <-done
	if !errors.Is(err, context.Canceled) || !strings.Contains(err.Error(), "operation interrupted") {
		t.Fatalf("running EvaluateContext error = %T %v", err, err)
	}
}

type controlledCancelContext struct {
	done     chan struct{}
	observed chan struct{}
	once     sync.Once
}

func newControlledCancelContext() *controlledCancelContext {
	return &controlledCancelContext{done: make(chan struct{}), observed: make(chan struct{})}
}

func (*controlledCancelContext) Deadline() (time.Time, bool) { return time.Time{}, false }
func (c *controlledCancelContext) Done() <-chan struct{} {
	c.once.Do(func() { close(c.observed) })
	return c.done
}
func (c *controlledCancelContext) Err() error {
	select {
	case <-c.done:
		return context.Canceled
	default:
		return nil
	}
}
func (*controlledCancelContext) Value(any) any { return nil }
func (c *controlledCancelContext) cancel()     { close(c.done) }

func TestSecretActivationRemovesPayloadWithoutMutatingSource(t *testing.T) {
	t.Parallel()
	source := map[string]any{
		"metadata":   map[string]any{"name": "credentials"},
		"data":       map[string]any{"password": "base64-secret"},
		"stringData": map[string]any{"token": "plaintext-secret"},
	}
	sanitized := SanitizeObjectActivation(source, true)
	if _, ok := sanitized["data"]; ok {
		t.Fatal("sanitized activation contains data")
	}
	if _, ok := sanitized["stringData"]; ok {
		t.Fatal("sanitized activation contains stringData")
	}
	if _, ok := source["data"]; !ok {
		t.Fatal("sanitization mutated source object")
	}

	compiler := newCompiler(t, DefaultCostLimit)
	program, err := compiler.Compile(Definition{
		ID:         "payload",
		Expression: `object.?data[?"password"].orValue("absent")`,
		ResultType: ResultString,
	})
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	value, err := program.Evaluate(Activation{Object: sanitized})
	if err != nil || value.Display != "absent" {
		t.Fatalf("Evaluate sanitized = %#v, %v", value, err)
	}
}

func TestObjectActivationAvoidsDeepCopiesOutsideSecretPayloadBoundary(t *testing.T) {
	t.Parallel()
	nested := map[string]any{"large": []any{map[string]any{"value": "retained"}}}
	object := map[string]any{"metadata": nested}
	if got := SanitizeObjectActivation(object, false); reflect.ValueOf(got).Pointer() != reflect.ValueOf(object).Pointer() {
		t.Fatal("non-Secret activation copied the immutable object")
	}

	secret := map[string]any{
		"metadata": nested,
		"data":     map[string]any{"token": "redacted"},
	}
	sanitized := SanitizeObjectActivation(secret, true)
	if reflect.ValueOf(sanitized).Pointer() == reflect.ValueOf(secret).Pointer() {
		t.Fatal("Secret activation reused the payload-bearing top-level map")
	}
	if reflect.ValueOf(sanitized["metadata"]).Pointer() != reflect.ValueOf(nested).Pointer() {
		t.Fatal("Secret activation recursively copied a safe nested field")
	}
	if _, found := sanitized["data"]; found {
		t.Fatal("Secret activation retained data")
	}
}

func TestBatchNowIsSuppliedByCaller(t *testing.T) {
	t.Parallel()
	compiler := newCompiler(t, DefaultCostLimit)
	program, err := compiler.Compile(Definition{
		ID: "now", Expression: "now", ResultType: ResultTimestamp,
	})
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	now := time.Date(2026, time.August, 13, 4, 0, 0, 0, time.UTC)
	first, err := program.Evaluate(Activation{Now: now})
	if err != nil {
		t.Fatalf("Evaluate first: %v", err)
	}
	second, err := program.Evaluate(Activation{Now: now})
	if err != nil {
		t.Fatalf("Evaluate second: %v", err)
	}
	if first.Time == nil || second.Time == nil || !first.Time.Equal(*second.Time) || !first.Time.Equal(now) {
		t.Fatalf("batch times = %#v, %#v", first.Time, second.Time)
	}
}

func TestCompilerValidatesVersionAndLimits(t *testing.T) {
	t.Parallel()
	if EnvironmentVersion != "kmgr.cel/v1" {
		t.Fatalf("environment version = %q", EnvironmentVersion)
	}
	if _, err := NewCompiler(0); err == nil {
		t.Fatal("zero cost limit accepted")
	}
	compiler := newCompiler(t, DefaultCostLimit)
	if _, err := compiler.Compile(Definition{ID: "x", Expression: "true", ResultType: "script"}); err == nil {
		t.Fatal("unknown result type accepted")
	}
}

func TestProgramDetectsMetricsDependencyWithoutMatchingLiterals(t *testing.T) {
	t.Parallel()
	compiler := newCompiler(t, DefaultCostLimit)
	metricProgram, err := compiler.Compile(Definition{
		ID: "cpu", Expression: `metrics.?resources[?"cpu"].orValue(0)`, ResultType: ResultInteger,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !metricProgram.UsesMetrics() {
		t.Fatal("metrics activation dependency was not detected")
	}
	objectProgram, err := compiler.Compile(Definition{
		ID: "label", Expression: `object.metadata.name + "-metrics"`, ResultType: ResultString,
	})
	if err != nil {
		t.Fatal(err)
	}
	if objectProgram.UsesMetrics() {
		t.Fatal("string literal woke optional metrics provider")
	}
}

func newCompiler(t *testing.T, cost uint64) *Compiler {
	t.Helper()
	compiler, err := NewCompiler(cost)
	if err != nil {
		t.Fatalf("NewCompiler: %v", err)
	}
	return compiler
}
