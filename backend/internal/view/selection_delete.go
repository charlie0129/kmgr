package view

import (
	"context"
	"errors"
	"fmt"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
)

const (
	DefaultDeleteSelectionPreviewLimit = 16
	MaxDeleteSelectionPreviewLimit     = 64
	selectionDeleteCancellationStride  = 256
)

type SelectionDeletePreview struct {
	Identity SelectionIdentity
	Hidden   bool
}

// SelectionDeleteDescription contains the exact bounded facts needed to show
// a destructive confirmation without materializing the complete selection.
type SelectionDeleteDescription struct {
	State         SelectionState
	Resource      SelectionResource
	Generation    uint64
	IndexRevision uint64
	HiddenCount   uint64
	Preview       []SelectionDeletePreview
}

func (r *Runtime) AcquireSelectionLease(
	sessionID, viewID, token string,
) (*SelectionLease, error) {
	store, err := r.runtimeSelectionStore()
	if err != nil {
		return nil, err
	}
	return store.AcquireSelectionLease(
		SelectionScope{SessionID: sessionID, ViewID: viewID}, token,
	)
}

// PrepareSelectionDelete computes hidden count against one exact current
// filtered index. It pins the subscription once, validates the requested
// revision at that linearization point, and returns those exact facts even if
// a later WATCH event commits immediately after the scan.
func (r *Runtime) PrepareSelectionDelete(
	ctx context.Context,
	sessionID, viewID, token string,
	generation, indexRevision uint64,
	previewLimit uint32,
) (SelectionDeleteDescription, error) {
	return r.prepareSelectionDelete(
		ctx, sessionID, viewID, token, generation, indexRevision, previewLimit, nil,
	)
}

func (r *Runtime) prepareSelectionDelete(
	ctx context.Context,
	sessionID, viewID, token string,
	generation, indexRevision uint64,
	previewLimit uint32,
	afterPinnedScan func(),
) (SelectionDeleteDescription, error) {
	if ctx == nil {
		return SelectionDeleteDescription{}, errors.New("selection delete context must not be nil")
	}
	if generation == 0 || indexRevision == 0 {
		return SelectionDeleteDescription{}, fmt.Errorf(
			"%w: generation and index revision are required",
			ErrInvalidViewRange,
		)
	}
	if previewLimit == 0 {
		previewLimit = DefaultDeleteSelectionPreviewLimit
	}
	if previewLimit > MaxDeleteSelectionPreviewLimit {
		return SelectionDeleteDescription{}, fmt.Errorf(
			"%w: preview limit must not exceed %d",
			ErrInvalidSelectionPage,
			MaxDeleteSelectionPreviewLimit,
		)
	}
	lease, err := r.AcquireSelectionLease(sessionID, viewID, token)
	if err != nil {
		return SelectionDeleteDescription{}, err
	}
	defer lease.Release()
	state := lease.State()
	resource, ok := lease.Resource()
	if !ok || state.SelectedCount == 0 {
		return SelectionDeleteDescription{}, fmt.Errorf(
			"%w: selection contains no deletable identities",
			ErrInvalidSelectionPage,
		)
	}

	previewPageLimit := min(
		uint64(previewLimit), state.SelectedCount, uint64(lease.MaxPageSize()),
	)
	previewPage, err := lease.Page(0, uint32(previewPageLimit))
	if err != nil {
		return SelectionDeleteDescription{}, err
	}
	preview := make([]SelectionDeletePreview, len(previewPage.Items))
	previewIndexes := make(map[string]int, len(preview))
	for index, item := range previewPage.Items {
		preview[index] = SelectionDeletePreview{Identity: item.Identity, Hidden: true}
		previewIndexes[item.Identity.UID] = index
	}

	// Pin exactly one current index while computing every confirmation fact.
	// Requiring a busy large view to remain quiescent across selection pages
	// would make confirmation spuriously fail. Holding Subscription.mu for one
	// allocation-free intersection makes the requested revision the single
	// linearization point instead.
	subscription, err := r.lockActiveSubscription(sessionID, viewID, generation)
	if err != nil {
		return SelectionDeleteDescription{}, err
	}
	if subscription.indexRevision != indexRevision {
		current := subscription.indexRevision
		subscription.mu.Unlock()
		return SelectionDeleteDescription{}, fmt.Errorf(
			"%w: requested index %d, current %d",
			ErrStaleViewRevision,
			indexRevision,
			current,
		)
	}
	currentResource := subscription.projector.spec.Resource
	if currentResource.Group != resource.Group ||
		currentResource.Version != resource.Version ||
		currentResource.Resource != resource.Resource {
		subscription.mu.Unlock()
		return SelectionDeleteDescription{}, fmt.Errorf(
			"%w: current view GVR %q/%q/%q differs from selection GVR %q/%q/%q",
			ErrSelectionScopeMismatch,
			currentResource.Group,
			currentResource.Version,
			currentResource.Resource,
			resource.Group,
			resource.Version,
			resource.Resource,
		)
	}
	visibleCount, err := selectionDeleteVisibility(
		ctx, lease, subscription.rows, previewIndexes, preview,
	)
	subscription.mu.Unlock()
	if err != nil {
		return SelectionDeleteDescription{}, err
	}
	if afterPinnedScan != nil {
		afterPinnedScan()
	}

	// The pinned result remains exact for the requested revision even if a
	// later WATCH event commits immediately after the lock is released. Only
	// token expiry can invalidate non-destructive preparation at this point.
	if err := lease.ValidateActive(); err != nil {
		return SelectionDeleteDescription{}, err
	}
	if visibleCount > state.SelectedCount {
		return SelectionDeleteDescription{}, fmt.Errorf(
			"%w: current selected count exceeds immutable token count",
			ErrSelectionSnapshotConflict,
		)
	}
	return SelectionDeleteDescription{
		State: state, Resource: resource, Generation: generation,
		IndexRevision: indexRevision, HiddenCount: state.SelectedCount - visibleCount,
		Preview: preview,
	}, nil
}

