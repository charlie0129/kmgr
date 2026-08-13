package cluster

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/discovery"
	dynamicfake "k8s.io/client-go/dynamic/fake"
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

func TestListNamespacesIsSortedAndUsesOneList(t *testing.T) {
	t.Parallel()
	scheme := runtime.NewScheme()
	listKinds := map[schema.GroupVersionResource]string{{Version: "v1", Resource: "namespaces"}: "NamespaceList"}
	objects := []runtime.Object{
		&unstructured.Unstructured{Object: map[string]any{"apiVersion": "v1", "kind": "Namespace", "metadata": map[string]any{"name": "z"}}},
		&unstructured.Unstructured{Object: map[string]any{"apiVersion": "v1", "kind": "Namespace", "metadata": map[string]any{"name": "a"}}},
	}
	dynamicClient := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(scheme, listKinds, objects...)
	session := &Session{backend: &sharedBackend{clients: BackendClients{Dynamic: dynamicClient}}}
	namespaces, err := ListNamespaces(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(namespaces, []string{"a", "z"}) {
		t.Fatalf("namespaces = %v", namespaces)
	}
}
