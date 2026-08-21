package view

import (
	"errors"
	"fmt"
	"strings"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"k8s.io/apimachinery/pkg/types"
)

const (
	DefaultViewRangeLength     = 512
	DefaultViewRetentionLength = 8_192
)

var (
	ErrViewNotFound        = errors.New("resource view was not found")
	ErrStaleViewGeneration = errors.New("resource view generation is stale")
	ErrStaleViewRevision   = errors.New("resource view revision is stale")
	ErrInvalidViewRange    = errors.New("invalid resource view range")
)

// ViewRange is one immutable, revision-pinned slice of the backend-owned
// presentation. Projected ResourceRows are immutable after publication;
// commits replace pointers rather than mutating messages. Fetch therefore
// copies only the bounded pointer slice while locked, and gRPC reads it after
// the lock is released without retaining or modifying messages.
type ViewRange struct {
	Generation           uint64
	PresentationRevision uint64
	IndexRevision        uint64
	StartIndex           uint64
	RowsVisible          uint64
	Rows                 []*kmgrv1.ResourceRow
}

// FetchRange returns only the requested portion of the active generation.
// Both revisions are required: index revision pins numeric positions while
// presentation revision prevents a cell update from returning mixed content.
func (r *Runtime) FetchRange(
	sessionID, viewID string,
	generation, presentationRevision, indexRevision, startIndex uint64,
	length uint32,
) (ViewRange, error) {
	if strings.TrimSpace(sessionID) == "" || strings.TrimSpace(viewID) == "" ||
		generation == 0 || presentationRevision == 0 || indexRevision == 0 {
		return ViewRange{}, fmt.Errorf("%w: session, view, generation, and revisions are required", ErrInvalidViewRange)
	}
	if err := validateRangeLength(length); err != nil {
		return ViewRange{}, err
	}
	subscription, err := r.lockActiveSubscription(sessionID, viewID, generation)
	if err != nil {
		return ViewRange{}, err
	}
	defer subscription.mu.Unlock()

	if subscription.presentationRevision != presentationRevision || subscription.indexRevision != indexRevision {
		return ViewRange{}, fmt.Errorf(
			"%w: requested presentation/index %d/%d, current %d/%d",
			ErrStaleViewRevision,
			presentationRevision,
			indexRevision,
			subscription.presentationRevision,
			subscription.indexRevision,
		)
	}
	total := uint64(len(subscription.order))
	if startIndex > total {
		return ViewRange{}, fmt.Errorf(
			"%w: start index %d exceeds row count %d", ErrInvalidViewRange, startIndex, total,
		)
	}
	endIndex := total
	if requestedEnd := startIndex + uint64(length); requestedEnd >= startIndex && requestedEnd < endIndex {
		endIndex = requestedEnd
	}
	rows := make([]*kmgrv1.ResourceRow, 0, endIndex-startIndex)
	for _, uid := range subscription.order[startIndex:endIndex] {
		row := subscription.rows[uid]
		if row == nil {
			// order and rows are committed atomically under Subscription.mu. A
			// missing row would indicate an internal invariant violation, not a
			// partial range that is safe to expose.
			return ViewRange{}, fmt.Errorf("resource view index references missing row %q", uid)
		}
		rows = append(rows, row)
	}
	return ViewRange{
		Generation:           subscription.generation,
		PresentationRevision: subscription.presentationRevision,
		IndexRevision:        subscription.indexRevision,
		StartIndex:           startIndex,
		RowsVisible:          total,
		Rows:                 rows,
	}, nil
}

// UpdateMetricInterest validates a range-only viewport hint against the
// current index. Exact PodMetrics fetching is attached separately; accepting a
// hint here must never silently rebind numeric positions after a reorder.
func (r *Runtime) UpdateMetricInterest(
	sessionID, viewID string,
	generation, indexRevision, startIndex uint64,
	length uint32,
) error {
	if strings.TrimSpace(sessionID) == "" || strings.TrimSpace(viewID) == "" ||
		generation == 0 || indexRevision == 0 {
		return fmt.Errorf("%w: session, view, generation, and index revision are required", ErrInvalidViewRange)
	}
	if err := validateRetentionLength(length); err != nil {
		return err
	}
	subscription, err := r.lockActiveSubscription(sessionID, viewID, generation)
	if err != nil {
		return err
	}
	if subscription.indexRevision != indexRevision {
		subscription.mu.Unlock()
		return fmt.Errorf(
			"%w: requested index %d, current %d",
			ErrStaleViewRevision, indexRevision, subscription.indexRevision,
		)
	}
	if startIndex > uint64(len(subscription.order)) {
		subscription.mu.Unlock()
		return fmt.Errorf(
			"%w: start index %d exceeds row count %d",
			ErrInvalidViewRange, startIndex, len(subscription.order),
		)
	}
	endIndex := uint64(len(subscription.order))
	if requestedEnd := startIndex + uint64(length); requestedEnd >= startIndex && requestedEnd < endIndex {
		endIndex = requestedEnd
	}
	uids := make([]types.UID, 0, endIndex-startIndex)
	for _, uid := range subscription.order[startIndex:endIndex] {
		uids = append(uids, types.UID(uid))
	}
	subscription.mu.Unlock()
	subscription.updateMetricInterest(indexRevision, uids)
	return nil
}

func validateRangeLength(length uint32) error {
	if length == 0 || length > DefaultViewRangeLength {
		return fmt.Errorf(
			"%w: length must be between 1 and %d", ErrInvalidViewRange, DefaultViewRangeLength,
		)
	}
	return nil
}

func validateRetentionLength(length uint32) error {
	if length == 0 || length > DefaultViewRetentionLength {
		return fmt.Errorf(
			"%w: length must be between 1 and %d", ErrInvalidViewRange, DefaultViewRetentionLength,
		)
	}
	return nil
}

// lockActiveSubscription returns with Subscription.mu held. The second
// Runtime.views lookup is intentional: replacement publication locks the old
// subscription before swapping the map entry, so this order makes generation
// replacement and range fetch linearizable without ever taking Runtime.mu
// before Subscription.mu.
func (r *Runtime) lockActiveSubscription(
	sessionID, viewID string,
	generation uint64,
) (*Subscription, error) {
	key := viewKey{sessionID: sessionID, viewID: viewID}
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return nil, ErrViewClosed
	}
	subscription := r.views[key]
	r.mu.Unlock()
	if subscription == nil {
		return nil, ErrViewNotFound
	}
	if subscription.generation != generation {
		return nil, fmt.Errorf(
			"%w: requested %d, current %d",
			ErrStaleViewGeneration, generation, subscription.generation,
		)
	}

	subscription.mu.Lock()
	r.mu.Lock()
	closed := r.closed
	active := r.views[key]
	r.mu.Unlock()
	if closed || subscription.closed {
		subscription.mu.Unlock()
		return nil, ErrViewClosed
	}
	if active != subscription || active.generation != generation {
		subscription.mu.Unlock()
		if active == nil {
			return nil, ErrViewNotFound
		}
		return nil, fmt.Errorf(
			"%w: requested %d, current %d",
			ErrStaleViewGeneration, generation, active.generation,
		)
	}
	return subscription, nil
}