// selectionDeleteVisibility intersects the smaller side of the current view
// and immutable selected set without copying either. Callers hold the current
// Subscription.mu; this helper holds the lease read lock for the complete
// scan so release cannot invalidate its snapshot midway through.
func selectionDeleteVisibility(
	ctx context.Context,
	lease *SelectionLease,
	currentRows map[string]*kmgrv1.ResourceRow,
	previewIndexes map[string]int,
	preview []SelectionDeletePreview,
) (uint64, error) {
	if ctx == nil {
		return 0, errors.New("selection delete context must not be nil")
	}
	if lease == nil {
		return 0, ErrSelectionTokenNotFound
	}
	lease.mu.RLock()
	defer lease.mu.RUnlock()
	if lease.released || lease.record == nil {
		return 0, ErrSelectionTokenNotFound
	}
	record := lease.record
	markVisible := func(uid string) {
		if previewIndex, found := previewIndexes[uid]; found {
			preview[previewIndex].Hidden = false
		}
	}
	var visibleCount uint64
	var scanned uint64
	checkCancellation := func() error {
		if scanned%selectionDeleteCancellationStride != 0 {
			return nil
		}
		return ctx.Err()
	}
	if uint64(len(currentRows)) < record.count {
		for uid, row := range currentRows {
			if err := checkCancellation(); err != nil {
				return 0, err
			}
			scanned++
			if row == nil {
				continue
			}
			index, found := record.snapshot.snapshot.uidToIndex[uid]
			if !found || !selectionContains(record.intervals, index) {
				continue
			}
			visibleCount++
			markVisible(uid)
		}
		return visibleCount, ctx.Err()
	}
	for _, interval := range record.intervals {
		for index := interval.Start; index < interval.End; index++ {
			if err := checkCancellation(); err != nil {
				return 0, err
			}
			scanned++
			uid := record.snapshot.snapshot.identities[index].UID
			if currentRows[uid] == nil {
				continue
			}
			visibleCount++
			markVisible(uid)
		}
	}
	return visibleCount, ctx.Err()
}
