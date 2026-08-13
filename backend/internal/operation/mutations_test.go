package operation

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/object"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/dynamic"
)

func TestScaleResourceUsesScaleSubresourceAndResourceVersion(t *testing.T) {
	t.Parallel()
	identity := appsIdentity("deployments")
	current := operationObject(identity, "rv-1")
	scale := operationObject(identity, "rv-1")
	scale.Object["apiVersion"] = "autoscaling/v1"
	scale.Object["kind"] = "Scale"
	scale.Object["spec"] = map[string]any{"replicas": int64(2)}
	resource := &mutationResource{getScale: scale, updateRV: "rv-2"}
	backend := &resourceBackendFake{current: current, resource: resource}
	resourceVersion, err := ScaleResource(context.Background(), backend, identity, "rv-1", 5)
	if err != nil || resourceVersion != "rv-2" {
		t.Fatalf("ScaleResource() = %q, %v", resourceVersion, err)
	}
	if resource.getSubresource != "scale" || resource.updateSubresource != "scale" {
		t.Fatalf("subresources = get %q, update %q", resource.getSubresource, resource.updateSubresource)
	}
	replicas, found, err := unstructured.NestedInt64(resource.updated.Object, "spec", "replicas")
	if err != nil || !found || replicas != 5 || resource.updated.GetResourceVersion() != "rv-1" {
		t.Fatalf("updated scale = %#v", resource.updated.Object)
	}
	_, err = ScaleResource(context.Background(), backend, identity, "stale", 5)
	var conflict *object.ResourceVersionConflictError
	if !errors.As(err, &conflict) || resource.updateCalls != 1 {
		t.Fatalf("stale ScaleResource error = %#v, update calls = %d", err, resource.updateCalls)
	}
}

func TestRestartResourceMutatesOnlyPodTemplateMetadata(t *testing.T) {
	t.Parallel()
	identity := appsIdentity("statefulsets")
	current := operationObject(identity, "rv-1")
	current.Object["spec"] = map[string]any{
		"replicas": int64(3),
		"template": map[string]any{
			"metadata": map[string]any{"annotations": map[string]any{"existing": "keep"}},
			"spec":     map[string]any{"containers": []any{map[string]any{"name": "app", "image": "example:v1"}}},
		},
	}
	resource := &mutationResource{updateRV: "rv-2"}
	backend := &resourceBackendFake{current: current, resource: resource}
	now := time.Date(2026, 8, 13, 12, 34, 56, 999, time.FixedZone("test", 8*60*60))
	resourceVersion, err := RestartResource(context.Background(), backend, identity, "rv-1", now)
	if err != nil || resourceVersion != "rv-2" {
		t.Fatalf("RestartResource() = %q, %v", resourceVersion, err)
	}
	annotations, _, _ := unstructured.NestedStringMap(resource.updated.Object, "spec", "template", "metadata", "annotations")
	if annotations["existing"] != "keep" || annotations[restartedAtAnnotation] != "2026-08-13T04:34:56Z" {
		t.Fatalf("annotations = %#v", annotations)
	}
	if replicas, _, _ := unstructured.NestedInt64(resource.updated.Object, "spec", "replicas"); replicas != 3 {
		t.Fatalf("replicas changed to %d", replicas)
	}
	unsupported := identity
	unsupported.Resource = "replicasets"
	if _, err := RestartResource(context.Background(), backend, unsupported, "rv-1", now); err == nil {
		t.Fatal("ReplicaSet restart unexpectedly succeeded")
	}
}

func TestUpdateResourceMetadataValidatesAndPreservesUnrelatedValues(t *testing.T) {
	t.Parallel()
	identity := appsIdentity("deployments")
	current := operationObject(identity, "rv-1")
	current.SetLabels(map[string]string{"keep": "yes", "remove": "old"})
	current.SetAnnotations(map[string]string{"existing": "yes", "remove": "old"})
	resource := &mutationResource{updateRV: "rv-2"}
	backend := &resourceBackendFake{current: current, resource: resource}
	resourceVersion, err := UpdateResourceMetadata(context.Background(), backend, identity, "rv-1", MetadataChanges{
		Labels: map[string]string{"team": "platform"}, Annotations: map[string]string{"note": "free form"},
		RemoveLabelKeys: []string{"remove"}, RemoveAnnotationKeys: []string{"remove"},
	})
	if err != nil || resourceVersion != "rv-2" {
		t.Fatalf("UpdateResourceMetadata() = %q, %v", resourceVersion, err)
	}
	if labels := resource.updated.GetLabels(); labels["keep"] != "yes" || labels["team"] != "platform" || labels["remove"] != "" {
		t.Fatalf("labels = %#v", labels)
	}
	if annotations := resource.updated.GetAnnotations(); annotations["existing"] != "yes" || annotations["note"] != "free form" || annotations["remove"] != "" {
		t.Fatalf("annotations = %#v", annotations)
	}
	tests := []MetadataChanges{
		{Labels: map[string]string{"bad key": "value"}},
		{Labels: map[string]string{"team": "contains space"}},
		{Labels: map[string]string{"team": "one"}, RemoveLabelKeys: []string{"team"}},
		{RemoveAnnotationKeys: []string{"same", "same"}},
	}
	for _, changes := range tests {
		if err := ValidateMetadataChanges(changes); err == nil {
			t.Fatalf("ValidateMetadataChanges(%#v) succeeded", changes)
		}
	}
}

