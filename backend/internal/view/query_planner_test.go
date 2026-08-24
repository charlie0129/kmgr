package view

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	viewfilter "github.com/charlie0129/kmgr/backend/internal/view/filter"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/watch"
)

func TestPlanViewQueryUsesOnlyExplicitNativeClauses(t *testing.T) {
	t.Parallel()
	spec := &kmgrv1.ViewSpec{
		Resource: &kmgrv1.ResourceType{
			Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true,
		},
		FilterExpression: strings.Join([]string{
			`labelSelector:"app=api,track in (canary,stable),zone notin (east,west)"`,
			`fieldSelector:"spec.nodeName=worker-1"`,
			`label:team`,
			`field:status.phase==Running`,
			`api`,
		}, " "),
	}

	plan, err := planViewQuery(spec)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := plan.labelSelector,
		`app=api,track in (canary,stable),zone notin (east,west)`; got != want {
		t.Fatalf("label selector = %q, want %q", got, want)
	}
	if got, want := plan.fieldSelector, `spec.nodeName=worker-1`; got != want {
		t.Fatalf("field selector = %q, want %q", got, want)
	}
	if got := plan.filter.NativeLabelSelectors(); !reflect.DeepEqual(got,
		[]string{`app=api,track in (canary,stable),zone notin (east,west)`}) {
		t.Fatalf("native labels = %#v", got)
	}

	candidate := viewFilterCandidateForPlannerTest()
	if !plan.filter.Match(candidate) {
		t.Fatal("complete visible query did not match its candidate")
	}
	candidate.Labels["track"] = "blue"
	if plan.filter.Match(candidate) {
		t.Fatal("native in selector was not retained for local correctness")
	}
}

func TestPlanViewQueryDoesNotPushBareOrLocalTerms(t *testing.T) {
	t.Parallel()
	plan, err := planViewQuery(&kmgrv1.ViewSpec{
		Resource:         &kmgrv1.ResourceType{Version: "v1", Resource: "pods"},
		FilterExpression: `api label:app==api field:spec.nodeName==worker-1`,
	})
	if err != nil {
		t.Fatal(err)
	}
	if plan.labelSelector != "" || plan.fieldSelector != "" {
		t.Fatalf("local query unexpectedly pushed selectors: %q / %q", plan.labelSelector, plan.fieldSelector)
	}
}

func TestPlanViewQueryResolvesColumnTermsAgainstRequestedColumns(t *testing.T) {
	t.Parallel()
	plan, err := planViewQuery(&kmgrv1.ViewSpec{
		Resource:         &kmgrv1.ResourceType{Version: "v1", Resource: "pods"},
		ColumnIds:        []string{"name", "block"},
		FilterExpression: `labelSelector:"app=api" block:ready`,
	})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := plan.filter.ColumnIDs(), []string{"block"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("column IDs = %#v, want %#v", got, want)
	}
	if got, want := plan.labelSelector, "app=api"; got != want {
		t.Fatalf("label selector = %q, want %q", got, want)
	}
}

func TestPlanViewQueryRejectsInvalidExplicitNativeSelectors(t *testing.T) {
	t.Parallel()
	for _, query := range []string{
		`labelSelector:"app in ("`,
		`fieldSelector:"metadata.name`,
	} {
		query := query
		t.Run(query, func(t *testing.T) {
			t.Parallel()
			_, err := planViewQuery(&kmgrv1.ViewSpec{
				Resource:         &kmgrv1.ResourceType{Version: "v1", Resource: "pods"},
				FilterExpression: query,
			})
			if err == nil {
				t.Fatalf("query %q unexpectedly compiled", query)
			}
		})
	}
}

func TestProjectorReusesQueryPlanCompiledFilter(t *testing.T) {
	t.Parallel()
	spec := &kmgrv1.ViewSpec{
		Resource:         &kmgrv1.ResourceType{Version: "v1", Resource: "pods", Namespaced: true},
		NamespaceScope:   &kmgrv1.NamespaceScope{Namespaces: []string{"ns"}},
		ColumnIds:        []string{"name"},
		FilterExpression: `labelSelector:"app=api"`,
	}
	plan, err := planViewQuery(spec)
	if err != nil {
		t.Fatal(err)
	}
	projector, err := projectorFromProto("session", spec, nil, plan.filter, nil)
	if err != nil {
		t.Fatal(err)
	}
	if projector.filter != plan.filter {
		t.Fatal("projector did not reuse the query planner's compiled filter")
	}
}

