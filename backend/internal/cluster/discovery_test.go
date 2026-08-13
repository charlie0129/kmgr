package cluster

import (
	"context"
	"slices"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/discovery/fake"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	clienttesting "k8s.io/client-go/testing"
)

func TestDiscoverResourcesFiltersSubresourcesAndNonListableKinds(t *testing.T) {
	t.Parallel()
	discovery := &fake.FakeDiscovery{Fake: &clienttesting.Fake{}}
	discovery.Resources = []*metav1.APIResourceList{
		{GroupVersion: "v1", APIResources: []metav1.APIResource{
			{Name: "pods", Kind: "Pod", Namespaced: true, Verbs: metav1.Verbs{"watch", "list", "get"}, ShortNames: []string{"po"}},
			{Name: "pods/status", Kind: "Pod", Namespaced: true, Verbs: metav1.Verbs{"get"}},
			{Name: "bindings", Kind: "Binding", Namespaced: true, Verbs: metav1.Verbs{"create"}},
		}},
		{GroupVersion: "apps/v1", APIResources: []metav1.APIResource{
			{Name: "deployments", Kind: "Deployment", Namespaced: true, Verbs: metav1.Verbs{"list", "watch"}, Categories: []string{"all"}},
		}},
	}
	session := &Session{backend: &sharedBackend{clients: BackendClients{Discovery: discovery}}}
	resources, revision, err := DiscoverResources(context.Background(), session)
	if err != nil {
		t.Fatal(err)
	}
	if len(resources) != 2 {
		t.Fatalf("resources = %#v", resources)
	}
	if resources[0].Resource != "pods" || resources[1].Resource != "deployments" {
		t.Fatalf("resource order = %#v", resources)
	}
	if !resources[0].PreferredVersion || !resources[1].PreferredVersion {
		t.Fatalf("preferred flags = %#v", resources)
	}
	if revision == "" {
		t.Fatal("empty discovery revision")
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
