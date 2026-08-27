package object

import (
	"context"
	"testing"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	"k8s.io/client-go/metadata"
	metadatafake "k8s.io/client-go/metadata/fake"
)

type cachedChildrenStub struct{ values []CachedChild }

func (s cachedChildrenStub) CachedChildren(string, string) []CachedChild { return s.values }

func TestRelationshipsAnchorsSelectedObjectWithMetadataOnlyGet(t *testing.T) {
	t.Parallel()
	target := kubernetesObject("apps/v1", "Deployment", "deployments", "ns", "api", "owner-uid")
	dynamicClient := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), target)
	metadataScheme := metadatafake.NewTestScheme()
	metav1.AddMetaToScheme(metadataScheme)
	metadataClient := metadatafake.NewSimpleMetadataClient(
		metadataScheme, relationshipPartialMetadata(target),
	)
	reader, err := NewReader(relationshipMetadataResolverStub{
		Resolver: fakeResolver{client: dynamicClient}, metadata: metadataClient,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = reader.Relationships(context.Background(), Identity{
		SessionID: "session", Group: "apps", Version: "v1", Resource: "deployments",
		Namespace: "ns", Name: "api", UID: "owner-uid",
	}, false, false)
	if err != nil {
		t.Fatal(err)
	}
	if actions := dynamicClient.Actions(); len(actions) != 0 {
		t.Fatalf("full-object actions = %v, want none", actions)
	}
	actions := metadataClient.Actions()
	if len(actions) != 1 || actions[0].GetVerb() != "get" ||
		actions[0].GetResource() != (schema.GroupVersionResource{
			Group: "apps", Version: "v1", Resource: "deployments",
		}) {
		t.Fatalf("metadata actions = %v, want one exact selected-object GET", actions)
	}
}

func TestRelationshipsReturnsCachedChildrenMarkedPotentiallyIncomplete(t *testing.T) {
	t.Parallel()
	target := kubernetesObject("v1", "Pod", "pods", "ns", "owner", "owner-uid")
	child := kubernetesObject("v1", "Pod", "pods", "ns", "child", "child-uid")
	child.SetOwnerReferences([]metav1.OwnerReference{{UID: "owner-uid"}})
	wrong := child.DeepCopy()
	wrong.SetName("wrong")
	wrong.SetUID("wrong-uid")
	wrong.SetOwnerReferences([]metav1.OwnerReference{{UID: "other-owner"}})
	reader := relationshipTestReader(t, target)
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
	reader := relationshipTestReader(t, target)
	values, incomplete, err := reader.Relationships(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "ns",
		Name: "owner", UID: "owner-uid",
	}, false, true)
	if err != nil || len(values) != 0 || !incomplete {
		t.Fatalf("relationships = %#v, incomplete=%t, err=%v", values, incomplete, err)
	}
}

