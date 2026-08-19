package view

import (
	"slices"
	"testing"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"k8s.io/apimachinery/pkg/util/validation"
)

func TestNamespaceStreamPlanCanonicalizesExactSelectionAndUsesCollisionSafeCacheKey(t *testing.T) {
	t.Parallel()
	spec := namespaceStreamTestSpec([]string{"team-b", "team-a", "team-b"}, false)
	plan, err := planNamespaceStream(spec)
	if err != nil {
		t.Fatal(err)
	}
	if !plan.exactFanIn || !slices.Equal(plan.apiNamespaces, []string{"team-a", "team-b"}) {
		t.Fatalf("exact plan = %#v", plan)
	}
	if plan.cacheNamespace != "@namespaces/team-a,team-b" {
		t.Fatalf("cache namespace = %q", plan.cacheNamespace)
	}
	if len(validation.IsDNS1123Label(plan.cacheNamespace)) == 0 {
		t.Fatalf("synthetic cache key %q can collide with a real namespace", plan.cacheNamespace)
	}
	if plan.metricNamespace != "" {
		t.Fatalf("exact fan-in metric namespace = %q; must not become one broad LIST", plan.metricNamespace)
	}

	reordered, err := planNamespaceStream(namespaceStreamTestSpec([]string{"team-a", "team-b"}, false))
	if err != nil {
		t.Fatal(err)
	}
	if reordered.cacheNamespace != plan.cacheNamespace || !slices.Equal(reordered.apiNamespaces, plan.apiNamespaces) {
		t.Fatalf("caller order changed canonical plan: %#v / %#v", plan, reordered)
	}
}

func TestNamespaceStreamPlanThresholdAndDefaultScopes(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name           string
		spec           *kmgrv1.ViewSpec
		wantAPI        []string
		wantCache      string
		wantMetric     string
		wantExactFanIn bool
	}{
		{
			name: "default", spec: namespaceStreamTestSpec(nil, false),
			wantAPI: []string{"default"}, wantCache: "default", wantMetric: "default",
		},
		{
			name: "single", spec: namespaceStreamTestSpec([]string{"team"}, false),
			wantAPI: []string{"team"}, wantCache: "team", wantMetric: "team",
		},
		{
			name: "eight exact", spec: namespaceStreamTestSpec(
				[]string{"h", "g", "f", "e", "d", "c", "b", "a"}, false,
			),
			wantAPI:   []string{"a", "b", "c", "d", "e", "f", "g", "h"},
			wantCache: "@namespaces/a,b,c,d,e,f,g,h", wantExactFanIn: true,
		},
		{
			name: "nine broad", spec: namespaceStreamTestSpec(
				[]string{"i", "h", "g", "f", "e", "d", "c", "b", "a"}, false,
			),
			wantAPI: []string{""},
		},
		{
			name: "explicit all", spec: namespaceStreamTestSpec([]string{"ignored"}, true),
			wantAPI: []string{""},
		},
		{
			name: "cluster scoped",
			spec: &kmgrv1.ViewSpec{
				Resource:       &kmgrv1.ResourceType{Version: "v1", Resource: "nodes"},
				NamespaceScope: &kmgrv1.NamespaceScope{Namespaces: []string{"ignored"}},
			},
			wantAPI: []string{""},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			plan, err := planNamespaceStream(test.spec)
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(plan.apiNamespaces, test.wantAPI) ||
				plan.cacheNamespace != test.wantCache ||
				plan.metricNamespace != test.wantMetric ||
				plan.exactFanIn != test.wantExactFanIn {
				t.Fatalf("plan = %#v", plan)
			}
		})
	}
}

func TestNamespaceStreamPlanRejectsEmptyExplicitNamespace(t *testing.T) {
	t.Parallel()
	if _, err := planNamespaceStream(namespaceStreamTestSpec([]string{"team", ""}, false)); err == nil {
		t.Fatal("empty explicit namespace was accepted")
	}
}

func namespaceStreamTestSpec(namespaces []string, all bool) *kmgrv1.ViewSpec {
	spec := &kmgrv1.ViewSpec{
		Resource: &kmgrv1.ResourceType{
			Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true,
		},
	}
	if namespaces != nil || all {
		spec.NamespaceScope = &kmgrv1.NamespaceScope{
			AllNamespaces: all, Namespaces: append([]string(nil), namespaces...),
		}
	}
	return spec
}
