package view

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"slices"
	"sync"
	"testing"
	"time"
)

func TestSelectionStoreGesturesProduceNormalizedImmutableIntervals(t *testing.T) {
	store := newTestSelectionStore(t, SelectionStoreConfig{}, nil)
	scope := selectionTestScope()
	snapshot := selectionTestSnapshot(t, 1, 1, selectionTestIdentities(10))

	replaced := applySelectionForTest(t, store, scope, snapshot, "", SelectionGesture{
		Kind: SelectionGestureReplace, Index: 4,
	})
	assertSelectionState(t, replaced, 1, 4, "uid-04")
	assertSelectionIntervals(t, store, replaced.Token, []SelectionInterval{{Start: 4, End: 5}})

	toggled := applySelectionForTest(t, store, scope, snapshot, replaced.Token, SelectionGesture{
		Kind: SelectionGestureCommandToggle, Index: 7,
	})
	assertSelectionState(t, toggled, 2, 7, "uid-07")
	assertSelectionIntervals(t, store, toggled.Token, []SelectionInterval{
		{Start: 4, End: 5}, {Start: 7, End: 8},
	})

	additive := applySelectionForTest(t, store, scope, snapshot, toggled.Token, SelectionGesture{
		Kind: SelectionGestureShiftExtend, Index: 9, Additive: true,
	})
	assertSelectionState(t, additive, 4, 7, "uid-07")
	assertSelectionIntervals(t, store, additive.Token, []SelectionInterval{
		{Start: 4, End: 5}, {Start: 7, End: 10},
	})

	extended := applySelectionForTest(t, store, scope, snapshot, additive.Token, SelectionGesture{
		Kind: SelectionGestureShiftExtend, Index: 6,
	})
	assertSelectionState(t, extended, 2, 7, "uid-07")
	assertSelectionIntervals(t, store, extended.Token, []SelectionInterval{{Start: 6, End: 8}})

	all := applySelectionForTest(t, store, scope, snapshot, extended.Token, SelectionGesture{
		Kind: SelectionGestureCommandAll,
	})
	assertSelectionState(t, all, 10, 7, "uid-07")
	assertSelectionIntervals(t, store, all.Token, []SelectionInterval{{Start: 0, End: 10}})

	cleared := applySelectionForTest(t, store, scope, snapshot, all.Token, SelectionGesture{
		Kind: SelectionGestureClear,
	})
	if cleared.SelectedCount != 0 || cleared.Anchor != nil {
		t.Fatalf("cleared state = %+v, want no selection or anchor", cleared)
	}
	assertSelectionIntervals(t, store, cleared.Token, nil)

	// Creating every successor token must not mutate any earlier token.
	page := selectionPageForTest(t, store, scope, replaced.Token, 0, 10)
	if got := selectionPageUIDs(page); !slices.Equal(got, []string{"uid-04"}) {
		t.Fatalf("original immutable token UIDs = %v, want [uid-04]", got)
	}
}

func TestSelectionStoreToggleSplitsAndMergesIntervals(t *testing.T) {
	store := newTestSelectionStore(t, SelectionStoreConfig{}, nil)
	scope := selectionTestScope()
	snapshot := selectionTestSnapshot(t, 1, 1, selectionTestIdentities(8))
	state := applySelectionForTest(t, store, scope, snapshot, "", SelectionGesture{
		Kind: SelectionGestureCommandAll,
	})
	state = applySelectionForTest(t, store, scope, snapshot, state.Token, SelectionGesture{
		Kind: SelectionGestureCommandToggle, Index: 3,
	})
	assertSelectionIntervals(t, store, state.Token, []SelectionInterval{
		{Start: 0, End: 3}, {Start: 4, End: 8},
	})
	state = applySelectionForTest(t, store, scope, snapshot, state.Token, SelectionGesture{
		Kind: SelectionGestureCommandToggle, Index: 3,
	})
	assertSelectionIntervals(t, store, state.Token, []SelectionInterval{{Start: 0, End: 8}})
	state = applySelectionForTest(t, store, scope, snapshot, state.Token, SelectionGesture{
		Kind: SelectionGestureCommandToggle, Index: 0,
	})
	state = applySelectionForTest(t, store, scope, snapshot, state.Token, SelectionGesture{
		Kind: SelectionGestureCommandToggle, Index: 7,
	})
	assertSelectionIntervals(t, store, state.Token, []SelectionInterval{{Start: 1, End: 7}})
}

