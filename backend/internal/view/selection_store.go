package view

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"hash"
	"io"
	"sort"
	"strings"
	"sync"
	"time"
	"unsafe"
)

const (
	DefaultSelectionTokenTTL         = 5 * time.Minute
	DefaultMaxSelectionTokens        = 16_384
	DefaultMaxSelectionTokenBytes    = 64 << 20
	DefaultMaxSelectionSnapshots     = 256
	DefaultMaxSelectionSnapshotBytes = 256 << 20
	DefaultMaxSelectionPageSize      = 1_024

	selectionTokenEntropyBytes = 32
	selectionTokenEncodedBytes = (selectionTokenEntropyBytes*8 + 5) / 6
	selectionTokenMapBytes     = 64
	selectionSnapshotMapBytes  = 96
	selectionUIDMapBytes       = 48
)

var (
	ErrInvalidSelectionScope      = errors.New("invalid selection scope")
	ErrInvalidSelectionSnapshot   = errors.New("invalid selection snapshot")
	ErrSelectionSnapshotConflict  = errors.New("selection snapshot conflicts with its revision")
	ErrInvalidSelectionGesture    = errors.New("invalid selection gesture")
	ErrSelectionTokenNotFound     = errors.New("selection token was not found")
	ErrSelectionTokenExpired      = errors.New("selection token expired")
	ErrSelectionScopeMismatch     = errors.New("selection token belongs to another scope")
	ErrSelectionCapacityExhausted = errors.New("selection store capacity exhausted")
	ErrInvalidSelectionPage       = errors.New("invalid selection page")
)

// SelectionStoreConfig bounds all state which immutable selection tokens can
// retain. Limits are process-wide for one store. A zero value selects the
// corresponding default; negative values are invalid and never mean
// unlimited capacity.
type SelectionStoreConfig struct {
	TokenTTL         time.Duration
	MaxTokens        int
	MaxTokenBytes    int64
	MaxSnapshots     int
	MaxSnapshotBytes int64
	MaxPageSize      uint32
}

// SelectionScope prevents an opaque token from being consumed by another
// cluster session or logical view. ViewID is the stable client-owned logical
// identity across subscription generations; generation/index live in the
// immutable snapshot and cannot be numerically rebound.
type SelectionScope struct {
	SessionID string
	ViewID    string
}

// SelectionIdentity is the immutable, UID-authoritative identity retained in
// a selection snapshot. Cluster session is intentionally represented once by
// SelectionScope rather than repeated for every row.
type SelectionIdentity struct {
	Group     string
	Version   string
	Resource  string
	Namespace string
	Name      string
	UID       string
}

// SelectionSnapshot is one immutable presentation index. Construct it once
// per generation/index revision and reuse its pointer for every gesture. The
// constructor copies only the value slice; immutable string data and the
// snapshot's UID index are then shared by all tokens for that revision.
type SelectionSnapshot struct {
	generation    uint64
	indexRevision uint64
	identities    []SelectionIdentity
	uidToIndex    map[string]uint64
	fingerprint   [sha256.Size]byte
	retainedBytes int64
}

