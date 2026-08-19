package view

import (
	"fmt"
	"sync"
)

// SelectionResource is the exact GVR shared by every identity in one
// immutable selection snapshot.
type SelectionResource struct {
	Group    string
	Version  string
	Resource string
}

// SelectionLease pins an immutable token record after an active-before-expiry
// acquisition. Its fixed expiry still rejects new consumers, while the lease
// itself remains safe to page until Release so accepted work cannot be
// retargeted or aborted by token cleanup.
type SelectionLease struct {
	mu          sync.RWMutex
	store       *SelectionStore
	token       string
	record      *selectionTokenRecord
	maxPageSize uint32
	released    bool
}

// AcquireSelectionLease atomically validates scope and fixed expiry, then
// keeps the token and snapshot charged to the bounded store until Release.
func (s *SelectionStore) AcquireSelectionLease(
	scope SelectionScope,
	token string,
) (*SelectionLease, error) {
	if err := validateSelectionScope(scope); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	record, err := s.activeTokenLocked(scope, token, s.now())
	if err != nil {
		return nil, err
	}
	record.leaseRefs++
	return &SelectionLease{
		store: s, token: token, record: record, maxPageSize: s.config.MaxPageSize,
	}, nil
}

func (l *SelectionLease) State() SelectionState {
	if l == nil {
		return SelectionState{}
	}
	l.mu.RLock()
	defer l.mu.RUnlock()
	if l.released || l.record == nil {
		return SelectionState{}
	}
	return selectionState(l.token, l.record)
}

func (l *SelectionLease) Scope() SelectionScope {
	if l == nil {
		return SelectionScope{}
	}
	l.mu.RLock()
	defer l.mu.RUnlock()
	if l.released || l.record == nil {
		return SelectionScope{}
	}
	return l.record.scope
}

func (l *SelectionLease) Resource() (SelectionResource, bool) {
	if l == nil {
		return SelectionResource{}, false
	}
	l.mu.RLock()
	defer l.mu.RUnlock()
	if l.released || l.record == nil || l.record.count == 0 ||
		len(l.record.snapshot.snapshot.identities) == 0 {
		return SelectionResource{}, false
	}
	identity := l.record.snapshot.snapshot.identities[0]
	return SelectionResource{
		Group: identity.Group, Version: identity.Version, Resource: identity.Resource,
	}, true
}

// MaxPageSize is the normalized per-request limit inherited from the store.
// Consumers which page a lease internally use it to stay within the same
// bound as client-driven selection transport requests.
func (l *SelectionLease) MaxPageSize() uint32 {
	if l == nil {
		return 0
	}
	return l.maxPageSize
}

// Page resolves selected identities by selected-set rank without consulting
// wall-clock expiry. Acquire performed the only expiry gate for this lease.
func (l *SelectionLease) Page(
	offset uint64,
	limit uint32,
) (SelectionPage, error) {
	if l == nil {
		return SelectionPage{}, ErrSelectionTokenNotFound
	}
	l.mu.RLock()
	defer l.mu.RUnlock()
	if l.released || l.record == nil {
		return SelectionPage{}, ErrSelectionTokenNotFound
	}
	if limit == 0 || limit > l.maxPageSize {
		return SelectionPage{}, fmt.Errorf(
			"%w: limit must be between 1 and %d",
			ErrInvalidSelectionPage,
			l.maxPageSize,
		)
	}
	if offset > l.record.count {
		return SelectionPage{}, fmt.Errorf(
			"%w: offset %d exceeds selected count %d",
			ErrInvalidSelectionPage,
			offset,
			l.record.count,
		)
	}
	items := selectionPageItems(l.record, offset, uint64(limit))
	nextOffset := offset + uint64(len(items))
	return SelectionPage{
		State: selectionState(l.token, l.record), Offset: offset, Items: items,
		NextOffset: nextOffset, Done: nextOffset == l.record.count,
	}, nil
}

// ContainsUID projects one current UID onto the token's pinned selection.
func (l *SelectionLease) ContainsUID(uid string) bool {
	if l == nil || uid == "" {
		return false
	}
	l.mu.RLock()
	defer l.mu.RUnlock()
	if l.released || l.record == nil {
		return false
	}
	index, found := l.record.snapshot.snapshot.uidToIndex[uid]
	return found && selectionContains(l.record.intervals, index)
}

// ValidateActive is for non-destructive preparation work: unlike accepted
// mutation paging, confirmation must fail if its token expires while an exact
// hidden-count scan is in progress.
func (l *SelectionLease) ValidateActive() error {
	if l == nil {
		return ErrSelectionTokenNotFound
	}
	l.mu.RLock()
	defer l.mu.RUnlock()
	if l.released || l.store == nil || l.record == nil {
		return ErrSelectionTokenNotFound
	}
	_, err := l.store.Describe(l.record.scope, l.token)
	return err
}

func (l *SelectionLease) Release() {
	if l == nil {
		return
	}
	l.mu.Lock()
	if l.released {
		l.mu.Unlock()
		return
	}
	l.released = true
	store, record, token := l.store, l.record, l.token
	l.store = nil
	l.record = nil
	l.token = ""
	l.mu.Unlock()
	if store == nil || record == nil {
		return
	}
	store.mu.Lock()
	if record.leaseRefs > 0 {
		record.leaseRefs--
	}
	if record.leaseRefs == 0 && !store.now().Before(record.expiresAt) {
		store.removeTokenLocked(token, record)
	}
	store.mu.Unlock()
}
