package cluster

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	apidiscoveryv2 "k8s.io/api/apidiscovery/v2"
	apidiscoveryv2beta1 "k8s.io/api/apidiscovery/v2beta1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/metadata"
	"k8s.io/client-go/rest"
)

func TestDiscoverResourcesFiltersSubresourcesAndNonListableKinds(t *testing.T) {
	t.Parallel()
	session := discoveryTestSession(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api":
			writeDiscoveryJSON(t, writer, &metav1.APIVersions{Versions: []string{"v1"}})
		case "/apis":
			writeDiscoveryJSON(t, writer, &metav1.APIGroupList{Groups: []metav1.APIGroup{{
				Name:             "apps",
				Versions:         []metav1.GroupVersionForDiscovery{{GroupVersion: "apps/v1", Version: "v1"}},
				PreferredVersion: metav1.GroupVersionForDiscovery{GroupVersion: "apps/v1", Version: "v1"},
			}}})
		case "/api/v1":
			writeDiscoveryJSON(t, writer, &metav1.APIResourceList{
				GroupVersion: "v1", APIResources: []metav1.APIResource{
					{Name: "pods", Kind: "Pod", Namespaced: true, Verbs: metav1.Verbs{"watch", "list", "get"}, ShortNames: []string{"po"}},
					{Name: "pods/status", Kind: "Pod", Namespaced: true, Verbs: metav1.Verbs{"get"}},
					{Name: "bindings", Kind: "Binding", Namespaced: true, Verbs: metav1.Verbs{"create"}},
				},
			})
		case "/apis/apps/v1":
			writeDiscoveryJSON(t, writer, &metav1.APIResourceList{
				GroupVersion: "apps/v1", APIResources: []metav1.APIResource{
					{Name: "deployments", Kind: "Deployment", Namespaced: true, Verbs: metav1.Verbs{"list", "watch"}, Categories: []string{"all"}},
				},
			})
		default:
			http.NotFound(writer, request)
		}
	}))

	result, err := DiscoverResources(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if result.PotentiallyIncomplete || len(result.Failures) != 0 {
		t.Fatalf("unexpected partial result = %#v", result)
	}
	if len(result.Resources) != 2 {
		t.Fatalf("resources = %#v", result.Resources)
	}
	if result.Resources[0].Resource != "pods" || result.Resources[1].Resource != "deployments" {
		t.Fatalf("resource order = %#v", result.Resources)
	}
	if !result.Resources[0].PreferredVersion || !result.Resources[1].PreferredVersion {
		t.Fatalf("preferred flags = %#v", result.Resources)
	}
	if result.Revision == "" {
		t.Fatal("empty discovery revision")
	}
}

func TestDiscoveryRevisionIncludesEveryCatalogBehaviorField(t *testing.T) {
	t.Parallel()
	base := APIResource{
		Group:            "autoscaling",
		Version:          "v2",
		Resource:         "horizontalpodautoscalers",
		Kind:             "HorizontalPodAutoscaler",
		Namespaced:       true,
		Verbs:            []string{"get", "list", "watch"},
		ShortNames:       []string{"hpa"},
		Categories:       []string{"all"},
		PreferredVersion: true,
	}
	baseRevision := discoveryRevision([]APIResource{base})
	tests := []struct {
		name   string
		mutate func(*APIResource)
	}{
		{name: "group", mutate: func(value *APIResource) { value.Group = "scaling.example.io" }},
		{name: "version", mutate: func(value *APIResource) { value.Version = "v1" }},
		{name: "resource", mutate: func(value *APIResource) { value.Resource = "autoscalers" }},
		{name: "kind", mutate: func(value *APIResource) { value.Kind = "Autoscaler" }},
		{name: "scope", mutate: func(value *APIResource) { value.Namespaced = false }},
		{name: "preferred version", mutate: func(value *APIResource) { value.PreferredVersion = false }},
		{name: "verbs", mutate: func(value *APIResource) { value.Verbs = []string{"get", "list"} }},
		{name: "short names", mutate: func(value *APIResource) { value.ShortNames = []string{"autoscale"} }},
		{name: "categories", mutate: func(value *APIResource) { value.Categories = []string{"scaling"} }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			changed := base
			changed.Verbs = slices.Clone(base.Verbs)
			changed.ShortNames = slices.Clone(base.ShortNames)
			changed.Categories = slices.Clone(base.Categories)
			test.mutate(&changed)
			if got := discoveryRevision([]APIResource{changed}); got == baseRevision {
				t.Fatalf("revision did not change after %s changed: %q", test.name, got)
			}
		})
	}
}

