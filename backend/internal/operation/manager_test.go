package operation

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"
	"unsafe"

	"github.com/charlie0129/kmgr/backend/internal/object"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const highCardinalityOperationItems = 100_000

func TestManagerReportsMultiItemProgressAndPartialSuccess(t *testing.T) {
	t.Parallel()
	manager := NewManager()
	t.Cleanup(manager.Close)
	identities := []object.Identity{
		operationTestIdentity("one", "uid-one"),
		operationTestIdentity("two", "uid-two"),
	}
	firstReported := make(chan struct{})
	continueRun := make(chan struct{})
	operation, err := manager.StartMany(context.Background(), "bulk", "delete", identities, func(_ context.Context, report Reporter) error {
		report(0, ItemUpdate{State: ItemStateRunning})
		report(0, ItemUpdate{State: ItemStateSucceeded})
		close(firstReported)
		<-continueRun
		report(1, ItemUpdate{State: ItemStateRunning})
		report(1, ItemUpdate{State: ItemStateFailed, Err: errors.New("forbidden")})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	<-firstReported
	status := operation.Status()
	if status.State != StateRunning || status.CompletedItems != 1 || status.Items[0].State != ItemStateSucceeded || status.Items[1].State != ItemStatePending {
		t.Fatalf("progress status = %#v", status)
	}
	status.Items[0].State = ItemStateFailed
	if operation.Status().Items[0].State != ItemStateSucceeded {
		t.Fatal("Status returned a mutable item slice")
	}
	close(continueRun)
	select {
	case <-operation.Done():
	case <-time.After(time.Second):
		t.Fatal("operation did not finish")
	}
	status = operation.Status()
	if status.State != StatePartiallySucceeded || status.CompletedItems != 2 || status.Err != nil {
		t.Fatalf("terminal status = %#v", status)
	}
	if status.Items[1].Err == nil || status.Items[1].State != ItemStateFailed {
		t.Fatalf("failed item = %#v", status.Items[1])
	}
}

func TestManagerCancelsPendingItems(t *testing.T) {
	t.Parallel()
	manager := NewManager()
	t.Cleanup(manager.Close)
	started := make(chan struct{})
	operation, err := manager.StartMany(context.Background(), "cancel-bulk", "delete", []object.Identity{
		operationTestIdentity("one", "uid-one"), operationTestIdentity("two", "uid-two"),
	}, func(ctx context.Context, report Reporter) error {
		report(0, ItemUpdate{State: ItemStateRunning})
		close(started)
		<-ctx.Done()
		report(0, ItemUpdate{State: ItemStateCancelled, Err: ctx.Err()})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	<-started
	operation.Cancel()
	<-operation.Done()
	status := operation.Status()
	if status.State != StateCancelled || status.CompletedItems != 2 ||
		status.Items[0].State != ItemStateCancelled || status.Items[1].State != ItemStateCancelled {
		t.Fatalf("cancelled status = %#v", status)
	}
}

func TestManagerCancelNotStartedLeavesRunningItemsAlive(t *testing.T) {
	t.Parallel()
	manager := NewManager()
	t.Cleanup(manager.Close)
	firstStarted := make(chan struct{})
	finishFirst := make(chan struct{})
	contextStillLive := make(chan bool, 1)
	secondClaimed := make(chan bool, 1)
	operation, err := manager.StartMany(context.Background(), "cancel-queued", "delete", []object.Identity{
		operationTestIdentity("one", "uid-one"), operationTestIdentity("two", "uid-two"),
	}, func(ctx context.Context, report Reporter) error {
		if !report(0, ItemUpdate{State: ItemStateRunning}) {
			return errors.New("first item did not claim its running state")
		}
		close(firstStarted)
		<-finishFirst
		select {
		case <-ctx.Done():
			contextStillLive <- false
		default:
			contextStillLive <- true
		}
		report(0, ItemUpdate{State: ItemStateSucceeded})
		claimed := report(1, ItemUpdate{State: ItemStateRunning})
		secondClaimed <- claimed
		if claimed {
			report(1, ItemUpdate{State: ItemStateSucceeded})
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	<-firstStarted
	if status := operation.Status(); status.State != StateRunning ||
		status.Items[0].State != ItemStateRunning || status.Items[1].State != ItemStatePending {
		t.Fatalf("pre-cancel status = %#v", status)
	}
	if !operation.CancelNotStarted() {
		t.Fatal("pending-only cancellation was not accepted")
	}
	status := operation.Status()
	if status.State != StateRunning || status.CompletedItems != 1 ||
		status.Items[0].State != ItemStateRunning || status.Items[1].State != ItemStateCancelled ||
		!errors.Is(status.Items[1].Err, context.Canceled) {
		t.Fatalf("pending-only status = %#v", status)
	}
	close(finishFirst)
	<-operation.Done()
	if !<-contextStillLive {
		t.Fatal("pending-only cancellation cancelled the running item's context")
	}
	if <-secondClaimed {
		t.Fatal("cancelled pending item claimed its running state")
	}
	status = operation.Status()
	if status.State != StatePartiallySucceeded || status.CompletedItems != 2 ||
		status.Items[0].State != ItemStateSucceeded || status.Items[1].State != ItemStateCancelled {
		t.Fatalf("terminal pending-only status = %#v", status)
	}
	if operation.CancelNotStarted() {
		t.Fatal("terminal operation accepted pending-only cancellation")
	}
}

func TestManagerHonorsCallerCancellationWithoutLosingShutdownOwnership(t *testing.T) {
	t.Parallel()
	manager := NewManager()
	t.Cleanup(manager.Close)
	parent, cancelParent := context.WithCancel(context.Background())
	started := make(chan struct{})
	operation, err := manager.StartOne(
		parent, "caller-cancel", "scale", operationTestIdentity("one", "uid-one"),
		func(ctx context.Context) (string, error) {
			close(started)
			<-ctx.Done()
			return "", context.Cause(ctx)
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	<-started
	cancelParent()
	<-operation.Done()
	if status := operation.Status(); status.State != StateCancelled ||
		!errors.Is(status.Err, context.Canceled) {
		t.Fatalf("caller-cancelled status = %#v", status)
	}
}

func TestManagerPreservesCallerDeadlineCause(t *testing.T) {
	t.Parallel()
	manager := NewManager()
	t.Cleanup(manager.Close)
	parent, cancelParent := context.WithTimeout(context.Background(), time.Millisecond)
	defer cancelParent()
	operation, err := manager.StartOne(
		parent, "caller-deadline", "scale", operationTestIdentity("one", "uid-one"),
		func(ctx context.Context) (string, error) {
			<-ctx.Done()
			return "", context.Cause(ctx)
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	<-operation.Done()
	if status := operation.Status(); status.State != StateCancelled ||
		!errors.Is(status.Err, context.DeadlineExceeded) {
		t.Fatalf("deadline status = %#v", status)
	}
}

func TestManagerCloseCancelsAndDrainsActiveOperations(t *testing.T) {
	t.Parallel()
	manager := NewManager()
	started := make(chan struct{})
	workerExited := make(chan struct{})
	operation, err := manager.StartOne(
		context.Background(), "active", "update-data", operationTestIdentity("one", "uid-one"),
		func(ctx context.Context) (string, error) {
			close(started)
			<-ctx.Done()
			close(workerExited)
			return "", context.Cause(ctx)
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	<-started
	manager.Close()
	select {
	case <-workerExited:
	default:
		t.Fatal("Close returned before the mutation worker exited")
	}
	select {
	case <-operation.Done():
	default:
		t.Fatal("Close returned before the operation published completion")
	}
	status := operation.Status()
	if status.State != StateCancelled || status.Err == nil {
		t.Fatalf("closed operation status = %#v", status)
	}
	if _, err := manager.StartOne(
		context.Background(), "late", "scale", operationTestIdentity("two", "uid-two"),
		func(context.Context) (string, error) { return "", nil },
	); !errors.Is(err, ErrManagerClosed) {
		t.Fatalf("start after close error = %v", err)
	}
}

func TestManagerCloseContextBoundsStubbornOperation(t *testing.T) {
	manager := NewManager()
	started := make(chan struct{})
	cancelled := make(chan struct{})
	release := make(chan struct{})
	released := false
	t.Cleanup(func() {
		if !released {
			close(release)
		}
		manager.Close()
	})
	operation, err := manager.StartOne(
		context.Background(), "stubborn", "delete", operationTestIdentity("one", "uid-one"),
		func(ctx context.Context) (string, error) {
			close(started)
			<-ctx.Done()
			close(cancelled)
			<-release
			return "", context.Cause(ctx)
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	<-started

	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancel()
	begin := time.Now()
	closeResult := make(chan error, 1)
	go func() { closeResult <- manager.CloseContext(ctx) }()
	select {
	case err = <-closeResult:
	case <-time.After(500 * time.Millisecond):
		close(release)
		released = true
		<-closeResult
		t.Fatal("CloseContext did not return within a bounded interval")
	}
	elapsed := time.Since(begin)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("CloseContext error = %v, want deadline exceeded", err)
	}
	if elapsed > 500*time.Millisecond {
		t.Fatalf("CloseContext elapsed = %v, want a bounded shutdown", elapsed)
	}
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("CloseContext did not cancel the stubborn operation")
	}
	select {
	case <-operation.Done():
		t.Fatal("stubborn operation finished before its runner was released")
	default:
	}

	close(release)
	released = true
	manager.Close()
	select {
	case <-operation.Done():
	default:
		t.Fatal("operation did not finish after its stubborn runner was released")
	}
}

func TestManagerEvictsOldestTerminalOperationsAndReusesIDs(t *testing.T) {
	t.Parallel()
	manager := NewManagerWithConfig(ManagerConfig{
		MaxTrackedOperations: 2, MaxTerminalOperations: 1, TerminalRetention: time.Hour,
	})
	t.Cleanup(manager.Close)
	startCompleted := func(id string) *TrackedOperation {
		t.Helper()
		operation, err := manager.StartOne(
			context.Background(), id, "scale", operationTestIdentity(id, "uid-"+id),
			func(context.Context) (string, error) { return "rv", nil },
		)
		if err != nil {
			t.Fatal(err)
		}
		<-operation.Done()
		return operation
	}
	first := startCompleted("first")
	startCompleted("second")
	if _, found := manager.Get("first"); found {
		t.Fatal("oldest terminal operation was not evicted")
	}
	if _, found := manager.Get("second"); !found {
		t.Fatal("newest terminal operation was evicted")
	}
	reused, err := manager.StartOne(
		context.Background(), "first", "scale", operationTestIdentity("again", "uid-again"),
		func(context.Context) (string, error) { return "rv-2", nil },
	)
	if err != nil {
		t.Fatalf("reuse evicted ID: %v", err)
	}
	<-reused.Done()
	if first == reused {
		t.Fatal("ID reuse returned the evicted operation")
	}
}

func TestManagerExpiresTerminalOperations(t *testing.T) {
	t.Parallel()
	manager := NewManagerWithConfig(ManagerConfig{
		MaxTrackedOperations: 10, MaxTerminalOperations: 10, TerminalRetention: time.Minute,
	})
	t.Cleanup(manager.Close)
	clock := time.Unix(100, 0)
	manager.now = func() time.Time { return clock }
	operation, err := manager.StartOne(
		context.Background(), "expired", "scale", operationTestIdentity("one", "uid-one"),
		func(context.Context) (string, error) { return "rv", nil },
	)
	if err != nil {
		t.Fatal(err)
	}
	<-operation.Done()
	if _, found := manager.Get("expired"); !found {
		t.Fatal("terminal operation expired too early")
	}
	clock = clock.Add(time.Minute)
	if _, found := manager.Get("expired"); found {
		t.Fatal("terminal operation was retained past its TTL")
	}
}

func TestManagerBoundsConcurrentOperationsWhenNoneAreEvictable(t *testing.T) {
	t.Parallel()
	manager := NewManagerWithConfig(ManagerConfig{
		MaxTrackedOperations: 1, MaxTerminalOperations: 1, TerminalRetention: time.Hour,
	})
	t.Cleanup(manager.Close)
	started := make(chan struct{})
	first, err := manager.StartOne(
		context.Background(), "first", "scale", operationTestIdentity("one", "uid-one"),
		func(ctx context.Context) (string, error) {
			close(started)
			<-ctx.Done()
			return "", ctx.Err()
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	<-started
	if _, err := manager.StartOne(
		context.Background(), "second", "scale", operationTestIdentity("two", "uid-two"),
		func(context.Context) (string, error) { return "", nil },
	); !errors.Is(err, ErrManagerFull) {
		t.Fatalf("full manager error = %v", err)
	}
	first.Cancel()
	<-first.Done()
}

func TestManagerHighCardinalityProgressIsLinearAndExactlyReplayable(t *testing.T) {
	manager := NewManager()
	t.Cleanup(manager.Close)
	identities := make([]object.Identity, highCardinalityOperationItems)
	for index := range identities {
		value := strconv.Itoa(index)
		identities[index] = operationTestIdentity("pod-"+value, "uid-"+value)
	}
	operation, err := manager.StartMany(
		context.Background(), "large-bulk", "delete", identities,
		func(_ context.Context, report Reporter) error {
			for index := range identities {
				if !report(index, ItemUpdate{State: ItemStateSucceeded}) {
					return errors.New("terminal item report was rejected")
				}
			}
			return nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-operation.Done():
	case <-time.After(10 * time.Second):
		t.Fatal("100k-item operation exceeded the linear progress budget")
	}

	offset := 0
	seen := make(map[string]struct{}, highCardinalityOperationItems)
	for offset < highCardinalityOperationItems {
		summary, items, next, _ := operation.Progress(offset, 257)
		if summary.Items != nil {
			t.Fatal("compact progress summary retained the complete item slice")
		}
		if next <= offset || len(items) > 257 {
			t.Fatalf("progress page offset=%d next=%d items=%d", offset, next, len(items))
		}
		for _, item := range items {
			if item.State != ItemStateSucceeded {
				t.Fatalf("item %q state = %v", item.Identity.UID, item.State)
			}
			if _, duplicate := seen[item.Identity.UID]; duplicate {
				t.Fatalf("item %q was replayed twice", item.Identity.UID)
			}
			seen[item.Identity.UID] = struct{}{}
		}
		offset = next
	}
	status := operation.Status()
	if status.State != StateSucceeded || status.CompletedItems != highCardinalityOperationItems ||
		len(status.Items) != highCardinalityOperationItems || len(seen) != highCardinalityOperationItems {
		t.Fatalf("large terminal status state=%v completed=%d items=%d seen=%d", status.State, status.CompletedItems, len(status.Items), len(seen))
	}
}

func TestManagerAggregateProgressRetainsOnlyBoundedFailureDetails(t *testing.T) {
	const total = 10_000
	manager := NewManager()
	t.Cleanup(manager.Close)
	operation, err := manager.StartAggregate(
		context.Background(), "aggregate-delete", "delete", "session", total,
		func(_ context.Context, report AggregateReporter) error {
			for index := range total {
				identity := operationTestIdentity(
					fmt.Sprintf("pod-%d", index), fmt.Sprintf("uid-%d", index),
				)
				if !report(identity, ItemUpdate{State: ItemStateRunning}) {
					return errors.New("aggregate running claim was rejected")
				}
				update := ItemUpdate{State: ItemStateSucceeded}
				if index%10 == 0 {
					update = ItemUpdate{State: ItemStateFailed, Err: errors.New("delete failed")}
				}
				if !report(identity, update) {
					return errors.New("aggregate terminal report was rejected")
				}
			}
			return nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	<-operation.Done()
	status := operation.Status()
	if !status.AggregateOnly || status.CompletedItems != total || status.TotalItems != total ||
		status.State != StatePartiallySucceeded {
		t.Fatalf("aggregate status = %#v", status)
	}
	if len(status.Items) != DefaultMaxAggregateResults ||
		status.RetainedItemResults != DefaultMaxAggregateResults ||
		status.OmittedItemResults != total/10-DefaultMaxAggregateResults {
		t.Fatalf(
			"retained=%d retained count=%d omitted=%d",
			len(status.Items), status.RetainedItemResults, status.OmittedItemResults,
		)
	}
	if status.Items[0].Identity.UID != "uid-0" || status.Items[1].Identity.UID != "uid-10" {
		t.Fatalf("failure detail order = %#v", status.Items[:2])
	}
	_, first, next, _ := operation.Progress(0, 17)
	if len(first) != 17 || next != 17 {
		t.Fatalf("first progress page = %d, next = %d", len(first), next)
	}
	if operation.CancelNotStarted() {
		t.Fatal("aggregate operation accepted unsupported pending-only cancellation")
	}
}

func TestManagerAggregateRunnerExitAccountsForUnnamedRemainder(t *testing.T) {
	manager := NewManager()
	t.Cleanup(manager.Close)
	operation, err := manager.StartAggregate(
		context.Background(), "aggregate-short", "delete", "session", 4,
		func(_ context.Context, report AggregateReporter) error {
			identity := operationTestIdentity("pod", "uid")
			if !report(identity, ItemUpdate{State: ItemStateSucceeded}) {
				t.Fatal("aggregate success report was rejected")
			}
			return errors.New("selection page failed")
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	<-operation.Done()
	status := operation.Status()
	if status.State != StatePartiallySucceeded || status.CompletedItems != 4 ||
		status.OmittedItemResults != 3 || status.Err == nil {
		t.Fatalf("aggregate short status = %#v", status)
	}
}

func TestManagerAggregateSnapshotsBoundedErrorsWithoutHiddenPayloads(t *testing.T) {
	manager := NewManager()
	t.Cleanup(manager.Close)
	itemErr := &aggregateHiddenPayloadError{
		message: strings.Repeat("failure ", maxAggregateErrorTextBytes),
		payload: make([]byte, DefaultMaxAggregateBytes*2),
	}
	runnerErr := &aggregateHiddenPayloadError{
		message: strings.Repeat("runner failure ", maxAggregateErrorTextBytes),
		payload: make([]byte, DefaultMaxAggregateBytes*2),
	}
	operation, err := manager.StartAggregate(
		context.Background(), "aggregate-error-snapshot", "delete", "session", 2,
		func(_ context.Context, report AggregateReporter) error {
			if !report(
				operationTestIdentity("pod", "uid"),
				ItemUpdate{State: ItemStateFailed, Err: itemErr},
			) {
				return errors.New("aggregate failure report was rejected")
			}
			return runnerErr
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	<-operation.Done()
	status := operation.Status()
	if len(status.Items) != 1 || status.Items[0].Err == nil || status.Err == nil {
		t.Fatalf("aggregate error status = %#v", status)
	}
	var retainedPayload *aggregateHiddenPayloadError
	if errors.As(status.Items[0].Err, &retainedPayload) ||
		errors.As(status.Err, &retainedPayload) {
		t.Fatal("aggregate status retained a concrete hidden-payload error")
	}
	if len(status.Items[0].Err.Error()) > maxAggregateErrorTextBytes ||
		len(status.Err.Error()) > maxAggregateErrorTextBytes ||
		!strings.HasPrefix(status.Err.Error(), "runner failure ") {
		t.Fatalf(
			"snapshot item bytes=%d terminal bytes=%d",
			len(status.Items[0].Err.Error()), len(status.Err.Error()),
		)
	}
	if status.retainedItemBytes != retainedAggregateItemBytes(status.Items[0]) ||
		status.retainedItemBytes > DefaultMaxAggregateBytes {
		t.Fatalf(
			"aggregate retained bytes = %d, maximum = %d",
			status.retainedItemBytes, DefaultMaxAggregateBytes,
		)
	}
}

func TestAggregateAccountingConstantsCoverRetainedStructures(t *testing.T) {
	if size := int(unsafe.Sizeof(ItemStatus{})); size > aggregateItemSlotBytes {
		t.Fatalf("ItemStatus size = %d, reserved slot = %d", size, aggregateItemSlotBytes)
	}
	if size := int(unsafe.Sizeof(aggregateTextError{})); size > aggregateTextErrorBytes {
		t.Fatalf("text error size = %d, reserved = %d", size, aggregateTextErrorBytes)
	}
	fixedAPIStatusSize := int(unsafe.Sizeof(aggregateAPIStatusSnapshot{})) +
		int(unsafe.Sizeof(metav1.StatusDetails{}))
	if fixedAPIStatusSize > aggregateAPIStatusFixedBytes {
		t.Fatalf(
			"API status fixed size = %d, reserved = %d",
			fixedAPIStatusSize, aggregateAPIStatusFixedBytes,
		)
	}
	if size := int(unsafe.Sizeof(metav1.StatusCause{})); size > aggregateAPIStatusCauseBytes {
		t.Fatalf("API status cause size = %d, reserved = %d", size, aggregateAPIStatusCauseBytes)
	}
	snapshot := newAggregateAPIStatusSnapshot(metav1.Status{
		Reason: metav1.StatusReasonForbidden, Code: 403,
		Details: &metav1.StatusDetails{
			Causes: make([]metav1.StatusCause, maxAggregateAPIStatusCauses),
		},
	}).(*aggregateAPIStatusSnapshot)
	if len(snapshot.status.Details.Causes) != 0 ||
		cap(snapshot.status.Details.Causes) != maxAggregateAPIStatusCauses ||
		snapshot.aggregateRetainedBytes() < aggregateAPIStatusFixedBytes+
			maxAggregateAPIStatusCauses*aggregateAPIStatusCauseBytes {
		t.Fatalf(
			"blank cause accounting len=%d cap=%d bytes=%d",
			len(snapshot.status.Details.Causes), cap(snapshot.status.Details.Causes),
			snapshot.aggregateRetainedBytes(),
		)
	}
}

func TestAggregateAPIStatusSnapshotPreservesStructuredDiagnostics(t *testing.T) {
	const (
		rawStatusMessage = "raw server response secret"
		rawCauseMessage  = "raw validation cause secret"
	)
	tests := []struct {
		name          string
		reason        metav1.StatusReason
		code          int32
		wantCategory  kmgrv1.ErrorCategory
		wantReason    string
		wantRetryable bool
		retryAfter    int32
	}{
		{
			name: "forbidden", reason: metav1.StatusReasonForbidden, code: 403,
			wantCategory: kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHORIZATION,
			wantReason:   "Forbidden",
		},
		{
			name: "unauthorized", reason: metav1.StatusReasonUnauthorized, code: 401,
			wantCategory: kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHENTICATION,
			wantReason:   "AuthenticationRejected",
		},
		{
			name: "not found", reason: metav1.StatusReasonNotFound, code: 404,
			wantCategory: kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND,
			wantReason:   "NotFound",
		},
		{
			name: "conflict", reason: metav1.StatusReasonConflict, code: 409,
			wantCategory: kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT,
			wantReason:   "ApplyConflict",
		},
		{
			name: "retryable timeout", reason: metav1.StatusReasonServerTimeout, code: 504,
			wantCategory: kmgrv1.ErrorCategory_ERROR_CATEGORY_INTERNAL,
			wantReason:   "ServerTimeout", wantRetryable: true, retryAfter: 7,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			original := &apierrors.StatusError{ErrStatus: metav1.Status{
				Status: metav1.StatusFailure, Message: rawStatusMessage,
				Reason: test.reason, Code: test.code,
				Details: &metav1.StatusDetails{
					Name: "settings", Group: "apps", Kind: "Deployment",
					RetryAfterSeconds: test.retryAfter,
					Causes: []metav1.StatusCause{{
						Type: metav1.CauseTypeForbidden, Field: "spec.replicas",
						Message: rawCauseMessage,
					}},
				},
			}}
			snapshot := snapshotAggregateError(original)
			structured := structuredOperationError(snapshot, nil, "delete")
			if structured.GetCategory() != test.wantCategory ||
				structured.GetReason() != test.wantReason ||
				structured.GetHttpStatusCode() != test.code ||
				structured.GetRetryable() != test.wantRetryable ||
				structured.GetRetryAfterMs() != int64(test.retryAfter)*1000 {
				t.Fatalf("structured snapshot = %#v", structured)
			}
			details := structured.GetKubernetesStatus()
			if details.GetName() != "settings" || details.GetGroup() != "apps" ||
				details.GetKind() != "Deployment" || len(details.GetCauses()) != 1 ||
				details.GetCauses()[0].GetReason() != "FieldValueForbidden" ||
				details.GetCauses()[0].GetField() != "spec.replicas" {
				t.Fatalf("safe snapshot details = %#v", details)
			}
			if encoded := structured.String(); strings.Contains(encoded, rawStatusMessage) ||
				strings.Contains(encoded, rawCauseMessage) {
				t.Fatal("structured snapshot retained raw Kubernetes messages")
			}
		})
	}
}

type aggregateHiddenPayloadError struct {
	message string
	payload []byte
}

func (e *aggregateHiddenPayloadError) Error() string { return e.message }

func TestManagerAggregateCancellationCancelsWholeCounterOnlyOperation(t *testing.T) {
	manager := NewManager()
	t.Cleanup(manager.Close)
	started := make(chan struct{})
	operation, err := manager.StartAggregate(
		context.Background(), "aggregate-cancel", "delete", "session", 4,
		func(ctx context.Context, report AggregateReporter) error {
			if !report(
				operationTestIdentity("pod", "uid"),
				ItemUpdate{State: ItemStateRunning},
			) {
				return errors.New("aggregate running claim was rejected")
			}
			close(started)
			<-ctx.Done()
			return context.Cause(ctx)
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	<-started
	operation.Cancel()
	<-operation.Done()
	status := operation.Status()
	if status.State != StateCancelled || status.CompletedItems != 4 ||
		status.OmittedItemResults != 4 || !errors.Is(status.Err, context.Canceled) ||
		len(status.Items) != 0 {
		t.Fatalf("aggregate cancellation status = %#v", status)
	}
}

func operationTestIdentity(name, uid string) object.Identity {
	return object.Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "ns", Name: name, UID: uid,
	}
}
