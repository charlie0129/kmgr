package view

import (
	"slices"
	"strings"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

const maxObservedOptionalResourceKeysPerEvent = 256

type optionalResourceKeyObservation struct {
	keys      []string
	truncated bool
}

// optionalResourceStreamHints is subscription-private and is accessed while
// Subscription.mu is held, except for extract, which reads immutable setup
// fields only. Authoritative catalog metadata remains in
// DiscoverOptionalResources.
type optionalResourceStreamHints struct {
	resource     string
	accelerators metrics.AcceleratorConfig
	pending      map[string]struct{}
	truncated    bool
}

func newOptionalResourceStreamHints(key resourceKey, config metrics.AcceleratorConfig) optionalResourceStreamHints {
	if key.group != "" || key.version != "v1" || (key.resource != "pods" && key.resource != "nodes") {
		return optionalResourceStreamHints{}
	}
	cloned := metrics.AcceleratorConfig{AutoDetectSuffixes: slices.Clone(config.AutoDetectSuffixes)}
	if config.Resources != nil {
		cloned.Resources = make(map[string]metrics.AcceleratorResourceConfig, len(config.Resources))
		for name, value := range config.Resources {
			cloned.Resources[name] = value
		}
	}
	return optionalResourceStreamHints{
		resource: key.resource, accelerators: cloned,
		pending: make(map[string]struct{}),
	}
}

func (h *optionalResourceStreamHints) enabled() bool {
	return h != nil && h.resource != ""
}

// extract does bounded field traversal only. It deliberately avoids typed
// conversion, scheduler aggregation, metrics providers, and all I/O so hints
// cannot turn optional discovery into a prerequisite for base row projection.
func (h *optionalResourceStreamHints) extract(objects []*unstructured.Unstructured) optionalResourceKeyObservation {
	if !h.enabled() || len(objects) == 0 {
		return optionalResourceKeyObservation{}
	}
	keys := make(map[string]struct{})
	truncated := false
	inspect := func(value any) {
		resources, ok := value.(map[string]any)
		if !ok {
			return
		}
		for exact := range resources {
			name := corev1.ResourceName(exact)
			if metrics.IsOptionalSchedulerResource(name, h.accelerators) {
				truncated = addBoundedOptionalResourceKey(keys, exact) || truncated
			}
		}
	}
	inspectNested := func(object map[string]any, fields ...string) {
		value, found, err := unstructured.NestedFieldNoCopy(object, fields...)
		if err == nil && found {
			inspect(value)
		}
	}

	for _, object := range objects {
		if object == nil {
			continue
		}
		switch h.resource {
		case "nodes":
			inspectNested(object.Object, "status", "capacity")
			inspectNested(object.Object, "status", "allocatable")
		case "pods":
			inspectNested(object.Object, "spec", "overhead")
			inspectNested(object.Object, "spec", "resources", "requests")
			inspectNested(object.Object, "spec", "resources", "limits")
			for _, field := range []string{"containers", "initContainers", "ephemeralContainers"} {
				value, found, err := unstructured.NestedFieldNoCopy(object.Object, "spec", field)
				if err != nil || !found {
					continue
				}
				containers, ok := value.([]any)
				if !ok {
					continue
				}
				for _, value := range containers {
					container, ok := value.(map[string]any)
					if !ok {
						continue
					}
					inspectNested(container, "resources", "requests")
					inspectNested(container, "resources", "limits")
				}
			}
		}
	}
	result := make([]string, 0, len(keys))
	for key := range keys {
		result = append(result, key)
	}
	slices.SortFunc(result, strings.Compare)
	return optionalResourceKeyObservation{keys: result, truncated: truncated}
}

// observeLocked coalesces duplicates within one pending delivery. Keys remain
// event-local and may appear again after the delivery drains, allowing clients
// to retry a failed cache-only catalog refresh on a later raw upsert.
func (h *optionalResourceStreamHints) observeLocked(observation optionalResourceKeyObservation) {
	if !h.enabled() {
		return
	}
	h.truncated = h.truncated || observation.truncated
	for _, key := range observation.keys {
		if key == "" {
			continue
		}
		h.truncated = addBoundedOptionalResourceKey(h.pending, key) || h.truncated
	}
}

func (h *optionalResourceStreamHints) takePendingLocked() optionalResourceKeyObservation {
	if h == nil || (len(h.pending) == 0 && !h.truncated) {
		return optionalResourceKeyObservation{}
	}
	result := make([]string, 0, len(h.pending))
	for key := range h.pending {
		result = append(result, key)
	}
	clear(h.pending)
	truncated := h.truncated
	h.truncated = false
	slices.SortFunc(result, strings.Compare)
	return optionalResourceKeyObservation{keys: result, truncated: truncated}
}

func (h *optionalResourceStreamHints) hasPendingLocked() bool {
	return h != nil && (len(h.pending) != 0 || h.truncated)
}

// addBoundedOptionalResourceKey keeps both extraction scratch space and the
// pending mailbox bounded. Huge-page sizes take precedence over accelerator
// keys at the limit so an accelerator-heavy object cannot hide a newly
// observed huge-page size. The truncated bit still forces authoritative
// cache-only discovery for whichever exact key was omitted.
func addBoundedOptionalResourceKey(values map[string]struct{}, key string) bool {
	if key == "" {
		return false
	}
	if _, exists := values[key]; exists {
		return false
	}
	if len(values) < maxObservedOptionalResourceKeysPerEvent {
		values[key] = struct{}{}
		return false
	}
	victim := ""
	for existing := range values {
		if victim == "" || optionalResourceKeyPrecedes(victim, existing) {
			victim = existing
		}
	}
	if victim == "" || !optionalResourceKeyPrecedes(key, victim) {
		return true
	}
	delete(values, victim)
	values[key] = struct{}{}
	return true
}

func isHugePageOptionalResourceKey(key string) bool {
	return strings.HasPrefix(key, corev1.ResourceHugePagesPrefix) && key != corev1.ResourceHugePagesPrefix
}

// optionalResourceKeyPrecedes defines the deterministic bounded subset:
// huge-page sizes first, then lexicographic exact Kubernetes identity.
func optionalResourceKeyPrecedes(left, right string) bool {
	leftHugePage := isHugePageOptionalResourceKey(left)
	rightHugePage := isHugePageOptionalResourceKey(right)
	if leftHugePage != rightHugePage {
		return leftHugePage
	}
	return strings.Compare(left, right) < 0
}