func TestDiscoverResourcesKeepsPartialListsAndReportsFailedGroup(t *testing.T) {
	t.Parallel()
	secretResponse := "credential=never-forward-this"
	session := discoveryTestSession(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api":
			writeDiscoveryJSON(t, writer, &metav1.APIVersions{Versions: []string{"v1"}})
		case "/apis":
			writeDiscoveryJSON(t, writer, &metav1.APIGroupList{Groups: []metav1.APIGroup{{
				Name:             "broken.example.io",
				Versions:         []metav1.GroupVersionForDiscovery{{GroupVersion: "broken.example.io/v1", Version: "v1"}},
				PreferredVersion: metav1.GroupVersionForDiscovery{GroupVersion: "broken.example.io/v1", Version: "v1"},
			}}})
		case "/api/v1":
			writeDiscoveryJSON(t, writer, &metav1.APIResourceList{
				GroupVersion: "v1", APIResources: []metav1.APIResource{{
					Name: "pods", Kind: "Pod", Namespaced: true, Verbs: metav1.Verbs{"list"},
				}},
			})
		case "/apis/broken.example.io/v1":
			http.Error(writer, secretResponse, http.StatusServiceUnavailable)
		default:
			http.NotFound(writer, request)
		}
	}))

	result, err := DiscoverResources(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if !result.PotentiallyIncomplete || len(result.Failures) != 1 {
		t.Fatalf("partial result = %#v", result)
	}
	if result.Failures[0].Target != "broken.example.io/v1" {
		t.Fatalf("failure = %#v", result.Failures[0])
	}
	if len(result.Resources) != 1 || result.Resources[0].Resource != "pods" || result.Revision == "" {
		t.Fatalf("usable resources = %#v, revision=%q", result.Resources, result.Revision)
	}
}

func TestDiscoverResourcesCancelsHangingResourceEndpoint(t *testing.T) {
	t.Parallel()
	requestStarted := make(chan struct{})
	var returned atomic.Bool
	session := discoveryTestSession(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api":
			writeDiscoveryJSON(t, writer, &metav1.APIVersions{Versions: []string{"v1"}})
		case "/apis":
			writeDiscoveryJSON(t, writer, &metav1.APIGroupList{})
		case "/api/v1":
			close(requestStarted)
			<-request.Context().Done()
			returned.Store(true)
		default:
			http.NotFound(writer, request)
		}
	}))

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := DiscoverResources(ctx, session)
		done <- err
	}()
	select {
	case <-requestStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("resource discovery request did not start")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("DiscoverResources error = %v, want context.Canceled", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("DiscoverResources did not return after cancellation")
	}
	deadline := time.Now().Add(2 * time.Second)
	for !returned.Load() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if !returned.Load() {
		t.Fatal("HTTP handler did not observe request cancellation")
	}
}

