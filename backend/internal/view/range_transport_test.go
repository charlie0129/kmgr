package view

import (
	"context"
	"errors"
	"fmt"
	"testing"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestFetchRangeReturnsExactBoundedOrder(t *testing.T) {
	runtime, subscription := rangeTestRuntime("session", "view", 7, "a", "b", "c")

	result, err := runtime.FetchRange("session", "view", 7, 3, 2, 1, 2)
	if err != nil {
		t.Fatal(err)
	}
	if result.Generation != 7 || result.PresentationRevision != 3 || result.IndexRevision != 2 ||
		result.StartIndex != 1 || result.RowsVisible != 3 {
		t.Fatalf("unexpected range metadata: %#v", result)
	}
	if got := rangeRowUIDs(result.Rows); !equalStrings(got, []string{"b", "c"}) {
		t.Fatalf("range UIDs = %v", got)
	}
	if result.Rows[0] != subscription.rows["b"] {
		t.Fatal("FetchRange deep-copied an immutable projected row")
	}

	end, err := runtime.FetchRange("session", "view", 7, 3, 2, 3, 8)
	if err != nil {
		t.Fatal(err)
	}
	if len(end.Rows) != 0 || end.RowsVisible != 3 || end.StartIndex != 3 {
		t.Fatalf("end range = %#v", end)
	}
}

func TestFetchRangeRejectsInvalidOrStaleCoordinates(t *testing.T) {
	runtime, _ := rangeTestRuntime("session", "view", 7, "a", "b")
	tests := []struct {
		name string
		call func() error
		want error
	}{
		{name: "zero length", call: func() error {
			_, err := runtime.FetchRange("session", "view", 7, 3, 2, 0, 0)
			return err
		}, want: ErrInvalidViewRange},
		{name: "oversized", call: func() error {
			_, err := runtime.FetchRange("session", "view", 7, 3, 2, 0, DefaultViewRangeLength+1)
			return err
		}, want: ErrInvalidViewRange},
		{name: "past end", call: func() error {
			_, err := runtime.FetchRange("session", "view", 7, 3, 2, 3, 1)
			return err
		}, want: ErrInvalidViewRange},
		{name: "presentation", call: func() error {
			_, err := runtime.FetchRange("session", "view", 7, 2, 2, 0, 1)
			return err
		}, want: ErrStaleViewRevision},
		{name: "index", call: func() error {
			_, err := runtime.FetchRange("session", "view", 7, 3, 1, 0, 1)
			return err
		}, want: ErrStaleViewRevision},
		{name: "generation", call: func() error {
			_, err := runtime.FetchRange("session", "view", 6, 3, 2, 0, 1)
			return err
		}, want: ErrStaleViewGeneration},
		{name: "missing", call: func() error {
			_, err := runtime.FetchRange("session", "missing", 7, 3, 2, 0, 1)
			return err
		}, want: ErrViewNotFound},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if err := test.call(); !errors.Is(err, test.want) {
				t.Fatalf("error = %v, want %v", err, test.want)
			}
		})
	}
}

func TestFetchRangeRejectsRevisionChangedWhileWaitingForView(t *testing.T) {
	runtime, subscription := rangeTestRuntime("session", "view", 7, "a")
	subscription.mu.Lock()
	started := make(chan struct{})
	result := make(chan error, 1)
	go func() {
		close(started)
		_, err := runtime.FetchRange("session", "view", 7, 3, 2, 0, 1)
		result <- err
	}()
	<-started
	subscription.rows["a"] = rangeTestRow("a", "new")
	subscription.presentationRevision = 4
	subscription.mu.Unlock()
	if err := <-result; !errors.Is(err, ErrStaleViewRevision) {
		t.Fatalf("error = %v, want stale revision", err)
	}
}

func TestFetchRangeRejectsReplacedGeneration(t *testing.T) {
	runtime, previous := rangeTestRuntime("session", "view", 7, "a")
	previous.mu.Lock()
	result := make(chan error, 1)
	started := make(chan struct{})
	go func() {
		close(started)
		_, err := runtime.FetchRange("session", "view", 7, 3, 2, 0, 1)
		result <- err
	}()
	<-started
	replacement := &Subscription{
		key: viewKey{sessionID: "session", viewID: "view"}, generation: 8,
		rows: map[string]*kmgrv1.ResourceRow{"b": rangeTestRow("b", "b")}, order: []string{"b"},
		presentationRevision: 1, indexRevision: 1,
	}
	runtime.mu.Lock()
	runtime.views[replacement.key] = replacement
	runtime.mu.Unlock()
	previous.mu.Unlock()
	if err := <-result; !errors.Is(err, ErrStaleViewGeneration) {
		t.Fatalf("error = %v, want stale generation", err)
	}
}

func TestUpdateMetricInterestPinsIndexRevisionAndBounds(t *testing.T) {
	runtime, _ := rangeTestRuntime("session", "view", 7, "a", "b")
	if err := runtime.UpdateMetricInterest("session", "view", 7, 2, 2, 1); err != nil {
		t.Fatal(err)
	}
	if err := runtime.UpdateMetricInterest("session", "view", 7, 1, 0, 1); !errors.Is(err, ErrStaleViewRevision) {
		t.Fatalf("stale index error = %v", err)
	}
	if err := runtime.UpdateMetricInterest("session", "view", 7, 2, 0, 0); !errors.Is(err, ErrInvalidViewRange) {
		t.Fatalf("zero length error = %v", err)
	}
}

