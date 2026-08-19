package object

import (
	"context"
	"testing"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

type cachedChildrenStub struct{ values []CachedChild }

func (s cachedChildrenStub) CachedChildren(string, string) []CachedChild { return s.values }

func TestRelationshipsReturnsCachedChildrenMarkedPotentiallyIncomplete(t *testing.T) {
	t.Parallel()
	target := kubernetesObject("v1", "Pod", "pods", "ns", "owner", "owner-uid")
	child := kubernetesObject("v1", "Pod", "pods", "ns", "child", "child-uid")
	child.SetOwnerReferences([]metav1.OwnerReference{{UID: "owner-uid"}})
	wrong := child.DeepCopy()
	wrong.SetName("wrong")
	wrong.SetUID("wrong-uid")
	wrong.SetOwnerReferences([]metav1.OwnerReference{{UID: "other-owner"}})
	reader := testReader(t, target)
	reader.SetCachedChildSource(cachedChildrenStub{values: []CachedChild{
		{Version: "v1", Resource: "pods", Object: child},
		{Version: "v1", Resource: "pods", Object: wrong},
		{Version: "v1", Resource: "pods", Object: (*unstructured.Unstructured)(nil)},
	}})
	values, incomplete, err := reader.Relationships(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "ns",
		Name: "owner", UID: "owner-uid",
	}, false, true)
	if err != nil {
		t.Fatal(err)
	}
	if !incomplete || len(values) != 1 || values[0].Kind != RelationshipChild ||
		values[0].Identity.UID != "child-uid" || !values[0].PotentiallyIncomplete {
		t.Fatalf("relationships = %#v, incomplete=%t", values, incomplete)
	}
}

func TestRelationshipsReportsEmptyCachedChildrenAsPotentiallyIncomplete(t *testing.T) {
	t.Parallel()
	target := kubernetesObject("v1", "Pod", "pods", "ns", "owner", "owner-uid")
	reader := testReader(t, target)
	values, incomplete, err := reader.Relationships(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "ns",
		Name: "owner", UID: "owner-uid",
	}, false, true)
	if err != nil || len(values) != 0 || !incomplete {
		t.Fatalf("relationships = %#v, incomplete=%t, err=%v", values, incomplete, err)
	}
}

func TestResourceForExactKindUsesExactGroupVersionKindAndScope(t *testing.T) {
	t.Parallel()
	resources := []cluster.APIResource{
		{Group: "apps", Version: "v1beta1", Resource: "deployments", Kind: "Deployment", Namespaced: true},
		{Group: "apps", Version: "v1", Resource: "deployments", Kind: "Deployment", Namespaced: true},
		{Group: "example.io", Version: "v1", Resource: "people", Kind: "Person", Namespaced: false},
	}
	deployment, found := resourceForExactKind(resources, schema.GroupVersionKind{
		Group: "apps", Version: "v1", Kind: "Deployment",
	})
	if !found || deployment.Version != "v1" || deployment.Resource != "deployments" || !deployment.Namespaced {
		t.Fatalf("deployment mapping = %#v, found=%t", deployment, found)
	}
	person, found := resourceForExactKind(resources, schema.GroupVersionKind{
		Group: "example.io", Version: "v1", Kind: "Person",
	})
	if !found || person.Resource != "people" || person.Namespaced {
		t.Fatalf("person mapping = %#v, found=%t", person, found)
	}
	if _, found := resourceForExactKind(resources, schema.GroupVersionKind{
		Group: "apps", Version: "v2", Kind: "Deployment",
	}); found {
		t.Fatal("unserved owner version unexpectedly matched another catalog entry")
	}
}
