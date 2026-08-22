package config

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/charlie0129/kmgr/backend/internal/view/columns"
)

func TestSharedNativeColumnContractCoversEveryExtractor(t *testing.T) {
	t.Parallel()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "native-columns-contract.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Columns []struct {
			Source string             `json:"source"`
			Value  string             `json:"value"`
			Type   columns.ResultType `json:"type"`
		} `json:"columns"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	seenBuiltins := make(map[string]columns.ResultType)
	seenMetrics := make(map[string]struct{})
	for _, definition := range fixture.Columns {
		switch definition.Source {
		case "builtin":
			if existing, found := seenBuiltins[definition.Value]; found && existing != definition.Type {
				t.Fatalf("builtin %q has conflicting fixture types %q and %q", definition.Value, existing, definition.Type)
			}
			seenBuiltins[definition.Value] = definition.Type
		case "metric":
			seenMetrics[definition.Value] = struct{}{}
		default:
			t.Fatalf("unsupported fixture source %q", definition.Source)
		}
	}
	if len(seenBuiltins) != len(builtinExtractors) {
		t.Fatalf("fixture builtins = %v; registry = %v", sortedKeys(seenBuiltins), sortedKeys(builtinExtractors))
	}
	for value, resultType := range builtinExtractors {
		if seenBuiltins[value] != resultType {
			t.Fatalf("fixture builtin %q type = %q; want %q", value, seenBuiltins[value], resultType)
		}
	}
	if len(seenMetrics) != len(metricExtractors) {
		t.Fatalf("fixture metrics = %v; registry = %v", sortedKeys(seenMetrics), sortedKeys(metricExtractors))
	}
	for value := range metricExtractors {
		if _, found := seenMetrics[value]; !found {
			t.Fatalf("fixture omits metric extractor %q", value)
		}
	}
}

func sortedKeys[M ~map[string]V, V any](values M) []string {
	result := make([]string, 0, len(values))
	for key := range values {
		result = append(result, key)
	}
	slices.Sort(result)
	return result
}

func TestParseColumnsRejectsLegacyNativeTypes(t *testing.T) {
	t.Parallel()
	compiler, err := columns.NewCompiler(columns.DefaultCostLimit)
	if err != nil {
		t.Fatal(err)
	}
	_, err = ParseColumns([]byte(`
apiVersion: kmgr.chlc.cc/v1alpha1
celEnvironment: kmgr.cel/v1
views:
- match: {version: v1, resource: pods}
  columns:
  - {id: ready, title: Ready, source: builtin, value: ready, type: number}
  - {id: age, title: Age, source: builtin, value: age, type: timestamp}
`), compiler)
	if err == nil {
		t.Fatal("legacy native types were silently migrated")
	}
}

func TestParseColumnsCompilesVersionedCELAndResolvesRequestedPrograms(t *testing.T) {
	t.Parallel()
	compiler, err := columns.NewCompiler(columns.DefaultCostLimit)
	if err != nil {
		t.Fatal(err)
	}
	compiled, err := ParseColumns([]byte(`
apiVersion: kmgr.chlc.cc/v1alpha1
celEnvironment: kmgr.cel/v1
views:
  - match:
      group: ""
      version: v1
      resource: pods
    columns:
      - id: team
        title: Team
        source: cel
        expression: object.?metadata.?labels[?"team"].orValue("—")
        type: string
        width: 120
      - id: status
        title: Status
        source: builtin
        value: status
        type: string
`), compiler)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(compiled.Version(), "sha256:") {
		t.Fatalf("version = %q", compiled.Version())
	}
	resolved, version, err := compiled.Resolve("", "v1", "pods", []string{"team"}, "")
	if err != nil || version != compiled.Version() || resolved.Programs["team"] == nil {
		t.Fatalf("Resolve = %#v, version %q, err %v", resolved, version, err)
	}
	if _, _, err := compiled.Resolve("", "v1", "pods", nil, "stale"); err == nil {
		t.Fatal("stale configuration version was accepted")
	}
}

func TestCompiledColumnsExposesExactAcceleratorConfig(t *testing.T) {
	t.Parallel()
	compiler, err := columns.NewCompiler(columns.DefaultCostLimit)
	if err != nil {
		t.Fatal(err)
	}
	compiled, err := ParseColumns([]byte(`
apiVersion: kmgr.chlc.cc/v1alpha1
celEnvironment: kmgr.cel/v1
accelerators:
  autoDetectSuffixes: [/gpu, /ppu]
  resources:
    nvidia.com/gpu: {displayName: GPU}
    aliyun.com/ppu: {displayName: PPU}