// newOwnedSelectionSnapshot consumes identities. Runtime uses it after
// capturing and cloning a private value slice, avoiding a second potentially
// large identity-array allocation while preserving NewSelectionSnapshot's
// public freeze guarantee.
func newOwnedSelectionSnapshot(
	generation, indexRevision uint64,
	identities []SelectionIdentity,
) (*SelectionSnapshot, error) {
	if generation == 0 || indexRevision == 0 {
		return nil, fmt.Errorf(
			"%w: generation and index revision must be nonzero",
			ErrInvalidSelectionSnapshot,
		)
	}
	frozen := identities
	uidToIndex := make(map[string]uint64, len(frozen))
	digest := sha256.New()
	writeSelectionHashUint64(digest, generation)
	writeSelectionHashUint64(digest, indexRevision)
	writeSelectionHashUint64(digest, uint64(len(frozen)))

	var group, version, resource string
	retainedBytes := int64(unsafe.Sizeof(SelectionSnapshot{})) +
		int64(len(frozen))*int64(unsafe.Sizeof(SelectionIdentity{}))
	for index, identity := range frozen {
		if err := validateSelectionIdentity(identity); err != nil {
			return nil, fmt.Errorf("%w: row %d: %v", ErrInvalidSelectionSnapshot, index, err)
		}
		if index == 0 {
			group, version, resource = identity.Group, identity.Version, identity.Resource
		} else if identity.Group != group || identity.Version != version || identity.Resource != resource {
			return nil, fmt.Errorf(
				"%w: row %d has GVR %q/%q/%q, expected %q/%q/%q",
				ErrInvalidSelectionSnapshot,
				index,
				identity.Group,
				identity.Version,
				identity.Resource,
				group,
				version,
				resource,
			)
		}
		if previous, duplicate := uidToIndex[identity.UID]; duplicate {
			return nil, fmt.Errorf(
				"%w: UID %q is duplicated at rows %d and %d",
				ErrInvalidSelectionSnapshot,
				identity.UID,
				previous,
				index,
			)
		}
		uidToIndex[identity.UID] = uint64(index)
		retainedBytes += int64(selectionUIDMapBytes + selectionIdentityStringBytes(identity))
		writeSelectionIdentityHash(digest, identity)
	}

	snapshot := &SelectionSnapshot{
		generation:    generation,
		indexRevision: indexRevision,
		identities:    frozen,
		uidToIndex:    uidToIndex,
		retainedBytes: retainedBytes,
	}
	copy(snapshot.fingerprint[:], digest.Sum(nil))
	return snapshot, nil
}

func (s *SelectionSnapshot) Generation() uint64 {
	if s == nil {
		return 0
	}
	return s.generation
}

func (s *SelectionSnapshot) IndexRevision() uint64 {
	if s == nil {
		return 0
	}
	return s.indexRevision
}

func (s *SelectionSnapshot) Len() uint64 {
	if s == nil {
		return 0
	}
	return uint64(len(s.identities))
}

func (s *SelectionSnapshot) RetainedBytes() int64 {
	if s == nil {
		return 0
	}
	return s.retainedBytes
}

type SelectionGestureKind uint8

const (
	SelectionGestureUnspecified SelectionGestureKind = iota
	SelectionGestureReplace
	SelectionGestureCommandToggle
	SelectionGestureShiftExtend
	SelectionGestureCommandAll
	SelectionGestureClear
)

// SelectionGesture describes one user action. Additive is meaningful only
// for ShiftExtend (Command-Shift); a plain ShiftExtend replaces the previous
// intervals with the anchor-to-target interval.
type SelectionGesture struct {
	Kind     SelectionGestureKind
	Index    uint64
	Additive bool
}

type SelectionInterval struct {
	Start uint64
	End   uint64
}

type SelectionAnchor struct {
	Index uint64
	UID   string
}

// SelectionState is safe to return over a transport. ExpiresAt is fixed when
// the token is created; reading or consuming the token never extends it.
type SelectionState struct {
	Token         string
	Generation    uint64
	IndexRevision uint64
	SelectedCount uint64
	Anchor        *SelectionAnchor
	ExpiresAt     time.Time
}

type SelectionPageItem struct {
	Index    uint64
	Identity SelectionIdentity
}

type SelectionPage struct {
	State      SelectionState
	Offset     uint64
	Items      []SelectionPageItem
	NextOffset uint64
	Done       bool
}

type SelectionMembership struct {
	State        SelectionState
	Selected     []bool
	AnchorOffset *uint32
}

type SelectionStoreStats struct {
	ActiveTokens    int
	TokenBytes      int64
	ActiveSnapshots int
	SnapshotBytes   int64
}

