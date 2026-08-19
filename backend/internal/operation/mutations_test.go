package operation

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/object"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/dynamic"
)

func TestScaleResourceUsesOneGuardedScalePatch(t *testing.T) {
	t.Parallel()
	identity := appsIdentity("deployments")
	resource := mutationResourceReturning("rv-2")
	backend := &resourceBackendFake{resource: resource}

	resourceVersion, err := ScaleResource(context.Background(), backend, identity, "rv-1", 5)
	if err != nil || resourceVersion != "rv-2" {
		t.Fatalf("ScaleResource() = %q, %v", resourceVersion, err)
	}
	assertMutationPatch(t, resource, identity.Name, []string{"scale"}, `{
		"metadata":{"uid":"uid","resourceVersion":"rv-1"},
		"spec":{"replicas":5}
	}`)
}

func TestScaleResourceReturnsPatchConflictWithoutAnotherRequest(t *testing.T) {
	t.Parallel()
	identity := appsIdentity("deployments")
	conflict := apierrors.NewConflict(
		schema.GroupResource{Group: "apps", Resource: "deployments/scale"},
		identity.Name,
		errors.New("the object has been modified"),
	)
	resource := &mutationResource{patchErr: conflict}
	backend := &resourceBackendFake{resource: resource}

	_, err := ScaleResource(context.Background(), backend, identity, "stale", 5)
	if err != conflict {
		t.Fatalf("ScaleResource error = %#v, want original conflict %#v", err, conflict)
	}
	if resource.patchCalls != 1 || backend.resourceCalls != 1 {
		t.Fatalf("calls = patch %d, resource %d; want one Kubernetes request", resource.patchCalls, backend.resourceCalls)
	}
}

func TestRestartResourceUsesOneNarrowGuardedPatch(t *testing.T) {
	t.Parallel()
	identity := appsIdentity("statefulsets")
	resource := mutationResourceReturning("rv-2")
	backend := &resourceBackendFake{resource: resource}
	now := time.Date(2026, 8, 13, 12, 34, 56, 999, time.FixedZone("test", 8*60*60))

	resourceVersion, err := RestartResource(context.Background(), backend, identity, "rv-1", now)
	if err != nil || resourceVersion != "rv-2" {
		t.Fatalf("RestartResource() = %q, %v", resourceVersion, err)
	}
	assertMutationPatch(t, resource, identity.Name, nil, `{
		"metadata":{"uid":"uid","resourceVersion":"rv-1"},
		"spec":{"template":{"metadata":{"annotations":{
			"kubectl.kubernetes.io/restartedAt":"2026-08-13T04:34:56Z"
		}}}}
	}`)

	unsupported := identity
	unsupported.Resource = "replicasets"
	if _, err := RestartResource(context.Background(), backend, unsupported, "rv-1", now); err == nil {
		t.Fatal("ReplicaSet restart unexpectedly succeeded")
	}
	if resource.patchCalls != 1 {
		t.Fatalf("unsupported restart made %d additional patch calls", resource.patchCalls-1)
	}
}

func TestUpdateResourceMetadataUsesMergePatchForKeysAndRemovals(t *testing.T) {
	t.Parallel()
	identity := appsIdentity("deployments")
	resource := mutationResourceReturning("rv-2")
	backend := &resourceBackendFake{resource: resource}

	resourceVersion, err := UpdateResourceMetadata(context.Background(), backend, identity, "rv-1", MetadataChanges{
		Labels: map[string]string{
			"example.com/team": "platform",
		},
		Annotations: map[string]string{
			"example.com/note": "line one\n\"quoted\"\\tail",
		},
		RemoveLabelKeys:      []string{"example.com/old-label"},
		RemoveAnnotationKeys: []string{"example.com/old-annotation"},
	})
	if err != nil || resourceVersion != "rv-2" {
		t.Fatalf("UpdateResourceMetadata() = %q, %v", resourceVersion, err)
	}
	assertMutationPatch(t, resource, identity.Name, nil, `{
		"metadata":{
			"uid":"uid",
			"resourceVersion":"rv-1",
			"labels":{
				"example.com/team":"platform",
				"example.com/old-label":null
			},
			"annotations":{
				"example.com/note":"line one\n\"quoted\"\\tail",
				"example.com/old-annotation":null
			}
		}
	}`)
	if !strings.Contains(string(resource.patch), `line one\n\"quoted\"\\tail`) {
		t.Fatalf("annotation was not safely JSON-escaped: %s", resource.patch)
	}
}

