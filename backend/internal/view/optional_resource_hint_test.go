package view

import (
	"fmt"
	"slices"
	"testing"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func TestOptionalResourceHintExtractsExactSortedPodAndNodeKeys(t *testing.T) {
	config := metrics.AcceleratorConfig{
		AutoDetectSuffixes: []string{"/xpu"},
		Resources: map[string]metrics.AcceleratorResourceConfig{
			"configured.example/fpga": {},
		},
	}
	podHints := newOptionalResourceStreamHints(resourceKey{version: "v1", resource: "pods"}, config)
	pod := &unstructured.Unstructured{Object: map[string]any{
		"spec": map[string]any{
			"overhead": map[string]any{
				"hugepages-2Mi": "2Mi", "vendor.example/xpu": "1",
			},
			"resources": map[string]any{
				"requests": map[string]any{"hugepages-1Gi": "1Gi"},
				"limits":   map[string]any{"configured.example/fpga": "1"},
			},
			"containers": []any{
				map[string]any{"resources": map[string]any{
					"requests": map[string]any{
						"hugepages-2Mi": "2Mi", "vendor.example/xpu": "1",
						"default.example/gpu": "1", "ephemeral-storage": "1Gi", "cpu": "1",
					},
					"limits": map[string]any{"configured.example/fpga": "2"},
				}},
				"malformed-container",
			},
			"initContainers": "malformed-list",
		},
	}}
	podObservation := podHints.extract([]*unstructured.Unstructured{nil, pod})
	wantPod := []string{
		"configured.example/fpga", "hugepages-1Gi", "hugepages-2Mi", "vendor.example/xpu",
	}
	if !slices.Equal(podObservation.keys, wantPod) || podObservation.truncated {
		t.Fatalf("Pod hint = %#v; want keys %q without truncation", podObservation, wantPod)
	}

	nodeHints := newOptionalResourceStreamHints(resourceKey{version: "v1", resource: "nodes"}, metrics.AcceleratorConfig{})
	node := &unstructured.Unstructured{Object: map[string]any{
		"status": map[string]any{
			"capacity": map[string]any{
				"nvidia.com/gpu": "8", "hugepages-1Gi": "4Gi", "memory": "64Gi",
			},
			"allocatable": map[string]any{
				"hugepages-2Mi": "1Gi", "nvidia.com/gpu": "7",
			},
		},
	}}
	nodeObservation := nodeHints.extract([]*unstructured.Unstructured{node})
	wantNode := []string{"hugepages-1Gi", "hugepages-2Mi", "nvidia.com/gpu"}
	if !slices.Equal(nodeObservation.keys, wantNode) || nodeObservation.truncated {
		t.Fatalf("Node hint = %#v; want keys %q without truncation", nodeObservation, wantNode)
	}

	disabled := newOptionalResourceStreamHints(resourceKey{group: "apps", version: "v1", resource: "deployments"}, config)
	if observation := disabled.extract([]*unstructured.Unstructured{pod}); len(observation.keys) != 0 || observation.truncated {
		t.Fatalf("non-core Pod/Node hint = %#v", observation)
	}
}

func TestOptionalResourceHintBoundsExtractionAndPendingDelivery(t *testing.T) {
	hints := newOptionalResourceStreamHints(resourceKey{version: "v1", resource: "pods"}, metrics.AcceleratorConfig{})
	resources := make(map[string]any, maxObservedOptionalResourceKeysPerEvent+64)
	for index := 0; index < maxObservedOptionalResourceKeysPerEvent+63; index++ {
		resources[fmt.Sprintf("device-%03d.example/gpu", index)] = "1"
	}
	resources["hugepages-2Mi"] = "2Mi"
	object := &unstructured.Unstructured{Object: map[string]any{
		"spec": map[string]any{"containers": []any{map[string]any{
			"resources": map[string]any{"requests": resources},
		}}},
	}}

	extracted := hints.extract([]*unstructured.Unstructured{object})
	if len(extracted.keys) != maxObservedOptionalResourceKeysPerEvent || !extracted.truncated ||
		!slices.Contains(extracted.keys, "hugepages-2Mi") || !slices.IsSorted(extracted.keys) {
		t.Fatalf("bounded extraction = %#v", extracted)
	}

	first := optionalResourceKeyObservation{keys: make([]string, maxObservedOptionalResourceKeysPerEvent)}
	for index := range first.keys {
		first.keys[index] = fmt.Sprintf("pending-%03d.example/gpu", index)
	}
	hints.observeLocked(first)
	hints.observeLocked(optionalResourceKeyObservation{keys: []string{"hugepages-1Gi"}})
	pending := hints.takePendingLocked()
	if len(pending.keys) != maxObservedOptionalResourceKeysPerEvent || !pending.truncated ||
		!slices.Contains(pending.keys, "hugepages-1Gi") || !slices.IsSorted(pending.keys) {
		t.Fatalf("bounded pending delivery = %#v", pending)
	}
	if hints.hasPendingLocked() {
		t.Fatal("taking bounded pending hints did not clear the mailbox")
	}
}
