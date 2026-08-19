package view

import (
	"container/list"
	"context"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/metrics"
	viewfilter "github.com/charlie0129/kmgr/backend/internal/view/filter"
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
		namespace, labelSelector string,
	) (*metrics.ProviderLease, error)
}

// PodMetricResolver is the exact, UID-pinned metrics path used when a Pod
// view's base query cannot be represented by Metrics Server. Implementations
// share their cache by Kubernetes authority; Runtime supplies only bounded
// viewport ranges unless metric-backed ordering or filtering requires complete
// candidate coverage.
type PodMetricResolver interface {
	ResolvePodMetrics(
		ctx context.Context,
		sessionID, authorityID string,
		references []metrics.PodReference,
	) (metrics.Snapshot, error)
}

// PodMetricRefreshCadence optionally exposes the positive TTL used by an exact
// PodMetricResolver. Complete-coverage views use it to refresh authoritative
// metric-backed order or membership even when their base objects are idle.
type PodMetricRefreshCadence interface {
	PodMetricRefreshInterval() time.Duration
}

// KubernetesMetricSource constructs Kubernetes Metrics API clients from
// authoritative session REST configs and shares providers between independent
// workspace sessions backed by the same Kubernetes authority.
type KubernetesMetricSource struct {
	Sessions        *cluster.SessionRegistry
	RefreshInterval time.Duration
	// Exact PodMetrics GETs reuse RefreshInterval unless an explicit positive
	// TTL is supplied here. The remaining zero values use metrics package
	// defaults. All limits are per Kubernetes authority.
	PodSampleRefreshTTL        time.Duration
	PodSampleNegativeTTL       time.Duration
	PodSampleEntryLimit        int
	PodSampleLimit             int
	PodDetailEntryLimit        int
	PodSampleMaxConcurrentGETs int
	// Zero uses the conservative defaults above. These budgets cover only idle
	// providers; providers with an open lookup lease or active subscriber are
	// always retained until that consumer releases them.
	IdleProviderLimit int
	IdleSampleLimit   int

	mu          sync.Mutex
	providers   map[metricProviderKey]*metricProviderEntry
	idle        list.List
	idleSamples int
	podCaches   map[string]*podSampleCacheEntry
}