func TestSelectionStoreShiftWithoutCompatibleAnchorStartsAtTarget(t *testing.T) {
	store := newTestSelectionStore(t, SelectionStoreConfig{}, nil)
	scope := selectionTestScope()
	snapshot := selectionTestSnapshot(t, 1, 1, selectionTestIdentities(4))
	state := applySelectionForTest(t, store, scope, snapshot, "", SelectionGesture{
		Kind: SelectionGestureShiftExtend, Index: 2, Additive: true,
	})
	assertSelectionState(t, state, 1, 2, "uid-02")
	assertSelectionIntervals(t, store, state.Token, []SelectionInterval{{Start: 2, End: 3}})
}

func TestSelectionStorePagesFragmentedSelectionBySelectedRank(t *testing.T) {
	store := newTestSelectionStore(t, SelectionStoreConfig{MaxPageSize: 3}, nil)
	scope := selectionTestScope()
	snapshot := selectionTestSnapshot(t, 1, 1, selectionTestIdentities(10))
	state := SelectionState{}
	for _, index := range []uint64{0, 2, 4, 6, 8} {
		state = applySelectionForTest(t, store, scope, snapshot, state.Token, SelectionGesture{
			Kind: SelectionGestureCommandToggle, Index: index,
		})
	}

	first := selectionPageForTest(t, store, scope, state.Token, 1, 2)
	if got := selectionPageIndices(first); !slices.Equal(got, []uint64{2, 4}) {
		t.Fatalf("first page indexes = %v, want [2 4]", got)
	}
	if first.NextOffset != 3 || first.Done {
		t.Fatalf("first page continuation = offset %d done %t, want 3 false", first.NextOffset, first.Done)
	}
	second := selectionPageForTest(t, store, scope, state.Token, first.NextOffset, 3)
	if got := selectionPageIndices(second); !slices.Equal(got, []uint64{6, 8}) {
		t.Fatalf("second page indexes = %v, want [6 8]", got)
	}
	if second.NextOffset != 5 || !second.Done {
		t.Fatalf("second page continuation = offset %d done %t, want 5 true", second.NextOffset, second.Done)
	}
	empty := selectionPageForTest(t, store, scope, state.Token, 5, 1)
	if len(empty.Items) != 0 || !empty.Done {
		t.Fatalf("terminal page = %+v, want empty and done", empty)
	}

	for name, test := range map[string]struct {
		offset uint64
		limit  uint32
	}{
		"zero limit":       {offset: 0, limit: 0},
		"oversized limit":  {offset: 0, limit: 4},
		"oversized offset": {offset: 6, limit: 1},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := store.Page(scope, state.Token, test.offset, test.limit)
			if !errors.Is(err, ErrInvalidSelectionPage) {
				t.Fatalf("Page error = %v, want %v", err, ErrInvalidSelectionPage)
			}
		})
	}
}

func TestSelectionStoreProjectsMembershipByUIDAcrossReorder(t *testing.T) {
	store := newTestSelectionStore(t, SelectionStoreConfig{}, nil)
	scope := selectionTestScope()
	snapshot := selectionTestSnapshot(t, 1, 1, selectionTestIdentities(5))
	state := applySelectionForTest(t, store, scope, snapshot, "", SelectionGesture{
		Kind: SelectionGestureReplace, Index: 1,
	})
	state = applySelectionForTest(t, store, scope, snapshot, state.Token, SelectionGesture{
		Kind: SelectionGestureShiftExtend, Index: 3,
	})

	membership, err := store.ProjectMembership(scope, state.Token, []string{
		"uid-03", "uid-new", "uid-01", "uid-00",
	})
	if err != nil {
		t.Fatalf("ProjectMembership: %v", err)
	}
	if !slices.Equal(membership.Selected, []bool{true, false, true, false}) {
		t.Fatalf("membership = %v, want [true false true false]", membership.Selected)
	}
	if membership.AnchorOffset == nil || *membership.AnchorOffset != 2 {
		t.Fatalf("anchor offset = %v, want 2", membership.AnchorOffset)
	}
	if membership.State.SelectedCount != 3 {
		t.Fatalf("selected count = %d, want 3", membership.State.SelectedCount)
	}
}

