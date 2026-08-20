// Package metrics contains Pod resource accounting and optional usage
// enrichment for Pods and Nodes.
package metrics

import (
	"slices"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	resourcehelper "k8s.io/component-helpers/resource"
)

// MeasurementState distinguishes a real measurement (including a real zero)
// from unavailable metrics. Stale measurements retain their last value so the
// UI can display it with an age instead of replacing it with a fabricated zero.
type MeasurementState uint8

const (
	MeasurementUnavailable MeasurementState = iota
	MeasurementCurrent
	MeasurementStale
)

// Measurement is actual utilization reported by a provider. Requests and
// limits are scheduler allocations, not measurements.
type Measurement struct {
	Quantity  resource.Quantity
	State     MeasurementState
	Provider  string
	Scope     string
	Timestamp time.Time
	Message   string
}

// CurrentMeasurement creates a current provider-backed utilization value.
func CurrentMeasurement(quantity resource.Quantity, provider, scope string, timestamp time.Time) Measurement {
	return Measurement{
		Quantity: quantity.DeepCopy(), State: MeasurementCurrent, Provider: provider,
		Scope: scope, Timestamp: timestamp,
	}
}

// StaleMeasurement creates a provider-backed value that is no longer fresh.
func StaleMeasurement(quantity resource.Quantity, provider, scope string, timestamp time.Time, message string) Measurement {
	return Measurement{
		Quantity: quantity.DeepCopy(), State: MeasurementStale, Provider: provider,
		Scope: scope, Timestamp: timestamp, Message: message,
	}
}

// UnavailableMeasurement creates a value with no utilization measurement.
func UnavailableMeasurement(message string) Measurement {
	return Measurement{State: MeasurementUnavailable, Message: message}
}

// HasValue reports whether the measurement contains a provider-supplied value.
// Both current and stale measurements have values.
func (m Measurement) HasValue() bool {
	return m.State == MeasurementCurrent || m.State == MeasurementStale
}

// EffectivePodResources applies the Kubernetes scheduling formula for regular
// containers, restartable and non-restartable init containers, Pod-level
// resources, and Pod overhead. Status resources are intentionally not used:
// this reports the resources declared to the scheduler, independent of the
// cluster's in-place resize feature-gate configuration.
func EffectivePodResources(pod *corev1.Pod) (requests, limits corev1.ResourceList) {
	if pod == nil {
		return corev1.ResourceList{}, corev1.ResourceList{}
	}
	options := resourcehelper.PodResourcesOptions{}
	return resourcehelper.PodRequests(pod, options), resourcehelper.PodLimits(pod, options)
}

var defaultAcceleratorSuffixes = [...]string{"/gpu", "/ppu", "/dcu"}

// AcceleratorResourceConfig configures the label for one exact extended
// resource. An empty DisplayName deliberately falls back to the exact key.
type AcceleratorResourceConfig struct {
	DisplayName string `json:"displayName,omitempty" yaml:"displayName,omitempty"`
}

// AcceleratorConfig controls exact-key accelerator discovery. A nil suffix
// slice uses /gpu, /ppu, and /dcu; an empty non-nil slice disables auto-detect.
type AcceleratorConfig struct {
	AutoDetectSuffixes []string                             `json:"autoDetectSuffixes,omitempty" yaml:"autoDetectSuffixes,omitempty"`
	Resources          map[string]AcceleratorResourceConfig `json:"resources,omitempty" yaml:"resources,omitempty"`
}

// DiscoveredResources lists scheduler-accounted optional resources. Names are
// sorted and exact; hugepages-2Mi and hugepages-1Gi remain independent entries.
type DiscoveredResources struct {
	EphemeralStorage bool
	HugePages        []corev1.ResourceName
	Accelerators     []corev1.ResourceName
	// Present distinguishes configured accelerator keys that are available for
	// opt-in even when no retained Node or Pod currently declares them. Keys in
	// HugePages are always present; accelerator keys may be present or absent.
	Present map[corev1.ResourceName]bool
}