func TestRelationshipsVerifiesOwnerWithMetadataGet(t *testing.T) {
	t.Parallel()
	controller := true
	target := kubernetesObject("apps/v1", "ReplicaSet", "replicasets", "ns", "api-rs", "child-uid")
	target.SetOwnerReferences([]metav1.OwnerReference{{
		APIVersion: "apps/v1", Kind: "Deployment", Name: "api", UID: "owner-uid",
		Controller: &controller,
	}})
	owner := &metav1.PartialObjectMetadata{
		TypeMeta: metav1.TypeMeta{APIVersion: "apps/v1", Kind: "Deployment"},
		ObjectMeta: metav1.ObjectMeta{
			Namespace: "ns", Name: "api", UID: "owner-uid", ResourceVersion: "rv-owner",
		},
	}
	owner.SetGroupVersionKind(schema.GroupVersionKind{Group: "apps", Version: "v1", Kind: "Deployment"})
	scheme := metadatafake.NewTestScheme()
	metav1.AddMetaToScheme(scheme)
	metadataClient := metadatafake.NewSimpleMetadataClient(
		scheme, relationshipPartialMetadata(target), owner,
	)
	gvr := schema.GroupVersionResource{Group: "apps", Version: "v1", Resource: "deployments"}

	reader := testReader(t, target)
	resolver := &kindMetadataResolverStub{
		Resolver:  reader.resolver,
		metadata:  metadataClient,
		resource:  metadataClient.Resource(gvr).Namespace("ns"),
		gvr:       gvr,
		namespace: "ns",
	}
	reader.resolver = resolver
	values, incomplete, err := reader.Relationships(context.Background(), Identity{
		SessionID: "session", Group: "apps", Version: "v1", Resource: "replicasets",
		Namespace: "ns", Name: "api-rs", UID: "child-uid",
	}, true, false)
	if err != nil {
		t.Fatal(err)
	}
	if incomplete || len(values) != 1 || values[0].Kind != RelationshipOwner ||
		values[0].Identity.UID != "owner-uid" || values[0].Stale || !values[0].Controller {
		t.Fatalf("owner relationships = %#v, incomplete=%t", values, incomplete)
	}
	if resolver.calls != 1 || resolver.requested != (schema.GroupVersionKind{
		Group: "apps", Version: "v1", Kind: "Deployment",
	}) {
		t.Fatalf("metadata kind resolution calls=%d GVK=%s", resolver.calls, resolver.requested)
	}
}

type kindMetadataResolverStub struct {
	Resolver
	metadata  metadata.Interface
	resource  metadata.ResourceInterface
	gvr       schema.GroupVersionResource
	namespace string
	calls     int
	requested schema.GroupVersionKind
}

func (r *kindMetadataResolverStub) MetadataResource(
	_ string,
	gvr schema.GroupVersionResource,
	namespace string,
) (metadata.ResourceInterface, error) {
	resource := r.metadata.Resource(gvr)
	if namespace != "" {
		return resource.Namespace(namespace), nil
	}
	return resource, nil
}

func (r *kindMetadataResolverStub) MetadataForKind(
	_ context.Context,
	_ string,
	gvk schema.GroupVersionKind,
	_ string,
) (metadata.ResourceInterface, schema.GroupVersionResource, string, error) {
	r.calls++
	r.requested = gvk
	return r.resource, r.gvr, r.namespace, nil
}

type relationshipMetadataResolverStub struct {
	Resolver
	metadata metadata.Interface
}

func (r relationshipMetadataResolverStub) MetadataResource(
	_ string,
	gvr schema.GroupVersionResource,
	namespace string,
) (metadata.ResourceInterface, error) {
	resource := r.metadata.Resource(gvr)
	if namespace != "" {
		return resource.Namespace(namespace), nil
	}
	return resource, nil
}

func relationshipTestReader(
	t *testing.T,
	target *unstructured.Unstructured,
) *Reader {
	t.Helper()
	reader := testReader(t, target)
	scheme := metadatafake.NewTestScheme()
	metav1.AddMetaToScheme(scheme)
	client := metadatafake.NewSimpleMetadataClient(
		scheme, relationshipPartialMetadata(target),
	)
	reader.resolver = relationshipMetadataResolverStub{
		Resolver: reader.resolver, metadata: client,
	}
	return reader
}

func relationshipPartialMetadata(
	value *unstructured.Unstructured,
) *metav1.PartialObjectMetadata {
	result := &metav1.PartialObjectMetadata{
		TypeMeta: metav1.TypeMeta{
			APIVersion: value.GetAPIVersion(), Kind: value.GetKind(),
		},
		ObjectMeta: metav1.ObjectMeta{
			Namespace: value.GetNamespace(), Name: value.GetName(),
			UID: value.GetUID(), ResourceVersion: value.GetResourceVersion(),
			OwnerReferences: value.GetOwnerReferences(),
		},
	}
	result.SetGroupVersionKind(value.GroupVersionKind())
	return result
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