func TestSelectionStoreNewIndexAndGenerationStartFreshWithoutRetargeting(t *testing.T) {
	store := newTestSelectionStore(t, SelectionStoreConfig{}, nil)
	scope := selectionTestScope()
	original := []SelectionIdentity{
		selectionTestIdentity("a"), selectionTestIdentity("b"), selectionTestIdentity("c"),
	}
	oldSnapshot := selectionTestSnapshot(t, 1, 1, original)
	old := applySelectionForTest(t, store, scope, oldSnapshot, "", SelectionGesture{
		Kind: SelectionGestureReplace, Index: 0,
	})

	for name, snapshot := range map[string]*SelectionSnapshot{
		"index revision": selectionTestSnapshot(t, 1, 2, []SelectionIdentity{
			selectionTestIdentity("b"), selectionTestIdentity("a"), selectionTestIdentity("c"),
		}),
		"generation": selectionTestSnapshot(t, 2, 1, []SelectionIdentity{
			selectionTestIdentity("c"), selectionTestIdentity("b"), selectionTestIdentity("a"),
		}),
	} {
		t.Run(name, func(t *testing.T) {
			fresh := applySelectionForTest(t, store, scope, snapshot, old.Token, SelectionGesture{
				Kind: SelectionGestureCommandToggle, Index: 0,
			})
			page := selectionPageForTest(t, store, scope, fresh.Token, 0, 10)
			if got := selectionPageUIDs(page); !slices.Equal(got, []string{snapshot.identities[0].UID}) {
				t.Fatalf("fresh selection UIDs = %v, want [%s]", got, snapshot.identities[0].UID)
			}
		})
	}

	page := selectionPageForTest(t, store, scope, old.Token, 0, 10)
	if got := selectionPageUIDs(page); !slices.Equal(got, []string{"a"}) {
		t.Fatalf("old pinned token UIDs = %v, want [a]", got)
	}
}

func TestSelectionStoreUIDGestureSafelyRebasesAcrossIndexRevision(t *testing.T) {
	store := newTestSelectionStore(t, SelectionStoreConfig{}, nil)
	scope := selectionTestScope()
	oldSnapshot := selectionTestSnapshot(t, 1, 1, []SelectionIdentity{
		selectionTestIdentity("a"), selectionTestIdentity("b"),
		selectionTestIdentity("c"), selectionTestIdentity("d"),
	})
	first := applySelectionForTest(t, store, scope, oldSnapshot, "", SelectionGesture{
		Kind: SelectionGestureReplace, Index: 1,
	})
	old := applySelectionForTest(t, store, scope, oldSnapshot, first.Token, SelectionGesture{
		Kind: SelectionGestureCommandToggle, Index: 3,
	})
	newSnapshot := selectionTestSnapshot(t, 1, 2, []SelectionIdentity{
		selectionTestIdentity("d"), selectionTestIdentity("c"),
		selectionTestIdentity("b"), selectionTestIdentity("e"),
	})

	rebased := applySelectionForTest(t, store, scope, newSnapshot, old.Token, SelectionGesture{
		Kind: SelectionGestureCommandToggle, TargetUID: "c",
	})
	if got := selectionPageUIDs(selectionPageForTest(t, store, scope, rebased.Token, 0, 10)); !slices.Equal(got, []string{"d", "c", "b"}) {
		t.Fatalf("UID-rebased selection = %v, want [d c b]", got)
	}
	if rebased.Anchor == nil || rebased.Anchor.UID != "c" || rebased.Anchor.Index != 1 {
		t.Fatalf("UID-rebased anchor = %#v, want c at index 1", rebased.Anchor)
	}

	extended := applySelectionForTest(t, store, scope, newSnapshot, old.Token, SelectionGesture{
		Kind: SelectionGestureShiftExtend, TargetUID: "e", AnchorUID: "b",
	})
	if got := selectionPageUIDs(selectionPageForTest(t, store, scope, extended.Token, 0, 10)); !slices.Equal(got, []string{"b", "e"}) {
		t.Fatalf("UID-anchored Shift selection = %v, want [b e]", got)
	}
	if extended.Anchor == nil || extended.Anchor.UID != "b" || extended.Anchor.Index != 2 {
		t.Fatalf("UID-anchored Shift anchor = %#v, want b at index 2", extended.Anchor)
	}

	_, err := store.Apply(scope, newSnapshot, old.Token, SelectionGesture{
		Kind: SelectionGestureReplace, TargetUID: "gone",
	})
	if !errors.Is(err, ErrSelectionTargetNotFound) {
		t.Fatalf("missing UID error = %v, want %v", err, ErrSelectionTargetNotFound)
	}
}

