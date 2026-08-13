package view

import (
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/metrics"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	metricsclient "k8s.io/metrics/pkg/client/clientset/versioned/typed/metrics/v1beta1"
)

const (
	PodCPUColumn                    = "cpu"
	PodMemoryColumn                 = "memory"
	PodEphemeralStorageColumn       = "ephemeral-storage"
	NodeCPUUsageColumn              = "cpu"
	NodeMemoryUsageColumn           = "memory"
	NodeEphemeralStorageUsageColumn = "ephemeral-storage"

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
	clients   map[string]metricsclient.MetricsV1beta1Interface
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
	key := metricProviderKey{authorityID: authorityID, kind: kind, namespace: namespace}

	s.mu.Lock()
	defer s.mu.Unlock()
	if provider := s.providers[key]; provider != nil {
		return provider, nil
	}
	client := s.clients[authorityID]
	if client == nil {
		config := session.RESTConfig()
		if config == nil {
			return nil, errors.New("cluster REST configuration is unavailable")
		}
		// Client construction is local-only: no discovery or Metrics API
		// request occurs until the returned provider receives a subscriber.
		created, err := metricsclient.NewForConfig(config)
		if err != nil {
			return nil, fmt.Errorf("construct Kubernetes Metrics API client: %w", err)
		}
		client = created
		if s.clients == nil {
			s.clients = make(map[string]metricsclient.MetricsV1beta1Interface)
		}
		s.clients[authorityID] = client
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
	for _, columnID := range projector.spec.ColumnIDs {
		if _, metric := metricColumnResource(projector.spec.Resource, columnID); metric {
			return true
		}
		if program := projector.spec.CELPrograms[columnID]; program != nil && program.UsesMetrics() {
			return true
		}
	}
	return false
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