func TestDiscoverResourcesUsesAggregatedV2WithoutPerGroupRequests(t *testing.T) {
	t.Parallel()
	var requestMu sync.Mutex
	requestPaths := make([]string, 0, 2)
	session := discoveryTestSession(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requestMu.Lock()
		requestPaths = append(requestPaths, request.URL.Path)
		requestMu.Unlock()
		if accept := request.Header.Get("Accept"); accept != aggregatedDiscoveryAcceptHeader {
			t.Errorf("%s Accept = %q, want %q", request.URL.Path, accept, aggregatedDiscoveryAcceptHeader)
		}

		switch request.URL.Path {
		case "/api":
			writeDiscoveryJSONWithContentType(t, writer,
				"application/json; charset=utf-8; as=APIGroupDiscoveryList; v=v2; g=apidiscovery.k8s.io",
				&apidiscoveryv2.APIGroupDiscoveryList{Items: []apidiscoveryv2.APIGroupDiscovery{{
					ObjectMeta: metav1.ObjectMeta{Name: ""},
					Versions: []apidiscoveryv2.APIVersionDiscovery{{
						Version: "v1", Freshness: apidiscoveryv2.DiscoveryFreshnessCurrent,
						Resources: []apidiscoveryv2.APIResourceDiscovery{{
							Resource: "pods", Scope: apidiscoveryv2.ScopeNamespace,
							ResponseKind: &metav1.GroupVersionKind{Version: "v1", Kind: "Pod"},
							Verbs:        []string{"watch", "get", "list"},
							ShortNames:   []string{"po"}, Categories: []string{"all"},
						}},
					}},
				}}})
		case "/apis":
			writeDiscoveryJSONWithContentType(t, writer, discovery.AcceptV2+"; charset=utf-8",
				&apidiscoveryv2.APIGroupDiscoveryList{Items: []apidiscoveryv2.APIGroupDiscovery{
					{
						ObjectMeta: metav1.ObjectMeta{Name: "apps"},
						Versions: []apidiscoveryv2.APIVersionDiscovery{{
							Version: "v1", Freshness: apidiscoveryv2.DiscoveryFreshnessCurrent,
							Resources: []apidiscoveryv2.APIResourceDiscovery{{
								Resource: "deployments", Scope: apidiscoveryv2.ScopeNamespace,
								ResponseKind: &metav1.GroupVersionKind{Group: "apps", Version: "v1", Kind: "Deployment"},
								Verbs:        []string{"list", "watch"},
							}},
						}},
					},
					{
						ObjectMeta: metav1.ObjectMeta{Name: "metrics.k8s.io"},
						Versions: []apidiscoveryv2.APIVersionDiscovery{{
							Version: "v1beta1", Freshness: apidiscoveryv2.DiscoveryFreshnessCurrent,
							Resources: []apidiscoveryv2.APIResourceDiscovery{{
								Resource: "pods", Scope: apidiscoveryv2.ScopeNamespace,
								ResponseKind: &metav1.GroupVersionKind{
									Group: "metrics.k8s.io", Version: "v1beta1", Kind: "PodMetricsList",
								},
								Verbs: []string{"get", "list"},
							}},
						}},
					},
				}})
		default:
			t.Errorf("unexpected per-group discovery request %s", request.URL.Path)
			http.NotFound(writer, request)
		}
	}))

	result, err := DiscoverResources(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if result.PotentiallyIncomplete || len(result.Failures) != 0 {
		t.Fatalf("unexpected partial result = %#v", result)
	}
	if !result.MetricsAPIAvailable {
		t.Fatal("aggregated metrics API resource was not detected")
	}
	if len(result.Resources) != 3 {
		t.Fatalf("resources = %#v", result.Resources)
	}
	pod := result.Resources[0]
	if pod.Group != "" || pod.Version != "v1" || pod.Resource != "pods" || pod.Kind != "Pod" ||
		!pod.Namespaced || !pod.PreferredVersion || !slices.Equal(pod.Verbs, []string{"get", "list", "watch"}) ||
		!slices.Equal(pod.ShortNames, []string{"po"}) || !slices.Equal(pod.Categories, []string{"all"}) {
		t.Fatalf("core resource = %#v", pod)
	}
	requestMu.Lock()
	gotPaths := slices.Clone(requestPaths)
	requestMu.Unlock()
	if !slices.Equal(gotPaths, []string{"/api", "/apis"}) {
		t.Fatalf("request paths = %v, want only aggregated endpoints", gotPaths)
	}
}