func TestSelectionStoreCellOnlyRevisionContinuesAndSharesSnapshot(t *testing.T) {
	store := newTestSelectionStore(t, SelectionStoreConfig{}, nil)
	scope := selectionTestScope()
	identities := selectionTestIdentities(4)
	firstSnapshot := selectionTestSnapshot(t, 3, 9, identities)
	first := applySelectionForTest(t, store, scope, firstSnapshot, "", SelectionGesture{
		Kind: SelectionGestureReplace, Index: 1,
	})
	// A separately constructed equivalent identity snapshot models a cell-only
	// presentation update: generation and index revision remain unchanged.
	equivalentSnapshot := selectionTestSnapshot(t, 3, 9, identities)
	second := applySelectionForTest(t, store, scope, equivalentSnapshot, first.Token, SelectionGesture{
		Kind: SelectionGestureCommandToggle, Index: 3,
	})
	if got := selectionPageUIDs(selectionPageForTest(t, store, scope, second.Token, 0, 10)); !slices.Equal(got, []string{"uid-01", "uid-03"}) {
		t.Fatalf("continued UIDs = %v, want [uid-01 uid-03]", got)
	}
	stats := store.Stats()
	if stats.ActiveSnapshots != 1 || stats.ActiveTokens != 2 {
		t.Fatalf("shared snapshot stats = %+v, want 1 snapshot and 2 tokens", stats)
	}
	store.mu.Lock()
	entry := store.tokens[first.Token].snapshot
	shared := store.tokens[second.Token].snapshot
	store.mu.Unlock()
	if entry != shared || entry.snapshot != firstSnapshot {
		t.Fatal("equivalent index revision did not reuse its first canonical immutable snapshot")
	}

	conflict := append([]SelectionIdentity(nil), identities...)
	conflict[0], conflict[1] = conflict[1], conflict[0]
	conflictingSnapshot := selectionTestSnapshot(t, 3, 9, conflict)
	_, err := store.Apply(scope, conflictingSnapshot, second.Token, SelectionGesture{
		Kind: SelectionGestureCommandToggle, Index: 0,
	})
	if !errors.Is(err, ErrSelectionSnapshotConflict) {
		t.Fatalf("conflicting same-revision snapshot error = %v, want %v", err, ErrSelectionSnapshotConflict)
	}
}

func TestSelectionStoreTokenExpiryIsFixedAndReleasesCapacity(t *testing.T) {
	clock := &selectionTestClock{value: time.Unix(10_000, 0)}
	store := newTestSelectionStore(t, SelectionStoreConfig{
		TokenTTL: time.Minute, MaxTokens: 2, MaxSnapshots: 2,
	}, clock)
	scope := selectionTestScope()
	firstSnapshot := selectionTestSnapshot(t, 1, 1, selectionTestIdentities(2))
	first := applySelectionForTest(t, store, scope, firstSnapshot, "", SelectionGesture{
		Kind: SelectionGestureReplace, Index: 0,
	})
	clock.Advance(30 * time.Second)
	firstDescription, err := store.Describe(scope, first.Token)
	if err != nil {
		t.Fatalf("Describe first token: %v", err)
	}
	if !firstDescription.ExpiresAt.Equal(first.ExpiresAt) {
		t.Fatalf("read extended expiry from %v to %v", first.ExpiresAt, firstDescription.ExpiresAt)
	}
	second := applySelectionForTest(t, store, scope, firstSnapshot, first.Token, SelectionGesture{
		Kind: SelectionGestureCommandToggle, Index: 1,
	})
	if !second.ExpiresAt.Equal(clock.Now().Add(time.Minute)) || !second.ExpiresAt.After(first.ExpiresAt) {
		t.Fatalf("successor expiry = %v, want %v and after first", second.ExpiresAt, clock.Now().Add(time.Minute))
	}

	clock.Advance(30 * time.Second)
	_, err = store.Page(scope, first.Token, 0, 1)
	if !errors.Is(err, ErrSelectionTokenExpired) {
		t.Fatalf("expired token error = %v, want %v", err, ErrSelectionTokenExpired)
	}
	if _, err := store.Describe(scope, second.Token); err != nil {
		t.Fatalf("newer token expired with older token: %v", err)
	}
	newSnapshot := selectionTestSnapshot(t, 1, 2, selectionTestIdentities(2))
	third := applySelectionForTest(t, store, scope, newSnapshot, "", SelectionGesture{
		Kind: SelectionGestureReplace, Index: 1,
	})
	if third.Token == "" {
		t.Fatal("expiry did not release token and snapshot admission capacity")
	}
	stats := store.Stats()
	if stats.ActiveTokens != 2 || stats.ActiveSnapshots != 2 {
		t.Fatalf("post-expiry stats = %+v, want two active tokens and snapshots", stats)
	}
}

