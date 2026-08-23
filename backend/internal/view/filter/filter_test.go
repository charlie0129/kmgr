package filter

import (
	"errors"
	"reflect"
	"testing"
)

func TestCompileAndMatch(t *testing.T) {
	t.Parallel()
	compiled, err := Compile(`namespace:"Team A" name:web label:app=Frontend field:spec.nodeName=node-1 status:running ready`)
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	candidate := Candidate{
		Namespace:   "team a",
		Name:        "web-server",
		Status:      "Running",
		Labels:      map[string]string{"app": "frontend-v2"},
		Fields:      map[string]string{"spec.nodeName": "NODE-1"},
		VisibleText: []string{"3/3 Ready"},
	}
	if !compiled.Match(candidate) {
		t.Fatal("candidate did not match all terms")
	}
	candidate.Labels["app"] = "backend"
	if compiled.Match(candidate) {
		t.Fatal("candidate matched the wrong label value")
	}
}

func TestPresenceTerms(t *testing.T) {
	t.Parallel()
	compiled, err := Compile("label:team field:metadata.creationTimestamp")
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	if !compiled.Match(Candidate{
		Labels: map[string]string{"team": ""},
		Fields: map[string]string{"metadata.creationTimestamp": ""},
	}) {
		t.Fatal("presence-only terms did not match present keys")
	}
}

func TestExactStructuredTermsAreCaseSensitiveAndDoNotMatchSubstrings(t *testing.T) {
	t.Parallel()
	compiled, err := Compile("label:app==api field:spec.nodeName==worker-1")
	if err != nil {
		t.Fatal(err)
	}
	matching := Candidate{
		Labels: map[string]string{"app": "api"},
		Fields: map[string]string{"spec.nodeName": "worker-1"},
	}
	if !compiled.Match(matching) {
		t.Fatal("exact values did not match themselves")
	}
	for _, candidate := range []Candidate{
		{Labels: map[string]string{"app": "myapi"}, Fields: matching.Fields},
		{Labels: map[string]string{"app": "API"}, Fields: matching.Fields},
		{Labels: matching.Labels, Fields: map[string]string{"spec.nodeName": "worker-10"}},
		{Labels: matching.Labels, Fields: map[string]string{"spec.nodeName": "WORKER-1"}},
	} {
		if compiled.Match(candidate) {
			t.Fatalf("exact filter matched near miss %#v", candidate)
		}
	}
}

func TestAllTermsAreConjunctive(t *testing.T) {
	t.Parallel()
	compiled, err := Compile("api running")
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	if compiled.Match(Candidate{Name: "api", Status: "Pending"}) {
		t.Fatal("filter matched only one of two terms")
	}
}

func TestNativeSelectorsAreExplicitAndMatchLocally(t *testing.T) {
	t.Parallel()
	compiled, err := Compile(
		`labelSelector:"app=api,track in (canary,stable),zone notin (east,west)" ` +
			`fieldSelector:"spec.nodeName=worker-1" ready`,
	)
	if err != nil {
		t.Fatal(err)
	}

	if got, want := compiled.NativeLabelSelectors(),
		[]string{"app=api,track in (canary,stable),zone notin (east,west)"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("native label selectors = %#v, want %#v", got, want)
	}
	if got, want := compiled.NativeFieldSelectors(), []string{"spec.nodeName=worker-1"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("native field selectors = %#v, want %#v", got, want)
	}
	if got, want := compiled.FieldPaths(), []string{"spec.nodeName"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("field paths = %#v, want %#v", got, want)
	}

	matching := Candidate{
		Labels: map[string]string{
			"app": "api", "track": "canary", "zone": "central",
		},
		Fields:      map[string]string{"spec.nodeName": "worker-1"},
		VisibleText: []string{"Ready"},
	}
	if !compiled.Match(matching) {
		t.Fatal("native selector query did not match")
	}
	matching.Labels["track"] = "blue"
	if compiled.Match(matching) {
		t.Fatal("native in selector matched a value outside its set")
	}
}

func TestNativeFieldSelectorPreservesKubernetesEscapes(t *testing.T) {
	t.Parallel()
	compiled, err := Compile(
		`fieldSelector:"metadata.name=a\\b\,c\=d"`,
	)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := compiled.NativeFieldSelectors(),
		[]string{`metadata.name=a\\b\,c\=d`}; !reflect.DeepEqual(got, want) {
		t.Fatalf("native field selectors = %#v, want %#v", got, want)
	}
	if !compiled.Match(Candidate{
		Fields: map[string]string{"metadata.name": `a\b,c=d`},
	}) {
		t.Fatal("escaped native field selector did not match its literal value")
	}
}

func TestNativeFieldSelectorPreservesKubernetesEscapesTypedByTheUser(t *testing.T) {
	t.Parallel()
	compiled, err := Compile(`fieldSelector:"metadata.name=a\,b"`)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := compiled.NativeFieldSelectors(), []string{`metadata.name=a\,b`}; !reflect.DeepEqual(got, want) {
		t.Fatalf("native field selectors = %#v, want %#v", got, want)
	}
	if !compiled.Match(Candidate{
		Fields: map[string]string{"metadata.name": "a,b"},
	}) {
		t.Fatal("native field selector did not match its escaped literal value")
	}
}

func TestBareTextRemainsLocalKeywordSearch(t *testing.T) {
	t.Parallel()
	compiled, err := Compile("api ready")
	if err != nil {
		t.Fatal(err)
	}
	if got := compiled.NativeLabelSelectors(); len(got) != 0 {
		t.Fatalf("bare text produced native label selectors: %#v", got)
	}
	if got := compiled.NativeFieldSelectors(); len(got) != 0 {
		t.Fatalf("bare text produced native field selectors: %#v", got)
	}
	if !compiled.Match(Candidate{
		Name:        "api-server",
		VisibleText: []string{"Ready"},
	}) {
		t.Fatal("bare text did not match visible local content")
	}
}

func TestQuotesAndEscapes(t *testing.T) {
	t.Parallel()
	compiled, err := Compile(`"hello world" web\ server`)
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	want := []Term{{Kind: Text, Value: "hello world"}, {Kind: Text, Value: "web server"}}
	if got := compiled.Terms(); !reflect.DeepEqual(got, want) {
		t.Fatalf("terms = %#v, want %#v", got, want)
	}
}

func TestParseErrorsIncludeOffset(t *testing.T) {
	t.Parallel()
	for _, query := range []string{
		`"unterminated`,
		`name:`,
		`unknown:value`,
		`label:=value`,
		`field:path=`,
		`labelSelector:"app in ("`,
		`fieldSelector:"metadata.name`,
		`labelSelector:" "`,
		`fieldSelector:","`,
		`trailing\`,
	} {
		t.Run(query, func(t *testing.T) {
			_, err := Compile(query)
			var parseError *ParseError
			if !errors.As(err, &parseError) {
				t.Fatalf("Compile(%q) error = %T %v", query, err, err)
			}
			if parseError.Offset < 0 {
				t.Fatalf("invalid offset: %d", parseError.Offset)
			}
		})
	}
}

func TestEmptyFilterMatches(t *testing.T) {
	t.Parallel()
	compiled, err := Compile("  ")
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	if !compiled.Match(Candidate{}) {
		t.Fatal("empty filter did not match")
	}
}