func TestDiscoverResourcesDecodesAggregatedV2Beta1(t *testing.T) {
	t.Parallel()
	var requests atomic.Int32
	session := discoveryTestSession(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requests.Add(1)
		switch request.URL.Path {
		case "/api":
			writeDiscoveryJSONWithContentType(t, writer, discovery.AcceptV2Beta1,
				&apidiscoveryv2beta1.APIGroupDiscoveryList{})
		case "/apis":
			writeDiscoveryJSONWithContentType(t, writer, discovery.AcceptV2Beta1,
				&apidiscoveryv2beta1.APIGroupDiscoveryList{Items: []apidiscoveryv2beta1.APIGroupDiscovery{{
					ObjectMeta: metav1.ObjectMeta{Name: "autoscaling"},
					Versions: []apidiscoveryv2beta1.APIVersionDiscovery{{
						Version: "v2", Freshness: apidiscoveryv2beta1.DiscoveryFreshnessCurrent,
						Resources: []apidiscoveryv2beta1.APIResourceDiscovery{{
							Resource: "horizontalpodautoscalers", Scope: apidiscoveryv2beta1.ScopeNamespace,
							ResponseKind: &metav1.GroupVersionKind{
								Group: "autoscaling", Version: "v2", Kind: "HorizontalPodAutoscaler",
							},
							Verbs: []string{"list"}, ShortNames: []string{"hpa"},
						}},
					}},
				}}})
		default:
			t.Errorf("unexpected per-group discovery request %s", request.URL.Path)
			http.NotFound(writer, request)
		}
	}))

	result, err := DiscoverResources(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if requests.Load() != 2 || len(result.Resources) != 1 {
		t.Fatalf("requests = %d, result = %#v", requests.Load(), result)
	}
	resource := result.Resources[0]
	if resource.Group != "autoscaling" || resource.Version != "v2" ||
		resource.Resource != "horizontalpodautoscalers" || resource.Kind != "HorizontalPodAutoscaler" ||
		!resource.Namespaced || !resource.PreferredVersion || !slices.Equal(resource.ShortNames, []string{"hpa"}) {
		t.Fatalf("resource = %#v", resource)
	}
}

func TestDiscoverResourcesUsesLegacyPerGroupFallback(t *testing.T) {
	t.Parallel()
	var requestMu sync.Mutex
	requestAccepts := make(map[string]string)
	session := discoveryTestSession(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requestMu.Lock()
		requestAccepts[request.URL.Path] = request.Header.Get("Accept")
		requestMu.Unlock()
		switch request.URL.Path {
		case "/api":
			writeDiscoveryJSON(t, writer, &metav1.APIVersions{Versions: []string{"v1"}})
		case "/apis":
			writeDiscoveryJSON(t, writer, &metav1.APIGroupList{Groups: []metav1.APIGroup{{
				Name:             "apps",
				Versions:         []metav1.GroupVersionForDiscovery{{GroupVersion: "apps/v1", Version: "v1"}},
				PreferredVersion: metav1.GroupVersionForDiscovery{GroupVersion: "apps/v1", Version: "v1"},
			}}})
		case "/api/v1":
			writeDiscoveryJSON(t, writer, &metav1.APIResourceList{GroupVersion: "v1"})
		case "/apis/apps/v1":
			writeDiscoveryJSON(t, writer, &metav1.APIResourceList{
				GroupVersion: "apps/v1", APIResources: []metav1.APIResource{{
					Name: "deployments", Kind: "Deployment", Namespaced: true, Verbs: metav1.Verbs{"list"},
				}},
			})
		default:
			http.NotFound(writer, request)
		}
	}))

	result, err := DiscoverResources(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Resources) != 1 || result.Resources[0].Resource != "deployments" {
		t.Fatalf("resources = %#v", result.Resources)
	}
	requestMu.Lock()
	gotAccepts := make(map[string]string, len(requestAccepts))
	for path, accept := range requestAccepts {
		gotAccepts[path] = accept
	}
	requestMu.Unlock()
	if len(gotAccepts) != 4 {
		t.Fatalf("request Accept headers = %#v", gotAccepts)
	}
	for _, path := range []string{"/api", "/apis"} {
		if gotAccepts[path] != aggregatedDiscoveryAcceptHeader {
			t.Errorf("%s Accept = %q, want %q", path, gotAccepts[path], aggregatedDiscoveryAcceptHeader)
		}
	}
	for _, path := range []string{"/api/v1", "/apis/apps/v1"} {
		if gotAccepts[path] != discovery.AcceptV1 {
			t.Errorf("%s Accept = %q, want %q", path, gotAccepts[path], discovery.AcceptV1)
		}
	}
}