func TestSelectionStoreRejectsAdmissionWithoutEvictingLiveTokens(t *testing.T) {
	t.Run("token count", func(t *testing.T) {
		store := newTestSelectionStore(t, SelectionStoreConfig{MaxTokens: 1}, nil)
		scope := selectionTestScope()
		firstSnapshot := selectionTestSnapshot(t, 1, 1, selectionTestIdentities(2))
		first := applySelectionForTest(t, store, scope, firstSnapshot, "", SelectionGesture{
			Kind: SelectionGestureReplace, Index: 0,
		})
		secondSnapshot := selectionTestSnapshot(t, 1, 2, selectionTestIdentities(2))
		_, err := store.Apply(scope, secondSnapshot, first.Token, SelectionGesture{
			Kind: SelectionGestureReplace, Index: 1,
		})
		assertSelectionCapacityError(t, err)
		if got := store.Stats(); got.ActiveTokens != 1 || got.ActiveSnapshots != 1 {
			t.Fatalf("failed admission changed retained state: %+v", got)
		}
		_ = selectionPageForTest(t, store, scope, first.Token, 0, 1)
	})

	t.Run("token bytes", func(t *testing.T) {
		scope := selectionTestScope()
		snapshot := selectionTestSnapshot(t, 1, 1, selectionTestIdentities(2))
		probe := newTestSelectionStore(t, SelectionStoreConfig{}, nil)
		applySelectionForTest(t, probe, scope, snapshot, "", SelectionGesture{
			Kind: SelectionGestureReplace, Index: 0,
		})
		firstBytes := probe.Stats().TokenBytes

		store := newTestSelectionStore(t, SelectionStoreConfig{MaxTokenBytes: firstBytes}, nil)
		first := applySelectionForTest(t, store, scope, snapshot, "", SelectionGesture{
			Kind: SelectionGestureReplace, Index: 0,
		})
		_, err := store.Apply(scope, snapshot, first.Token, SelectionGesture{
			Kind: SelectionGestureCommandToggle, Index: 1,
		})
		assertSelectionCapacityError(t, err)
		_ = selectionPageForTest(t, store, scope, first.Token, 0, 1)
	})

	t.Run("snapshot count", func(t *testing.T) {
		store := newTestSelectionStore(t, SelectionStoreConfig{MaxSnapshots: 1}, nil)
		scope := selectionTestScope()
		firstSnapshot := selectionTestSnapshot(t, 1, 1, selectionTestIdentities(2))
		first := applySelectionForTest(t, store, scope, firstSnapshot, "", SelectionGesture{
			Kind: SelectionGestureReplace, Index: 0,
		})
		secondSnapshot := selectionTestSnapshot(t, 1, 2, selectionTestIdentities(2))
		_, err := store.Apply(scope, secondSnapshot, first.Token, SelectionGesture{
			Kind: SelectionGestureReplace, Index: 1,
		})
		assertSelectionCapacityError(t, err)
		_ = selectionPageForTest(t, store, scope, first.Token, 0, 1)
	})

	t.Run("snapshot bytes", func(t *testing.T) {
		scope := selectionTestScope()
		firstSnapshot := selectionTestSnapshot(t, 1, 1, selectionTestIdentities(2))
		probe := newTestSelectionStore(t, SelectionStoreConfig{}, nil)
		applySelectionForTest(t, probe, scope, firstSnapshot, "", SelectionGesture{
			Kind: SelectionGestureReplace, Index: 0,
		})
		firstBytes := probe.Stats().SnapshotBytes

		store := newTestSelectionStore(t, SelectionStoreConfig{MaxSnapshotBytes: firstBytes}, nil)
		first := applySelectionForTest(t, store, scope, firstSnapshot, "", SelectionGesture{
			Kind: SelectionGestureReplace, Index: 0,
		})
		secondSnapshot := selectionTestSnapshot(t, 1, 2, selectionTestIdentities(2))
		_, err := store.Apply(scope, secondSnapshot, first.Token, SelectionGesture{
			Kind: SelectionGestureReplace, Index: 1,
		})
		assertSelectionCapacityError(t, err)
		_ = selectionPageForTest(t, store, scope, first.Token, 0, 1)
	})
}