func TestViewportRetentionCanSpanMultipleFetchRanges(t *testing.T) {
	uids := make([]string, DefaultViewRangeLength+1)
	for index := range uids {
		uids[index] = fmt.Sprintf("uid-%d", index)
	}
	runtime, _ := rangeTestRuntime("session", "view", 7, uids...)
	if err := runtime.UpdateMetricInterest(
		"session", "view", 7, 2, 0, DefaultViewRangeLength+1,
	); err != nil {
		t.Fatalf("retention spanning fetch ranges: %v", err)
	}
	if err := runtime.UpdateMetricInterest(
		"session", "view", 7, 2, 0, DefaultViewRetentionLength+1,
	); !errors.Is(err, ErrInvalidViewRange) {
		t.Fatalf("oversized retention error = %v, want %v", err, ErrInvalidViewRange)
	}
}

func TestGRPCFetchViewRangeMapsValidationAndRevisions(t *testing.T) {
	runtime, _ := rangeTestRuntime("session", "view", 7, "a", "b")
	service := &GRPCService{runtime: runtime}
	request := &kmgrv1.FetchViewRangeRequest{
		Context: &kmgrv1.RequestContext{RequestId: "request", ClusterSessionId: "session"},
		ViewId:  "view", Generation: 7, PresentationRevision: 3, IndexRevision: 2,
		StartIndex: 0, Length: 1,
	}
	response, err := service.FetchViewRange(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if response.GetRequestId() != "request" || response.GetRowsVisible() != 2 ||
		!equalStrings(rangeRowUIDs(response.GetRows()), []string{"a"}) {
		t.Fatalf("response = %#v", response)
	}

	request.PresentationRevision = 2
	if _, err := service.FetchViewRange(context.Background(), request); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("stale revision code = %v (%v)", status.Code(err), err)
	}
	request.PresentationRevision = 3
	request.Length = 0
	if _, err := service.FetchViewRange(context.Background(), request); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("invalid range code = %v (%v)", status.Code(err), err)
	}
	request.Length = 1
	request.ViewId = "missing"
	if _, err := service.FetchViewRange(context.Background(), request); status.Code(err) != codes.NotFound {
		t.Fatalf("missing view code = %v (%v)", status.Code(err), err)
	}
}

func TestGRPCUpdateMetricInterestReturnsAcknowledgement(t *testing.T) {
	runtime, _ := rangeTestRuntime("session", "view", 7, "a")
	service := &GRPCService{runtime: runtime}
	response, err := service.UpdateMetricInterest(context.Background(), &kmgrv1.UpdateMetricInterestRequest{
		Context: &kmgrv1.RequestContext{RequestId: "request", ClusterSessionId: "session"},
		ViewId:  "view", Generation: 7, IndexRevision: 2, Length: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !response.GetAccepted() || response.GetRequestId() != "request" {
		t.Fatalf("acknowledgement = %#v", response)
	}
}

func rangeTestRuntime(sessionID, viewID string, generation uint64, uids ...string) (*Runtime, *Subscription) {
	key := viewKey{sessionID: sessionID, viewID: viewID}
	rows := make(map[string]*kmgrv1.ResourceRow, len(uids))
	for _, uid := range uids {
		rows[uid] = rangeTestRow(uid, uid)
	}
	subscription := &Subscription{
		key: key, generation: generation, rows: rows, order: append([]string(nil), uids...),
		presentationRevision: 3, indexRevision: 2,
	}
	return &Runtime{views: map[viewKey]*Subscription{key: subscription}}, subscription
}

func rangeTestRow(uid, value string) *kmgrv1.ResourceRow {
	return &kmgrv1.ResourceRow{
		Identity: &kmgrv1.ResourceIdentity{Uid: uid, Name: uid},
		Cells:    []*kmgrv1.Cell{{ColumnId: "value", DisplayText: value}},
	}
}

func rangeRowUIDs(rows []*kmgrv1.ResourceRow) []string {
	result := make([]string, 0, len(rows))
	for _, row := range rows {
		result = append(result, row.GetIdentity().GetUid())
	}
	return result
}

func equalStrings(left, right []string) bool {
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

// invalidationRows is a test-only adapter for assertions that previously read
// row payloads directly from StreamView. Production clients use FetchViewRange;
// these unit tests already hold the concrete Subscription and only need a
// consistent copy of its immutable pointers after observing an invalidation.
func invalidationRows(
	subscription *Subscription,
	events []*kmgrv1.ViewEvent,
) []*kmgrv1.ResourceRow {
	if firstInvalidation(events) == nil {
		return nil
	}
	subscription.mu.Lock()
	defer subscription.mu.Unlock()
	rows := make([]*kmgrv1.ResourceRow, 0, len(subscription.order))
	for _, uid := range subscription.order {
		if row := subscription.rows[uid]; row != nil {
			rows = append(rows, row)
		}
	}
	return rows
}

func subscriptionHasUID(subscription *Subscription, uid string) bool {
	subscription.mu.Lock()
	defer subscription.mu.Unlock()
	return subscription.rows[uid] != nil
}
