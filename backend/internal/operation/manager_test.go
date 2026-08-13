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

func operationTestIdentity(name, uid string) object.Identity {
	return object.Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "ns", Name: name, UID: uid,
	}
}
