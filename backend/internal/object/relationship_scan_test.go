package object

import (
	"context"
	"errors"
	"slices"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/discovery/fake"
	"k8s.io/client-go/dynamic"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	metadatafake "k8s.io/client-go/metadata/fake"
	clienttesting "k8s.io/client-go/testing"
)

type scanTestResolver struct {
	dynamic   dynamic.Interface
	discovery *fake.FakeDiscovery
	metadata  *metadatafake.FakeMetadataClient
}

func (r scanTestResolver) Resource(
	_ string, gvr schema.GroupVersionResource, namespace string,
) (dynamic.ResourceInterface, error) {
	client := r.dynamic.Resource(gvr)
	if namespace != "" {
		return client.Namespace(namespace), nil
	}
	return client, nil
}

func (r scanTestResolver) RelationshipScanSession(string) (RelationshipScanSession, error) {
	return RelationshipScanSession{Discovery: r.discovery, Metadata: r.metadata}, nil
}

func TestScanRelationshipsUsesExactOwnerUIDPreferredVersionsAndNamespace(t *testing.T) {
	t.Parallel()
	target := kubernetesObject("apps/v1", "Deployment", "deployments", "ns", "api", "owner-uid")
	dynamicClient := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), target)
	metadataScheme := metadatafake.NewTestScheme()
	metav1.AddMetaToScheme(metadataScheme)
	child := partialMetadata("apps/v1", "ReplicaSet", "ns", "api-rs", "child-uid", "owner-uid")
	wrongUID := partialMetadata("v1", "Pod", "ns", "same-name-owner", "wrong-child", "replacement-owner-uid")
	otherNamespace := partialMetadata("v1", "Pod", "other", "other", "other-child", "owner-uid")
	metadataClient := metadatafake.NewSimpleMetadataClient(metadataScheme, child, wrongUID, otherNamespace)
	discovery := &fake.FakeDiscovery{Fake: &clienttesting.Fake{}}
	discovery.Resources = []*metav1.APIResourceList{
		{GroupVersion: "apps/v1", APIResources: []metav1.APIResource{
			{Name: "replicasets", Kind: "ReplicaSet", Namespaced: true, Verbs: metav1.Verbs{"list"}},
		}},
		{GroupVersion: "apps/v1beta1", APIResources: []metav1.APIResource{
			{Name: "replicasets", Kind: "ReplicaSet", Namespaced: true, Verbs: metav1.Verbs{"list"}},
		}},
		{GroupVersion: "v1", APIResources: []metav1.APIResource{
			{Name: "pods", Kind: "Pod", Namespaced: true, Verbs: metav1.Verbs{"list"}},
			{Name: "nodes", Kind: "Node", Namespaced: false, Verbs: metav1.Verbs{"list"}},
		}},
	}
	reader, err := NewReader(scanTestResolver{dynamic: dynamicClient, discovery: discovery, metadata: metadataClient})
	if err != nil {
		t.Fatal(err)
	}
	var updates []RelationshipScanUpdate
	err = reader.ScanRelationships(context.Background(), Identity{
		SessionID: "session", Group: "apps", Version: "v1", Resource: "deployments",
		Namespace: "ns", Name: "api", UID: "owner-uid",
	}, func(update RelationshipScanUpdate) error {
		updates = append(updates, update)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	var children []Relationship
	for _, update := range updates {
		children = append(children, update.Relationships...)
	}
	if len(children) != 1 || children[0].Identity.UID != "child-uid" ||
		children[0].Identity.Resource != "replicasets" {
		t.Fatalf("children = %#v", children)
	}
	final := updates[len(updates)-1].Progress
	if !final.Complete || final.PotentiallyIncomplete || final.ResourcesTotal != 2 || final.ObjectsExamined != 2 {
		t.Fatalf("final progress = %#v", final)
	}
	for _, action := range metadataClient.Actions() {
		if action.GetResource().Resource == "nodes" || action.GetNamespace() != "ns" {
			t.Fatalf("unexpected metadata action = %#v", action)
		}
		if action.GetResource().Version == "v1beta1" {
			t.Fatalf("non-preferred version scanned = %#v", action)
		}
	}
}

func TestScanRelationshipsRejectsRecreatedTargetBeforeBulkLists(t *testing.T) {
	t.Parallel()
	target := kubernetesObject("apps/v1", "Deployment", "deployments", "ns", "api", "new-uid")
	metadataScheme := metadatafake.NewTestScheme()
	metav1.AddMetaToScheme(metadataScheme)
	metadataClient := metadatafake.NewSimpleMetadataClient(metadataScheme)
	discovery := &fake.FakeDiscovery{Fake: &clienttesting.Fake{}}
	reader, _ := NewReader(scanTestResolver{
		dynamic:   dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), target),
		discovery: discovery, metadata: metadataClient,
	})
	err := reader.ScanRelationships(context.Background(), Identity{
		SessionID: "session", Group: "apps", Version: "v1", Resource: "deployments",
		Namespace: "ns", Name: "api", UID: "old-uid",
	}, func(RelationshipScanUpdate) error { return nil })
	var changed *IdentityChangedError
	if !errors.As(err, &changed) || changed.ActualUID != "new-uid" {
		t.Fatalf("scan error = %#v", err)
	}
	if len(metadataClient.Actions()) != 0 || len(discovery.Actions()) != 0 {
		t.Fatalf("bulk access occurred before UID guard: metadata=%v discovery=%v",
			metadataClient.Actions(), discovery.Actions())
	}
}

func TestDiscoverRelationshipResourcesSelectsStablePreferredVersion(t *testing.T) {
	t.Parallel()
	discovery := &fake.FakeDiscovery{Fake: &clienttesting.Fake{}}
	discovery.Resources = []*metav1.APIResourceList{
		{GroupVersion: "apps/v1beta1", APIResources: []metav1.APIResource{{Name: "deployments", Kind: "Deployment", Verbs: metav1.Verbs{"list"}}}},
		{GroupVersion: "apps/v1", APIResources: []metav1.APIResource{{Name: "deployments", Kind: "Deployment", Verbs: metav1.Verbs{"list"}}}},
	}
	metadataScheme := metadatafake.NewTestScheme()
	metav1.AddMetaToScheme(metadataScheme)
	resources, incomplete, err := discoverRelationshipResources(context.Background(), RelationshipScanSession{
		Discovery: discovery, Metadata: metadatafake.NewSimpleMetadataClient(metadataScheme),
	})
	if err != nil || incomplete || len(resources) != 1 || resources[0].Version != "v1beta1" {
		// FakeDiscovery declares the first observed version preferred. This test
		// ensures exactly that declared preferred version is honored rather than
		// guessing version order.
		t.Fatalf("resources=%#v incomplete=%t err=%v", resources, incomplete, err)
	}
	if !slices.Equal([]string{resources[0].Group, resources[0].Resource}, []string{"apps", "deployments"}) {
		t.Fatalf("resource = %#v", resources[0])
	}
}

func partialMetadata(
	apiVersion, kind, namespace, name string,
	uid, ownerUID types.UID,
) *metav1.PartialObjectMetadata {
	value := &metav1.PartialObjectMetadata{
		TypeMeta: metav1.TypeMeta{APIVersion: apiVersion, Kind: kind},
		ObjectMeta: metav1.ObjectMeta{
			Namespace: namespace, Name: name, UID: uid,
			OwnerReferences: []metav1.OwnerReference{{UID: ownerUID}},
		},
	}
	value.SetGroupVersionKind(schema.FromAPIVersionAndKind(apiVersion, kind))
	return value
}
