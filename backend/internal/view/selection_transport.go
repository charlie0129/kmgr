package view

import (
	"errors"
	"fmt"
	"strings"
)

var ErrSelectionStoreUnavailable = errors.New("selection store is unavailable")

// SelectionRangeProjection is one UID-based projection of an immutable token
// onto a revision-pinned portion of the current backend ordering.
type SelectionRangeProjection struct {
	Generation    uint64
	IndexRevision uint64
	StartIndex    uint64
	RowsVisible   uint64
	Membership    SelectionMembership
}

// ApplySelectionGesture validates numeric input against the complete current
// ordering while Subscription.mu is held, then creates a new immutable token.
// A concurrent later index commit cannot retarget the captured snapshot.
func (r *Runtime) ApplySelectionGesture(
	sessionID, viewID string,
	generation, indexRevision uint64,
	previousToken string,
	gesture SelectionGesture,
) (SelectionState, error) {
	store, err := r.runtimeSelectionStore()
	if err != nil {
		return SelectionState{}, err
	}
	scope := SelectionScope{SessionID: sessionID, ViewID: viewID}
	if err := validateSelectionScope(scope); err != nil {
		return SelectionState{}, err
	}
	if generation == 0 || indexRevision == 0 {
		return SelectionState{}, fmt.Errorf(
			"%w: generation and index revision are required",
			ErrInvalidSelectionGesture,
		)
	}
	// Reject expired, missing, or cross-scope predecessors before paying the
	// O(total rows) cost of a first snapshot build. Apply validates it again at
	// the linearization point and never extends its expiry.
	if previousToken != "" {
		if _, err := store.Describe(scope, previousToken); err != nil {
			return SelectionState{}, err
		}
	}

	subscription, err := r.lockActiveSubscription(sessionID, viewID, generation)
	if err != nil {
		return SelectionState{}, err
	}
	if subscription.indexRevision != indexRevision {
		subscription.mu.Unlock()
		return SelectionState{}, fmt.Errorf(
			"%w: requested index %d, current %d",
			ErrStaleViewRevision,
			indexRevision,
			subscription.indexRevision,
		)
	}
	if err := validateSelectionGesture(gesture, uint64(len(subscription.order))); err != nil {
		subscription.mu.Unlock()
		return SelectionState{}, err
	}
	snapshot := subscription.selectionSnapshot
	if snapshot != nil && (snapshot.Generation() != generation || snapshot.IndexRevision() != indexRevision) {
		subscription.selectionSnapshot = nil
		snapshot = nil
	}
	builtSnapshot := snapshot == nil
	if builtSnapshot {
		identities, captureErr := subscription.captureSelectionIdentitiesLocked()
		buildHook := subscription.selectionSnapshotBuildHook
		subscription.mu.Unlock()
		if captureErr != nil {
			return SelectionState{}, captureErr
		}
		// Hashing, UID indexing, and string ownership can be O(total rows).
		// Keep that work off Subscription.mu so WATCH projection and range fetches
		// remain responsive even for the maximum supported presentation.
		if buildHook != nil {
			buildHook()
		}
		snapshot, err = buildSelectionSnapshot(generation, indexRevision, identities)
		if err != nil {
			return SelectionState{}, err
		}

	} else {
		subscription.mu.Unlock()
	}
	state, err := store.Apply(
		scope,
		snapshot,
		previousToken,
		gesture,
	)
	if err != nil {
		return SelectionState{}, err
	}
	if !builtSnapshot {
		return state, nil
	}
	// Publish only after bounded store admission succeeds. Ask the store for
	// its canonical pointer because another concurrent gesture may have won
	// admission with an equivalent independently built snapshot.
	canonical, err := store.snapshotForToken(scope, state.Token)
	if err != nil {
		return SelectionState{}, err
	}
	subscription.mu.Lock()
	if !subscription.closed && subscription.generation == generation &&
		subscription.indexRevision == indexRevision {
		subscription.selectionSnapshot = canonical
	}
	subscription.mu.Unlock()
	return state, nil
}

