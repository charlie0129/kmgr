package view

import (
	"context"
	"errors"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/metrics"
	metricsapi "k8s.io/metrics/pkg/apis/metrics/v1beta1"
	metricsclient "k8s.io/metrics/pkg/client/clientset/versioned/typed/metrics/v1beta1"
)

var ErrMetricAuthorityMismatch = errors.New("metrics authority does not match the cluster session")

type podSampleCacheEntry struct {
	cache  *metrics.PodSampleCache
	active int
}

// ResolvePodMetrics resolves exact Pod samples through one cache shared by all
// workspace sessions backed by the same Kubernetes authority. Creating the
// cache is lazy; the authority's existing Metrics client preserves the shared
// REST transport, activity accounting, and aggregate rate limiter.
func (s *KubernetesMetricSource) ResolvePodMetrics(
	ctx context.Context,
	sessionID, authorityID string,
	references []metrics.PodReference,
) (metrics.Snapshot, error) {
	if ctx == nil {
		return metrics.Snapshot{}, errors.New("Pod metrics context must not be nil")
	}
	if err := ctx.Err(); err != nil {
		return metrics.Snapshot{}, err
	}
	cache, release, err := s.acquirePodSampleCache(sessionID, authorityID)
	if err != nil {
		return metrics.Snapshot{}, err
	}
	defer release()
	return cache.Resolve(ctx, references)
}

// ResolvePodMetricsDetail serves an explicit container-table request through
// the same authority-owned cache and in-flight GET as viewport samples. Only
// explicit calls retain the per-container payload in the cache's small detail
// tier.
func (s *KubernetesMetricSource) ResolvePodMetricsDetail(
	ctx context.Context,
	sessionID string,
	reference metrics.PodReference,
) (*metricsapi.PodMetrics, error) {
	if ctx == nil {
		return nil, errors.New("Pod metrics detail context must not be nil")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if s == nil || s.Sessions == nil {
		return nil, errors.New("cluster session registry is unavailable")
	}
	session, ok := s.Sessions.Get(sessionID)
	if !ok {
		return nil, ErrSessionNotFound
	}
	authorityID := session.AuthorityID()
	cache, release, err := s.acquirePodSampleCache(sessionID, authorityID)
	if err != nil {
		return nil, err
	}
	defer release()
	return cache.ResolveDetail(ctx, reference)
}

func (s *KubernetesMetricSource) acquirePodSampleCache(
	sessionID, authorityID string,
) (*metrics.PodSampleCache, func(), error) {
	session, lease, err := s.acquireMetricsSession(sessionID, authorityID)
	if err != nil {
		return nil, nil, err
	}
	client := session.Metrics()
	if client == nil {
		lease.Release()
		return nil, nil, errors.New("cluster Metrics API client is unavailable")
	}

	s.mu.Lock()
	entry := s.podCaches[authorityID]
	if entry == nil {
		var cache *metrics.PodSampleCache
		cache, err = metrics.NewPodSampleCache(s.podSampleCacheConfig(client))
		if err == nil {
			if s.podCaches == nil {
				s.podCaches = make(map[string]*podSampleCacheEntry)
			}
			entry = &podSampleCacheEntry{cache: cache}
			s.podCaches[authorityID] = entry
		}
	}
	if entry != nil {
		entry.active++
	}
	s.mu.Unlock()
	if err != nil {
		lease.Release()
		return nil, nil, err
	}
	return entry.cache, func() {
		s.finishPodSampleResolve(authorityID, entry)
		lease.Release()
	}, nil
}

func (s *KubernetesMetricSource) finishPodSampleResolve(
	authorityID string,
	entry *podSampleCacheEntry,
) {
	s.mu.Lock()
	if entry != nil && s.podCaches[authorityID] == entry && entry.active > 0 {
		entry.active--
	}
	s.mu.Unlock()
}

func (s *KubernetesMetricSource) acquireMetricsSession(
	sessionID, authorityID string,
) (*cluster.Session, *cluster.SessionLease, error) {
	if s == nil || s.Sessions == nil {
		return nil, nil, errors.New("cluster session registry is unavailable")
	}
	if authorityID == "" {
		return nil, nil, errors.New("metrics authority must not be empty")
	}
	session, lease, ok := s.Sessions.Acquire(sessionID)
	if !ok {
		return nil, nil, ErrSessionNotFound
	}
	if err := validateMetricSession(session, authorityID); err != nil {
		lease.Release()
		return nil, nil, err
	}
	return session, lease, nil
}

func (s *KubernetesMetricSource) metricsSession(
	sessionID, authorityID string,
) (*cluster.Session, error) {
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
	if err := validateMetricSession(session, authorityID); err != nil {
		return nil, err
	}
	return session, nil
}

func validateMetricSession(session *cluster.Session, authorityID string) error {
	if session.AuthorityID() != authorityID {
		return ErrMetricAuthorityMismatch
	}
	if available, known := session.CachedMetricsAPIAvailability(); known && !available {
		// Discovery is explicit. Reuse an authoritative negative result without
		// issuing a Metrics request; partial/unknown discovery still degrades via
		// the normal provider or exact-cache path.
		return metrics.ErrMetricsAPIUnavailable
	}
	return nil
}

func (s *KubernetesMetricSource) podSampleCacheConfig(
	client metricsclient.MetricsV1beta1Interface,
) metrics.PodSampleCacheConfig {
	refreshTTL := s.PodSampleRefreshTTL
	if refreshTTL == 0 {
		refreshTTL = s.RefreshInterval
	}
	negativeTTL := s.PodSampleNegativeTTL
	if negativeTTL == 0 && refreshTTL > 0 &&
		metrics.DefaultPodSampleNegativeTTL >= refreshTTL {
		// Preserve the required shorter retry TTL even when a caller configures a
		// refresh interval below the cache's ordinary two-second default.
		negativeTTL = refreshTTL / 4
		if negativeTTL <= 0 {
			// No positive duration can be shorter than a one-nanosecond refresh;
			// pass an invalid relationship through for a deterministic constructor
			// error instead of silently changing the requested refresh cadence.
			negativeTTL = refreshTTL
		}
	}
	return metrics.PodSampleCacheConfig{
		Client: client, RefreshTTL: refreshTTL, NegativeTTL: negativeTTL,
		EntryLimit: s.PodSampleEntryLimit, SampleLimit: s.PodSampleLimit,
		DetailEntryLimit:  s.PodDetailEntryLimit,
		MaxConcurrentGETs: s.PodSampleMaxConcurrentGETs,
	}
}

func (s *KubernetesMetricSource) PodMetricRefreshInterval() time.Duration {
	if s != nil {
		if s.PodSampleRefreshTTL > 0 {
			return s.PodSampleRefreshTTL
		}
		if s.RefreshInterval > 0 {
			return s.RefreshInterval
		}
	}
	return metrics.DefaultPodSampleRefreshTTL
}