type selectionSnapshotKey struct {
	scope         SelectionScope
	generation    uint64
	indexRevision uint64
}

type selectionSnapshotEntry struct {
	snapshot *SelectionSnapshot
	refs     int
	bytes    int64
}

type selectionTokenRecord struct {
	scope     SelectionScope
	snapshot  *selectionSnapshotEntry
	intervals []SelectionInterval
	prefix    []uint64
	count     uint64
	anchor    *uint64
	expiresAt time.Time
	bytes     int64
	leaseRefs int
}

type selectionStoreDependencies struct {
	now    func() time.Time
	random io.Reader
}

// SelectionStore owns immutable tokens and revision-scoped identity
// snapshots. It never evicts an unexpired token: callers receive an explicit
// capacity error and may retry after an expiry instead.
type SelectionStore struct {
	mu sync.Mutex

	config SelectionStoreConfig
	now    func() time.Time
	random io.Reader

	tokens        map[string]*selectionTokenRecord
	snapshots     map[selectionSnapshotKey]*selectionSnapshotEntry
	tokenBytes    int64
	snapshotBytes int64
}

func NewSelectionStore(config SelectionStoreConfig) (*SelectionStore, error) {
	return newSelectionStore(config, selectionStoreDependencies{now: time.Now, random: rand.Reader})
}

func newSelectionStore(
	config SelectionStoreConfig,
	dependencies selectionStoreDependencies,
) (*SelectionStore, error) {
	var err error
	if config, err = normalizeSelectionStoreConfig(config); err != nil {
		return nil, err
	}
	if dependencies.now == nil {
		return nil, errors.New("selection store clock must not be nil")
	}
	if dependencies.random == nil {
		return nil, errors.New("selection store random source must not be nil")
	}
	return &SelectionStore{
		config:    config,
		now:       dependencies.now,
		random:    dependencies.random,
		tokens:    make(map[string]*selectionTokenRecord),
		snapshots: make(map[selectionSnapshotKey]*selectionSnapshotEntry),
	}, nil
}

