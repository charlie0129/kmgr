package view

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	viewcolumns "github.com/charlie0129/kmgr/backend/internal/view/columns"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
)

func TestDiscoverOptionalResourcesUsesOnlyCurrentAuthorityCaches(t *testing.T) {
	t.Parallel()
	source := &fakeResourceSource{
		client: newSearchClient(),
		sessions: map[string]string{
			"session-a": "authority-a", "session-b": "authority-b",
		},
	}
	columns := catalogColumnResolver{accelerators: metrics.AcceleratorConfig{
		Resources: map[string]metrics.AcceleratorResourceConfig{
			"custom.example/fpga-card": {DisplayName: "FPGA"},
		},
	}}
	runtime, err := NewRuntime(RuntimeConfig{Source: source, Columns: columns})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	nodes := cachedCatalogRuntime(true, nodeObject(
		"node-a", "node-a",
		catalogResourceList(
			corev1.ResourceEphemeralStorage, "100Gi",
			"hugepages-1Gi", "2Gi",
			"nvidia.com/gpu", "4",
		), nil,
	))
	pods := cachedCatalogRuntime(true, catalogPod(
		"pod-a", "team", "pod-a",
		catalogResourceList("hugepages-2Mi", "4Mi", "aliyun.com/ppu", "1"),
		catalogResourceList("pod.example/dcu", "2"),
	))
	runtime.resources[resourceKey{
		authorityID: "authority-a", version: "v1", resource: "nodes",
	}] = nodes
	runtime.resources[resourceKey{
		authorityID: "authority-a", version: "v1", resource: "pods", namespace: "team",
	}] = pods
	runtime.resources[resourceKey{
		authorityID: "authority-b", version: "v1", resource: "nodes",
	}] = cachedCatalogRuntime(true, nodeObject(
		"other", "other", catalogResourceList("other.example/gpu", "8"), nil,
	))

	catalog, err := runtime.DiscoverOptionalResources(context.Background(), "session-a")
	if err != nil {
		t.Fatal(err)
	}
	if source.opens.Load() != 0 || runtime.ActiveResourceCount() != 0 {
		t.Fatalf("cache-only discovery opened resources or started a watcher: opens=%d active=%d",
			source.opens.Load(), runtime.ActiveResourceCount())
	}
	if !catalog.NodesCacheAvailable || !catalog.PodsCacheAvailable ||
		!catalog.NodesSnapshotComplete || catalog.PodsSnapshotComplete || !catalog.PotentiallyIncomplete {
		t.Fatalf("cache coverage = %#v", catalog)
	}
	if !catalog.Discovered.EphemeralStorage ||
		!slices.Equal(catalog.Discovered.HugePages, []corev1.ResourceName{"hugepages-1Gi", "hugepages-2Mi"}) ||
		!slices.Equal(catalog.Discovered.Accelerators, []corev1.ResourceName{
			"aliyun.com/ppu", "custom.example/fpga-card", "nvidia.com/gpu", "pod.example/dcu",
		}) {
		t.Fatalf("discovered exact resources = %#v", catalog.Discovered)
	}
	if catalog.Discovered.Present["custom.example/fpga-card"] ||
		!catalog.Discovered.Present["nvidia.com/gpu"] ||
		catalog.Discovered.Present["other.example/gpu"] {
		t.Fatalf("resource presence = %#v", catalog.Discovered.Present)
	}
}

