package view

import (
	"container/list"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/metrics"
	corev1 "k8s.io/api/core/v1"
)

const (
	PodCPUColumn                    = "cpu"
	PodMemoryColumn                 = "memory"
	PodEphemeralStorageColumn       = "ephemeral-storage"
	NodeCPUUsageColumn              = "cpu"
	NodeMemoryUsageColumn           = "memory"
	NodeEphemeralStorageUsageColumn = "ephemeral-storage"

	metricResourceColumnPrefix = "resource:"

	// Idle providers retain one last snapshot for a fast return to a recently
	// visited metrics view. Both provider and sample budgets prevent namespace
	// churn from retaining every old Metrics API client and full Pod snapshot.
	DefaultIdleMetricProviderLimit = 8
	DefaultIdleMetricSampleLimit   = 100_000
)

// MetricSource resolves a lazily refreshed provider for one Kubernetes
// authority. Implementations must not perform network I/O in OpenMetrics;
// fetching starts only after Runtime attaches the first active view consumer.
type MetricSource interface {
	OpenMetrics(
		sessionID, authorityID string,
		kind metrics.APIKind,
		namespace string,
	) (*metrics.ProviderLease, error)
}

// KubernetesMetricSource constructs Kubernetes Metrics API clients from
// authoritative session REST configs and shares providers between independent
// workspace sessions backed by the same Kubernetes authority.
type KubernetesMetricSource struct {
	Sessions        *cluster.SessionRegistry
	RefreshInterval time.Duration
	// Zero uses the conservative defaults above. These budgets cover only idle
	// providers; providers with an open lookup lease or active subscriber are
	// always retained until that consumer releases them.
	IdleProviderLimit int
	IdleSampleLimit   int

	mu          sync.Mutex
	providers   map[metricProviderKey]*metricProviderEntry
	idle        list.List
	idleSamples int
}

type metricProviderKey struct {
	authorityID string
	kind        metrics.APIKind
	namespace   string
}

type metricProviderEntry struct {
	key         metricProviderKey
	provider    *metrics.Provider
	idleElement *list.Element
	idleSamples int
}

func (s *KubernetesMetricSource) OpenMetrics(
	sessionID, authorityID string,
	kind metrics.APIKind,
	namespace string,
) (*metrics.ProviderLease, error) {
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
	if entry := s.providers[key]; entry != nil {
		s.removeIdleLocked(entry)
		lease, err := entry.provider.Acquire()
		if err == nil {
			return lease, nil
		}
		// A released entry should never remain indexed, but recover by replacing
		// it rather than making optional metrics fail the base view.
		delete(s.providers, key)
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
	lease, err := provider.Acquire()
	if err != nil {
		return nil, err
	}
	entry := &metricProviderEntry{key: key, provider: provider}
	if err := provider.SetIdleCallback(func() { s.providerBecameIdle(entry) }); err != nil {
		lease.Close()
		provider.ReleaseIdle()
		return nil, err
	}
	if s.providers == nil {
		s.providers = make(map[metricProviderKey]*metricProviderEntry)
	}
	s.providers[key] = entry
	return lease, nil
}

func (s *KubernetesMetricSource) providerBecameIdle(entry *metricProviderEntry) {
	if s == nil || entry == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.providers[entry.key] != entry || entry.idleElement != nil {
		return
	}
	entry.idleSamples = entry.provider.RetainedSampleCount()
	entry.idleElement = s.idle.PushBack(entry)
	s.idleSamples += entry.idleSamples
	s.enforceIdleBudgetsLocked()
}

func (s *KubernetesMetricSource) enforceIdleBudgetsLocked() {
	providerLimit := s.IdleProviderLimit
	if providerLimit <= 0 {
		providerLimit = DefaultIdleMetricProviderLimit
	}
	sampleLimit := s.IdleSampleLimit
	if sampleLimit <= 0 {
		sampleLimit = DefaultIdleMetricSampleLimit
	}
	for s.idle.Len() > providerLimit || s.idleSamples > sampleLimit {
		element := s.idle.Front()
		if element == nil {
			return
		}
		entry := element.Value.(*metricProviderEntry)
		s.removeIdleLocked(entry)
		if entry.provider.ReleaseIdle() {
			delete(s.providers, entry.key)
		}
	}
}

func (s *KubernetesMetricSource) removeIdleLocked(entry *metricProviderEntry) {
	if entry == nil || entry.idleElement == nil {
		return
	}
	s.idle.Remove(entry.idleElement)
	s.idleSamples -= entry.idleSamples
	entry.idleElement = nil
	entry.idleSamples = 0
}

// ReleaseIdleAuthority drops warm metrics snapshots and client references for
// one Kubernetes authority without disrupting any active provider.
func (s *KubernetesMetricSource) ReleaseIdleAuthority(authorityID string) int {
	if s == nil || authorityID == "" {
		return 0
	}
	return s.releaseIdleMatching(func(entry *metricProviderEntry) bool {
		return entry.key.authorityID == authorityID
	})
}

// ReleaseIdleProviders drops all currently idle providers. Runtime shutdown
// uses this after closing its subscriptions; active providers shared by
// another consumer remain indexed and continue normally.
func (s *KubernetesMetricSource) ReleaseIdleProviders() int {
	if s == nil {
		return 0
	}
	return s.releaseIdleMatching(func(*metricProviderEntry) bool { return true })
}

func (s *KubernetesMetricSource) releaseIdleMatching(match func(*metricProviderEntry) bool) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	released := 0
	for element := s.idle.Front(); element != nil; {
		next := element.Next()
		entry := element.Value.(*metricProviderEntry)
		if match(entry) {
			s.removeIdleLocked(entry)
			if entry.provider.ReleaseIdle() {
				delete(s.providers, entry.key)
				released++
			}
		}
		element = next
	}
	return released
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
		// Exact huge-page and extended-resource columns are scheduler
		// values sourced from the row object. Metrics Server does not supply their
		// utilization, so an exact-resource-only view must not wake that provider.
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
