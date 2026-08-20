package metrics

import (
	"slices"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestEffectivePodResourcesRegularInitSidecarAndOverhead(t *testing.T) {
	always := corev1.ContainerRestartPolicyAlways
	pod := &corev1.Pod{Spec: corev1.PodSpec{
		Containers: []corev1.Container{
			container("app-a", resourceList(
				corev1.ResourceCPU, "500m", corev1.ResourceMemory, "256Mi",
				corev1.ResourceEphemeralStorage, "1Gi", "hugepages-2Mi", "4Mi", "vendor.example/gpu", "1",
			), resourceList(
				corev1.ResourceCPU, "1", corev1.ResourceMemory, "512Mi",
				corev1.ResourceEphemeralStorage, "2Gi", "hugepages-2Mi", "4Mi", "vendor.example/gpu", "1",
			)),
			container("app-b", resourceList(
				corev1.ResourceCPU, "250m", corev1.ResourceMemory, "128Mi",
				corev1.ResourceEphemeralStorage, "512Mi", "hugepages-2Mi", "2Mi",
			), resourceList(
				corev1.ResourceCPU, "500m", corev1.ResourceMemory, "256Mi",
				corev1.ResourceEphemeralStorage, "1Gi", "hugepages-2Mi", "2Mi",
			)),
		},
		InitContainers: []corev1.Container{
			restartableContainer("sidecar-init", &always, resourceList(
				corev1.ResourceCPU, "100m", corev1.ResourceMemory, "64Mi",
				corev1.ResourceEphemeralStorage, "256Mi", "hugepages-2Mi", "2Mi", "vendor.example/gpu", "1",
			), resourceList(
				corev1.ResourceCPU, "200m", corev1.ResourceMemory, "128Mi",
				corev1.ResourceEphemeralStorage, "512Mi", "hugepages-2Mi", "2Mi", "vendor.example/gpu", "1",
			)),
			container("setup", resourceList(
				corev1.ResourceCPU, "2", corev1.ResourceMemory, "1Gi",
				corev1.ResourceEphemeralStorage, "3Gi", "hugepages-2Mi", "8Mi", "vendor.example/gpu", "2",
			), resourceList(
				corev1.ResourceCPU, "3", corev1.ResourceMemory, "2Gi",
				corev1.ResourceEphemeralStorage, "4Gi", "hugepages-2Mi", "8Mi", "vendor.example/gpu", "2",
			)),
		},
		Overhead: resourceList(
			corev1.ResourceCPU, "50m", corev1.ResourceMemory, "32Mi",
			corev1.ResourceEphemeralStorage, "128Mi", "hugepages-2Mi", "2Mi", "vendor.example/gpu", "1",
		),
	}}

	requests, limits := EffectivePodResources(pod)
	assertResources(t, requests, map[corev1.ResourceName]string{
		corev1.ResourceCPU: "2150m", corev1.ResourceMemory: "1120Mi",
		corev1.ResourceEphemeralStorage: "3456Mi", "hugepages-2Mi": "12Mi", "vendor.example/gpu": "4",
	})
	assertResources(t, limits, map[corev1.ResourceName]string{
		corev1.ResourceCPU: "3250m", corev1.ResourceMemory: "2208Mi",
		corev1.ResourceEphemeralStorage: "4736Mi", "hugepages-2Mi": "12Mi", "vendor.example/gpu": "4",
	})
}

func TestDiscoverHugePagesPreservesPageSizeIdentity(t *testing.T) {
	tests := []struct {
		name  string
		nodes []*corev1.Node
		pods  []*corev1.Pod
		want  []corev1.ResourceName
	}{
		{name: "none"},
		{
			name:  "one size from node",
			nodes: []*corev1.Node{node("node", resourceList("hugepages-2Mi", "64Mi"), nil)},
			want:  []corev1.ResourceName{"hugepages-2Mi"},
		},
		{
			name:  "multiple sizes from node and pod",
			nodes: []*corev1.Node{node("node", resourceList("hugepages-1Gi", "2Gi"), nil)},
			pods: []*corev1.Pod{boundPod("pod", "node", corev1.PodRunning,
				resourceList("hugepages-2Mi", "12Mi"), resourceList("hugepages-2Mi", "16Mi"))},
			want: []corev1.ResourceName{"hugepages-1Gi", "hugepages-2Mi"},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := DiscoverResources(test.nodes, test.pods, AcceleratorConfig{}).HugePages
			if !slices.Equal(got, test.want) {
				t.Fatalf("huge-page keys = %q; want %q", got, test.want)
			}
		})
	}
}