func TestSelectionStoreEnforcesSessionAndViewIsolation(t *testing.T) {
	store := newTestSelectionStore(t, SelectionStoreConfig{}, nil)
	scope := selectionTestScope()
	snapshot := selectionTestSnapshot(t, 1, 1, selectionTestIdentities(2))
	state := applySelectionForTest(t, store, scope, snapshot, "", SelectionGesture{
		Kind: SelectionGestureReplace, Index: 0,
	})
	for name, other := range map[string]SelectionScope{
		"session": {SessionID: "another-session", ViewID: scope.ViewID},
		"view":    {SessionID: scope.SessionID, ViewID: "another-view"},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := store.Describe(other, state.Token); !errors.Is(err, ErrSelectionScopeMismatch) {
				t.Fatalf("Describe error = %v, want %v", err, ErrSelectionScopeMismatch)
			}
			if _, err := store.Page(other, state.Token, 0, 1); !errors.Is(err, ErrSelectionScopeMismatch) {
				t.Fatalf("Page error = %v, want %v", err, ErrSelectionScopeMismatch)
			}
			if _, err := store.Apply(other, snapshot, state.Token, SelectionGesture{
				Kind: SelectionGestureReplace, Index: 1,
			}); !errors.Is(err, ErrSelectionScopeMismatch) {
				t.Fatalf("Apply error = %v, want %v", err, ErrSelectionScopeMismatch)
			}
		})
	}
	_ = selectionPageForTest(t, store, scope, state.Token, 0, 1)
}

func TestNewSelectionSnapshotRejectsMalformedAndDuplicateIdentities(t *testing.T) {
	valid := selectionTestIdentity("uid-a")
	for name, test := range map[string]struct {
		generation uint64
		revision   uint64
		identities []SelectionIdentity
	}{
		"zero generation": {generation: 0, revision: 1},
		"zero revision":   {generation: 1, revision: 0},
		"missing UID": {
			generation: 1, revision: 1,
			identities: []SelectionIdentity{{Version: "v1", Resource: "pods", Name: "pod"}},
		},
		"missing name": {
			generation: 1, revision: 1,
			identities: []SelectionIdentity{{Version: "v1", Resource: "pods", UID: "uid"}},
		},
		"untrimmed field": {
			generation: 1, revision: 1,
			identities: []SelectionIdentity{{Version: "v1", Resource: "pods", Name: " pod", UID: "uid"}},
		},
		"duplicate UID": {
			generation: 1, revision: 1,
			identities: []SelectionIdentity{valid, valid},
		},
		"mixed GVR": {
			generation: 1, revision: 1,
			identities: []SelectionIdentity{valid, {
				Version: "v1", Resource: "services", Name: "service", UID: "uid-b",
			}},
		},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := NewSelectionSnapshot(test.generation, test.revision, test.identities)
			if !errors.Is(err, ErrInvalidSelectionSnapshot) {
				t.Fatalf("NewSelectionSnapshot error = %v, want %v", err, ErrInvalidSelectionSnapshot)
			}
		})
	}
}

func TestSelectionSnapshotFreezesCallerSliceAndTokensAreOpaque(t *testing.T) {
	identities := selectionTestIdentities(2)
	snapshot := selectionTestSnapshot(t, 1, 1, identities)
	identities[0] = selectionTestIdentity("mutated")
	randomBytes := append(
		bytes.Repeat([]byte{1}, selectionTokenEntropyBytes),
		bytes.Repeat([]byte{2}, selectionTokenEntropyBytes)...,
	)
	store, err := newSelectionStore(SelectionStoreConfig{}, selectionStoreDependencies{
		now: time.Now, random: bytes.NewReader(randomBytes),
	})
	if err != nil {
		t.Fatalf("newSelectionStore: %v", err)
	}
	scope := selectionTestScope()
	first := applySelectionForTest(t, store, scope, snapshot, "", SelectionGesture{
		Kind: SelectionGestureReplace, Index: 0,
	})
	second := applySelectionForTest(t, store, scope, snapshot, first.Token, SelectionGesture{
		Kind: SelectionGestureCommandToggle, Index: 1,
	})
	if first.Token == second.Token {
		t.Fatal("successive immutable states reused the same token")
	}
	for _, token := range []string{first.Token, second.Token} {
		decoded, err := base64.RawURLEncoding.DecodeString(token)
		if err != nil || len(decoded) != selectionTokenEntropyBytes {
			t.Fatalf("opaque token %q decoded to %d bytes with error %v", token, len(decoded), err)
		}
		if stringsContainAny(token, scope.SessionID, scope.ViewID, "uid-00") {
			t.Fatalf("opaque token %q embeds selection metadata", token)
		}
	}
	page := selectionPageForTest(t, store, scope, first.Token, 0, 1)
	if got := selectionPageUIDs(page); !slices.Equal(got, []string{"uid-00"}) {
		t.Fatalf("snapshot changed with caller slice: %v", got)
	}
}