// Apply creates a new immutable token for one gesture. A previous token is
// continued only when scope, generation, and index revision all match the
// supplied current snapshot. A generation or index change deliberately starts
// a fresh selection, so numeric positions can never silently retarget.
func (s *SelectionStore) Apply(
	scope SelectionScope,
	snapshot *SelectionSnapshot,
	previousToken string,
	gesture SelectionGesture,
) (SelectionState, error) {
	if err := validateSelectionScope(scope); err != nil {
		return SelectionState{}, err
	}
	if snapshot == nil {
		return SelectionState{}, fmt.Errorf("%w: snapshot is required", ErrInvalidSelectionSnapshot)
	}
	if err := validateSelectionGesture(gesture, snapshot.Len()); err != nil {
		return SelectionState{}, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	var previous *selectionTokenRecord
	if previousToken != "" {
		var err error
		previous, err = s.activeTokenLocked(scope, previousToken, now)
		if err != nil {
			return SelectionState{}, err
		}
	}
	s.removeExpiredLocked(now)

	key := selectionSnapshotKey{
		scope: scope, generation: snapshot.generation, indexRevision: snapshot.indexRevision,
	}
	entry := s.snapshots[key]
	if entry != nil && !sameSelectionSnapshot(entry.snapshot, snapshot) {
		return SelectionState{}, fmt.Errorf(
			"%w: session %q view %q generation %d index revision %d",
			ErrSelectionSnapshotConflict,
			scope.SessionID,
			scope.ViewID,
			snapshot.generation,
			snapshot.indexRevision,
		)
	}

	var base []SelectionInterval
	var anchor *uint64
	if previous != nil &&
		previous.snapshot.snapshot.generation == snapshot.generation &&
		previous.snapshot.snapshot.indexRevision == snapshot.indexRevision {
		if !sameSelectionSnapshot(previous.snapshot.snapshot, snapshot) {
			return SelectionState{}, fmt.Errorf(
				"%w: current identities differ from the token's pinned index",
				ErrSelectionSnapshotConflict,
			)
		}
		entry = previous.snapshot
		base = previous.intervals
		anchor = copySelectionIndex(previous.anchor)
	}

	intervals, nextAnchor := applySelectionGesture(base, anchor, snapshot.Len(), gesture)
	prefix, selectedCount := selectionIntervalPrefix(intervals)
	if len(s.tokens) >= s.config.MaxTokens {
		return SelectionState{}, fmt.Errorf(
			"%w: active token limit %d reached",
			ErrSelectionCapacityExhausted,
			s.config.MaxTokens,
		)
	}
	tokenBytes := retainedSelectionTokenBytes(scope, intervals, prefix)
	if tokenBytes > s.config.MaxTokenBytes-s.tokenBytes {
		return SelectionState{}, fmt.Errorf(
			"%w: token memory limit %d bytes reached",
			ErrSelectionCapacityExhausted,
			s.config.MaxTokenBytes,
		)
	}

	newSnapshot := entry == nil
	if newSnapshot {
		if len(s.snapshots) >= s.config.MaxSnapshots {
			return SelectionState{}, fmt.Errorf(
				"%w: active snapshot limit %d reached",
				ErrSelectionCapacityExhausted,
				s.config.MaxSnapshots,
			)
		}
		snapshotBytes := retainedSelectionSnapshotBytes(scope, snapshot)
		if snapshotBytes > s.config.MaxSnapshotBytes-s.snapshotBytes {
			return SelectionState{}, fmt.Errorf(
				"%w: snapshot memory limit %d bytes reached",
				ErrSelectionCapacityExhausted,
				s.config.MaxSnapshotBytes,
			)
		}
		entry = &selectionSnapshotEntry{snapshot: snapshot, bytes: snapshotBytes}
	}

	token, err := s.newTokenLocked()
	if err != nil {
		return SelectionState{}, fmt.Errorf("generate selection token: %w", err)
	}
	if newSnapshot {
		s.snapshots[key] = entry
		s.snapshotBytes += entry.bytes
	}
	entry.refs++
	record := &selectionTokenRecord{
		scope: scope, snapshot: entry, intervals: intervals, prefix: prefix,
		count: selectedCount, anchor: nextAnchor,
		expiresAt: now.Add(s.config.TokenTTL), bytes: tokenBytes,
	}
	s.tokens[token] = record
	s.tokenBytes += tokenBytes
	return selectionState(token, record), nil
}

// Describe returns count, anchor, revision, and fixed expiry without exposing
// or changing the token's interval representation.
func (s *SelectionStore) Describe(scope SelectionScope, token string) (SelectionState, error) {
	if err := validateSelectionScope(scope); err != nil {
		return SelectionState{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	record, err := s.activeTokenLocked(scope, token, s.now())
	if err != nil {
		return SelectionState{}, err
	}
	return selectionState(token, record), nil
}

// snapshotForToken is a runtime integration hook. It lets a Subscription
// publish the exact canonical pointer retained by the bounded store after two
// concurrent first gestures independently build equivalent snapshots.
func (s *SelectionStore) snapshotForToken(
	scope SelectionScope,
	token string,
) (*SelectionSnapshot, error) {
	if err := validateSelectionScope(scope); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	record, err := s.activeTokenLocked(scope, token, s.now())
	if err != nil {
		return nil, err
	}
	return record.snapshot.snapshot, nil
}

// Page returns selected identities in pinned index order. Offset is a rank in
// the selected set, not a row index, and limit is bounded by MaxPageSize.
func (s *SelectionStore) Page(
	scope SelectionScope,
	token string,
	offset uint64,
	limit uint32,
) (SelectionPage, error) {
	if err := validateSelectionScope(scope); err != nil {
		return SelectionPage{}, err
	}
	if limit == 0 || limit > s.config.MaxPageSize {
		return SelectionPage{}, fmt.Errorf(
			"%w: limit must be between 1 and %d",
			ErrInvalidSelectionPage,
			s.config.MaxPageSize,
		)
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	record, err := s.activeTokenLocked(scope, token, s.now())
	if err != nil {
		return SelectionPage{}, err
	}
	if offset > record.count {
		return SelectionPage{}, fmt.Errorf(
			"%w: offset %d exceeds selected count %d",
			ErrInvalidSelectionPage,
			offset,
			record.count,
		)
	}
	items := selectionPageItems(record, offset, uint64(limit))
	nextOffset := offset + uint64(len(items))
	return SelectionPage{
		State:      selectionState(token, record),
		Offset:     offset,
		Items:      items,
		NextOffset: nextOffset,
		Done:       nextOffset == record.count,
	}, nil
}

// ProjectMembership maps a current visible range to the token's immutable
// identities by UID. It remains correct after reorder/removal because visible
// numeric positions are never compared with the token's pinned positions.
func (s *SelectionStore) ProjectMembership(
	scope SelectionScope,
	token string,
	visibleUIDs []string,
) (SelectionMembership, error) {
	if err := validateSelectionScope(scope); err != nil {
		return SelectionMembership{}, err
	}
	if len(visibleUIDs) > int(s.config.MaxPageSize) {
		return SelectionMembership{}, fmt.Errorf(
			"%w: visible range has %d rows; maximum is %d",
			ErrInvalidSelectionPage,
			len(visibleUIDs),
			s.config.MaxPageSize,
		)
	}
	for index, uid := range visibleUIDs {
		if uid == "" || strings.TrimSpace(uid) != uid {
			return SelectionMembership{}, fmt.Errorf(
				"%w: visible row %d has an invalid UID",
				ErrInvalidSelectionPage,
				index,
			)
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	record, err := s.activeTokenLocked(scope, token, s.now())
	if err != nil {
		return SelectionMembership{}, err
	}
	selected := make([]bool, len(visibleUIDs))
	var anchorOffset *uint32
	anchorUID := ""
	if record.anchor != nil {
		anchorUID = record.snapshot.snapshot.identities[*record.anchor].UID
	}
	for offset, uid := range visibleUIDs {
		if index, exists := record.snapshot.snapshot.uidToIndex[uid]; exists {
			selected[offset] = selectionContains(record.intervals, index)
		}
		if anchorOffset == nil && uid == anchorUID {
			value := uint32(offset)
			anchorOffset = &value
		}
	}
	return SelectionMembership{
		State: selectionState(token, record), Selected: selected, AnchorOffset: anchorOffset,
	}, nil
}

// Stats cleans expired tokens and reports currently retained admission state.
func (s *SelectionStore) Stats() SelectionStoreStats {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.removeExpiredLocked(s.now())
	return SelectionStoreStats{
		ActiveTokens: len(s.tokens), TokenBytes: s.tokenBytes,
		ActiveSnapshots: len(s.snapshots), SnapshotBytes: s.snapshotBytes,
	}
}

func (s *SelectionStore) activeTokenLocked(
	scope SelectionScope,
	token string,
	now time.Time,
) (*selectionTokenRecord, error) {
	if token == "" {
		return nil, ErrSelectionTokenNotFound
	}
	record := s.tokens[token]
	if record == nil {
		return nil, ErrSelectionTokenNotFound
	}
	if record.scope != scope {
		return nil, ErrSelectionScopeMismatch
	}
	if !now.Before(record.expiresAt) {
		s.removeTokenLocked(token, record)
		return nil, ErrSelectionTokenExpired
	}
	return record, nil
}

func (s *SelectionStore) removeExpiredLocked(now time.Time) {
	for token, record := range s.tokens {
		if !now.Before(record.expiresAt) {
			s.removeTokenLocked(token, record)
		}
	}
}

func (s *SelectionStore) removeTokenLocked(token string, record *selectionTokenRecord) {
	if record.leaseRefs > 0 {
		// An accepted destructive operation owns the immutable token record until
		// its worker exits. Expiry makes it unavailable to new consumers but does
		// not invalidate or under-account the already acquired memory.
		return
	}
	delete(s.tokens, token)
	s.tokenBytes -= record.bytes
	record.snapshot.refs--
	if record.snapshot.refs != 0 {
		return
	}
	snapshot := record.snapshot.snapshot
	key := selectionSnapshotKey{
		scope: record.scope, generation: snapshot.generation, indexRevision: snapshot.indexRevision,
	}
	delete(s.snapshots, key)
	s.snapshotBytes -= record.snapshot.bytes
}

func (s *SelectionStore) newTokenLocked() (string, error) {
	buffer := make([]byte, selectionTokenEntropyBytes)
	for attempt := 0; attempt < 8; attempt++ {
		if _, err := io.ReadFull(s.random, buffer); err != nil {
			return "", err
		}
		token := base64.RawURLEncoding.EncodeToString(buffer)
		if _, collision := s.tokens[token]; !collision {
			return token, nil
		}
	}
	return "", errors.New("random source produced repeated token collisions")
}

func normalizeSelectionStoreConfig(config SelectionStoreConfig) (SelectionStoreConfig, error) {
	if config.TokenTTL < 0 || config.MaxTokens < 0 || config.MaxTokenBytes < 0 ||
		config.MaxSnapshots < 0 || config.MaxSnapshotBytes < 0 {
		return SelectionStoreConfig{}, errors.New("selection store limits must not be negative")
	}
	if config.TokenTTL == 0 {
		config.TokenTTL = DefaultSelectionTokenTTL
	}
	if config.MaxTokens == 0 {
		config.MaxTokens = DefaultMaxSelectionTokens
	}
	if config.MaxTokenBytes == 0 {
		config.MaxTokenBytes = DefaultMaxSelectionTokenBytes
	}
	if config.MaxSnapshots == 0 {
		config.MaxSnapshots = DefaultMaxSelectionSnapshots
	}
	if config.MaxSnapshotBytes == 0 {
		config.MaxSnapshotBytes = DefaultMaxSelectionSnapshotBytes
	}
	if config.MaxPageSize == 0 {
		config.MaxPageSize = DefaultMaxSelectionPageSize
	}
	return config, nil
}

func validateSelectionScope(scope SelectionScope) error {
	if scope.SessionID == "" || strings.TrimSpace(scope.SessionID) != scope.SessionID ||
		scope.ViewID == "" || strings.TrimSpace(scope.ViewID) != scope.ViewID {
		return fmt.Errorf("%w: session and view IDs must be nonblank and trimmed", ErrInvalidSelectionScope)
	}
	return nil
}

func validateSelectionIdentity(identity SelectionIdentity) error {
	fields := []struct {
		name     string
		value    string
		required bool
	}{
		{name: "group", value: identity.Group},
		{name: "version", value: identity.Version, required: true},
		{name: "resource", value: identity.Resource, required: true},
		{name: "namespace", value: identity.Namespace},
		{name: "name", value: identity.Name, required: true},
		{name: "UID", value: identity.UID, required: true},
	}
	for _, field := range fields {
		if field.required && field.value == "" {
			return fmt.Errorf("%s must not be empty", field.name)
		}
		if strings.TrimSpace(field.value) != field.value {
			return fmt.Errorf("%s must be trimmed", field.name)
		}
	}
	return nil
}

func validateSelectionGesture(gesture SelectionGesture, rowCount uint64) error {
	switch gesture.Kind {
	case SelectionGestureReplace, SelectionGestureCommandToggle, SelectionGestureShiftExtend:
		if gesture.Index >= rowCount {
			return fmt.Errorf(
				"%w: row index %d exceeds row count %d",
				ErrInvalidSelectionGesture,
				gesture.Index,
				rowCount,
			)
		}
	case SelectionGestureCommandAll, SelectionGestureClear:
		if gesture.Additive {
			return fmt.Errorf("%w: additive applies only to shift extension", ErrInvalidSelectionGesture)
		}
	default:
		return fmt.Errorf("%w: unsupported gesture kind %d", ErrInvalidSelectionGesture, gesture.Kind)
	}
	if gesture.Kind != SelectionGestureShiftExtend && gesture.Additive {
		return fmt.Errorf("%w: additive applies only to shift extension", ErrInvalidSelectionGesture)
	}
	return nil
}

func applySelectionGesture(
	base []SelectionInterval,
	anchor *uint64,
	rowCount uint64,
	gesture SelectionGesture,
) ([]SelectionInterval, *uint64) {
	switch gesture.Kind {
	case SelectionGestureReplace:
		return []SelectionInterval{{Start: gesture.Index, End: gesture.Index + 1}}, selectionIndex(gesture.Index)
	case SelectionGestureCommandToggle:
		return toggleSelectionIndex(base, gesture.Index), selectionIndex(gesture.Index)
	case SelectionGestureShiftExtend:
		if anchor == nil {
			return []SelectionInterval{{Start: gesture.Index, End: gesture.Index + 1}}, selectionIndex(gesture.Index)
		}
		start, end := min(*anchor, gesture.Index), max(*anchor, gesture.Index)+1
		if gesture.Additive {
			return addSelectionInterval(base, SelectionInterval{Start: start, End: end}), copySelectionIndex(anchor)
		}
		return []SelectionInterval{{Start: start, End: end}}, copySelectionIndex(anchor)
	case SelectionGestureCommandAll:
		if rowCount == 0 {
			return nil, copySelectionIndex(anchor)
		}
		return []SelectionInterval{{Start: 0, End: rowCount}}, copySelectionIndex(anchor)
	case SelectionGestureClear:
		return nil, nil
	default:
		panic("validated selection gesture has an unsupported kind")
	}
}

func toggleSelectionIndex(intervals []SelectionInterval, index uint64) []SelectionInterval {
	position := sort.Search(len(intervals), func(i int) bool { return intervals[i].End > index })
	if position == len(intervals) || intervals[position].Start > index {
		return addSelectionInterval(intervals, SelectionInterval{Start: index, End: index + 1})
	}
	current := intervals[position]
	result := make([]SelectionInterval, 0, len(intervals)+1)
	result = append(result, intervals[:position]...)
	if current.Start < index {
		result = append(result, SelectionInterval{Start: current.Start, End: index})
	}
	if index+1 < current.End {
		result = append(result, SelectionInterval{Start: index + 1, End: current.End})
	}
	result = append(result, intervals[position+1:]...)
	return result
}

func addSelectionInterval(intervals []SelectionInterval, added SelectionInterval) []SelectionInterval {
	result := make([]SelectionInterval, 0, len(intervals)+1)
	inserted := false
	for _, current := range intervals {
		if current.End < added.Start {
			result = append(result, current)
			continue
		}
		if added.End < current.Start {
			if !inserted {
				result = append(result, added)
				inserted = true
			}
			result = append(result, current)
			continue
		}
		added.Start = min(added.Start, current.Start)
		added.End = max(added.End, current.End)
	}
	if !inserted {
		result = append(result, added)
	}
	return result
}

func selectionIntervalPrefix(intervals []SelectionInterval) ([]uint64, uint64) {
	if len(intervals) == 0 {
		return nil, 0
	}
	prefix := make([]uint64, len(intervals)+1)
	for index, interval := range intervals {
		prefix[index+1] = prefix[index] + interval.End - interval.Start
	}
	return prefix, prefix[len(prefix)-1]
}

func selectionPageItems(
	record *selectionTokenRecord,
	offset, limit uint64,
) []SelectionPageItem {
	remaining := min(limit, record.count-offset)
	items := make([]SelectionPageItem, 0, remaining)
	if remaining == 0 {
		return items
	}
	intervalIndex := sort.Search(len(record.intervals), func(index int) bool {
		return record.prefix[index+1] > offset
	})
	index := record.intervals[intervalIndex].Start + offset - record.prefix[intervalIndex]
	for remaining > 0 {
		interval := record.intervals[intervalIndex]
		for index < interval.End && remaining > 0 {
			items = append(items, SelectionPageItem{
				Index: index, Identity: record.snapshot.snapshot.identities[index],
			})
			index++
			remaining--
		}
		intervalIndex++
		if remaining > 0 {
			index = record.intervals[intervalIndex].Start
		}
	}
	return items
}

func selectionContains(intervals []SelectionInterval, index uint64) bool {
	position := sort.Search(len(intervals), func(i int) bool { return intervals[i].End > index })
	return position < len(intervals) && intervals[position].Start <= index
}

func selectionState(token string, record *selectionTokenRecord) SelectionState {
	state := SelectionState{
		Token:         token,
		Generation:    record.snapshot.snapshot.generation,
		IndexRevision: record.snapshot.snapshot.indexRevision,
		SelectedCount: record.count,
		ExpiresAt:     record.expiresAt,
	}
	if record.anchor != nil {
		state.Anchor = &SelectionAnchor{
			Index: *record.anchor,
			UID:   record.snapshot.snapshot.identities[*record.anchor].UID,
		}
	}
	return state
}

func selectionIndex(value uint64) *uint64 {
	return &value
}

func copySelectionIndex(value *uint64) *uint64 {
	if value == nil {
		return nil
	}
	return selectionIndex(*value)
}

func sameSelectionSnapshot(left, right *SelectionSnapshot) bool {
	return left != nil && right != nil &&
		left.generation == right.generation &&
		left.indexRevision == right.indexRevision &&
		len(left.identities) == len(right.identities) &&
		left.fingerprint == right.fingerprint
}

func retainedSelectionTokenBytes(
	scope SelectionScope,
	intervals []SelectionInterval,
	prefix []uint64,
) int64 {
	return int64(unsafe.Sizeof(selectionTokenRecord{})) + selectionTokenMapBytes +
		selectionTokenEncodedBytes + int64(len(scope.SessionID)+len(scope.ViewID)) +
		int64(len(intervals))*int64(unsafe.Sizeof(SelectionInterval{})) +
		int64(len(prefix))*int64(unsafe.Sizeof(uint64(0)))
}

func retainedSelectionSnapshotBytes(scope SelectionScope, snapshot *SelectionSnapshot) int64 {
	return snapshot.retainedBytes + selectionSnapshotMapBytes +
		int64(len(scope.SessionID)+len(scope.ViewID))
}

func selectionIdentityStringBytes(identity SelectionIdentity) int {
	return len(identity.Group) + len(identity.Version) + len(identity.Resource) +
		len(identity.Namespace) + len(identity.Name) + len(identity.UID)
}

func writeSelectionIdentityHash(digest hash.Hash, identity SelectionIdentity) {
	writeSelectionHashString(digest, identity.Group)
	writeSelectionHashString(digest, identity.Version)
	writeSelectionHashString(digest, identity.Resource)
	writeSelectionHashString(digest, identity.Namespace)
	writeSelectionHashString(digest, identity.Name)
	writeSelectionHashString(digest, identity.UID)
}

func writeSelectionHashString(digest hash.Hash, value string) {
	writeSelectionHashUint64(digest, uint64(len(value)))
	_, _ = digest.Write([]byte(value))
}

func writeSelectionHashUint64(digest hash.Hash, value uint64) {
	var encoded [8]byte
	binary.LittleEndian.PutUint64(encoded[:], value)
	_, _ = digest.Write(encoded[:])
}
