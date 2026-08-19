package view

import (
	"context"
	"errors"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/protobuf/proto"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
)

// updateMetricInterest starts one latest-wins exact metrics resolve. Range
// coordinates have already been validated by Runtime.UpdateMetricInterest;
// everything after this point is UID-based so a Kubernetes object cannot be
// confused with a same-name replacement.
func (s *Subscription) updateMetricInterest(indexRevision uint64, uids []types.UID) {
	s.mu.Lock()
	if s.closed || s.metricPlan.strategy != metricFetchPodObjects ||
		s.metricPlan.dependency.requiresCompleteCoverage() ||
		s.podMetricResolver == nil || s.resource == nil || len(uids) == 0 {
		s.mu.Unlock()
		return
	}
	if s.indexRevision != indexRevision {
		s.mu.Unlock()
		return
	}
	s.metricInterestID++
	interestID := s.metricInterestID
	if s.metricInterestStop != nil {
		s.metricInterestStop()
	}
	parent := s.projectionContext
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithCancel(parent)
	s.metricInterestStop = cancel
	resolver := s.podMetricResolver
	sessionID := s.metricSessionID
	authorityID := s.metricAuthorityID
	resource := s.resource
	s.mu.Unlock()

	go s.resolveMetricInterest(
		ctx, interestID, indexRevision, resolver, sessionID, authorityID, resource, uids,
	)
}

func (s *Subscription) requestCompleteMetricCoverage() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.requireCompleteMetricCoverageLocked(true)
}

// requireCompleteMetricCoverageLocked marks the current base-resource state as
// non-authoritative until a full metrics snapshot has been projected. Exact
// Pod views run a bounded-concurrency UID-pinned resolve over their already
// narrowed raw store. An immediate request is reserved for the initial LIST,
// a relist, or the configured metrics cadence. Ordinary WATCH batches only
// mark the result dirty; they never turn object churn into candidate scans or
// Metrics LIST pagination.
func (s *Subscription) requireCompleteMetricCoverageLocked(immediate bool) {
	if s.closed || !s.snapshotComplete ||
		!s.metricPlan.dependency.requiresCompleteCoverage() {
		return
	}
	s.metricCoverageID++
	s.metricCoverageCommit = 0
	s.setMetricsReconcilingLocked(true)
	s.metricRefreshAfter = time.Now()

	switch s.metricPlan.strategy {
	case metricFetchSharedList:
		// Initial snapshots and authoritative relists request one post-barrier
		// refresh. Ordinary WATCH churn only advances metricRefreshAfter: the
		// provider's configured cadence will satisfy the newest barrier without a
		// full PodMetrics/NodeMetrics LIST for every object batch.
		if immediate {
			if s.metrics != nil {
				s.metrics.RequestRefresh()
				s.metricRefreshPending = false
			} else {
				s.metricRefreshPending = true
			}
		}
	case metricFetchPodObjects:
		if s.podMetricResolver == nil || s.resource == nil {
			// Missing optional metrics support is a complete, unavailable result;
			// do not leave staging or status permanently reconciling.
			s.metricCoverageCommit = s.metricCoverageID
			s.projectionRevision++
			s.projectionResnapshot = true
			s.scheduleProjectionLocked()
			return
		}
		s.metricCoverageDirty = true
		if !immediate {
			s.scheduleCompletePodMetricCoverageLocked()
			return
		}
		s.stopCompletePodMetricCoverageTimerLocked()
		if s.metricCoverageRunning {
			return
		}
		s.metricCoverageRunning = true
		go s.resolveCompletePodMetrics()
	default:
		s.metricCoverageCommit = s.metricCoverageID
		s.projectionRevision++
		s.projectionResnapshot = true
		s.scheduleProjectionLocked()
	}
}

func (s *Subscription) resolveCompletePodMetrics() {
	s.mu.Lock()
	if s.closed || !s.metricCoverageDirty || s.resource == nil || s.podMetricResolver == nil {
		s.metricCoverageRunning = false
		s.mu.Unlock()
		return
	}
	s.metricCoverageDirty = false
	coverageID := s.metricCoverageID
	resource := s.resource
	resolver := s.podMetricResolver
	sessionID := s.metricSessionID
	authorityID := s.metricAuthorityID
	ctx := s.projectionContext
	if ctx == nil {
		ctx = context.Background()
	}
	s.mu.Unlock()

	objects, err := resource.store.SnapshotContext(ctx)
	if err != nil {
		if ctx.Err() != nil {
			s.mu.Lock()
			s.metricCoverageRunning = false
			s.mu.Unlock()
			return
		}
		objects = nil
	}
	references, _ := podMetricReferences(objects)
	snapshot := metrics.Snapshot{
		Samples: make(map[string]metrics.Sample), State: metrics.MeasurementCurrent,
		UpdatedAt: time.Now(),
	}
	if len(references) != 0 {
		snapshot, err = resolver.ResolvePodMetrics(ctx, sessionID, authorityID, references)
	}
	if err != nil {
		if ctx.Err() != nil || errors.Is(err, context.Canceled) ||
			errors.Is(err, context.DeadlineExceeded) {
			s.mu.Lock()
			s.metricCoverageRunning = false
			s.mu.Unlock()
			return
		}
		snapshot = metrics.Snapshot{
			State: metrics.MeasurementUnavailable, UpdatedAt: time.Now(), Err: err,
		}
	}

	s.mu.Lock()
	if s.closed || s.resource != resource {
		s.metricCoverageRunning = false
		s.mu.Unlock()
		return
	}
	if coverageID != s.metricCoverageID {
		// The scan is no longer a complete snapshot of the base candidates. Drop
		// it and wait for the next cadence instead of repeatedly traversing the
		// store while a busy WATCH stream keeps invalidating the result.
		s.metricCoverageDirty = true
		s.metricCoverageRunning = false
		s.scheduleCompletePodMetricCoverageLocked()
		s.mu.Unlock()
		return
	}
	s.projector = s.projector.WithMetrics(snapshot)
	s.projectionRevision++
	s.projectionResnapshot = true
	s.metricCoverageCommit = coverageID
	s.metricRefreshAfter = time.Time{}
	s.metricCoverageRunning = false
	s.scheduleProjectionLocked()
	s.mu.Unlock()
}