func TestUpdateResourceMetadataValidatesBeforeCallingAPI(t *testing.T) {
	t.Parallel()
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
	resource := mutationResourceReturning("rv-2")
	backend := &resourceBackendFake{resource: resource}
	_, err := UpdateResourceMetadata(context.Background(), backend, appsIdentity("deployments"), "rv-1", tests[0])
	if err == nil || resource.patchCalls != 0 || backend.resourceCalls != 0 {
		t.Fatalf("invalid change error = %v, calls = patch %d, resource %d", err, resource.patchCalls, backend.resourceCalls)
	}
}

func assertMutationPatch(
	t *testing.T,
	resource *mutationResource,
	wantName string,
	wantSubresources []string,
	wantJSON string,
) {
	t.Helper()
	if resource.patchCalls != 1 {
		t.Fatalf("Patch calls = %d, want 1", resource.patchCalls)
	}
	if resource.patchName != wantName || resource.patchType != types.MergePatchType {
		t.Fatalf("Patch target = %q type %q, want %q type %q", resource.patchName, resource.patchType, wantName, types.MergePatchType)
	}
	if resource.patchOptions.FieldManager != operationFieldManager {
		t.Fatalf("Patch options = %#v", resource.patchOptions)
	}
	if strings.Join(resource.patchSubresources, "/") != strings.Join(wantSubresources, "/") {
		t.Fatalf("Patch subresources = %#v, want %#v", resource.patchSubresources, wantSubresources)
	}
	var got any
	if err := json.Unmarshal(resource.patch, &got); err != nil {
		t.Fatalf("decode actual patch %q: %v", resource.patch, err)
	}
	var want any
	if err := json.Unmarshal([]byte(wantJSON), &want); err != nil {
		t.Fatalf("decode expected patch %q: %v", wantJSON, err)
	}
	gotJSON, _ := json.Marshal(got)
	wantEncoded, _ := json.Marshal(want)
	if string(gotJSON) != string(wantEncoded) {
		t.Fatalf("Patch = %s, want %s", gotJSON, wantEncoded)
	}
}

type resourceBackendFake struct {
	resource      dynamic.ResourceInterface
	resourceCalls int
}

func (b *resourceBackendFake) Resource(object.Identity) (dynamic.ResourceInterface, error) {
	b.resourceCalls++
	return b.resource, nil
}

type mutationResource struct {
	patchResult       *unstructured.Unstructured
	patchErr          error
	patchName         string
	patchType         types.PatchType
	patch             []byte
	patchOptions      metav1.PatchOptions
	patchSubresources []string
	patchCalls        int
}

func mutationResourceReturning(resourceVersion string) *mutationResource {
	result := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "apps/v1",
		"kind":       "Deployment",
		"metadata": map[string]any{
			"name": "workload", "resourceVersion": resourceVersion,
		},
	}}
	return &mutationResource{patchResult: result}
}

func (r *mutationResource) Patch(
	_ context.Context,
	name string,
	patchType types.PatchType,
	patch []byte,
	options metav1.PatchOptions,
	subresources ...string,
) (*unstructured.Unstructured, error) {
	r.patchCalls++
	r.patchName = name
	r.patchType = patchType
	r.patch = append([]byte(nil), patch...)
	r.patchOptions = options
	r.patchSubresources = append([]string(nil), subresources...)
	if r.patchErr != nil {
		return nil, r.patchErr
	}
	return r.patchResult.DeepCopy(), nil
}

func (*mutationResource) Create(context.Context, *unstructured.Unstructured, metav1.CreateOptions, ...string) (*unstructured.Unstructured, error) {
	panic("unexpected Create")
}
func (*mutationResource) Update(context.Context, *unstructured.Unstructured, metav1.UpdateOptions, ...string) (*unstructured.Unstructured, error) {
	panic("unexpected Update")
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
func (*mutationResource) Get(context.Context, string, metav1.GetOptions, ...string) (*unstructured.Unstructured, error) {
	panic("unexpected Get")
}
func (*mutationResource) List(context.Context, metav1.ListOptions) (*unstructured.UnstructuredList, error) {
	panic("unexpected List")
}
func (*mutationResource) Watch(context.Context, metav1.ListOptions) (watch.Interface, error) {
	panic("unexpected Watch")
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

var _ dynamic.ResourceInterface = (*mutationResource)(nil)
