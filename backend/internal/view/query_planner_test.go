package view

import (
	"context"
	"errors"
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

func TestPlanViewQueryCanonicalizesAndMergesExplicitAndDerivedSelectors(t *testing.T) {
	t.Parallel()
	spec := &kmgrv1.ViewSpec{
		Resource: &kmgrv1.ResourceType{
			Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true,
		},
		LabelSelector: `tier in (frontend,api),app==web,app=web,!debug,zone notin (west,east)`,
		FieldSelector: `metadata.name==pod\,one,spec.nodeName!=old`,
		FilterExpression: strings.Join([]string{
			`label:team`,
			`label:app==web`,
			`label:app=WEB`,
			`label:bad$key`,
			`label:bad==bad/value`,
			`field:metadata.name=="pod,one"`,
			`field:metadata.namespace==ns`,
			`field:spec.nodeName=="node=one"`,
			`field:status.phase==Running`,
			`field:metadata.uid`,
			`name:pod`,
			`ready`,
		}, " "),
	}

	plan, err := planViewQuery(spec)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := plan.labelSelector, `!debug,app=web,team,tier in (api,frontend),zone notin (east,west)`; got != want {
		t.Fatalf("label selector = %q, want %q", got, want)
	}
	if got, want := plan.fieldSelector, `metadata.name=pod\,one,metadata.namespace=ns,spec.nodeName!=old,spec.nodeName=node\=one`; got != want {
		t.Fatalf("field selector = %q, want %q", got, want)
	}

	candidate := viewFilterCandidateForPlannerTest()
	if !plan.filter.Match(candidate) {
		t.Fatal("complete local filter did not match its candidate")
	}
	candidate.Labels["app"] = "Web"
	if plan.filter.Match(candidate) {
		t.Fatal("pushed exact label term was not retained for local correctness")
	}
}

func TestPlanViewQueryPushesOnlyApprovedFieldTerms(t *testing.T) {
	t.Parallel()
	filterExpression := strings.Join([]string{
		`field:metadata.name==n`,
		`field:metadata.namespace==ns`,
		`field:spec.nodeName==node`,
		`field:involvedObject.uid==uid`,
		`field:status.phase==Running`,
		`field:spec.nodeName=partial`,
		`field:metadata.uid`,
	}, " ")
	tests := []struct {
		name     string
		resource *kmgrv1.ResourceType
		want     string
	}{
		{
			name: "core Pod",
			resource: &kmgrv1.ResourceType{
				Version: "v1", Resource: "pods", Namespaced: true,
			},
			want: `metadata.name=n,metadata.namespace=ns,spec.nodeName=node`,
		},
		{
			name: "core Event",
			resource: &kmgrv1.ResourceType{
				Version: "v1", Resource: "events", Namespaced: true,
			},
			want: `involvedObject.uid=uid,metadata.name=n,metadata.namespace=ns`,
		},
		{
			name: "namespaced CRD",
			resource: &kmgrv1.ResourceType{
				Group: "example.io", Version: "v1", Resource: "widgets", Namespaced: true,
			},
			want: `metadata.name=n,metadata.namespace=ns`,
		},
		{
			name: "cluster scoped resource",
			resource: &kmgrv1.ResourceType{
				Version: "v1", Resource: "nodes",
			},
			want: `metadata.name=n`,
		},
		{
			name: "non-core Pod GVR",
			resource: &kmgrv1.ResourceType{
				Group: "example.io", Version: "v1", Resource: "pods", Namespaced: true,
			},
			want: `metadata.name=n,metadata.namespace=ns`,
		},
		{
			name: "events.k8s.io Event",
			resource: &kmgrv1.ResourceType{
				Group: "events.k8s.io", Version: "v1", Resource: "events", Namespaced: true,
			},
			want: `metadata.name=n,metadata.namespace=ns`,
		},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			plan, err := planViewQuery(&kmgrv1.ViewSpec{
				Resource: test.resource, FilterExpression: filterExpression,
			})
			if err != nil {
				t.Fatal(err)
			}
			if plan.fieldSelector != test.want {
				t.Fatalf("field selector = %q, want %q", plan.fieldSelector, test.want)
			}
		})
	}
}

func TestPlanViewQueryPushesOnlyKubernetesValidLabelTerms(t *testing.T) {
	t.Parallel()
	plan, err := planViewQuery(&kmgrv1.ViewSpec{
		Resource: &kmgrv1.ResourceType{
			Group: "example.io", Version: "v1", Resource: "widgets", Namespaced: true,
		},
		FilterExpression: strings.Join([]string{
			`label:valid`,
			`label:app==API`,
			`label:app=api`,
			`label:bad$key`,
			`label:valid==bad/value`,
		}, " "),
	})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := plan.labelSelector, `app=API,valid`; got != want {
		t.Fatalf("label selector = %q, want %q", got, want)
	}
}