func TestRuntimeUsesExplicitNativeSelectorsForSharingAndListWatch(t *testing.T) {
	t.Parallel()
	client := newSelectorRecordingClient()
	source := &fakeResourceSource{authority: "cluster-a", client: client}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: source, ReleaseDelay: time.Hour, BatchDelay: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	firstRequest := openView("session-1", "pods-1", 1)
	firstRequest.Spec.FilterExpression = strings.Join([]string{
		`labelSelector:"env=prod,app==api"`,
		`label:team`, `fieldSelector:"spec.nodeName=node-a"`, `name:first`,
	}, " ")
	first, err := runtime.Open(firstRequest)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	eventually(t, time.Second, func() bool { return client.delegate.watchCalls.Load() == 1 })

	secondRequest := openView("session-2", "pods-2", 1)
	secondRequest.Spec.FilterExpression = strings.Join([]string{
		`name:second`, `fieldSelector:"spec.nodeName=node-a"`,
		`labelSelector:"app=api,env==prod"`, `label:team`,
	}, " ")
	second, err := runtime.Open(secondRequest)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	eventually(t, time.Second, func() bool { return source.opens.Load() == 2 })
	if got := client.delegate.listCalls.Load(); got != 1 {
		t.Fatalf("canonical-equivalent LIST calls = %d, want 1", got)
	}
	if got := client.delegate.watchCalls.Load(); got != 1 {
		t.Fatalf("canonical-equivalent WATCH calls = %d, want 1", got)
	}

	listOptions, watchOptions := client.snapshots()
	if len(listOptions) != 1 || len(watchOptions) != 1 {
		t.Fatalf("captured LIST/WATCH options = %d/%d, want 1/1", len(listOptions), len(watchOptions))
	}
	for operation, options := range map[string]metav1.ListOptions{
		"LIST":  listOptions[0],
		"WATCH": watchOptions[0],
	} {
		if got, want := options.LabelSelector, `app=api,env=prod`; got != want {
			t.Fatalf("%s label selector = %q, want %q", operation, got, want)
		}
		if got, want := options.FieldSelector, `spec.nodeName=node-a`; got != want {
			t.Fatalf("%s field selector = %q, want %q", operation, got, want)
		}
	}

	thirdRequest := openView("session-3", "pods-3", 1)
	thirdRequest.Spec.FilterExpression = `labelSelector:"env=prod" label:team`
	third, err := runtime.Open(thirdRequest)
	if err != nil {
		t.Fatal(err)
	}
	defer third.Close()
	eventually(t, time.Second, func() bool { return client.delegate.watchCalls.Load() == 2 })
	if got := client.delegate.listCalls.Load(); got != 2 {
		t.Fatalf("selector-changing LIST calls = %d, want 2", got)
	}
}

func TestRuntimeRejectsInvalidNativeQueryBeforeOpeningResource(t *testing.T) {
	t.Parallel()
	source := &fakeResourceSource{authority: "cluster-a", client: newScriptedResource()}
	runtime, err := NewRuntime(RuntimeConfig{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	request := openView("session", "pods", 1)
	request.Spec.FilterExpression = `labelSelector:"app in ("`
	if _, err := runtime.Open(request); !errors.Is(err, ErrInvalidView) {
		t.Fatalf("Open error = %v, want ErrInvalidView", err)
	}
	if got := source.opens.Load(); got != 0 {
		t.Fatalf("resource opens after invalid query = %d, want 0", got)
	}
}

func viewFilterCandidateForPlannerTest() viewfilter.Candidate {
	return viewfilter.Candidate{
		Namespace: "ns",
		Name:      "pod-one",
		Labels: map[string]string{
			"team": "platform", "app": "api", "track": "canary", "zone": "central",
		},
		Fields: map[string]string{
			"spec.nodeName": "worker-1", "status.phase": "Running",
		},
		VisibleText: []string{"Ready", "api"},
	}
}

type selectorRecordingClient struct {
	delegate *scriptedResource

	mu           sync.Mutex
	listOptions  []metav1.ListOptions
	watchOptions []metav1.ListOptions
}

func newSelectorRecordingClient() *selectorRecordingClient {
	return &selectorRecordingClient{delegate: newScriptedResource()}
}

func (c *selectorRecordingClient) List(
	ctx context.Context,
	options metav1.ListOptions,
) (*unstructured.UnstructuredList, error) {
	c.mu.Lock()
	c.listOptions = append(c.listOptions, options)
	c.mu.Unlock()
	return c.delegate.List(ctx, options)
}

func (c *selectorRecordingClient) Watch(
	ctx context.Context,
	options metav1.ListOptions,
) (watch.Interface, error) {
	c.mu.Lock()
	c.watchOptions = append(c.watchOptions, options)
	c.mu.Unlock()
	return c.delegate.Watch(ctx, options)
}

func (c *selectorRecordingClient) snapshots() ([]metav1.ListOptions, []metav1.ListOptions) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]metav1.ListOptions(nil), c.listOptions...),
		append([]metav1.ListOptions(nil), c.watchOptions...)
}
