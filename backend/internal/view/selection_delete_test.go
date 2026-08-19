package view

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
)

func TestSelectionLeaseSurvivesExpiryAndKeepsMemoryChargedUntilRelease(t *testing.T) {
	now := time.Date(2026, time.August, 19, 12, 0, 0, 0, time.UTC)
	store, err := newSelectionStore(
		SelectionStoreConfig{TokenTTL: time.Minute},
		selectionStoreDependencies{
			now: func() time.Time { return now }, random: &incrementingSelectionReader{},
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	scope := SelectionScope{SessionID: "session", ViewID: "view"}
	snapshot := selectionTestSnapshot(t, 1, 1, selectionTestIdentities(3))
	state, err := store.Apply(
		scope, snapshot, "", SelectionGesture{Kind: SelectionGestureCommandAll},
	)
	if err != nil {
		t.Fatal(err)
	}
	lease, err := store.AcquireSelectionLease(scope, state.Token)
	if err != nil {
		t.Fatal(err)
	}
	now = state.ExpiresAt
	if _, err := store.Describe(scope, state.Token); !errors.Is(err, ErrSelectionTokenExpired) {
		t.Fatalf("expired token describe = %v", err)
	}
	stats := store.Stats()
	if stats.ActiveTokens != 1 || stats.ActiveSnapshots != 1 {
		t.Fatalf("leased expired token was under-accounted: %#v", stats)
	}
	page, err := lease.Page(0, 3)
	if err != nil || len(page.Items) != 3 || page.Items[2].Identity.UID != "uid-02" {
		t.Fatalf("leased page after expiry = %#v, %v", page, err)
	}
	if err := lease.ValidateActive(); !errors.Is(err, ErrSelectionTokenExpired) {
		t.Fatalf("leased active validation = %v", err)
	}
	lease.Release()
	lease.Release()
	if _, err := lease.Page(0, 1); !errors.Is(err, ErrSelectionTokenNotFound) ||
		lease.State().Token != "" {
		t.Fatalf("released lease remained consumable: state=%#v error=%v", lease.State(), err)
	}
	stats = store.Stats()
	if stats.ActiveTokens != 0 || stats.ActiveSnapshots != 0 ||
		stats.TokenBytes != 0 || stats.SnapshotBytes != 0 {
		t.Fatalf("released expired lease remained charged: %#v", stats)
	}
}

func TestSelectionLeaseReleaseSerializesWithConcurrentPage(t *testing.T) {
	store := newTestSelectionStore(t, SelectionStoreConfig{}, nil)
	scope := selectionTestScope()
	state := applySelectionForTest(
		t, store, scope,
		selectionTestSnapshot(t, 1, 1, selectionTestIdentities(64)),
		"", SelectionGesture{Kind: SelectionGestureCommandAll},
	)
	lease, err := store.AcquireSelectionLease(scope, state.Token)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 32)
	for range cap(done) {
		go func() {
			_, pageErr := lease.Page(0, 32)
			done <- pageErr
		}()
	}
	lease.Release()
	for range cap(done) {
		pageErr := <-done
		if pageErr != nil && !errors.Is(pageErr, ErrSelectionTokenNotFound) {
			t.Fatalf("concurrent page error = %v", pageErr)
		}
	}
	if _, err := lease.Page(0, 1); !errors.Is(err, ErrSelectionTokenNotFound) {
		t.Fatalf("post-release page error = %v", err)
	}
}

func TestPrepareSelectionDeleteReportsExactHiddenCountAndBoundedPreview(t *testing.T) {
	runtime, subscription := newSelectionDeleteTestRuntime(t, "a", "b", "c")
	state, err := runtime.ApplySelectionGesture(
		"session", "view", 7, 2, "",
		SelectionGesture{Kind: SelectionGestureCommandAll},
	)
	if err != nil {
		t.Fatal(err)
	}

	subscription.mu.Lock()
	delete(subscription.rows, "b")
	subscription.order = []string{"c", "a"}
	subscription.advancePresentationLocked(true)
	currentIndex := subscription.indexRevision
	subscription.mu.Unlock()

	description, err := runtime.PrepareSelectionDelete(
		context.Background(), "session", "view", state.Token, 7, currentIndex, 2,
	)
	if err != nil {
		t.Fatal(err)
	}
	if description.State.SelectedCount != 3 || description.HiddenCount != 1 ||
		description.Resource != (SelectionResource{Version: "v1", Resource: "pods"}) ||
		len(description.Preview) != 2 || description.Preview[0].Identity.UID != "a" ||
		description.Preview[0].Hidden || description.Preview[1].Identity.UID != "b" ||
		!description.Preview[1].Hidden {
		t.Fatalf("delete selection description = %#v", description)
	}
	if _, err := runtime.PrepareSelectionDelete(
		context.Background(), "session", "view", state.Token, 7, currentIndex-1, 2,
	); !errors.Is(err, ErrStaleViewRevision) {
		t.Fatalf("stale confirmation index error = %v", err)
	}
	if _, err := runtime.PrepareSelectionDelete(
		context.Background(), "session", "view", state.Token, 7, currentIndex, MaxDeleteSelectionPreviewLimit+1,
	); !errors.Is(err, ErrInvalidSelectionPage) {
		t.Fatalf("oversized preview error = %v", err)
	}
}

func TestPrepareSelectionDeleteAllowsRevisionAdvanceAfterPinnedScan(t *testing.T) {
	runtime, subscription := newSelectionDeleteTestRuntime(t, "a", "b", "c")
	state, err := runtime.ApplySelectionGesture(
		"session", "view", 7, 2, "",
		SelectionGesture{Kind: SelectionGestureCommandAll},
	)
	if err != nil {
		t.Fatal(err)
	}

	requestedIndex := subscription.indexRevision
	description, err := runtime.prepareSelectionDelete(
		context.Background(), "session", "view", state.Token, 7, requestedIndex, 2,
		func() {
			// This callback runs at the scan-to-response boundary. Taking the
			// subscription lock proves the pinned scan released it, while the
			// mutation verifies a later WATCH commit cannot invalidate facts
			// already computed for requestedIndex.
			subscription.mu.Lock()
			delete(subscription.rows, "a")
			subscription.order = []string{"b", "c"}
			subscription.advancePresentationLocked(true)
			subscription.mu.Unlock()
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if description.IndexRevision != requestedIndex || description.HiddenCount != 0 ||
		len(description.Preview) != 2 || description.Preview[0].Identity.UID != "a" ||
		description.Preview[0].Hidden {
		t.Fatalf("pinned delete selection description = %#v", description)
	}
	subscription.mu.Lock()
	advancedIndex := subscription.indexRevision
	subscription.mu.Unlock()
	if advancedIndex <= requestedIndex {
		t.Fatalf("index revision = %d, want newer than %d", advancedIndex, requestedIndex)
	}
}

func TestPrepareSelectionDeleteClampsPreviewToStorePageLimit(t *testing.T) {
	runtime, subscription := newSelectionDeleteTestRuntimeWithConfig(
		t, SelectionStoreConfig{MaxPageSize: 2}, "a", "b", "c", "d",
	)
	state, err := runtime.ApplySelectionGesture(
		"session", "view", 7, 2, "",
		SelectionGesture{Kind: SelectionGestureCommandAll},
	)
	if err != nil {
		t.Fatal(err)
	}
	description, err := runtime.PrepareSelectionDelete(
		context.Background(), "session", "view", state.Token,
		7, subscription.indexRevision, MaxDeleteSelectionPreviewLimit,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(description.Preview) != 2 || description.Preview[0].Identity.UID != "a" ||
		description.Preview[1].Identity.UID != "b" || description.HiddenCount != 0 {
		t.Fatalf("page-limited delete preview = %#v", description)
	}
}

func TestPrepareSelectionDeleteCancelsPinnedVisibilityScan(t *testing.T) {
	uids := make([]string, selectionDeleteCancellationStride*3)
	for index := range uids {
		uids[index] = fmt.Sprintf("uid-%04d", index)
	}
	runtime, subscription := newSelectionDeleteTestRuntime(t, uids...)
	state, err := runtime.ApplySelectionGesture(
		"session", "view", 7, 2, "",
		SelectionGesture{Kind: SelectionGestureCommandAll},
	)
	if err != nil {
		t.Fatal(err)
	}
	baseContext, cancel := context.WithCancel(context.Background())
	defer cancel()
	ctx := &cancelAfterSelectionDeleteChecksContext{
		Context: baseContext, cancel: cancel, cancelAt: 2,
	}
	_, err = runtime.PrepareSelectionDelete(
		ctx, "session", "view", state.Token, 7, subscription.indexRevision, 1,
	)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled visibility scan error = %v", err)
	}
	if ctx.checks != 2 {
		t.Fatalf("visibility cancellation checks = %d, want 2", ctx.checks)
	}
	if !subscription.mu.TryLock() {
		t.Fatal("cancelled visibility scan retained the subscription lock")
	}
	subscription.mu.Unlock()
}

type cancelAfterSelectionDeleteChecksContext struct {
	context.Context
	checks   int
	cancel   context.CancelFunc
	cancelAt int
}

func (c *cancelAfterSelectionDeleteChecksContext) Err() error {
	c.checks++
	if c.checks >= c.cancelAt {
		c.cancel()
	}
	return c.Context.Err()
}

func newSelectionDeleteTestRuntime(
	t *testing.T,
	uids ...string,
) (*Runtime, *Subscription) {
	return newSelectionDeleteTestRuntimeWithConfig(t, SelectionStoreConfig{}, uids...)
}

func newSelectionDeleteTestRuntimeWithConfig(
	t *testing.T,
	config SelectionStoreConfig,
	uids ...string,
) (*Runtime, *Subscription) {
	t.Helper()
	store, err := newSelectionStore(
		config,
		selectionStoreDependencies{now: time.Now, random: &incrementingSelectionReader{}},
	)
	if err != nil {
		t.Fatal(err)
	}
	projector, err := NewProjector(ProjectionSpec{
		ClusterSessionID: "session",
		Resource:         ResourceType{Version: "v1", Resource: "pods", Namespaced: true},
		NamespaceScope:   NamespaceScope{All: true},
	})
	if err != nil {
		t.Fatal(err)
	}
	key := viewKey{sessionID: "session", viewID: "view"}
	rows := make(map[string]*kmgrv1.ResourceRow, len(uids))
	for _, uid := range uids {
		rows[uid] = selectionTransportTestRow(uid)
	}
	subscription := &Subscription{
		key: key, generation: 7, projector: projector, rows: rows,
		order: append([]string(nil), uids...), presentationRevision: 3, indexRevision: 2,
	}
	runtime := &Runtime{
		views: map[viewKey]*Subscription{key: subscription}, selectionStore: store,
	}
	return runtime, subscription
}