func TestDiscoverResourcesFallsBackOnlyForStaleAggregatedVersions(t *testing.T) {
	t.Parallel()
	var requestMu sync.Mutex
	requestPaths := make([]string, 0, 3)
	session := discoveryTestSession(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requestMu.Lock()
		requestPaths = append(requestPaths, request.URL.Path)
		requestMu.Unlock()
		switch request.URL.Path {
		case "/api":
			writeDiscoveryJSONWithContentType(t, writer, discovery.AcceptV2,
				&apidiscoveryv2.APIGroupDiscoveryList{})
		case "/apis":
			writeDiscoveryJSONWithContentType(t, writer, discovery.AcceptV2,
				&apidiscoveryv2.APIGroupDiscoveryList{Items: []apidiscoveryv2.APIGroupDiscovery{
					{
						ObjectMeta: metav1.ObjectMeta{Name: "apps"},
						Versions: []apidiscoveryv2.APIVersionDiscovery{
							{Version: "v1", Freshness: apidiscoveryv2.DiscoveryFreshnessStale},
							{
								Version: "v1beta1", Freshness: apidiscoveryv2.DiscoveryFreshnessCurrent,
								Resources: []apidiscoveryv2.APIResourceDiscovery{{
									Resource: "deployments", Scope: apidiscoveryv2.ScopeNamespace,
									ResponseKind: &metav1.GroupVersionKind{
										Group: "apps", Version: "v1beta1", Kind: "Deployment",
									},
									Verbs: []string{"list"},
								}},
							},
						},
					},
					{
						ObjectMeta: metav1.ObjectMeta{Name: "batch"},
						Versions: []apidiscoveryv2.APIVersionDiscovery{{
							Version: "v1", Freshness: apidiscoveryv2.DiscoveryFreshnessCurrent,
							Resources: []apidiscoveryv2.APIResourceDiscovery{{
								Resource: "jobs", Scope: apidiscoveryv2.ScopeNamespace,
								ResponseKind: &metav1.GroupVersionKind{Group: "batch", Version: "v1", Kind: "Job"},
								Verbs:        []string{"list"},
							}},
						}},
					},
				}})
		case "/apis/apps/v1":
			if accept := request.Header.Get("Accept"); accept != discovery.AcceptV1 {
				t.Errorf("stale fallback Accept = %q, want %q", accept, discovery.AcceptV1)
			}
			writeDiscoveryJSON(t, writer, &metav1.APIResourceList{
				GroupVersion: "apps/v1", APIResources: []metav1.APIResource{{
					Name: "deployments", Kind: "Deployment", Namespaced: true, Verbs: metav1.Verbs{"list"},
				}},
			})
		default:
			t.Errorf("unexpected current-version fallback request %s", request.URL.Path)
			http.NotFound(writer, request)
		}
	}))

	result, err := DiscoverResources(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if result.PotentiallyIncomplete || len(result.Resources) != 3 {
		t.Fatalf("result = %#v", result)
	}
	for _, resource := range result.Resources {
		if resource.Group == "apps" && resource.Version == "v1" && !resource.PreferredVersion {
			t.Fatalf("stale preferred version lost preference after fallback: %#v", resource)
		}
		if resource.Group == "apps" && resource.Version == "v1beta1" && resource.PreferredVersion {
			t.Fatalf("non-preferred current version marked preferred: %#v", resource)
		}
	}
	requestMu.Lock()
	gotPaths := slices.Clone(requestPaths)
	requestMu.Unlock()
	if !slices.Equal(gotPaths, []string{"/api", "/apis", "/apis/apps/v1"}) {
		t.Fatalf("request paths = %v", gotPaths)
	}
}