func TestPlanViewQueryDeduplicatesOnlyIdenticalRequirements(t *testing.T) {
	t.Parallel()
	plan, err := planViewQuery(&kmgrv1.ViewSpec{
		Resource: &kmgrv1.ResourceType{
			Version: "v1", Resource: "pods", Namespaced: true,
		},
		LabelSelector:    `app in (web,api),app!=old,app==api`,
		FieldSelector:    `metadata.name==api,metadata.name=api`,
		FilterExpression: `label:app label:app==api label:app==api field:metadata.name==api`,
	})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := plan.labelSelector, `app,app in (api,web),app!=old,app=api`; got != want {
		t.Fatalf("label selector = %q, want %q", got, want)
	}
	if got, want := plan.fieldSelector, `metadata.name=api`; got != want {
		t.Fatalf("field selector = %q, want %q", got, want)
	}
}

func TestPlanViewQueryRejectsInvalidExplicitSelectors(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		labels string
		fields string
		want   string
	}{
		{name: "label", labels: `app in (`, want: "parse label selector"},
		{name: "field", fields: `metadata.name`, want: "parse field selector"},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			_, err := planViewQuery(&kmgrv1.ViewSpec{
				Resource:      &kmgrv1.ResourceType{Version: "v1", Resource: "pods", Namespaced: true},
				LabelSelector: test.labels,
				FieldSelector: test.fields,
			})
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want containing %q", err, test.want)
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
		FilterExpression: `label:app==api`,
	}
	plan, err := planViewQuery(spec)
	if err != nil {
		t.Fatal(err)
	}
	projector, err := projectorFromProto("session", spec, nil, plan.filter)
	if err != nil {
		t.Fatal(err)
	}
	if projector.filter != plan.filter {
		t.Fatal("projector did not reuse the query planner's compiled filter")
	}
}

func TestRuntimeUsesCanonicalPlannedSelectorsForSharingAndListWatch(t *testing.T) {
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
	firstRequest.Spec.LabelSelector = `env=prod,app==api`
	firstRequest.Spec.FilterExpression = strings.Join([]string{
		`label:team`, `label:app==api`, `field:spec.nodeName==node-a`, `name:first`,
	}, " ")
	first, err := runtime.Open(firstRequest)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	eventually(t, time.Second, func() bool { return client.delegate.watchCalls.Load() == 1 })

	secondRequest := openView("session-2", "pods-2", 1)
	secondRequest.Spec.LabelSelector = `app=api,env==prod`
	secondRequest.Spec.FilterExpression = strings.Join([]string{
		`name:second`, `field:spec.nodeName==node-a`, `label:app==api`, `label:team`,
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
		if got, want := options.LabelSelector, `app=api,env=prod,team`; got != want {
			t.Fatalf("%s label selector = %q, want %q", operation, got, want)
		}
		if got, want := options.FieldSelector, `spec.nodeName=node-a`; got != want {
			t.Fatalf("%s field selector = %q, want %q", operation, got, want)
		}
	}

	thirdRequest := openView("session-3", "pods-3", 1)
	thirdRequest.Spec.LabelSelector = `env=prod`
	thirdRequest.Spec.FilterExpression = strings.Join([]string{
		`label:team`, `label:app==web`, `field:spec.nodeName==node-a`,
	}, " ")
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

func TestRuntimeRejectsInvalidExplicitSelectorBeforeOpeningResource(t *testing.T) {
	t.Parallel()
	source := &fakeResourceSource{authority: "cluster-a", client: newScriptedResource()}
	runtime, err := NewRuntime(RuntimeConfig{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	request := openView("session", "pods", 1)
	request.Spec.LabelSelector = `app in (`
	if _, err := runtime.Open(request); !errors.Is(err, ErrInvalidView) {
		t.Fatalf("Open error = %v, want ErrInvalidView", err)
	}
	if got := source.opens.Load(); got != 0 {
		t.Fatalf("resource opens after invalid selector = %d, want 0", got)
	}
}

func viewFilterCandidateForPlannerTest() viewfilter.Candidate {
	return viewfilter.Candidate{
		Namespace: "ns",
		Name:      "pod-one",
		Labels: map[string]string{
			"team": "platform", "app": "web", "bad$key": "present", "bad": "bad/value",
		},
		Fields: map[string]string{
			"metadata.name": "pod,one", "metadata.namespace": "ns",
			"spec.nodeName": "node=one", "status.phase": "Running", "metadata.uid": "uid",
		},
		VisibleText: []string{"Ready"},
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