func TestDiscoverAcceleratorsExactKeysAndConfiguredResources(t *testing.T) {
	config := AcceleratorConfig{Resources: map[string]AcceleratorResourceConfig{
		"custom.example/fpga-card": {DisplayName: "FPGA"},
	}}
	if got := DiscoverResources(nil, nil, AcceleratorConfig{}).Accelerators; len(got) != 0 {
		t.Fatalf("no accelerator inputs = %q; want none", got)
	}

	nodes := []*corev1.Node{node("node", resourceList(
		"nvidia.com/gpu", "4", "another.example/gpu", "2", "aliyun.com/ppu", "8", "vendor.example/dcu", "6",
		"vendor.example/fpga", "20", corev1.ResourceCPU, "8",
	), nil)}
	pods := []*corev1.Pod{boundPod("pod", "node", corev1.PodRunning,
		resourceList("pod-only.example/ppu", "1"), resourceList("limit-only.example/dcu", "2"))}
	want := []corev1.ResourceName{
		"aliyun.com/ppu", "another.example/gpu", "custom.example/fpga-card", "limit-only.example/dcu",
		"nvidia.com/gpu", "pod-only.example/ppu", "vendor.example/dcu",
	}
	discovered := DiscoverResources(nodes, pods, config)
	got := discovered.Accelerators
	if !slices.Equal(got, want) {
		t.Fatalf("accelerator keys = %q; want %q", got, want)
	}
	if discovered.Present["custom.example/fpga-card"] ||
		!discovered.Present["aliyun.com/ppu"] || !discovered.Present["limit-only.example/dcu"] {
		t.Fatalf("accelerator presence = %#v", discovered.Present)
	}
	if AcceleratorDisplayName("aliyun.com/ppu", config) != "PPU" ||
		AcceleratorDisplayName("custom.example/fpga-card", config) != "FPGA" ||
		AcceleratorDisplayName("vendor.example/fpga", config) != "vendor.example/fpga" {
		t.Fatal("unexpected accelerator display-name mapping")
	}
}

func TestAcceleratorSuffixDiscoveryIsExactCaseSensitiveAndDisableable(t *testing.T) {
	nodes := []*corev1.Node{node("node", resourceList(
		"vendor.example/gpu", "1", "vendor.example/GPU", "2", "vendor.example/mygpu", "3",
	), nil)}

	if got := DiscoverResources(nodes, nil, AcceleratorConfig{}).Accelerators; !slices.Equal(got, []corev1.ResourceName{"vendor.example/gpu"}) {
		t.Fatalf("default suffix discovery = %q; want only exact lowercase /gpu", got)
	}
	if got := DiscoverResources(nodes, nil, AcceleratorConfig{AutoDetectSuffixes: []string{}}).Accelerators; len(got) != 0 {
		t.Fatalf("disabled suffix discovery = %q; want none", got)
	}
	if got := DiscoverResources(nodes, nil, AcceleratorConfig{AutoDetectSuffixes: []string{"/GPU"}}).Accelerators; !slices.Equal(got, []corev1.ResourceName{"vendor.example/GPU"}) {
		t.Fatalf("custom suffix discovery = %q; want exact uppercase /GPU", got)
	}
	if !IsAcceleratorResource("vendor.example/gpu", AcceleratorConfig{}) ||
		IsAcceleratorResource("hugepages-2Mi", AcceleratorConfig{}) ||
		!IsOptionalSchedulerResource("hugepages-2Mi", AcceleratorConfig{}) {
		t.Fatal("accelerator classification conflated accelerators and huge pages")
	}
}

