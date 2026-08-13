package operation

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/object"
)

func TestDataOperationReportsProgressWithoutSecretPayload(t *testing.T) {
	t.Parallel()
	updater := &recordingUpdater{result: object.Data{Secret: true}}
	manager, err := NewDataOperationManager(updater)
	if err != nil {
		t.Fatal(err)
	}
	identity := object.Identity{
		SessionID: "session", Version: "v1", Resource: "secrets",
		Namespace: "ns", Name: "secret", UID: "uid",
	}
	operation, err := manager.Start(context.Background(), "operation", identity, "rv-1", []object.DataMutation{{
		Type: object.MutationSet, Key: "token", Kind: object.DataText, Value: []byte("never-log-this"),
	}})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-operation.Done():
	case <-time.After(time.Second):
		t.Fatal("operation did not finish")
	}
	status := operation.Status()
	if status.State != DataOperationSucceeded || status.Err != nil {
		t.Fatalf("status = %#v", status)
	}
	if strings.Contains(strings.ToLower(status.Identity.Name+status.OperationID), "never-log-this") {
		t.Fatal("operation status retained secret value")
	}
}

func TestDataOperationCancellation(t *testing.T) {
	t.Parallel()
	updater := &recordingUpdater{wait: true}
	manager, err := NewDataOperationManager(updater)
	if err != nil {
		t.Fatal(err)
	}
	operation, err := manager.Start(context.Background(), "cancel", object.Identity{
		SessionID: "session", Version: "v1", Resource: "configmaps",
		Namespace: "ns", Name: "config", UID: "uid",
	}, "rv", []object.DataMutation{{Type: object.MutationDelete, Key: "old"}})
	if err != nil {
		t.Fatal(err)
	}
	operation.Cancel()
	select {
	case <-operation.Done():
	case <-time.After(time.Second):
		t.Fatal("cancelled operation did not finish")
	}
	if operation.Status().State != DataOperationCancelled {
		t.Fatalf("state = %v", operation.Status().State)
	}
}

type recordingUpdater struct {
	result object.Data
	err    error
	wait   bool
}

func (u *recordingUpdater) UpdateData(
	ctx context.Context,
	_ object.Identity,
	_ string,
	_ []object.DataMutation,
) (object.Data, error) {
	if u.wait {
		<-ctx.Done()
		return object.Data{}, ctx.Err()
	}
	return u.result, u.err
}
