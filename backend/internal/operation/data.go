package operation

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/object"
)

// DataUpdater is satisfied by object.Reader and keeps the operation manager
// testable without exposing Secret values to status or diagnostic types.
type DataUpdater interface {
	UpdateData(context.Context, object.Identity, string, []object.DataMutation) (object.Data, error)
}

type DataOperationState uint8

const (
	DataOperationPending DataOperationState = iota + 1
	DataOperationRunning
	DataOperationSucceeded
	DataOperationFailed
	DataOperationCancelled
)

type DataOperationStatus struct {
	OperationID string
	Identity    object.Identity
	State       DataOperationState
	StartedAt   time.Time
	FinishedAt  time.Time
	Err         error
}

// DataOperation deliberately contains no values, hashes, or mutation payloads.
// It is safe to report through redacted diagnostics and operation progress.
type DataOperation struct {
	mu     sync.RWMutex
	status DataOperationStatus
	done   chan struct{}
	cancel context.CancelFunc
}

func (o *DataOperation) Status() DataOperationStatus {
	o.mu.RLock()
	defer o.mu.RUnlock()
	return o.status
}

func (o *DataOperation) Done() <-chan struct{} { return o.done }
func (o *DataOperation) Cancel()               { o.cancel() }

type DataOperationManager struct {
	mu         sync.Mutex
	updater    DataUpdater
	operations map[string]*DataOperation
}

func NewDataOperationManager(updater DataUpdater) (*DataOperationManager, error) {
	if updater == nil {
		return nil, errors.New("data updater must not be nil")
	}
	return &DataOperationManager{updater: updater, operations: make(map[string]*DataOperation)}, nil
}

func (m *DataOperationManager) Start(
	parent context.Context,
	operationID string,
	identity object.Identity,
	expectedResourceVersion string,
	mutations []object.DataMutation,
) (*DataOperation, error) {
	if operationID == "" {
		return nil, errors.New("operation ID must not be empty")
	}
	if err := identity.Validate(); err != nil {
		return nil, err
	}
	if len(mutations) == 0 {
		return nil, errors.New("data operation has no mutations")
	}
	ctx, cancel := context.WithCancel(parent)
	operation := &DataOperation{
		status: DataOperationStatus{
			OperationID: operationID, Identity: identity, State: DataOperationPending,
		},
		done: make(chan struct{}), cancel: cancel,
	}
	m.mu.Lock()
	if _, duplicate := m.operations[operationID]; duplicate {
		m.mu.Unlock()
		cancel()
		return nil, fmt.Errorf("operation ID %q already exists", operationID)
	}
	m.operations[operationID] = operation
	m.mu.Unlock()

	// Copy every sensitive byte slice so the caller may release its request as
	// soon as Start returns without racing the background operation.
	mutations = cloneDataMutations(mutations)
	go m.run(ctx, operation, expectedResourceVersion, mutations)
	return operation, nil
}

func (m *DataOperationManager) Get(operationID string) (*DataOperation, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	operation, ok := m.operations[operationID]
	return operation, ok
}

func (m *DataOperationManager) run(
	ctx context.Context,
	operation *DataOperation,
	expectedResourceVersion string,
	mutations []object.DataMutation,
) {
	defer close(operation.done)
	operation.mu.Lock()
	operation.status.State = DataOperationRunning
	operation.status.StartedAt = time.Now()
	identity := operation.status.Identity
	operation.mu.Unlock()

	_, err := m.updater.UpdateData(ctx, identity, expectedResourceVersion, mutations)
	// Release our copies promptly. This is best-effort buffer hygiene, not a
	// claim of guaranteed zeroization under Swift/Go runtime copies.
	for index := range mutations {
		clear(mutations[index].Value)
		clear(mutations[index].ExpectedContentHash)
	}
	operation.mu.Lock()
	defer operation.mu.Unlock()
	operation.status.FinishedAt = time.Now()
	operation.status.Err = err
	switch {
	case errors.Is(err, context.Canceled):
		operation.status.State = DataOperationCancelled
	case err != nil:
		operation.status.State = DataOperationFailed
	default:
		operation.status.State = DataOperationSucceeded
	}
}

func cloneDataMutations(values []object.DataMutation) []object.DataMutation {
	result := make([]object.DataMutation, len(values))
	for index, value := range values {
		result[index] = value
		result[index].Value = append([]byte(nil), value.Value...)
		result[index].ExpectedContentHash = append([]byte(nil), value.ExpectedContentHash...)
	}
	return result
}