func TestEphemeralStorageDiscoveryAndAccounting(t *testing.T) {
	pod := boundPod("pod", "node", corev1.PodRunning,
		resourceList(corev1.ResourceEphemeralStorage, "2Gi"), resourceList(corev1.ResourceEphemeralStorage, "4Gi"))
	if !DiscoverResources(nil, []*corev1.Pod{pod}, AcceleratorConfig{}).EphemeralStorage {
		t.Fatal("ephemeral-storage present only in Pod was not discovered")
	}
	requests, limits := EffectivePodResources(pod)
	assertQuantity(t, requests, corev1.ResourceEphemeralStorage, "2Gi")
	assertQuantity(t, limits, corev1.ResourceEphemeralStorage, "4Gi")
}

func TestMeasurementStatesDistinguishUnavailableZeroForbiddenAndStale(t *testing.T) {
	timestamp := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	zero := CurrentMeasurement(resource.MustParse("0"), "metrics.k8s.io", "pod containers", timestamp)
	if zero.State != MeasurementCurrent || !zero.HasValue() || !zero.Quantity.IsZero() {
		t.Fatalf("present zero measurement was conflated with unavailable: %#v", zero)
	}
	stale := StaleMeasurement(resource.MustParse("64Mi"), "metrics.k8s.io", "pod containers", timestamp, "last refresh failed")
	if stale.State != MeasurementStale || !stale.HasValue() || stale.Timestamp != timestamp {
		t.Fatalf("stale measurement lost value or timestamp: %#v", stale)
	}
	forbidden := UnavailableMeasurement("metrics API forbidden and no storage provider is configured")
	if forbidden.State != MeasurementUnavailable || forbidden.HasValue() || forbidden.Message == "" {
		t.Fatalf("forbidden measurement = %#v; want unavailable reason", forbidden)
	}
	absent := UnavailableMeasurement("no usage provider reported this resource")
	if absent.State != MeasurementUnavailable || absent.HasValue() {
		t.Fatalf("absent accelerator utilization = %#v; want unavailable", absent)
	}
}

func resourceList(values ...any) corev1.ResourceList {
	if len(values)%2 != 0 {
		panic("resourceList requires name/value pairs")
	}
	result := make(corev1.ResourceList, len(values)/2)
	for i := 0; i < len(values); i += 2 {
		var name corev1.ResourceName
		switch value := values[i].(type) {
		case corev1.ResourceName:
			name = value
		case string:
			name = corev1.ResourceName(value)
		default:
			panic("resource name must be string or ResourceName")
		}
		quantity, ok := values[i+1].(string)
		if !ok {
			panic("resource quantity must be string")
		}
		result[name] = resource.MustParse(quantity)
	}
	return result
}

func container(name string, requests, limits corev1.ResourceList) corev1.Container {
	return restartableContainer(name, nil, requests, limits)
}

func restartableContainer(name string, restartPolicy *corev1.ContainerRestartPolicy, requests, limits corev1.ResourceList) corev1.Container {
	return corev1.Container{
		Name: name, RestartPolicy: restartPolicy,
		Resources: corev1.ResourceRequirements{Requests: requests, Limits: limits},
	}
}

func boundPod(name, nodeName string, phase corev1.PodPhase, requests, limits corev1.ResourceList) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: corev1.PodSpec{
			NodeName:   nodeName,
			Containers: []corev1.Container{container("app", requests, limits)},
		},
		Status: corev1.PodStatus{Phase: phase},
	}
}

func node(name string, capacity, allocatable corev1.ResourceList) *corev1.Node {
	return &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Status:     corev1.NodeStatus{Capacity: capacity, Allocatable: allocatable},
	}
}

func assertResources(t *testing.T, got corev1.ResourceList, want map[corev1.ResourceName]string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("resource count = %d (%#v); want %d (%#v)", len(got), got, len(want), want)
	}
	for name, quantity := range want {
		assertQuantity(t, got, name, quantity)
	}
}

func assertQuantity(t *testing.T, resources corev1.ResourceList, name corev1.ResourceName, want string) {
	t.Helper()
	got, found := resources[name]
	if !found {
		t.Fatalf("resource %q is absent from %#v", name, resources)
	}
	expected := resource.MustParse(want)
	if got.Cmp(expected) != 0 {
		t.Fatalf("resource %q = %s; want %s", name, got.String(), expected.String())
	}
}