func TestDiscoverResourcesReportsFailedStaleFallbackWithCurrentAggregatedData(t *testing.T) {
	t.Parallel()
	session := discoveryTestSession(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api":
			writeDiscoveryJSONWithContentType(t, writer, discovery.AcceptV2,
				&apidiscoveryv2.APIGroupDiscoveryList{})
		case "/apis":
			writeDiscoveryJSONWithContentType(t, writer, discovery.AcceptV2,
				&apidiscoveryv2.APIGroupDiscoveryList{Items: []apidiscoveryv2.APIGroupDiscovery{
					{
						ObjectMeta: metav1.ObjectMeta{Name: "broken.example.io"},
						Versions: []apidiscoveryv2.APIVersionDiscovery{{
							Version: "v1", Freshness: apidiscoveryv2.DiscoveryFreshnessStale,
						}},
					},
					{
						ObjectMeta: metav1.ObjectMeta{Name: "apps"},
						Versions: []apidiscoveryv2.APIVersionDiscovery{{
							Version: "v1", Freshness: apidiscoveryv2.DiscoveryFreshnessCurrent,
							Resources: []apidiscoveryv2.APIResourceDiscovery{{
								Resource: "deployments", Scope: apidiscoveryv2.ScopeNamespace,
								ResponseKind: &metav1.GroupVersionKind{Group: "apps", Version: "v1", Kind: "Deployment"},
								Verbs:        []string{"list"},
							}},
						}},
					},
				}})
		case "/apis/broken.example.io/v1":
			http.Error(writer, "credential=must-not-appear", http.StatusServiceUnavailable)
		default:
			http.NotFound(writer, request)
		}
	}))

	result, err := DiscoverResources(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if !result.PotentiallyIncomplete || len(result.Failures) != 1 ||
		result.Failures[0].Target != "broken.example.io/v1" {
		t.Fatalf("failures = %#v", result.Failures)
	}
	if len(result.Resources) != 1 || result.Resources[0].Resource != "deployments" {
		t.Fatalf("usable resources = %#v", result.Resources)
	}
}

func TestDiscoverResourcesDoesNotRelabelCurrentVersionAfterPreferredFallbackFails(t *testing.T) {
	t.Parallel()
	session := discoveryTestSession(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api":
			writeDiscoveryJSONWithContentType(t, writer, discovery.AcceptV2,
				&apidiscoveryv2.APIGroupDiscoveryList{})
		case "/apis":
			writeDiscoveryJSONWithContentType(t, writer, discovery.AcceptV2,
				&apidiscoveryv2.APIGroupDiscoveryList{Items: []apidiscoveryv2.APIGroupDiscovery{{
					ObjectMeta: metav1.ObjectMeta{Name: "apps"},
					Versions: []apidiscoveryv2.APIVersionDiscovery{
						{Version: "v1", Freshness: apidiscoveryv2.DiscoveryFreshnessStale},
						{
							Version: "v1beta1", Freshness: apidiscoveryv2.DiscoveryFreshnessCurrent,
							Resources: []apidiscoveryv2.APIResourceDiscovery{{
								Resource: "deployments", Scope: apidiscoveryv2.ScopeNamespace,
								ResponseKind: &metav1.GroupVersionKind{
									Group: "apps", Version: "v1beta1", Kind: "Deployment",
								},
								Verbs: []string{"list"},
							}},
						},
					},
				}}})
		case "/apis/apps/v1":
			http.Error(writer, "unavailable", http.StatusServiceUnavailable)
		default:
			http.NotFound(writer, request)
		}
	}))

	result, err := DiscoverResources(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if !result.PotentiallyIncomplete || len(result.Failures) != 1 || len(result.Resources) != 1 {
		t.Fatalf("result = %#v", result)
	}
	if resource := result.Resources[0]; resource.Version != "v1beta1" || resource.PreferredVersion {
		t.Fatalf("current fallback version was relabeled preferred: %#v", resource)
	}
}