`), compiler)
	if err != nil {
		t.Fatal(err)
	}
	got := compiled.AcceleratorConfig()
	if len(got.AutoDetectSuffixes) != 2 || got.Resources["nvidia.com/gpu"].DisplayName != "GPU" ||
		got.Resources["aliyun.com/ppu"].DisplayName != "PPU" {
		t.Fatalf("AcceleratorConfig = %#v", got)
	}
	got.AutoDetectSuffixes[0] = "changed"
	delete(got.Resources, "nvidia.com/gpu")
	again := compiled.AcceleratorConfig()
	if again.AutoDetectSuffixes[0] != "/gpu" || again.Resources["nvidia.com/gpu"].DisplayName != "GPU" {
		t.Fatalf("AcceleratorConfig was not caller-owned: %#v", again)
	}
}

func TestParseColumnsPreservesOmittedAndExplicitlyEmptyAcceleratorSuffixes(t *testing.T) {
	t.Parallel()
	compiler, err := columns.NewCompiler(columns.DefaultCostLimit)
	if err != nil {
		t.Fatal(err)
	}
	for name, acceleratorYAML := range map[string]string{
		"omitted":        "",
		"explicit empty": "accelerators:\n  autoDetectSuffixes: []\n",
	} {
		name, acceleratorYAML := name, acceleratorYAML
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			compiled, err := ParseColumns([]byte(
				"apiVersion: kmgr.chlc.cc/v1alpha1\n"+
					"celEnvironment: kmgr.cel/v1\n"+acceleratorYAML,
			), compiler)
			if err != nil {
				t.Fatal(err)
			}
			suffixes := compiled.AcceleratorConfig().AutoDetectSuffixes
			if name == "omitted" && suffixes != nil {
				t.Fatalf("omitted suffixes = %#v; want nil default sentinel", suffixes)
			}
			if name == "explicit empty" && (suffixes == nil || len(suffixes) != 0) {
				t.Fatalf("explicitly empty suffixes = %#v; want non-nil empty slice", suffixes)
			}
		})
	}
}

func TestParseColumnsRejectsInvalidPresentationAndAcceleratorSchema(t *testing.T) {
	t.Parallel()
	compiler, err := columns.NewCompiler(columns.DefaultCostLimit)
	if err != nil {
		t.Fatal(err)
	}
	maximumQualifiedPrefix := strings.Join([]string{
		strings.Repeat("a", 63), strings.Repeat("b", 63),
		strings.Repeat("c", 63), strings.Repeat("d", 61),
	}, ".")
	cases := map[string]string{
		"missing title": `views:
- match: {version: v1, resource: pods}
  columns:
  - {id: name, source: builtin, value: name, type: string}
`,
		"blank title": `views:
- match: {version: v1, resource: pods}
  columns:
  - {id: name, title: "  ", source: builtin, value: name, type: string}
`,
		"unqualified accelerator": `accelerators:
  resources:
    gpu: {}
`,
		"native accelerator": `accelerators:
  resources:
    kubernetes.io/gpu: {}
`,
		"quota-prefixed accelerator": `accelerators:
  resources:
    requests.example.com/gpu: {}
`,
		"malformed accelerator": `accelerators:
  resources:
    bad/resource/name: {}
`,
		"quota-form-too-long accelerator": "accelerators:\n  resources:\n    " + maximumQualifiedPrefix + "/gpu: {}\n",
	}
	for name, body := range cases {
		name, body := name, body
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			input := "apiVersion: kmgr.chlc.cc/v1alpha1\n" +
				"celEnvironment: kmgr.cel/v1\n" + body
			if _, err := ParseColumns([]byte(input), compiler); err == nil {
				t.Fatalf("invalid schema accepted:\n%s", input)
			}
		})
	}

	for name, width := range map[string]float64{
		"negative":          -1,
		"positive infinity": math.Inf(1),
		"negative infinity": math.Inf(-1),
		"not a number":      math.NaN(),
	} {
		if validColumnWidth(width) {
			t.Errorf("%s width was accepted", name)
		}
	}
	for name, width := range map[string]float64{"zero": 0, "positive": 180.5} {
		if !validColumnWidth(width) {
			t.Errorf("%s width was rejected", name)
		}
	}
}

func TestResolvePreservesDisplayIDAndUsesConfiguredExtractorValue(t *testing.T) {
	t.Parallel()
	compiler, err := columns.NewCompiler(columns.DefaultCostLimit)
	if err != nil {
		t.Fatal(err)
	}
	compiled, err := ParseColumns([]byte(`
