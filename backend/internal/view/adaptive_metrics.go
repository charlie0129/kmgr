package view

import (
	"context"
	"errors"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	"github.com/charlie0129/kmgr/backend/internal/store"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/protobuf/proto"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
)

// initialMetricEpoch pins one complete base-object snapshot until its metric
// projection becomes the staged generation's first client-visible barrier.
// Newer WATCH state is represented only by bounded deferred work.
type initialMetricEpoch struct {
	coverageID      uint64
	objects         []*unstructured.Unstructured
	serverCells     map[string][]*kmgrv1.Cell
	objectsReady    bool
	dirty           bool
	needsResnapshot bool
}

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

// seedInitialMetricEpochUnlocked reuses the immutable raw snapshot already
// taken by Open. The subscription is still private when this is called, so no
// lock is necessary. Reusing that slice avoids a second 50,000-Pod snapshot on
// the common filter-edit path.
func (s *Subscription) seedInitialMetricEpochUnlocked(
	objects []*unstructured.Unstructured,
	serverCells map[string][]*kmgrv1.Cell,
) {
	if !s.stageUntilReconciled || !s.metricsReconciling ||
		!s.metricPlan.dependency.requiresCompleteCoverage() {
		return
	}
	s.initialMetricEpoch = &initialMetricEpoch{
		objects:      objects,
		serverCells:  cloneServerCells(serverCells),
		objectsReady: true,
	}
}

func (s *Subscription) discardInitialMetricEpochSeedUnlocked() {
	if s.initialMetricEpoch != nil && s.initialMetricEpoch.coverageID != 0 {
		return
	}
	s.initialMetricEpoch = nil
}

func (s *Subscription) shouldStartInitialMetricEpochLocked() bool {
	return (s.initialMetricEpoch == nil || s.initialMetricEpoch.coverageID == 0) &&
		s.stageUntilReconciled &&
		!s.reconciliationDelivered && !s.pendingReconciliation &&
		s.hasCompleteMetricCoverageSourceLocked() && s.snapshotComplete &&
		s.metricPlan.dependency.requiresCompleteCoverage()
}

func (s *Subscription) hasCompleteMetricCoverageSourceLocked() bool {
	switch s.metricPlan.strategy {
	case metricFetchSharedList:
		// metricsReconciling is initialized while Open still owns provider leases;
		// s.metrics becomes non-nil after publication and remains available across
		// a resource-stream restart.
		return s.metricsReconciling || s.metrics != nil
	case metricFetchPodObjects:
		return s.podMetricResolver != nil && s.resource != nil
	default:
		return false
	}
}

func (s *Subscription) shouldDeferForInitialMetricEpochLocked() bool {
	return s.activeInitialMetricEpochLocked() != nil ||
		s.shouldStartInitialMetricEpochLocked()
}

func (s *Subscription) activeInitialMetricEpochLocked() *initialMetricEpoch {
	if s.initialMetricEpoch == nil || s.initialMetricEpoch.coverageID == 0 {
		return nil
	}
	return s.initialMetricEpoch
}

// initialMetricEpochBlocksProjectionLocked keeps catch-up and WATCH work
// behind the first complete metric projection. Once the pinned metric snapshot
// is ready, that one projection is allowed through and commits the barrier.
func (s *Subscription) initialMetricEpochBlocksProjectionLocked() bool {
	epoch := s.activeInitialMetricEpochLocked()
	if epoch == nil {
		return s.shouldStartInitialMetricEpochLocked()
	}
	return !epoch.objectsReady || s.metricCoverageCommit != epoch.coverageID
}

