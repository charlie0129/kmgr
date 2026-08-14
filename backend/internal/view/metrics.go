package view

import (
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/metrics"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

const (
	PodCPUColumn                       = "cpu"
	PodMemoryColumn                    = "memory"
	PodEphemeralStorageColumn          = "ephemeral-storage"
	NodeCPUUsageColumn                 = "cpu"
	NodeMemoryUsageColumn              = "memory"
	NodeEphemeralStorageUsageColumn    = "ephemeral-storage"
	NodeCPURequestsColumn              = "cpu-requests"
	NodeCPULimitsColumn                = "cpu-limits"
	NodeMemoryRequestsColumn           = "memory-requests"
	NodeMemoryLimitsColumn             = "memory-limits"
	NodeEphemeralStorageRequestsColumn = "ephemeral-storage-requests"
	NodeEphemeralStorageLimitsColumn   = "ephemeral-storage-limits"
	NodePodCountColumn                 = "pod-count"

	metricResourceColumnPrefix = "resource:"
)

// MetricSource resolves a lazily refreshed provider for one Kubernetes
// authority. Implementations must not perform network I/O in OpenMetrics;
// fetching starts only after Runtime attaches the first active view consumer.
type MetricSource interface {
	OpenMetrics(
		sessionID, authorityID string,
		kind metrics.APIKind,
		namespace string,
	) (*metrics.Provider, error)
}

// KubernetesMetricSource constructs Kubernetes Metrics API clients from
// authoritative session REST configs and shares providers between independent
// workspace sessions backed by the same Kubernetes authority.
type KubernetesMetricSource struct {
	Sessions        *cluster.SessionRegistry
	RefreshInterval time.Duration

	mu        sync.Mutex
	providers map[metricProviderKey]*metrics.Provider
}

type metricProviderKey struct {
	authorityID string
	kind        metrics.APIKind
	namespace   string
}

func (s *KubernetesMetricSource) OpenMetrics(
	sessionID, authorityID string,
	kind metrics.APIKind,
	namespace string,
) (*metrics.Provider, error) {
	if s == nil || s.Sessions == nil {
		return nil, errors.New("cluster session registry is unavailable")
	}
	if authorityID == "" {
		return nil, errors.New("metrics authority must not be empty")
	}
	session, ok := s.Sessions.Get(sessionID)
	if !ok {
		return nil, ErrSessionNotFound
	}
	if available, known := session.CachedMetricsAPIAvailability(); known && !available {
		// Discovery is performed explicitly when the workspace opens. Reuse its
		// authoritative negative result instead of waking a provider that can
		// only generate repeated 404/forbidden traffic. Partial discovery stays
		// unknown and is allowed to degrade through the normal provider path.
		return nil, metrics.ErrMetricsAPIUnavailable
	}
	key := metricProviderKey{authorityID: authorityID, kind: kind, namespace: namespace}

	s.mu.Lock()
	defer s.mu.Unlock()
	if provider := s.providers[key]; provider != nil {
		return provider, nil
	}
	client := session.Metrics()
	if client == nil {
		return nil, errors.New("cluster Metrics API client is unavailable")
	}
	provider, err := metrics.NewProvider(metrics.KubernetesFetcher{
		Client: client, Kind: kind, Namespace: namespace,
	}, s.RefreshInterval)
	if err != nil {
		return nil, err
	}
	if s.providers == nil {
		s.providers = make(map[metricProviderKey]*metrics.Provider)
	}
	s.providers[key] = provider
	return provider, nil
}

func metricKindFor(resource ResourceType) (metrics.APIKind, bool) {
	if resource.Group != "" || resource.Version != "v1" {
		return 0, false
	}
	switch resource.Resource {
	case "pods":
		return metrics.PodMetrics, true
	case "nodes":
		return metrics.NodeMetrics, true
	default:
		return 0, false
	}
}

func metricColumnResource(resource ResourceType, columnID string) (corev1.ResourceName, bool) {
	if _, supported := metricKindFor(resource); !supported {
		return "", false
	}
	switch columnID {
	case PodCPUColumn:
		return corev1.ResourceCPU, true
	case PodMemoryColumn:
		return corev1.ResourceMemory, true
	case PodEphemeralStorageColumn:
		return corev1.ResourceEphemeralStorage, true
	}
	if exact, found := strings.CutPrefix(columnID, metricResourceColumnPrefix); found && exact != "" {
		return corev1.ResourceName(exact), true
	}
	return "", false
}

type nodeAllocationField uint8

const (
	nodeRequested nodeAllocationField = iota
	nodeLimited
)

func isNodeResource(resource ResourceType) bool {
	return resource.Group == "" && resource.Version == "v1" && resource.Resource == "nodes"
}

func nodeAllocationColumn(
	resource ResourceType,
	columnID string,
) (corev1.ResourceName, nodeAllocationField, bool) {
	if !isNodeResource(resource) {
		return "", 0, false
	}
	switch columnID {
	case NodeCPURequestsColumn:
		return corev1.ResourceCPU, nodeRequested, true
	case NodeCPULimitsColumn:
		return corev1.ResourceCPU, nodeLimited, true
	case NodeMemoryRequestsColumn:
		return corev1.ResourceMemory, nodeRequested, true
	case NodeMemoryLimitsColumn:
		return corev1.ResourceMemory, nodeLimited, true
	case NodeEphemeralStorageRequestsColumn:
		return corev1.ResourceEphemeralStorage, nodeRequested, true
	case NodeEphemeralStorageLimitsColumn:
		return corev1.ResourceEphemeralStorage, nodeLimited, true
	}
	if exact, found := strings.CutPrefix(columnID, metricResourceColumnPrefix); found && exact != "" {
		return corev1.ResourceName(exact), nodeRequested, true
	}
	return "", 0, false
}

func needsNodeAccounting(projector *Projector) bool {
	if projector == nil || !isNodeResource(projector.spec.Resource) {
		return false
	}
	for _, displayID := range projector.spec.ColumnIDs {
		if program := projector.spec.CELPrograms[displayID]; program != nil {
			if program.UsesMetrics() {
				return true
			}
			continue
		}
		columnID := projector.extractorID(displayID)
		if source := projector.extractorSource(displayID); source != "" && source != "metric" {
			continue
		}
		if columnID == NodePodCountColumn {
			return true
		}
		if _, _, allocation := nodeAllocationColumn(projector.spec.Resource, columnID); allocation {
			return true
		}
	}
	return false
}

func metricColumnID(resourceName corev1.ResourceName) string {
	return metricResourceColumnPrefix + string(resourceName)
}

func needsMetricProvider(projector *Projector) bool {
	if projector == nil {
		return false
	}
	if _, supported := metricKindFor(projector.spec.Resource); !supported {
		return false
	}
	for _, displayID := range projector.spec.ColumnIDs {
		if program := projector.spec.CELPrograms[displayID]; program != nil {
			if program.UsesMetrics() {
				return true
			}
			continue
		}
		columnID := projector.extractorID(displayID)
		if source := projector.extractorSource(displayID); source != "" && source != "metric" {
			continue
		}
		if _, _, allocation := nodeAllocationColumn(projector.spec.Resource, columnID); allocation ||
			columnID == NodePodCountColumn {
			continue
		}
		// Exact huge-page and extended-resource columns are scheduler
		// allocations. Metrics Server does not supply their utilization, so an
		// otherwise allocation-only view must not wake that optional provider.
		if _, found := exactResourceColumn(columnID); found {
			continue
		}
		if _, metric := metricColumnResource(projector.spec.Resource, columnID); metric {
			return true
		}
	}
	return false
}

func exactResourceColumn(columnID string) (corev1.ResourceName, bool) {
	exact, found := strings.CutPrefix(columnID, metricResourceColumnPrefix)
	return corev1.ResourceName(exact), found && exact != ""
}

func metricsNamespace(resource ResourceType, serverNamespace string) string {
	if resource.Resource == "pods" {
		return serverNamespace
	}
	return ""
}

func metricsActivation(sample metrics.Sample, state metrics.MeasurementState) map[string]any {
	resources := make(map[string]any, len(sample.Resources))
	if state == metrics.MeasurementCurrent || state == metrics.MeasurementStale {
		for name, value := range sample.Resources {
			resources[name] = value
		}
	}
	activation := map[string]any{
		"available": state == metrics.MeasurementCurrent || state == metrics.MeasurementStale,
		"stale":     state == metrics.MeasurementStale,
		"provider":  metrics.MetricsAPIGroupVersion,
		"resources": resources,
	}
	if !sample.MeasuredAt.IsZero() {
		activation["measuredAt"] = sample.MeasuredAt
	}
	return activation
}

func sampleForObject(snapshot metrics.Snapshot, uid, namespace, name string, kind metrics.APIKind) metrics.Sample {
	if uid != "" {
		if sample, found := snapshot.Samples[uid]; found {
			return sample
		}
	}
	fallback := name
	if kind == metrics.PodMetrics {
		fallback = namespace + "/" + name
	}
	return snapshot.Samples[fallback]
}

func gvrForProjector(projector *Projector) schema.GroupVersionResource {
	return schema.GroupVersionResource{
		Group: projector.spec.Resource.Group, Version: projector.spec.Resource.Version,
		Resource: projector.spec.Resource.Resource,
	}
}