apiVersion: kmgr.chlc.cc/v1alpha1
celEnvironment: kmgr.cel/v1
views:
- match: {version: v1, resource: pods}
  columns:
  - {id: phase, title: Phase, source: builtin, value: status, type: string}
  - {id: gpu, title: GPU, source: metric, value: resource:nvidia.com/gpu, type: resourceUsage}
  - {id: cpu-load, title: CPU, source: metric, value: cpu, type: resourceUsage}
`), compiler)
	if err != nil {
		t.Fatal(err)
	}
	resolved, _, err := compiled.Resolve("", "v1", "pods", []string{"phase", "gpu", "cpu-load"}, "")
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"phase": "status", "gpu": "resource:nvidia.com/gpu", "cpu-load": "cpu",
	}
	if len(resolved.Programs) != 0 || len(resolved.Extractors) != len(want) {
		t.Fatalf("resolution = %#v", resolved)
	}
	for id, extractor := range want {
		if got := resolved.Extractors[id]; got.Value != extractor || (got.Source != "builtin" && got.Source != "metric") {
			t.Fatalf("extractor[%q] = %#v, want value %q", id, got, extractor)
		}
	}

	selected, _, err := compiled.Resolve("", "v1", "pods", []string{"gpu"}, "")
	if err != nil || len(selected.Extractors) != 1 || selected.Extractors["gpu"].Value != "resource:nvidia.com/gpu" {
		t.Fatalf("selected resolution = %#v, %v", selected, err)
	}
}

func TestResolveUsesEnabledDefinitionsWhenRequestOmitsColumnIDs(t *testing.T) {
	t.Parallel()
	compiler, err := columns.NewCompiler(columns.DefaultCostLimit)
	if err != nil {
		t.Fatal(err)
	}
	compiled, err := ParseColumns([]byte(`
apiVersion: kmgr.chlc.cc/v1alpha1
celEnvironment: kmgr.cel/v1
views:
- match: {version: v1, resource: pods}
  columns:
  - {id: phase, title: Phase, source: builtin, value: status, type: string}
  - {id: gpu, title: GPU, source: metric, value: resource:nvidia.com/gpu, type: resourceUsage, enabled: false}
  - {id: team, title: Team, source: cel, expression: object.metadata.name, type: string}