func TestSelectionStoreValidatesGesturesAndMembershipBounds(t *testing.T) {
	store := newTestSelectionStore(t, SelectionStoreConfig{MaxPageSize: 2}, nil)
	scope := selectionTestScope()
	snapshot := selectionTestSnapshot(t, 1, 1, selectionTestIdentities(2))
	for name, gesture := range map[string]SelectionGesture{
		"unspecified":      {Kind: SelectionGestureUnspecified},
		"out of range":     {Kind: SelectionGestureReplace, Index: 2},
		"invalid additive": {Kind: SelectionGestureCommandToggle, Index: 0, Additive: true},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := store.Apply(scope, snapshot, "", gesture)
			if !errors.Is(err, ErrInvalidSelectionGesture) {
				t.Fatalf("Apply error = %v, want %v", err, ErrInvalidSelectionGesture)
			}
		})
	}
	state := applySelectionForTest(t, store, scope, snapshot, "", SelectionGesture{
		Kind: SelectionGestureReplace, Index: 0,
	})
	for name, uids := range map[string][]string{
		"too many":  {"uid-00", "uid-01", "uid-02"},
		"empty":     {""},
		"untrimmed": {" uid-00"},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := store.ProjectMembership(scope, state.Token, uids)
			if !errors.Is(err, ErrInvalidSelectionPage) {
				t.Fatalf("ProjectMembership error = %v, want %v", err, ErrInvalidSelectionPage)
			}
		})
	}
}

func TestSelectionStoreConcurrentApplyPageAndMembership(t *testing.T) {
	const (
		workers    = 24
		iterations = 40
	)
	store := newTestSelectionStore(t, SelectionStoreConfig{
		MaxTokens:     workers*iterations + 1,
		MaxTokenBytes: 64 << 20,
	}, nil)
	scope := selectionTestScope()
	snapshot := selectionTestSnapshot(t, 7, 11, selectionTestIdentities(128))
	root := applySelectionForTest(t, store, scope, snapshot, "", SelectionGesture{
		Kind: SelectionGestureReplace, Index: 0,
	})

	var wait sync.WaitGroup
	errorsFound := make(chan error, workers)
	tokens := make(chan string, workers*iterations)
	for worker := 0; worker < workers; worker++ {
		wait.Add(1)
		go func(worker int) {
			defer wait.Done()
			for iteration := 0; iteration < iterations; iteration++ {
				state, err := store.Apply(scope, snapshot, root.Token, SelectionGesture{
					Kind:  SelectionGestureCommandToggle,
					Index: uint64(1 + (worker*iterations+iteration)%127),
				})
				if err != nil {
					errorsFound <- fmt.Errorf("worker %d apply %d: %w", worker, iteration, err)
					return
				}
				tokens <- state.Token
				page, err := store.Page(scope, state.Token, 0, 2)
				if err != nil || len(page.Items) != 2 {
					errorsFound <- fmt.Errorf(
						"worker %d page %d: items=%d err=%w", worker, iteration, len(page.Items), err,
					)
					return
				}
				membership, err := store.ProjectMembership(scope, state.Token, []string{
					"uid-00", page.Items[1].Identity.UID,
				})
				if err != nil || !slices.Equal(membership.Selected, []bool{true, true}) {
					errorsFound <- fmt.Errorf(
						"worker %d membership %d: selected=%v err=%w",
						worker, iteration, membership.Selected, err,
					)
					return
				}
			}
		}(worker)
	}
	wait.Wait()
	close(errorsFound)
	close(tokens)
	for err := range errorsFound {
		if err != nil {
			t.Fatal(err)
		}
	}
	seen := make(map[string]struct{}, workers*iterations)
	for token := range tokens {
		if _, duplicate := seen[token]; duplicate {
			t.Fatalf("duplicate opaque token %q", token)
		}
		seen[token] = struct{}{}
	}
	if len(seen) != workers*iterations {
		t.Fatalf("concurrent tokens = %d, want %d", len(seen), workers*iterations)
	}
	stats := store.Stats()
	if stats.ActiveTokens != workers*iterations+1 || stats.ActiveSnapshots != 1 {
		t.Fatalf("concurrent store stats = %+v", stats)
	}
	if page := selectionPageForTest(t, store, scope, root.Token, 0, 2); len(page.Items) != 1 {
		t.Fatalf("root token mutated by concurrent successors: %+v", page.Items)
	}
}

type selectionTestClock struct {
	mu    sync.Mutex
	value time.Time
}

func (c *selectionTestClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.value
}

