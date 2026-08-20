package view

import (
	"context"
	"errors"
	"testing"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestRuntimeSelectionReusesCellOnlySnapshotAndNeverRebindsOldIndex(t *testing.T) {
	runtime, subscription, _ := newSelectionTransportTestRuntime(
		t,
		SelectionStoreConfig{},
		"a", "b", "c",
	)
	first, err := runtime.ApplySelectionGesture(
		"session", "view", 7, 2, "",
		SelectionGesture{Kind: SelectionGestureReplace, Index: 0},
	)
	if err != nil {
		t.Fatal(err)
	}
	subscription.mu.Lock()
	firstSnapshot := subscription.selectionSnapshot
	if firstSnapshot == nil {
		t.Fatal("first gesture did not publish the current snapshot")
	}
	// Published ResourceRows are immutable in production. Mutating this fixture
	// proves the token retained value identities rather than protobuf pointers.
	subscription.rows["a"].Identity.Name = "mutated-after-snapshot"
	subscription.advancePresentationLocked(false)
	if subscription.selectionSnapshot != firstSnapshot {
		t.Fatal("cell-only revision discarded the reusable selection snapshot")
	}
	subscription.mu.Unlock()

	continued, err := runtime.ApplySelectionGesture(
		"session", "view", 7, 2, first.Token,
		SelectionGesture{Kind: SelectionGestureCommandToggle, Index: 2},
	)
	if err != nil {
		t.Fatal(err)
	}
	if continued.SelectedCount != 2 || continued.IndexRevision != 2 {
		t.Fatalf("continued state = %#v", continued)
	}
	subscription.mu.Lock()
	if subscription.selectionSnapshot != firstSnapshot {
		t.Fatal("same index revision rebuilt the selection snapshot")
	}
	subscription.order = []string{"c", "b", "a"}
	subscription.advancePresentationLocked(true)
	if subscription.selectionSnapshot != nil {
		t.Fatal("index change retained the previous current snapshot pointer")
	}
	currentRevision := subscription.indexRevision
	subscription.mu.Unlock()

	projection, err := runtime.ProjectSelectionRange(
		"session", "view", 7, currentRevision, 0, 3, continued.Token,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !equalBools(projection.Membership.Selected, []bool{true, false, true}) {
		t.Fatalf("projected membership = %v", projection.Membership.Selected)
	}
	if projection.Membership.AnchorOffset == nil || *projection.Membership.AnchorOffset != 0 {
		t.Fatalf("anchor offset = %v, want 0", projection.Membership.AnchorOffset)
	}
	if _, err := runtime.ProjectSelectionRange(
		"session", "other-view", 7, currentRevision, 0, 3, continued.Token,
	); !errors.Is(err, ErrViewNotFound) {
		t.Fatalf("cross-view projection error = %v", err)
	}
	if _, err := runtime.ProjectSelectionRange(
		"session", "view", 7, 2, 0, 3, continued.Token,
	); !errors.Is(err, ErrStaleViewRevision) {
		t.Fatalf("stale projection error = %v", err)
	}

	// A previous token on a different index is validated but deliberately not
	// used as a numeric base. Index zero now identifies c, not a.
	fresh, err := runtime.ApplySelectionGesture(
		"session", "view", 7, currentRevision, continued.Token,
		SelectionGesture{Kind: SelectionGestureCommandToggle, Index: 0},
	)
	if err != nil {
		t.Fatal(err)
	}
	if fresh.SelectedCount != 1 || fresh.IndexRevision != currentRevision {
		t.Fatalf("fresh selection = %#v", fresh)
	}
	freshPage, err := runtime.FetchSelectionPage("session", "view", fresh.Token, 0, 8)
	if err != nil {
		t.Fatal(err)
	}
	if len(freshPage.Items) != 1 || freshPage.Items[0].Identity.UID != "c" {
		t.Fatalf("fresh page = %#v", freshPage)
	}
	oldPage, err := runtime.FetchSelectionPage("session", "view", first.Token, 0, 8)
	if err != nil {
		t.Fatal(err)
	}
	if len(oldPage.Items) != 1 || oldPage.Items[0].Identity.UID != "a" ||
		oldPage.Items[0].Identity.Name != "a" {
		t.Fatalf("old immutable page = %#v", oldPage)
	}
}

func TestRuntimeSelectionBuildDoesNotHoldSubscriptionLockOrPublishStaleSnapshot(t *testing.T) {
	runtime, subscription, _ := newSelectionTransportTestRuntime(
		t,
		SelectionStoreConfig{},
		"a", "b", "c",
	)
	buildStarted := make(chan struct{})
	continueBuild := make(chan struct{})
	subscription.selectionSnapshotBuildHook = func() {
		close(buildStarted)
		<-continueBuild
	}
	result := make(chan SelectionState, 1)
	failure := make(chan error, 1)
	go func() {
		state, err := runtime.ApplySelectionGesture(
			"session", "view", 7, 2, "",
			SelectionGesture{Kind: SelectionGestureReplace, Index: 0},
		)
		if err != nil {
			failure <- err
			return
		}
		result <- state
	}()
	<-buildStarted

	// This lock acquisition is deterministic evidence that hashing/map creation
	// happens outside Subscription.mu. Commit a newer index while it is paused.
	subscription.mu.Lock()
	subscription.order = []string{"c", "b", "a"}
	subscription.advancePresentationLocked(true)
	newRevision := subscription.indexRevision
	subscription.mu.Unlock()
	close(continueBuild)

	var captured SelectionState
	select {
	case err := <-failure:
		t.Fatal(err)
	case captured = <-result:
	}
	if captured.IndexRevision != 2 {
		t.Fatalf("racing gesture rebound to index revision %d", captured.IndexRevision)
	}
	page, err := runtime.FetchSelectionPage("session", "view", captured.Token, 0, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 1 || page.Items[0].Identity.UID != "a" {
		t.Fatalf("captured page = %#v", page)
	}
	subscription.mu.Lock()
	if subscription.selectionSnapshot != nil {
		t.Fatal("stale asynchronous build was published as the current snapshot")
	}
	subscription.selectionSnapshotBuildHook = nil
	subscription.mu.Unlock()

	current, err := runtime.ApplySelectionGesture(
		"session", "view", 7, newRevision, captured.Token,
		SelectionGesture{Kind: SelectionGestureReplace, Index: 0},
	)
	if err != nil {
		t.Fatal(err)
	}
	currentPage, err := runtime.FetchSelectionPage("session", "view", current.Token, 0, 1)
	if err != nil {
		t.Fatal(err)
	}
	if current.SelectedCount != 1 || currentPage.Items[0].Identity.UID != "c" {
		t.Fatalf("current page = %#v", currentPage)
	}
}

func TestRuntimeSelectionProjectionRejectsUIDCollisionInAnotherLogicalView(t *testing.T) {
	runtime, source, _ := newSelectionTransportTestRuntime(
		t,
		SelectionStoreConfig{},
		"same-uid",
	)
	state, err := runtime.ApplySelectionGesture(
		"session", "view", 7, 2, "",
		SelectionGesture{Kind: SelectionGestureReplace, Index: 0},
	)
	if err != nil {
		t.Fatal(err)
	}
	otherKey := viewKey{sessionID: "session", viewID: "other-view"}
	other := &Subscription{
		key: otherKey, generation: 9,
		rows: map[string]*kmgrv1.ResourceRow{
			"same-uid": selectionTransportTestRow("same-uid"),
		},
		order: []string{"same-uid"}, presentationRevision: 1, indexRevision: 1,
	}
	runtime.mu.Lock()
	runtime.views[otherKey] = other
	runtime.mu.Unlock()

	_, err = runtime.ProjectSelectionRange(
		"session", "other-view", 9, 1, 0, 1, state.Token,
	)
	if !errors.Is(err, ErrSelectionScopeMismatch) {
		t.Fatalf("cross-view UID collision error = %v", err)
	}
	// The source logical view can close without changing the token's scope.
	runtime.mu.Lock()
	delete(runtime.views, source.key)
	runtime.mu.Unlock()
	if _, err := runtime.FetchSelectionPage("session", "view", state.Token, 0, 1); err != nil {
		t.Fatalf("source page after close: %v", err)
	}
}

func TestRuntimeSelectionPageSurvivesViewCloseUntilFixedExpiry(t *testing.T) {
	runtime, subscription, clock := newSelectionTransportTestRuntime(
		t,
		SelectionStoreConfig{TokenTTL: time.Minute},
		"a",
	)
	state, err := runtime.ApplySelectionGesture(
		"session", "view", 7, 2, "",
		SelectionGesture{Kind: SelectionGestureReplace, Index: 0},
	)
	if err != nil {
		t.Fatal(err)
	}
	expiresAt := state.ExpiresAt
	runtime.mu.Lock()
	delete(runtime.views, subscription.key)
	runtime.mu.Unlock()
	subscription.mu.Lock()
	subscription.closed = true
	subscription.selectionSnapshot = nil
	subscription.mu.Unlock()

	if _, err := runtime.FetchSelectionPage("session", "view", state.Token, 0, 1); err != nil {
		t.Fatalf("page after view close: %v", err)
	}
	if _, err := runtime.FetchSelectionPage("other", "view", state.Token, 0, 1); !errors.Is(err, ErrSelectionScopeMismatch) {
		t.Fatalf("wrong-scope error = %v", err)
	}
	*clock = expiresAt
	if _, err := runtime.FetchSelectionPage("session", "view", state.Token, 0, 1); !errors.Is(err, ErrSelectionTokenExpired) {
		t.Fatalf("expiry error = %v", err)
	}
}

func TestRuntimeSelectionDoesNotCacheSnapshotRejectedByStoreBudget(t *testing.T) {
	runtime, subscription, _ := newSelectionTransportTestRuntime(
		t,
		SelectionStoreConfig{MaxSnapshotBytes: 1},
		"a",
	)
	_, err := runtime.ApplySelectionGesture(
		"session", "view", 7, 2, "",
		SelectionGesture{Kind: SelectionGestureReplace, Index: 0},
	)
	if !errors.Is(err, ErrSelectionCapacityExhausted) {
		t.Fatalf("apply error = %v", err)
	}
	subscription.mu.Lock()
	defer subscription.mu.Unlock()
	if subscription.selectionSnapshot != nil {
		t.Fatal("capacity-rejected snapshot remained cached by the subscription")
	}
}

func TestNewRuntimeOwnsConfiguredBoundedSelectionStore(t *testing.T) {
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{},
		SelectionStoreConfig: SelectionStoreConfig{
			TokenTTL: time.Minute, MaxTokens: 3, MaxPageSize: 7,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if runtime.selectionStore == nil || runtime.selectionStore.config.MaxTokens != 3 ||
		runtime.selectionStore.config.MaxPageSize != 7 ||
		runtime.selectionStore.config.TokenTTL != time.Minute {
		t.Fatalf("selection store config = %#v", runtime.selectionStore)
	}
	runtime.Close()

	invalid, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{},
		SelectionStoreConfig: SelectionStoreConfig{
			TokenTTL: -time.Second,
		},
	})
	if err == nil {
		invalid.Close()
		t.Fatal("negative selection token TTL was accepted")
	}
}

func TestGRPCSelectionTransportAndStatusMapping(t *testing.T) {
	runtime, subscription, _ := newSelectionTransportTestRuntime(
		t,
		SelectionStoreConfig{MaxTokens: 1},
		"a", "b",
	)
	service := &GRPCService{runtime: runtime}
	requestContext := &kmgrv1.RequestContext{
		RequestId: "request", ClusterSessionId: "session",
	}
	apply, err := service.ApplySelectionGesture(context.Background(), &kmgrv1.ApplySelectionGestureRequest{
		Context: requestContext, ViewId: "view", Generation: 7, IndexRevision: 2,
		Gesture: &kmgrv1.SelectionGesture{
			Kind:      kmgrv1.SelectionGestureKind_SELECTION_GESTURE_KIND_REPLACE,
			TargetUid: "b",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if apply.GetRequestId() != "request" || apply.GetSelection().GetSelectedCount() != 1 ||
		apply.GetSelection().GetAnchor().GetUid() != "b" || apply.GetSelection().GetExpiresAtUnixMs() == 0 {
		t.Fatalf("apply response = %#v", apply)
	}
	projection, err := service.ProjectSelectionRange(context.Background(), &kmgrv1.ProjectSelectionRangeRequest{
		Context: requestContext, ViewId: "view", Generation: 7, IndexRevision: 2,
		Length: 2, Token: apply.GetSelection().GetToken(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if !equalBools(projection.GetSelected(), []bool{false, true}) ||
		projection.AnchorOffset == nil || projection.GetAnchorOffset() != 1 {
		t.Fatalf("projection response = %#v", projection)
	}
	page, err := service.FetchSelectionPage(context.Background(), &kmgrv1.FetchSelectionPageRequest{
		Context: requestContext, ViewId: "view", Token: apply.GetSelection().GetToken(), Limit: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !page.GetDone() || len(page.GetItems()) != 1 || page.GetItems()[0].GetPinnedIndex() != 1 ||
		page.GetItems()[0].GetIdentity().GetClusterSessionId() != "session" ||
		page.GetItems()[0].GetIdentity().GetUid() != "b" {
		t.Fatalf("page response = %#v", page)
	}
	_, err = service.ApplySelectionGesture(context.Background(), &kmgrv1.ApplySelectionGestureRequest{
		Context: requestContext, ViewId: "view", Generation: 7, IndexRevision: 2,
		Gesture: &kmgrv1.SelectionGesture{
			Kind:      kmgrv1.SelectionGestureKind_SELECTION_GESTURE_KIND_REPLACE,
			TargetUid: "gone",
		},
	})
	if status.Code(err) != codes.NotFound {
		t.Fatalf("missing stable target code = %v (%v)", status.Code(err), err)
	}

	// The first immutable token remains live, so the configured process-wide
	// admission limit rejects a second gesture without evicting it.
	_, err = service.ApplySelectionGesture(context.Background(), &kmgrv1.ApplySelectionGestureRequest{
		Context: requestContext, ViewId: "view", Generation: 7, IndexRevision: 2,
		PreviousToken: apply.GetSelection().GetToken(),
		Gesture: &kmgrv1.SelectionGesture{
			Kind: kmgrv1.SelectionGestureKind_SELECTION_GESTURE_KIND_CLEAR,
		},
	})
	if status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("capacity code = %v (%v)", status.Code(err), err)
	}
	_, err = service.ApplySelectionGesture(context.Background(), &kmgrv1.ApplySelectionGestureRequest{
		Context: requestContext, ViewId: "view", Generation: 7, IndexRevision: 2,
		Gesture: &kmgrv1.SelectionGesture{},
	})
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("invalid gesture code = %v (%v)", status.Code(err), err)
	}
	subscription.mu.Lock()
	subscription.advancePresentationLocked(true)
	staleRevision := subscription.indexRevision - 1
	subscription.mu.Unlock()
	_, err = service.ProjectSelectionRange(context.Background(), &kmgrv1.ProjectSelectionRangeRequest{
		Context: requestContext, ViewId: "view", Generation: 7, IndexRevision: staleRevision,
		Length: 1, Token: apply.GetSelection().GetToken(),
	})
	if status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("stale projection code = %v (%v)", status.Code(err), err)
	}
	_, err = service.FetchSelectionPage(context.Background(), &kmgrv1.FetchSelectionPageRequest{
		Context: &kmgrv1.RequestContext{RequestId: "request", ClusterSessionId: "other"},
		ViewId:  "view", Token: apply.GetSelection().GetToken(), Limit: 1,
	})
	if status.Code(err) != codes.NotFound {
		t.Fatalf("wrong-scope code = %v (%v)", status.Code(err), err)
	}
}

func newSelectionTransportTestRuntime(
	t *testing.T,
	config SelectionStoreConfig,
	uids ...string,
) (*Runtime, *Subscription, *time.Time) {
	t.Helper()
	now := time.Date(2026, time.August, 19, 12, 0, 0, 0, time.UTC)
	store, err := newSelectionStore(config, selectionStoreDependencies{
		now:    func() time.Time { return now },
		random: &incrementingSelectionReader{},
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
		key: key, generation: 7, rows: rows, order: append([]string(nil), uids...),
		presentationRevision: 3, indexRevision: 2,
	}
	runtime := &Runtime{
		views: map[viewKey]*Subscription{key: subscription}, selectionStore: store,
	}
	return runtime, subscription, &now
}

type incrementingSelectionReader struct {
	next byte
}

func (r *incrementingSelectionReader) Read(buffer []byte) (int, error) {
	for index := range buffer {
		r.next++
		buffer[index] = r.next
	}
	return len(buffer), nil
}

func selectionTransportTestRow(uid string) *kmgrv1.ResourceRow {
	return &kmgrv1.ResourceRow{Identity: &kmgrv1.ResourceIdentity{
		ClusterSessionId: "session",
		Version:          "v1",
		Resource:         "pods",
		Namespace:        "default",
		Name:             uid,
		Uid:              uid,
	}}
}

func equalBools(left, right []bool) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}