func TestDiscoverResourcesRejectsAggregatedBodyWithoutNegotiatedContentType(t *testing.T) {
	t.Parallel()
	session := discoveryTestSession(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api":
			http.NotFound(writer, request)
		case "/apis":
			// A proxy that strips the aggregated media-type parameters must not
			// make an aggregated document look like a valid empty legacy catalog.
			writeDiscoveryJSON(t, writer, &apidiscoveryv2.APIGroupDiscoveryList{})
		default:
			http.NotFound(writer, request)
		}
	}))

	_, err := DiscoverResources(context.Background(), session)
	if err == nil || !strings.Contains(err.Error(), `missing "groups"`) {
		t.Fatalf("DiscoverResources error = %v, want invalid legacy document shape", err)
	}
}

func TestDiscoverResourcesRejectsMalformedDiscoveryContentType(t *testing.T) {
	t.Parallel()
	session := discoveryTestSession(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api":
			http.NotFound(writer, request)
		case "/apis":
			writer.Header().Set("Content-Type", `application/json; broken`)
			_, _ = writer.Write([]byte(`{"groups":[]}`))
		default:
			http.NotFound(writer, request)
		}
	}))

	_, err := DiscoverResources(context.Background(), session)
	if err == nil || !strings.Contains(err.Error(), "invalid media") {
		t.Fatalf("DiscoverResources error = %v, want malformed content type", err)
	}
}

func discoveryTestSession(t *testing.T, handler http.Handler) *Session {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if authorization := request.Header.Get("Authorization"); authorization != "Bearer discovery-test-token" {
			t.Errorf("Authorization header = %q, want discovery client bearer token", authorization)
			http.Error(writer, "unauthorized", http.StatusUnauthorized)
			return
		}
		handler.ServeHTTP(writer, request)
	}))
	t.Cleanup(server.Close)
	client, err := discovery.NewDiscoveryClientForConfig(&rest.Config{
		Host: server.URL, BearerToken: "discovery-test-token",
	})
	if err != nil {
		t.Fatal(err)
	}
	return &Session{backend: &sharedBackend{clients: BackendClients{Discovery: client}}}
}

func writeDiscoveryJSON(t *testing.T, writer http.ResponseWriter, value any) {
	t.Helper()
	writeDiscoveryJSONWithContentType(t, writer, "application/json", value)
}

func writeDiscoveryJSONWithContentType(
	t *testing.T,
	writer http.ResponseWriter,
	contentType string,
	value any,
) {
	t.Helper()
	writer.Header().Set("Content-Type", contentType)
	if err := json.NewEncoder(writer).Encode(value); err != nil {
		t.Errorf("encode discovery response: %v", err)
	}
}

