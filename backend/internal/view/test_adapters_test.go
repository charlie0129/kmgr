package view

import (
	"context"
	"fmt"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	"github.com/charlie0129/kmgr/backend/internal/store"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func cloneMetricSample(sample metrics.Sample) metrics.Sample {
	resources := make(map[string]int64, len(sample.Resources))
	for name, value := range sample.Resources {
		resources[name] = value
	}
	sample.Resources = resources
	return sample
}

func metricColumnID(resourceName corev1.ResourceName) string {
	return metricResourceColumnPrefix + string(resourceName)
}

func projectBounded(count, workerLimit int, project func(index int)) {
	if project == nil {
		return
	}
	_ = projectBoundedContext(context.Background(), count, workerLimit, func(index int) error {
		project(index)
		return nil
	})
}

func (r *Runtime) installSearchSnapshot(
	key searchSnapshotKey,
	snapshotStore *store.UIDStore,
) (*completedSearchSnapshot, bool) {
	if snapshotStore == nil || snapshotStore.ResourceVersion() == "" {
		return nil, false
	}
	objectCount := snapshotStore.Len()
	if objectCount > r.searchSnapshotObjectLimit {
		return nil, false
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.installCompletedSearchSnapshotLocked(key, snapshotStore, time.Now()) {
		return nil, false
	}
	return r.searchSnapshots[key], true
}

func (s *Subscription) initializeRows(rows []*kmgrv1.ResourceRow) {
	clear(s.rows)
	clear(s.presentationRowBytes)
	s.presentationRowBytesTotal = 0
	s.presentationUIDBytesTotal = 0
	s.order = s.order[:0]
	for _, row := range rows {
		uid := row.GetIdentity().GetUid()
		if uid == "" {
			continue
		}
		s.rows[uid] = row
		s.presentationRowBytes[uid] = projectedRowRetainedBytes(row)
		s.presentationRowBytesTotal = saturatingProjectionBytes(
			s.presentationRowBytesTotal,
			s.presentationRowBytes[uid],
		)
		s.presentationUIDBytesTotal = saturatingProjectionBytes(
			s.presentationUIDBytesTotal,
			int64(len(uid)),
		)
		s.order = append(s.order, uid)
	}
	s.publishPresentationRetentionLocked()
	if s.presentationRevision == 0 {
		s.presentationRevision = 1
	}
	if s.indexRevision == 0 {
		s.indexRevision = 1
	}
	s.pendingInvalidation = true
	s.signalLocked(true)
}

func (s *Subscription) sealInitial(
	status *kmgrv1.ViewStatus,
	rows []*kmgrv1.ResourceRow,
	reconciled bool,
) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	s.sealInitialUnlocked(status, rows, reconciled)
}

func rankSearchObjects(
	query SearchQuery,
	objects []*unstructured.Unstructured,
	limit int,
	stale bool,
) []*kmgrv1.SearchResult {
	seen := newBoundedSearchResults(limit)
	for _, value := range objects {
		if !includesSearchNamespace(value.GetNamespace(), query.Resource, query.NamespaceScope) {
			continue
		}
		if rank, match := searchRank(query.Query, value.GetNamespace(), value.GetName()); match {
			seen.Add(makeSearchResult(query.SessionID, query.Resource, value, rank, stale))
		}
	}
	return seen.Sorted()
}

func NewSelectionSnapshot(
	generation, indexRevision uint64,
	identities []SelectionIdentity,
) (*SelectionSnapshot, error) {
	if generation == 0 || indexRevision == 0 {
		return nil, fmt.Errorf(
			"%w: generation and index revision must be nonzero",
			ErrInvalidSelectionSnapshot,
		)
	}
	frozen := make([]SelectionIdentity, len(identities))
	copy(frozen, identities)
	return newOwnedSelectionSnapshot(generation, indexRevision, frozen)
}