func (s *Subscription) stopCompletePodMetricCoverageTimerLocked() {
	if s.metricCoverageTimer == nil {
		return
	}
	s.metricCoverageTimer.Stop()
	s.metricCoverageTimer = nil
	s.metricCoverageTimerID++
}

func (s *Subscription) scheduleCompletePodMetricCoverageLocked() {
	if s.closed || s.metricPlan.strategy != metricFetchPodObjects ||
		s.metricRefreshInterval <= 0 || s.metricCoverageRunning ||
		s.metricCoverageTimer != nil {
		return
	}
	s.metricCoverageTimerID++
	timerID := s.metricCoverageTimerID
	interval := s.metricRefreshInterval
	s.metricCoverageTimer = time.AfterFunc(interval, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.closed || s.metricCoverageTimer == nil ||
			s.metricCoverageTimerID != timerID {
			return
		}
		s.metricCoverageTimer = nil
		s.requireCompleteMetricCoverageLocked(true)
	})
}

func (s *Subscription) completeMetricCoverageLocked() {
	if !s.metricsReconciling || s.metricCoverageCommit == 0 ||
		s.metricCoverageCommit != s.metricCoverageID {
		return
	}
	s.metricCoverageCommit = 0
	s.setMetricsReconcilingLocked(false)
	s.markReconciledLocked()
	if s.metricPlan.strategy == metricFetchPodObjects {
		s.scheduleCompletePodMetricCoverageLocked()
	}
}

func (s *Subscription) setMetricsReconcilingLocked(value bool) {
	if s.metricsReconciling == value {
		return
	}
	s.metricsReconciling = value
	status := &kmgrv1.ViewStatus{Freshness: kmgrv1.ViewFreshness_VIEW_FRESHNESS_LOADING}
	if s.lastStatus != nil {
		status = proto.Clone(s.lastStatus).(*kmgrv1.ViewStatus)
	}
	status.MetricsReconciling = value
	s.setStatusLocked(status)
}

func (s *Subscription) resolveMetricInterest(
	ctx context.Context,
	interestID, indexRevision uint64,
	resolver PodMetricResolver,
	sessionID, authorityID string,
	resource *resourceRuntime,
	uids []types.UID,
) {
	objects := resource.store.GetMany(uids)
	references, resolvedUIDs := podMetricReferences(objects)
	if len(references) == 0 {
		return
	}
	snapshot, err := resolver.ResolvePodMetrics(ctx, sessionID, authorityID, references)
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) || ctx.Err() != nil {
			return
		}
		snapshot = metrics.Snapshot{
			State: metrics.MeasurementUnavailable, UpdatedAt: time.Now(), Err: err,
		}
	}
	if ctx.Err() != nil {
		return
	}

	// Re-read the raw objects after the network wait. A deleted UID is skipped,
	// while a recreated same-name Pod has a different UID and can never inherit
	// the old sample.
	currentObjects := resource.store.GetMany(resolvedUIDs)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.metricInterestID != interestID ||
		s.indexRevision != indexRevision || s.resource != resource {
		return
	}
	// Keep only the current bounded interest window in the projector. Rows that
	// were enriched by an older window retain their immutable cell payload until
	// another base update touches them; revisiting that range resolves through
	// the authority cache again. This prevents a long scroll through a huge
	// cluster from growing a second unbounded per-view sample map.
	s.projector = s.projector.WithMetrics(snapshot)
	s.projectionRevision++
	for index, object := range currentObjects {
		if object == nil || object.GetUID() != resolvedUIDs[index] {
			continue
		}
		s.pendingObjects[string(resolvedUIDs[index])] = object
	}
	if len(s.pendingObjects) > s.pendingLimit {
		clear(s.pendingObjects)
		s.projectionResnapshot = true
	}
	if len(s.pendingObjects) != 0 || s.projectionResnapshot {
		s.scheduleProjectionLocked()
	}
}

func podMetricReferences(objects []*unstructured.Unstructured) ([]metrics.PodReference, []types.UID) {
	references := make([]metrics.PodReference, 0, len(objects))
	uids := make([]types.UID, 0, len(objects))
	for _, object := range objects {
		if object == nil || object.GetNamespace() == "" || object.GetName() == "" || object.GetUID() == "" {
			continue
		}
		references = append(references, metrics.PodReference{
			Namespace: object.GetNamespace(), Name: object.GetName(), UID: object.GetUID(),
		})
		uids = append(uids, object.GetUID())
	}
	return references, uids
}