// requireCompleteMetricCoverageLocked marks the current base-resource state as
// non-authoritative until a full metrics snapshot has been projected. Exact
// Pod views run a bounded-concurrency UID-pinned resolve over their already
// narrowed raw store. An immediate request is reserved for the initial LIST,
// a relist, or the configured metrics cadence. Ordinary WATCH batches only
// mark the result dirty; they never turn object churn into candidate scans or
// Metrics LIST pagination. A staged generation pins its first request so WATCH
// churn cannot move the ViewReconciled barrier indefinitely.
func (s *Subscription) requireCompleteMetricCoverageLocked(immediate bool) {
	if s.closed || !s.snapshotComplete ||
		!s.metricPlan.dependency.requiresCompleteCoverage() {
		return
	}
	if epoch := s.activeInitialMetricEpochLocked(); epoch != nil {
		if !immediate {
			epoch.dirty = true
		}
		return
	}
	if s.shouldStartInitialMetricEpochLocked() {
		s.startInitialMetricEpochLocked(!immediate)
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

func (s *Subscription) startInitialMetricEpochLocked(dirty bool) {
	s.metricCoverageID++
	s.metricCoverageCommit = 0
	s.setMetricsReconcilingLocked(true)
	epoch := s.initialMetricEpoch
	if epoch == nil {
		epoch = &initialMetricEpoch{}
		s.initialMetricEpoch = epoch
	}
	epoch.coverageID = s.metricCoverageID
	epoch.dirty = dirty
	epoch.needsResnapshot = false
	if epoch.objectsReady {
		s.startInitialMetricRefreshLocked()
		return
	}

	resource := s.resource
	if resource == nil || resource.currentStore() == nil {
		epoch.objectsReady = true
		s.startInitialMetricRefreshLocked()
		return
	}
	resourceStore := resource.currentStore()
	ctx := s.projectionContext
	if ctx == nil {
		ctx = context.Background()
	}
	go s.captureInitialMetricEpoch(ctx, epoch, resource, resourceStore)
}

func (s *Subscription) captureInitialMetricEpoch(
	ctx context.Context,
	epoch *initialMetricEpoch,
	resource *resourceRuntime,
	resourceStore *store.UIDStore,
) {
	objects, err := resourceStore.SnapshotContext(ctx)
	if err != nil && ctx.Err() != nil {
		return
	}
	if err != nil {
		objects = nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.initialMetricEpoch != epoch || s.resource != resource ||
		resource.currentStore() != resourceStore {
		return
	}
	epoch.objects = objects
	epoch.serverCells = cloneServerCells(s.serverCells)
	epoch.objectsReady = true
	s.startInitialMetricRefreshLocked()
}

func (s *Subscription) startInitialMetricRefreshLocked() {
	epoch := s.activeInitialMetricEpochLocked()
	if s.closed || epoch == nil || !epoch.objectsReady {
		return
	}
	s.metricCoverageCommit = 0
	s.metricRefreshAfter = time.Now()
	s.stopCompletePodMetricCoverageTimerLocked()

	switch s.metricPlan.strategy {
	case metricFetchSharedList:
		if s.metrics != nil {
			s.metrics.RequestRefresh()
			s.metricRefreshPending = false
		} else {
			s.metricRefreshPending = true
		}
	case metricFetchPodObjects:
		if s.podMetricResolver == nil || s.resource == nil {
			s.metricCoverageCommit = epoch.coverageID
			s.projectionRevision++
			s.projectionResnapshot = true
			s.scheduleProjectionLocked()
			return
		}
		s.metricCoverageRunning = true
		go s.resolveCompletePodMetrics()
	default:
		s.metricCoverageCommit = epoch.coverageID
		s.projectionRevision++
		s.projectionResnapshot = true
		s.scheduleProjectionLocked()
	}
}

func (s *Subscription) resolveCompletePodMetrics() {
	s.mu.Lock()
	epoch := s.activeInitialMetricEpochLocked()
	initialEpoch := epoch != nil && epoch.objectsReady
	if s.closed || (!initialEpoch && !s.metricCoverageDirty) ||
		s.resource == nil || s.podMetricResolver == nil {
		s.metricCoverageRunning = false
		s.mu.Unlock()
		return
	}
	coverageID := s.metricCoverageID
	resource := s.resource
	var objects []*unstructured.Unstructured
	var resourceStore *store.UIDStore
	if initialEpoch {
		coverageID = epoch.coverageID
		objects = epoch.objects
	} else {
		s.metricCoverageDirty = false
		resourceStore = resource.currentStore()
	}
	resolver := s.podMetricResolver
	sessionID := s.metricSessionID
	authorityID := s.metricAuthorityID
	ctx := s.projectionContext
	if ctx == nil {
		ctx = context.Background()
	}
	s.mu.Unlock()

	var err error
	if !initialEpoch {
		objects, err = resourceStore.SnapshotContext(ctx)
		if err != nil {
			if ctx.Err() != nil {
				s.mu.Lock()
				s.metricCoverageRunning = false
				s.mu.Unlock()
				return
			}
			objects = nil
		}
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
	if initialEpoch {
		if s.initialMetricEpoch != epoch || coverageID != epoch.coverageID {
			s.metricCoverageRunning = false
			s.mu.Unlock()
			return
		}
	} else if coverageID != s.metricCoverageID {
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
	epoch := s.activeInitialMetricEpochLocked()
	completedInitialEpoch := epoch != nil && epoch.coverageID == s.metricCoverageCommit
	s.metricCoverageCommit = 0
	if completedInitialEpoch {
		s.initialMetricEpoch = nil
		if epoch.needsResnapshot {
			clear(s.pendingObjects)
			s.projectionResnapshot = true
		}
	}
	s.setMetricsReconcilingLocked(false)
	s.markReconciledLocked()
	if completedInitialEpoch && epoch.dirty {
		// The pinned epoch now owns the client barrier. Re-enter the ordinary
		// cadence path for coalesced WATCH work without delaying that barrier.
		s.requireCompleteMetricCoverageLocked(false)
		return
	}
	if s.metricPlan.strategy == metricFetchPodObjects {
		s.scheduleCompletePodMetricCoverageLocked()
	}
}

func cloneServerCells(values map[string][]*kmgrv1.Cell) map[string][]*kmgrv1.Cell {
	if len(values) == 0 {
		return nil
	}
	cloned := make(map[string][]*kmgrv1.Cell, len(values))
	for uid, cells := range values {
		cloned[uid] = append([]*kmgrv1.Cell(nil), cells...)
	}
	return cloned
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
	resourceStore := resource.currentStore()
	objects := resourceStore.GetMany(uids)
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
	currentObjects := resourceStore.GetMany(resolvedUIDs)
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