// DiscoverResources finds optional resource keys without requiring a metrics
// provider. It inspects Node capacity/allocatable and effective Pod resources.
// Configured accelerator keys are returned even when currently absent.
func DiscoverResources(nodes []*corev1.Node, pods []*corev1.Pod, acceleratorConfig AcceleratorConfig) DiscoveredResources {
	hugePages := make(map[corev1.ResourceName]struct{})
	accelerators := make(map[corev1.ResourceName]struct{}, len(acceleratorConfig.Resources))
	configuredAccelerators := make(map[corev1.ResourceName]struct{}, len(acceleratorConfig.Resources))
	for configuredName := range acceleratorConfig.Resources {
		if configuredName != "" {
			name := corev1.ResourceName(configuredName)
			accelerators[name] = struct{}{}
			configuredAccelerators[name] = struct{}{}
		}
	}

	suffixes := acceleratorConfig.AutoDetectSuffixes
	if suffixes == nil {
		suffixes = defaultAcceleratorSuffixes[:]
	}
	discovered := DiscoveredResources{Present: make(map[corev1.ResourceName]bool)}
	inspect := func(resources corev1.ResourceList) {
		for name := range resources {
			switch {
			case name == corev1.ResourceEphemeralStorage:
				discovered.EphemeralStorage = true
				discovered.Present[name] = true
			case isHugePageResource(name):
				hugePages[name] = struct{}{}
				discovered.Present[name] = true
			case hasAnySuffix(string(name), suffixes):
				accelerators[name] = struct{}{}
				discovered.Present[name] = true
			default:
				if _, configured := configuredAccelerators[name]; configured {
					discovered.Present[name] = true
				}
			}
		}
	}

	for _, node := range nodes {
		if node == nil {
			continue
		}
		inspect(node.Status.Capacity)
		inspect(node.Status.Allocatable)
	}
	for _, pod := range pods {
		requests, limits := EffectivePodResources(pod)
		inspect(requests)
		inspect(limits)
	}

	discovered.HugePages = sortedResourceNames(hugePages)
	discovered.Accelerators = sortedResourceNames(accelerators)
	return discovered
}

// IsOptionalSchedulerResource reports whether an observed exact Kubernetes
// resource name represents a huge-page size or an accelerator under the same
// configured exact-key and suffix rules used by DiscoverResources. It excludes
// base resources such as CPU, memory, and ephemeral-storage.
func IsOptionalSchedulerResource(name corev1.ResourceName, acceleratorConfig AcceleratorConfig) bool {
	if name == "" {
		return false
	}
	if isHugePageResource(name) {
		return true
	}
	return IsAcceleratorResource(name, acceleratorConfig)
}

// IsAcceleratorResource applies the configured exact-key and suffix rules
// without including huge-page resources, whose request/limit presentation is
// different from allocation-only accelerator columns.
func IsAcceleratorResource(name corev1.ResourceName, acceleratorConfig AcceleratorConfig) bool {
	if name == "" {
		return false
	}
	if _, configured := acceleratorConfig.Resources[string(name)]; configured {
		return true
	}
	suffixes := acceleratorConfig.AutoDetectSuffixes
	if suffixes == nil {
		suffixes = defaultAcceleratorSuffixes[:]
	}
	return hasAnySuffix(string(name), suffixes)
}

func isHugePageResource(name corev1.ResourceName) bool {
	value := string(name)
	return strings.HasPrefix(value, corev1.ResourceHugePagesPrefix) && value != corev1.ResourceHugePagesPrefix
}

func hasAnySuffix(name string, suffixes []string) bool {
	for _, suffix := range suffixes {
		if suffix != "" && strings.HasSuffix(name, suffix) {
			return true
		}
	}
	return false
}

func sortedResourceNames(values map[corev1.ResourceName]struct{}) []corev1.ResourceName {
	names := make([]corev1.ResourceName, 0, len(values))
	for name := range values {
		names = append(names, name)
	}
	slices.SortFunc(names, func(a, b corev1.ResourceName) int {
		return strings.Compare(string(a), string(b))
	})
	return names
}

// AcceleratorDisplayName returns the configured label, a built-in generic
// label, or the exact key. Full keys remain identity regardless of this label.
func AcceleratorDisplayName(name corev1.ResourceName, config AcceleratorConfig) string {
	exact := string(name)
	if configured, ok := config.Resources[exact]; ok {
		if label := strings.TrimSpace(configured.DisplayName); label != "" {
			return label
		}
		return exact
	}
	component := exact
	if slash := strings.LastIndexByte(component, '/'); slash >= 0 {
		component = component[slash+1:]
	}
	switch component {
	case "gpu", "ppu", "dcu":
		return strings.ToUpper(component)
	default:
		return exact
	}
}
