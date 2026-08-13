package operation

import (
	"context"
	"errors"
	"fmt"
	"sync"

	"github.com/charlie0129/kmgr/backend/internal/object"
)

type State uint8

const (
	StatePending State = iota + 1
	StateRunning
	StateSucceeded
	StateFailed
	StateCancelled
)

type Status struct {
	OperationID        string
	Identity           object.Identity
	State              State
	CompletedItems     uint32
	TotalItems         uint32
	NewResourceVersion string
	Err                error
}

// TrackedOperation retains only progress, identity, and safe errors. Mutation
// payloads stay on the worker stack and are released when the worker exits.
type TrackedOperation struct {
	mu      sync.RWMutex
	status  Status
	done    chan struct{}
	changed chan struct{}
	cancel  context.CancelFunc
}

func (o *TrackedOperation) Status() Status {
	o.mu.RLock()
	defer o.mu.RUnlock()
	return o.status
}

func (o *TrackedOperation) Done() <-chan struct{} { return o.done }
func (o *TrackedOperation) Cancel()               { o.cancel() }
func (o *TrackedOperation) Changed() <-chan struct{} {
	o.mu.RLock()
	defer o.mu.RUnlock()
	return o.changed
}

func (o *TrackedOperation) update(change func(*Status)) {
	o.mu.Lock()
	change(&o.status)
	close(o.changed)
	o.changed = make(chan struct{})
	o.mu.Unlock()
}

type Runner func(context.Context) (string, error)

type Manager struct {
	mu         sync.RWMutex
	operations map[string]*TrackedOperation
}

func NewManager() *Manager { return &Manager{operations: make(map[string]*TrackedOperation)} }

func (m *Manager) Start(
	parent context.Context,
	operationID string,
	identity object.Identity,
	run Runner,
) (*TrackedOperation, error) {
	if operationID == "" {
		return nil, errors.New("operation ID must not be empty")
	}
	if err := identity.Validate(); err != nil {
		return nil, err
	}
	if run == nil {
		return nil, errors.New("operation runner must not be nil")
	}
	ctx, cancel := context.WithCancel(parent)
	operation := &TrackedOperation{
		status: Status{OperationID: operationID, Identity: identity, State: StatePending, TotalItems: 1},
		done:   make(chan struct{}), changed: make(chan struct{}), cancel: cancel,
	}
	m.mu.Lock()
	if _, duplicate := m.operations[operationID]; duplicate {
		m.mu.Unlock()
		cancel()
		return nil, fmt.Errorf("operation ID %q already exists", operationID)
	}
	m.operations[operationID] = operation
	m.mu.Unlock()
	go func() {
		defer close(operation.done)
		operation.update(func(status *Status) { status.State = StateRunning })
		resourceVersion, err := run(ctx)
		operation.update(func(status *Status) {
			status.CompletedItems = 1
			status.NewResourceVersion = resourceVersion
			status.Err = err
			switch {
			case errors.Is(err, context.Canceled):
				status.State = StateCancelled
			case err != nil:
				status.State = StateFailed
			default:
				status.State = StateSucceeded
			}
		})
	}()
	return operation, nil
}

func (m *Manager) Get(operationID string) (*TrackedOperation, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	operation, found := m.operations[operationID]
	return operation, found
}

func (m *Manager) Cancel(operationID string) bool {
	operation, found := m.Get(operationID)
	if found {
		operation.Cancel()
	}
	return found
}
