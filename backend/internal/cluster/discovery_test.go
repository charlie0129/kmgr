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
	"sync/atomic"
	"testing"
	"time"

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
	writer.Header().Set("Content-Type", "application/json")
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
