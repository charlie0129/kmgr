package columns

import (
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
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