func (c *selectionTestClock) Advance(duration time.Duration) {
	c.mu.Lock()
	c.value = c.value.Add(duration)
	c.mu.Unlock()
}

func newTestSelectionStore(
	t *testing.T,
	config SelectionStoreConfig,
	clock *selectionTestClock,
) *SelectionStore {
	t.Helper()
	now := time.Now
	if clock != nil {
		now = clock.Now
	}
	store, err := newSelectionStore(config, selectionStoreDependencies{now: now, random: rand.Reader})
	if err != nil {
		t.Fatalf("newSelectionStore: %v", err)
	}
	return store
}

func selectionTestScope() SelectionScope {
	return SelectionScope{SessionID: "session-a", ViewID: "view-a"}
}

func selectionTestIdentity(uid string) SelectionIdentity {
	return SelectionIdentity{
		Version: "v1", Resource: "pods", Namespace: "default", Name: "pod-" + uid, UID: uid,
	}
}

func selectionTestIdentities(count int) []SelectionIdentity {
	identities := make([]SelectionIdentity, count)
	for index := range identities {
		identities[index] = selectionTestIdentity(fmt.Sprintf("uid-%02d", index))
	}
	return identities
}

func selectionTestSnapshot(
	t *testing.T,
	generation, indexRevision uint64,
	identities []SelectionIdentity,
) *SelectionSnapshot {
	t.Helper()
	snapshot, err := NewSelectionSnapshot(generation, indexRevision, identities)
	if err != nil {
		t.Fatalf("NewSelectionSnapshot: %v", err)
	}
	return snapshot
}

func applySelectionForTest(
	t *testing.T,
	store *SelectionStore,
	scope SelectionScope,
	snapshot *SelectionSnapshot,
	previousToken string,
	gesture SelectionGesture,
) SelectionState {
	t.Helper()
	state, err := store.Apply(scope, snapshot, previousToken, gesture)
	if err != nil {
		t.Fatalf("Apply selection gesture %+v: %v", gesture, err)
	}
	return state
}

func selectionPageForTest(
	t *testing.T,
	store *SelectionStore,
	scope SelectionScope,
	token string,
	offset uint64,
	limit uint32,
) SelectionPage {
	t.Helper()
	page, err := store.Page(scope, token, offset, limit)
	if err != nil {
		t.Fatalf("Page selection: %v", err)
	}
	return page
}

func selectionPageUIDs(page SelectionPage) []string {
	uids := make([]string, len(page.Items))
	for index, item := range page.Items {
		uids[index] = item.Identity.UID
	}
	return uids
}

func selectionPageIndices(page SelectionPage) []uint64 {
	indexes := make([]uint64, len(page.Items))
	for index, item := range page.Items {
		indexes[index] = item.Index
	}
	return indexes
}

func assertSelectionState(
	t *testing.T,
	state SelectionState,
	selectedCount, anchorIndex uint64,
	anchorUID string,
) {
	t.Helper()
	if state.SelectedCount != selectedCount || state.Anchor == nil ||
		state.Anchor.Index != anchorIndex || state.Anchor.UID != anchorUID {
		t.Fatalf(
			"selection state = %+v, want count %d anchor %d/%s",
			state,
			selectedCount,
			anchorIndex,
			anchorUID,
		)
	}
}

func assertSelectionIntervals(
	t *testing.T,
	store *SelectionStore,
	token string,
	want []SelectionInterval,
) {
	t.Helper()
	store.mu.Lock()
	record := store.tokens[token]
	var got []SelectionInterval
	if record != nil {
		got = append(got, record.intervals...)
	}
	store.mu.Unlock()
	if !slices.Equal(got, want) {
		t.Fatalf("selection intervals = %v, want %v", got, want)
	}
	for index, interval := range got {
		if interval.Start >= interval.End {
			t.Fatalf("interval %d is empty or reversed: %+v", index, interval)
		}
		if index > 0 && got[index-1].End >= interval.Start {
			t.Fatalf("intervals are not normalized: %v", got)
		}
	}
}

func assertSelectionCapacityError(t *testing.T, err error) {
	t.Helper()
	if !errors.Is(err, ErrSelectionCapacityExhausted) {
		t.Fatalf("admission error = %v, want %v", err, ErrSelectionCapacityExhausted)
	}
}

func stringsContainAny(value string, candidates ...string) bool {
	for _, candidate := range candidates {
		if candidate != "" && len(value) >= len(candidate) {
			for start := 0; start+len(candidate) <= len(value); start++ {
				if value[start:start+len(candidate)] == candidate {
					return true
				}
			}
		}
	}
	return false
}