func TestListNamespacesPaginatesSortsAndDeduplicates(t *testing.T) {
	t.Parallel()
	queries := make(chan url.Values, 2)
	accepts := make(chan string, 2)
	session := namespaceTestSession(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/api/v1/namespaces" {
			http.NotFound(writer, request)
			return
		}
		query := request.URL.Query()
		queries <- query
		accepts <- request.Header.Get("Accept")
		switch query.Get("continue") {
		case "":
			writeNamespaceList(t, writer, "namespace-next", "z")
		case "namespace-next":
			writeNamespaceList(t, writer, "", "a", "z")
		default:
			t.Errorf("unexpected namespace continuation %q", query.Get("continue"))
			http.Error(writer, "bad continuation", http.StatusBadRequest)
		}
	}))
	namespaces, err := ListNamespaces(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(namespaces, []string{"a", "z"}) {
		t.Fatalf("namespaces = %v", namespaces)
	}
	first, second := <-queries, <-queries
	if first.Get("limit") != "500" || first.Get("continue") != "" ||
		second.Get("limit") != "500" || second.Get("continue") != "namespace-next" {
		t.Fatalf("namespace queries = %#v, %#v", first, second)
	}
	firstAccept, secondAccept := <-accepts, <-accepts
	if !strings.Contains(firstAccept, "as=PartialObjectMetadataList") ||
		!strings.Contains(secondAccept, "as=PartialObjectMetadataList") {
		t.Fatalf("namespace Accept headers = %q, %q", firstAccept, secondAccept)
	}
}

func TestListNamespacesRequiresMetadataClient(t *testing.T) {
	t.Parallel()
	session := &Session{backend: &sharedBackend{}}
	const want = "cluster session metadata client is unavailable"

	if _, err := ListNamespaces(context.Background(), session); err == nil || err.Error() != want {
		t.Fatalf("ListNamespaces error = %v, want %q", err, want)
	}
	if _, err := session.ListNamespacesCached(context.Background()); err == nil || err.Error() != want {
		t.Fatalf("ListNamespacesCached error = %v, want %q", err, want)
	}
}

func TestListNamespacesRejectsRepeatedContinuationAndHonorsCancellation(t *testing.T) {
	t.Parallel()
	var repeatedCalls atomic.Int32
	repeated := namespaceTestSession(t, http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		repeatedCalls.Add(1)
		writeNamespaceList(t, writer, "sensitive-token")
	}))
	_, err := ListNamespaces(context.Background(), repeated)
	if err == nil || !strings.Contains(err.Error(), "repeated continuation") ||
		strings.Contains(err.Error(), "sensitive-token") || repeatedCalls.Load() != 2 {
		t.Fatalf("repeated-token error = %v, calls = %d", err, repeatedCalls.Load())
	}

	ctx, cancel := context.WithCancel(context.Background())
	var cancelledCalls atomic.Int32
	cancelled := namespaceTestSession(t, http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		cancelledCalls.Add(1)
		cancel()
		writeNamespaceList(t, writer, "next")
	}))
	_, err = ListNamespaces(ctx, cancelled)
	if !errors.Is(err, context.Canceled) || cancelledCalls.Load() != 1 {
		t.Fatalf("cancellation error = %v, calls = %d", err, cancelledCalls.Load())
	}
}

func namespaceTestSession(t *testing.T, handler http.Handler) *Session {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	client, err := metadata.NewForConfig(&rest.Config{Host: server.URL})
	if err != nil {
		t.Fatal(err)
	}
	return &Session{backend: &sharedBackend{clients: BackendClients{Metadata: client}}}
}

func writeNamespaceList(t *testing.T, writer http.ResponseWriter, continuation string, names ...string) {
	t.Helper()
	items := make([]map[string]any, 0, len(names))
	for _, name := range names {
		items = append(items, map[string]any{
			"apiVersion": "meta.k8s.io/v1", "kind": "PartialObjectMetadata",
			"metadata": map[string]any{"name": name},
		})
	}
	writeDiscoveryJSON(t, writer, map[string]any{
		"apiVersion": "meta.k8s.io/v1", "kind": "PartialObjectMetadataList",
		"metadata": map[string]any{"continue": continuation, "resourceVersion": "1"},
		"items":    items,
	})
}
