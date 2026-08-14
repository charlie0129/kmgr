package operation

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/object"
)

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

func operationTestIdentity(name, uid string) object.Identity {
	return object.Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "ns", Name: name, UID: uid,
	}
}