// ProjectSelectionRange resolves current absolute positions under the active
// subscription lock and compares only their UIDs with the token's pinned
// snapshot. The store validates the same session/logical-view scope before
// projection, so UID collisions in another view cannot inherit selection. This
// remains correct across reorder, insertion, deletion, and live generations of
// the same logical view.
func (r *Runtime) ProjectSelectionRange(
	sessionID, viewID string,
	generation, indexRevision, startIndex uint64,
	length uint32,
	token string,
) (SelectionRangeProjection, error) {
	store, err := r.runtimeSelectionStore()
	if err != nil {
		return SelectionRangeProjection{}, err
	}
	scope := SelectionScope{SessionID: sessionID, ViewID: viewID}
	if err := validateSelectionScope(scope); err != nil {
		return SelectionRangeProjection{}, err
	}
	if generation == 0 || indexRevision == 0 {
		return SelectionRangeProjection{}, fmt.Errorf(
			"%w: generation and index revision are required",
			ErrInvalidViewRange,
		)
	}
	if err := validateRangeLength(length); err != nil {
		return SelectionRangeProjection{}, err
	}

	subscription, err := r.lockActiveSubscription(sessionID, viewID, generation)
	if err != nil {
		return SelectionRangeProjection{}, err
	}
	if subscription.indexRevision != indexRevision {
		subscription.mu.Unlock()
		return SelectionRangeProjection{}, fmt.Errorf(
			"%w: requested index %d, current %d",
			ErrStaleViewRevision,
			indexRevision,
			subscription.indexRevision,
		)
	}
	total := uint64(len(subscription.order))
	if startIndex > total {
		subscription.mu.Unlock()
		return SelectionRangeProjection{}, fmt.Errorf(
			"%w: start index %d exceeds row count %d",
			ErrInvalidViewRange,
			startIndex,
			total,
		)
	}
	endIndex := total
	if requestedEnd := startIndex + uint64(length); requestedEnd >= startIndex && requestedEnd < endIndex {
		endIndex = requestedEnd
	}
	visibleUIDs := make([]string, 0, endIndex-startIndex)
	for _, uid := range subscription.order[startIndex:endIndex] {
		visibleUIDs = append(visibleUIDs, uid)
	}
	subscription.mu.Unlock()

	membership, err := store.ProjectMembership(
		scope,
		token,
		visibleUIDs,
	)
	if err != nil {
		return SelectionRangeProjection{}, err
	}
	return SelectionRangeProjection{
		Generation:    generation,
		IndexRevision: indexRevision,
		StartIndex:    startIndex,
		RowsVisible:   total,
		Membership:    membership,
	}, nil
}

// FetchSelectionPage deliberately does not look up an active Subscription.
// Tokens and their immutable identities remain consumable after a view closes
// or advances to a different generation, until their fixed expiry.
func (r *Runtime) FetchSelectionPage(
	sessionID, viewID, token string,
	offset uint64,
	limit uint32,
) (SelectionPage, error) {
	store, err := r.runtimeSelectionStore()
	if err != nil {
		return SelectionPage{}, err
	}
	return store.Page(
		SelectionScope{SessionID: sessionID, ViewID: viewID},
		token,
		offset,
		limit,
	)
}

func (r *Runtime) runtimeSelectionStore() (*SelectionStore, error) {
	if r == nil || r.selectionStore == nil {
		return nil, ErrSelectionStoreUnavailable
	}
	return r.selectionStore, nil
}

// captureSelectionIdentitiesLocked copies compact identity values from the
// authoritative ordered ResourceRows. Callers must hold Subscription.mu. It
// deliberately performs no hashing, UID-map construction, or string cloning.
func (s *Subscription) captureSelectionIdentitiesLocked() ([]SelectionIdentity, error) {
	identities := make([]SelectionIdentity, 0, len(s.order))
	for index, uid := range s.order {
		row := s.rows[uid]
		if row == nil || row.GetIdentity() == nil {
			return nil, fmt.Errorf(
				"%w: ordered row %d (%q) has no identity",
				ErrInvalidSelectionSnapshot,
				index,
				uid,
			)
		}
		identity := row.GetIdentity()
		if identity.GetUid() != uid {
			return nil, fmt.Errorf(
				"%w: ordered UID %q does not match row identity %q",
				ErrInvalidSelectionSnapshot,
				uid,
				identity.GetUid(),
			)
		}
		identities = append(identities, SelectionIdentity{
			Group:     identity.GetGroup(),
			Version:   identity.GetVersion(),
			Resource:  identity.GetResource(),
			Namespace: identity.GetNamespace(),
			Name:      identity.GetName(),
			UID:       identity.GetUid(),
		})
	}
	return identities, nil
}

func buildSelectionSnapshot(
	generation, indexRevision uint64,
	identities []SelectionIdentity,
) (*SelectionSnapshot, error) {
	for index := range identities {
		identity := &identities[index]
		identity.Group = strings.Clone(identity.Group)
		identity.Version = strings.Clone(identity.Version)
		identity.Resource = strings.Clone(identity.Resource)
		identity.Namespace = strings.Clone(identity.Namespace)
		identity.Name = strings.Clone(identity.Name)
		identity.UID = strings.Clone(identity.UID)
	}
	return newOwnedSelectionSnapshot(generation, indexRevision, identities)
}
