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
	programs, version, err := compiled.Resolve("", "v1", "pods", []string{"team"}, "")
	if err != nil || version != compiled.Version() || programs["team"] == nil {
		t.Fatalf("Resolve = programs %#v, version %q, err %v", programs, version, err)
	}
	if _, _, err := compiled.Resolve("", "v1", "pods", nil, "stale"); err == nil {
		t.Fatal("stale configuration version was accepted")
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