type metricProviderKey struct {
	authorityID string
	kind        metrics.APIKind
	namespace   string
	labels      string
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
	namespace, labelSelector string,
) (*metrics.ProviderLease, error) {
	if s == nil || s.Sessions == nil {
		return nil, errors.New("cluster session registry is unavailable")
	}
	if authorityID == "" {
		return nil, errors.New("metrics authority must not be empty")
	}
	session, err := s.metricsSession(sessionID, authorityID)
	if err != nil {
		return nil, err
	}
	if kind != metrics.PodMetrics {
		// NodeMetrics does not have a label-selected view today. Keeping the
		// unused selector out of its key prevents accidental provider splits.
		labelSelector = ""
	}
	key := metricProviderKey{
		authorityID: authorityID,
		kind:        kind,
		namespace:   namespace,
		labels:      labelSelector,
	}

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
		LabelSelector: labelSelector,
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

// ReleaseIdleAuthority drops warm metrics snapshots, an idle exact Pod sample
// cache, and client references for one Kubernetes authority without disrupting
// active LIST or exact consumers. Authority retirement uses this after its
// shared backend clients have closed.
func (s *KubernetesMetricSource) ReleaseIdleAuthority(authorityID string) int {
	if s == nil || authorityID == "" {
		return 0
	}
	return s.releaseIdleMatching(
		func(entry *metricProviderEntry) bool { return entry.key.authorityID == authorityID },
		func(candidate string) bool { return candidate == authorityID },
		false,
	)
}

// ReleaseIdleProviders drops all currently idle LIST providers and force-closes
// every exact Pod cache. Runtime shutdown uses this after canceling its
// subscriptions, so any final exact Resolve is woken instead of being orphaned;
// an active LIST provider shared by another consumer remains indexed.
func (s *KubernetesMetricSource) ReleaseIdleProviders() int {
	if s == nil {
		return 0
	}
	return s.releaseIdleMatching(
		func(*metricProviderEntry) bool { return true },
		func(string) bool { return true },
		true,
	)
}

func (s *KubernetesMetricSource) releaseIdleMatching(
	matchProvider func(*metricProviderEntry) bool,
	matchPodCache func(string) bool,
	forcePodCaches bool,
) int {
	s.mu.Lock()
	released := 0
	for element := s.idle.Front(); element != nil; {
		next := element.Next()
		entry := element.Value.(*metricProviderEntry)
		if matchProvider(entry) {
			s.removeIdleLocked(entry)
			if entry.provider.ReleaseIdle() {
				delete(s.providers, entry.key)
				released++
			}
		}
		element = next
	}
	podCaches := make([]*metrics.PodSampleCache, 0)
	for authorityID, entry := range s.podCaches {
		if !matchPodCache(authorityID) ||
			(!forcePodCaches && entry != nil && entry.active != 0) {
			continue
		}
		delete(s.podCaches, authorityID)
		if entry != nil && entry.cache != nil {
			podCaches = append(podCaches, entry.cache)
		}
	}
	s.mu.Unlock()
	for _, cache := range podCaches {
		cache.Close()
		released++
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

// metricDependency describes every way optional Metrics API values can affect
// one projection. Display-only enrichment may be fetched lazily for a bounded
// viewport; order or membership dependencies require complete candidate
// coverage before the projection can be considered reconciled.
type metricDependency struct {
	display    bool
	order      bool
	membership bool
}

func (d metricDependency) requiresCompleteCoverage() bool {
	return d.order || d.membership
}

type metricFetchStrategy uint8

const (
	metricFetchDisabled metricFetchStrategy = iota
	metricFetchSharedList
	// metricFetchPodObjects is the point-cache hook for Pod views whose base
	// resource query contains a field selector. Metrics Server cannot apply
	// that selector, so this strategy must never fall through to a broad LIST.
	metricFetchPodObjects
)

type metricViewPlan struct {
	dependency metricDependency
	strategy   metricFetchStrategy
}

func planMetricView(projector *Projector, fieldSelector string) metricViewPlan {
	dependency := metricDependencies(projector)
	if !dependency.display {
		return metricViewPlan{dependency: dependency, strategy: metricFetchDisabled}
	}
	kind, _ := metricKindFor(projector.spec.Resource)
	if kind == metrics.PodMetrics && strings.TrimSpace(fieldSelector) != "" {
		return metricViewPlan{dependency: dependency, strategy: metricFetchPodObjects}
	}
	return metricViewPlan{dependency: dependency, strategy: metricFetchSharedList}
}

func metricDependencies(projector *Projector) metricDependency {
	if projector == nil {
		return metricDependency{}
	}
	if _, supported := metricKindFor(projector.spec.Resource); !supported {
		return metricDependency{}
	}

	metricColumns := make(map[string]struct{})
	for _, displayID := range projector.spec.ColumnIDs {
		if metricColumnDependsOnProvider(projector, displayID) {
			metricColumns[displayID] = struct{}{}
		}
	}
	dependency := metricDependency{display: len(metricColumns) != 0}
	if !dependency.display {
		return dependency
	}
	for _, descriptor := range projector.spec.Sort {
		if _, metric := metricColumns[descriptor.ColumnID]; metric {
			dependency.order = true
			break
		}
	}
	for _, term := range projector.filter.Terms() {
		if term.Kind == viewfilter.Text {
			// Bare text searches every rendered cell. If any such cell is backed
			// by metrics, absent samples can change projection membership.
			dependency.membership = true
			break
		}
	}
	return dependency
}

func metricColumnDependsOnProvider(projector *Projector, displayID string) bool {
	if projector == nil {
		return false
	}
	if program := projector.spec.CELPrograms[displayID]; program != nil {
		return program.UsesMetrics()
	}
	columnID := projector.extractorID(displayID)
	if source := projector.extractorSource(displayID); source != "" && source != "metric" {
		return false
	}
	// Exact huge-page and extended-resource columns are scheduler values sourced
	// from the row object. Metrics Server does not supply their utilization.
	if _, found := exactResourceColumn(columnID); found {
		return false
	}
	_, metric := metricColumnResource(projector.spec.Resource, columnID)
	return metric
}

func needsMetricProvider(projector *Projector) bool {
	return metricDependencies(projector).display
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