`), compiler)
	if err != nil {
		t.Fatal(err)
	}
	resolved, _, err := compiled.Resolve("", "v1", "pods", nil, "")
	if err != nil {
		t.Fatal(err)
	}
	if resolved.Extractors["phase"].Value != "status" || resolved.Extractors["gpu"].Value != "" ||
		resolved.Programs["team"] == nil {
		t.Fatalf("enabled resolution = %#v", resolved)
	}
}

func TestParseColumnsCompileValidatesSourceValueContracts(t *testing.T) {
	t.Parallel()
	compiler, err := columns.NewCompiler(columns.DefaultCostLimit)
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string]string{
		"CEL value":                `{id: x, title: X, source: cel, expression: '"x"', value: name, type: string}`,
		"builtin expression":       `{id: x, title: X, source: builtin, expression: '"x"', value: name, type: string}`,
		"unknown builtin":          `{id: x, title: X, source: builtin, value: pod.unknown, type: string}`,
		"builtin type":             `{id: x, title: X, source: builtin, value: restarts, type: string}`,
		"ready type":               `{id: x, title: X, source: builtin, value: ready, type: number}`,
		"age type":                 `{id: x, title: X, source: builtin, value: age, type: timestamp}`,
		"unknown metric":           `{id: x, title: X, source: metric, value: pod.network, type: resourceUsage}`,
		"metric type":              `{id: x, title: X, source: metric, value: cpu, type: number}`,
		"malformed exact resource": `{id: x, title: X, source: metric, value: 'resource:bad/resource/name', type: resourceUsage}`,
		"legacy builtin alias":     `{id: x, title: X, source: builtin, value: pod.status, type: string}`,
		"legacy Pod metric alias":  `{id: x, title: X, source: metric, value: pod.cpu.usageRequestLimit, type: resourceUsage}`,
		"legacy Node metric alias": `{id: x, title: X, source: metric, value: node.cpu.usageAllocatable, type: resourceUsage}`,
	}
	for name, column := range cases {
		name, column := name, column
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			input := "apiVersion: kmgr.chlc.cc/v1alpha1\n" +
				"celEnvironment: kmgr.cel/v1\nviews:\n" +
				"- match: {version: v1, resource: pods}\n  columns:\n  - " + column + "\n"
			if _, err := ParseColumns([]byte(input), compiler); err == nil {
				t.Fatalf("invalid source/value contract accepted:\n%s", input)
			}
		})
	}
}

func TestDesiredBuiltinSupportsStandardReplicaControllersOnly(t *testing.T) {
	t.Parallel()
	definition := ColumnConfiguration{
		ID: "desired", Title: "Desired", Source: "builtin",
		Value: "desired", Type: columns.ResultInteger,
	}
	valid := []resourceKey{
		{group: "apps", version: "v1", resource: "deployments"},
		{group: "apps", version: "v1", resource: "statefulsets"},
		{group: "apps", version: "v1", resource: "daemonsets"},
		{group: "apps", version: "v1", resource: "replicasets"},
		{version: "v1", resource: "replicationcontrollers"},
	}
	for _, key := range valid {
		if got, err := validateExtractor(key, definition); err != nil || got != "desired" {
			t.Errorf("validateExtractor(%#v) = %q, %v", key, got, err)
		}
	}
	invalid := []resourceKey{
		{version: "v1", resource: "pods"},
		{group: "apps", version: "v1", resource: "controllerrevisions"},
		{group: "apps", version: "v1beta1", resource: "deployments"},
		{group: "example.test", version: "v1", resource: "deployments"},
	}
	for _, key := range invalid {
		if _, err := validateExtractor(key, definition); err == nil {
			t.Errorf("validateExtractor(%#v) accepted desired replica count", key)
		}
	}
}

func TestNodeMetadataBuiltinsSupportCoreNodesOnly(t *testing.T) {
	t.Parallel()
	definitions := []ColumnConfiguration{
		{ID: "roles", Title: "Roles", Source: "builtin", Value: "roles", Type: columns.ResultString},
		{ID: "taints", Title: "Taints", Source: "builtin", Value: "taints", Type: columns.ResultInteger},
		{ID: "internal-ip", Title: "Internal IP", Source: "builtin", Value: "internal-ip", Type: columns.ResultString},
	}
	for _, definition := range definitions {
		if got, err := validateExtractor(
			resourceKey{version: "v1", resource: "nodes"}, definition,
		); err != nil || got != definition.Value {
			t.Errorf("validate Node %q = %q, %v", definition.Value, got, err)
		}
		if _, err := validateExtractor(
			resourceKey{version: "v1", resource: "pods"}, definition,
		); err == nil {
			t.Errorf("Pod accepted Node builtin %q", definition.Value)
		}
	}
}

func TestParseColumnsRejectsUnknownFieldsEnvironmentAndDuplicateIDs(t *testing.T) {
	t.Parallel()
	compiler, err := columns.NewCompiler(columns.DefaultCostLimit)
	if err != nil {
		t.Fatal(err)
	}
	cases := []string{
		"apiVersion: wrong\ncelEnvironment: kmgr.cel/v1\n",
		"apiVersion: kmgr.chlc.cc/v1alpha1\ncelEnvironment: future\n",
		"apiVersion: kmgr.chlc.cc/v1alpha1\ncelEnvironment: kmgr.cel/v1\nunknown: true\n",
		`apiVersion: kmgr.chlc.cc/v1alpha1
celEnvironment: kmgr.cel/v1
views:
- match: {version: v1, resource: pods}
  columns:
  - {id: same, title: A, source: builtin, value: name, type: string}
  - {id: same, title: B, source: builtin, value: name, type: string}
`,
	}
	for _, input := range cases {
		if _, err := ParseColumns([]byte(input), compiler); err == nil {
			t.Fatalf("invalid document accepted:\n%s", input)
		}
	}
}

func TestColumnManagerKeepsLastValidProgramsAfterInvalidExternalEdit(t *testing.T) {
	t.Parallel()
	compiler, err := columns.NewCompiler(columns.DefaultCostLimit)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "columns.yaml")
	valid := []byte(`apiVersion: kmgr.chlc.cc/v1alpha1
celEnvironment: kmgr.cel/v1
views:
- match: {version: v1, resource: pods}
  columns:
  - id: team
    title: Team
    source: cel
    expression: object.metadata.name
    type: string
`)
	if err := os.WriteFile(path, valid, 0o600); err != nil {
		t.Fatal(err)
	}
	manager, err := NewColumnManager(path, compiler)
	if err != nil {
		t.Fatal(err)
	}
	version := manager.Version()
	// Change size as well as contents so filesystems with coarse mtime still
	// make the edit observable.
	if err := os.WriteFile(path, []byte("invalid: configuration with different size\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := manager.Resolve("", "v1", "pods", []string{"team"}, ""); err == nil {
		t.Fatal("invalid external edit was not reported")
	}
	if manager.Version() != version {
		t.Fatal("invalid edit replaced the last valid configuration")
	}
}