func TestDiscoverOptionalResourcesGRPCMapsTypedCatalogAndConfiguredAbsence(t *testing.T) {
	t.Parallel()
	source := &fakeResourceSource{authority: "authority", client: newSearchClient()}
	columns := catalogColumnResolver{accelerators: metrics.AcceleratorConfig{
		Resources: map[string]metrics.AcceleratorResourceConfig{
			"custom.example/fpga-card": {DisplayName: "FPGA Cards"},
		},
	}}
	runtime, err := NewRuntime(RuntimeConfig{Source: source, Columns: columns})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	runtime.resources[resourceKey{
		authorityID: "authority", version: "v1", resource: "nodes",
	}] = cachedCatalogRuntime(true, nodeObject(
		"node", "node", catalogResourceList("hugepages-2Mi", "64Mi", "aliyun.com/ppu", "8"), nil,
	))
	service, err := NewGRPCService(runtime)
	if err != nil {
		t.Fatal(err)
	}

	response, err := service.DiscoverOptionalResources(context.Background(), optionalResourceRequest("nodes"))
	if err != nil {
		t.Fatal(err)
	}
	if response.GetRequestId() != "catalog-request" || response.GetError() != nil ||
		!response.GetNodesCacheAvailable() || !response.GetNodesSnapshotComplete() ||
		response.GetPodsCacheAvailable() || !response.GetPotentiallyIncomplete() {
		t.Fatalf("catalog envelope = %#v", response)
	}
	byKey := make(map[string]*kmgrv1.OptionalResource, len(response.GetResources()))
	for _, discovered := range response.GetResources() {
		byKey[discovered.GetExactKey()] = discovered
		gvr := discovered.GetApplicableResource()
		if gvr.GetGroup() != "" || gvr.GetVersion() != "v1" || gvr.GetResource() != "nodes" ||
			gvr.GetKind() != "Node" || gvr.GetNamespaced() {
			t.Fatalf("applicable GVR = %#v", gvr)
		}
	}
	if ephemeral := byKey["ephemeral-storage"]; ephemeral == nil || ephemeral.GetPresent() ||
		ephemeral.GetCategory() != kmgrv1.OptionalResourceCategory_OPTIONAL_RESOURCE_CATEGORY_EPHEMERAL_STORAGE {
		t.Fatalf("ephemeral-storage entry = %#v", ephemeral)
	}
	if huge := byKey["hugepages-2Mi"]; huge == nil || !huge.GetPresent() || huge.GetDisplayName() != "Huge Pages (2Mi)" ||
		huge.GetCategory() != kmgrv1.OptionalResourceCategory_OPTIONAL_RESOURCE_CATEGORY_HUGE_PAGE {
		t.Fatalf("huge-page entry = %#v", huge)
	}
	if accelerator := byKey["aliyun.com/ppu"]; accelerator == nil || !accelerator.GetPresent() ||
		accelerator.GetDisplayName() != "PPU" || accelerator.GetExplicitlyConfigured() ||
		accelerator.GetCategory() != kmgrv1.OptionalResourceCategory_OPTIONAL_RESOURCE_CATEGORY_ACCELERATOR {
		t.Fatalf("detected accelerator entry = %#v", accelerator)
	}
	if configured := byKey["custom.example/fpga-card"]; configured == nil || configured.GetPresent() ||
		configured.GetDisplayName() != "FPGA Cards" || !configured.GetExplicitlyConfigured() {
		t.Fatalf("configured accelerator entry = %#v", configured)
	}
	if source.opens.Load() != 0 {
		t.Fatalf("gRPC catalog opened %d resources", source.opens.Load())
	}
}

func TestDiscoverOptionalResourcesGRPCRejectsUnsupportedGVR(t *testing.T) {
	t.Parallel()
	service := newPreviewService(t, &fakeResourceSource{authority: "authority", client: newSearchClient()})
	request := optionalResourceRequest("deployments")
	request.ApplicableResource.Group = "apps"
	_, err := service.DiscoverOptionalResources(context.Background(), request)
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("unsupported GVR error = %v", err)
	}
}

type catalogColumnResolver struct {
	accelerators metrics.AcceleratorConfig
}

func (r catalogColumnResolver) Resolve(
	_, _, _ string,
	_ []string,
	_ string,
) (viewcolumns.Resolution, string, error) {
	return viewcolumns.Resolution{}, "test", nil
}

func (r catalogColumnResolver) AcceleratorConfig() metrics.AcceleratorConfig {
	return r.accelerators
}

func optionalResourceRequest(resourceName string) *kmgrv1.DiscoverOptionalResourcesRequest {
	return &kmgrv1.DiscoverOptionalResourcesRequest{
		Context: &kmgrv1.RequestContext{
			RequestId: "catalog-request", ClusterSessionId: "session",
			DeadlineUnixMs: time.Now().Add(time.Minute).UnixMilli(),
		},
		ApplicableResource: &kmgrv1.ResourceType{
			Version: "v1", Resource: resourceName, Kind: "Node",
		},
	}
}

func cachedCatalogRuntime(complete bool, objects ...*unstructured.Unstructured) *resourceRuntime {
	entry := cachedSearchRuntime(objects...)
	entry.snapshotComplete = complete
	return entry
}

func catalogPod(
	uid, namespace, name string,
	requests, limits corev1.ResourceList,
) *unstructured.Unstructured {
	value := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{UID: types.UID(uid), Namespace: namespace, Name: name},
		Spec: corev1.PodSpec{Containers: []corev1.Container{{
			Name: "main", Resources: corev1.ResourceRequirements{Requests: requests, Limits: limits},
		}}},
	}
	object, _ := runtime.DefaultUnstructuredConverter.ToUnstructured(value)
	return &unstructured.Unstructured{Object: object}
}

func catalogResourceList(values ...any) corev1.ResourceList {
	result := make(corev1.ResourceList, len(values)/2)
	for index := 0; index < len(values); index += 2 {
		var name corev1.ResourceName
		switch value := values[index].(type) {
		case corev1.ResourceName:
			name = value
		case string:
			name = corev1.ResourceName(value)
		}
		result[name] = resource.MustParse(values[index+1].(string))
	}
	return result
}
