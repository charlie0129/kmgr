package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charlie0129/kmgr/backend/internal/view/columns"
)

func TestParseColumnsCompilesVersionedCELAndResolvesRequestedPrograms(t *testing.T) {
	t.Parallel()
	compiler, err := columns.NewCompiler(columns.DefaultCostLimit)
	if err != nil {
		t.Fatal(err)
	}
	compiled, err := ParseColumns([]byte(`
apiVersion: kmgr.charlie0129.dev/v1alpha1
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
        value: pod.status
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
apiVersion: kmgr.charlie0129.dev/v1alpha1
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

func TestResolvePreservesDisplayIDAndUsesConfiguredExtractorValue(t *testing.T) {
	t.Parallel()
	compiler, err := columns.NewCompiler(columns.DefaultCostLimit)
	if err != nil {
		t.Fatal(err)
	}
	compiled, err := ParseColumns([]byte(`
apiVersion: kmgr.charlie0129.dev/v1alpha1
celEnvironment: kmgr.cel/v1
views:
- match: {version: v1, resource: pods}
  columns:
  - {id: phase, title: Phase, source: builtin, value: pod.status, type: string}
  - {id: gpu, title: GPU, source: metric, value: resource:nvidia.com/gpu, type: resourceUsage}
  - {id: cpu-load, title: CPU, source: metric, value: pod.cpu.usageRequestLimit, type: resourceUsage}
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
apiVersion: kmgr.charlie0129.dev/v1alpha1
celEnvironment: kmgr.cel/v1
views:
- match: {version: v1, resource: pods}
  columns:
  - {id: phase, title: Phase, source: builtin, value: pod.status, type: string}
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
		"Pod metric on Node":       `{id: x, title: X, source: metric, value: pod.cpu.usageRequestLimit, type: resourceUsage}`,
	}
	for name, column := range cases {
		name, column := name, column
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			resource := "pods"
			if name == "Pod metric on Node" {
				resource = "nodes"
			}
			input := "apiVersion: kmgr.charlie0129.dev/v1alpha1\n" +
				"celEnvironment: kmgr.cel/v1\nviews:\n" +
				"- match: {version: v1, resource: " + resource + "}\n  columns:\n  - " + column + "\n"
			if _, err := ParseColumns([]byte(input), compiler); err == nil {
				t.Fatalf("invalid source/value contract accepted:\n%s", input)
			}
		})
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
		"apiVersion: kmgr.charlie0129.dev/v1alpha1\ncelEnvironment: future\n",
		"apiVersion: kmgr.charlie0129.dev/v1alpha1\ncelEnvironment: kmgr.cel/v1\nunknown: true\n",
		`apiVersion: kmgr.charlie0129.dev/v1alpha1
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
	valid := []byte(`apiVersion: kmgr.charlie0129.dev/v1alpha1
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