type resourceBackendFake struct {
	current  *unstructured.Unstructured
	resource dynamic.ResourceInterface
}

func (b *resourceBackendFake) Get(context.Context, object.Identity) (*unstructured.Unstructured, error) {
	return b.current.DeepCopy(), nil
}

func (b *resourceBackendFake) Resource(object.Identity) (dynamic.ResourceInterface, error) {
	return b.resource, nil
}

type mutationResource struct {
	getScale          *unstructured.Unstructured
	updated           *unstructured.Unstructured
	updateRV          string
	getSubresource    string
	updateSubresource string
	updateCalls       int
}

func (r *mutationResource) Get(_ context.Context, _ string, _ metav1.GetOptions, subresources ...string) (*unstructured.Unstructured, error) {
	if len(subresources) > 0 {
		r.getSubresource = subresources[0]
	}
	return r.getScale.DeepCopy(), nil
}

func (r *mutationResource) Update(_ context.Context, value *unstructured.Unstructured, _ metav1.UpdateOptions, subresources ...string) (*unstructured.Unstructured, error) {
	r.updateCalls++
	if len(subresources) > 0 {
		r.updateSubresource = subresources[0]
	}
	r.updated = value.DeepCopy()
	result := value.DeepCopy()
	result.SetResourceVersion(r.updateRV)
	return result, nil
}

func (*mutationResource) Create(context.Context, *unstructured.Unstructured, metav1.CreateOptions, ...string) (*unstructured.Unstructured, error) {
	panic("unexpected Create")
}
func (*mutationResource) UpdateStatus(context.Context, *unstructured.Unstructured, metav1.UpdateOptions) (*unstructured.Unstructured, error) {
	panic("unexpected UpdateStatus")
}
func (*mutationResource) Delete(context.Context, string, metav1.DeleteOptions, ...string) error {
	panic("unexpected Delete")
}
func (*mutationResource) DeleteCollection(context.Context, metav1.DeleteOptions, metav1.ListOptions) error {
	panic("unexpected DeleteCollection")
}
func (*mutationResource) List(context.Context, metav1.ListOptions) (*unstructured.UnstructuredList, error) {
	panic("unexpected List")
}
func (*mutationResource) Watch(context.Context, metav1.ListOptions) (watch.Interface, error) {
	panic("unexpected Watch")
}
func (*mutationResource) Patch(context.Context, string, types.PatchType, []byte, metav1.PatchOptions, ...string) (*unstructured.Unstructured, error) {
	panic("unexpected Patch")
}
func (*mutationResource) Apply(context.Context, string, *unstructured.Unstructured, metav1.ApplyOptions, ...string) (*unstructured.Unstructured, error) {
	panic("unexpected Apply")
}
func (*mutationResource) ApplyStatus(context.Context, string, *unstructured.Unstructured, metav1.ApplyOptions) (*unstructured.Unstructured, error) {
	panic("unexpected ApplyStatus")
}

func appsIdentity(resource string) object.Identity {
	return object.Identity{
		SessionID: "session", Group: "apps", Version: "v1", Resource: resource,
		Namespace: "ns", Name: "workload", UID: "uid",
	}
}

func operationObject(identity object.Identity, resourceVersion string) *unstructured.Unstructured {
	value := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "apps/v1",
		"kind":       "Deployment",
		"metadata": map[string]any{
			"namespace": identity.Namespace, "name": identity.Name, "uid": identity.UID,
			"resourceVersion": resourceVersion,
		},
	}}
	return value
}

var _ dynamic.ResourceInterface = (*mutationResource)(nil)
