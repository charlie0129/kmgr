package operation

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/object"
)

type State uint8

const (
	StatePending State = iota + 1
	StateRunning
	StateSucceeded
	StatePartiallySucceeded
	StateFailed
	StateCancelled
)

type ItemState uint8

const (
	ItemStatePending ItemState = iota + 1
	ItemStateRunning
	ItemStateSucceeded
	ItemStateFailed
	ItemStateSkipped
	ItemStateCancelled
)

type ItemStatus struct {
	Identity           object.Identity
	State              ItemState
	NewResourceVersion string
	Err                error
}

type Status struct {
	OperationID    string
	Operation      string
	SessionID      string
	ContextName    string
	Identity       object.Identity
	State          State
	CompletedItems uint32
	TotalItems     uint32
	Items          []ItemStatus
	Err            error
	Revision       uint64
}

// TrackedOperation retains only progress, identity, and safe errors. Mutation
// payloads stay on worker stacks and are released when their workers exit.
type TrackedOperation struct {
	mu             sync.RWMutex
	status         Status
	completedOrder []int
	done           chan struct{}
	changed        chan struct{}
	cancel         context.CancelFunc
}

func (o *TrackedOperation) Status() Status {
	o.mu.RLock()
	defer o.mu.RUnlock()
	return cloneStatus(o.status)
}

// Snapshot returns progress and the exact notification channel associated
// with that revision under one lock. Watchers therefore cannot miss a change
// between separately reading Status and Changed.
func (o *TrackedOperation) Snapshot() (Status, <-chan struct{}) {
	o.mu.RLock()
	defer o.mu.RUnlock()
	return cloneStatus(o.status), o.changed
}

// Progress returns a compact summary plus a bounded, ordered slice of item
// results that became terminal at or after offset. Terminal items are retained
// exactly once in completion order, so an operation watcher can reconnect and
// replay every result without cloning or serializing all items on each state
// transition.
func (o *TrackedOperation) Progress(offset, maxItems int) (Status, []ItemStatus, int, <-chan struct{}) {
	o.mu.RLock()
	defer o.mu.RUnlock()
	if offset < 0 || offset > len(o.completedOrder) {
		offset = 0
	}
	if maxItems < 1 {
		maxItems = 1
	}
	end := min(offset+maxItems, len(o.completedOrder))
	items := make([]ItemStatus, 0, end-offset)
	for _, index := range o.completedOrder[offset:end] {
		items = append(items, o.status.Items[index])
	}
	summary := o.status
	summary.Items = nil
	return summary, items, end, o.changed
}

func cloneStatus(value Status) Status {
	value.Items = append([]ItemStatus(nil), value.Items...)
	return value
}

func (o *TrackedOperation) Done() <-chan struct{} { return o.done }
func (o *TrackedOperation) Cancel()               { o.cancel() }

func (o *TrackedOperation) SetContextName(value string) {
	if value == "" {
		return
	}
	o.update(func(status *Status) bool {
		if status.ContextName == value {
			return false
		}
		status.ContextName = value
		return true
	})
}

// CancelNotStarted atomically cancels every item that has not claimed its
// running state yet. Running items keep their operation context and are
// allowed to finish; runners must treat a false running report as a rejected
// claim and skip the corresponding work.
func (o *TrackedOperation) CancelNotStarted() bool {
	accepted := false
	o.update(func(status *Status) bool {
		for index := range status.Items {
			if status.Items[index].State != ItemStatePending {
				continue
			}
			status.Items[index].State = ItemStateCancelled
			status.Items[index].Err = context.Canceled
			status.CompletedItems++
			o.completedOrder = append(o.completedOrder, index)
			accepted = true
		}
		if !accepted {
			return false
		}
		if status.CompletedItems == status.TotalItems {
			status.State = aggregateState(status.Items, nil)
			if status.State == StateFailed || status.State == StateCancelled {
				status.Err = firstOperationError(status.Items)
			}
		}
		return true
	})
	return accepted
}

func (o *TrackedOperation) update(change func(*Status) bool) bool {
	o.mu.Lock()
	if !change(&o.status) {
		o.mu.Unlock()
		return false
	}
	o.status.Revision++
	close(o.changed)
	o.changed = make(chan struct{})
	o.mu.Unlock()
	return true
}

type Runner func(context.Context) (string, error)

type ItemUpdate struct {
	State              ItemState
	NewResourceVersion string
	Err                error
}

// Reporter atomically applies an item transition. A running report returns
// false when cancellation or a deadline won before the item started; the
// runner must then skip that item's work.
type Reporter func(index int, update ItemUpdate) bool
type MultiRunner func(context.Context, Reporter) error

type Manager struct {
	mu                sync.RWMutex
	operations        map[string]*TrackedOperation
	terminalOrder     []terminalOperation
	ctx               context.Context
	cancel            context.CancelCauseFunc
	closed            bool
	maxTracked        int
	maxTerminal       int
	terminalRetention time.Duration
	now               func() time.Time
}

const (
	DefaultMaxTrackedOperations  = 512
	DefaultMaxTerminalOperations = 256
	DefaultTerminalRetention     = 15 * time.Minute
)

var (
	ErrManagerClosed = errors.New("operation manager is closed")
	ErrManagerFull   = errors.New("operation manager reached its tracked-operation limit")
)

type ManagerConfig struct {
	MaxTrackedOperations  int
	MaxTerminalOperations int
	TerminalRetention     time.Duration
}

type terminalOperation struct {
	id         string
	operation  *TrackedOperation
	finishedAt time.Time
}

func NewManager() *Manager { return NewManagerWithConfig(ManagerConfig{}) }

func NewManagerWithConfig(config ManagerConfig) *Manager {
	maxTracked := config.MaxTrackedOperations
	if maxTracked == 0 {
		maxTracked = DefaultMaxTrackedOperations
	}
	maxTerminal := config.MaxTerminalOperations
	if maxTerminal == 0 {
		maxTerminal = DefaultMaxTerminalOperations
	}
	retention := config.TerminalRetention
	if retention == 0 {
		retention = DefaultTerminalRetention
	}
	ctx, cancel := context.WithCancelCause(context.Background())
	return &Manager{
		operations: make(map[string]*TrackedOperation), ctx: ctx, cancel: cancel,
		maxTracked: maxTracked, maxTerminal: maxTerminal, terminalRetention: retention, now: time.Now,
	}
}

func (m *Manager) StartOne(
	parent context.Context,
	operationID string,
	operationName string,
	identity object.Identity,
	run Runner,
) (*TrackedOperation, error) {
	if run == nil {
		return nil, errors.New("operation runner must not be nil")
	}
	return m.StartMany(parent, operationID, operationName, []object.Identity{identity}, func(ctx context.Context, report Reporter) error {
		if !report(0, ItemUpdate{State: ItemStateRunning}) {
			return nil
		}
		resourceVersion, err := run(ctx)
		state := ItemStateSucceeded
		switch {
		case context.Cause(ctx) != nil:
			state = ItemStateCancelled
		case err != nil:
			state = ItemStateFailed
		}
		report(0, ItemUpdate{State: state, NewResourceVersion: resourceVersion, Err: err})
		return nil
	})
}

func (m *Manager) StartMany(
	parent context.Context,
	operationID string,
	operationName string,
	identities []object.Identity,
	run MultiRunner,
) (*TrackedOperation, error) {
	if parent == nil {
		return nil, errors.New("operation parent context must not be nil")
	}
	if operationID == "" {
		return nil, errors.New("operation ID must not be empty")
	}
	if operationName == "" {
		return nil, errors.New("operation name must not be empty")
	}
	if len(identities) == 0 {
		return nil, errors.New("operation must contain at least one item")
	}
	if run == nil {
		return nil, errors.New("operation runner must not be nil")
	}
	items := make([]ItemStatus, len(identities))
	for index, identity := range identities {
		if err := identity.Validate(); err != nil {
			return nil, fmt.Errorf("operation item %d: %w", index, err)
		}
		if index > 0 && identity.SessionID != identities[0].SessionID {
			return nil, errors.New("operation items belong to different cluster sessions")
		}
		items[index] = ItemStatus{Identity: identity, State: ItemStatePending}
	}

	// Keep the caller as the direct parent so its exact Deadline remains
	// visible to Kubernetes. Manager shutdown is the second cancellation
	// source and is bridged with its original cause.
	operationParent, releaseParent := context.WithCancelCause(parent)
	stopManager := context.AfterFunc(m.ctx, func() {
		releaseParent(context.Cause(m.ctx))
	})
	ctx, cancel := context.WithCancel(operationParent)
	operation := &TrackedOperation{
		status: Status{
			OperationID: operationID, Operation: operationName, SessionID: identities[0].SessionID,
			Identity: identities[0], State: StatePending, TotalItems: uint32(len(items)),
			Items: items, Revision: 1,
		},
		done: make(chan struct{}), changed: make(chan struct{}), cancel: cancel,
	}
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		stopManager()
		releaseParent(context.Canceled)
		cancel()
		return nil, ErrManagerClosed
	}
	m.evictTerminalLocked(m.now())
	if _, duplicate := m.operations[operationID]; duplicate {
		m.mu.Unlock()
		stopManager()
		releaseParent(context.Canceled)
		cancel()
		return nil, fmt.Errorf("operation ID %q already exists", operationID)
	}
	m.evictForCapacityLocked()
	if m.maxTracked >= 0 && len(m.operations) >= m.maxTracked {
		m.mu.Unlock()
		stopManager()
		releaseParent(context.Canceled)
		cancel()
		return nil, ErrManagerFull
	}
	m.operations[operationID] = operation
	m.mu.Unlock()

	go func() {
		defer func() {
			stopManager()
			releaseParent(context.Canceled)
			cancel()
			m.recordTerminal(operationID, operation)
			close(operation.done)
		}()
		operation.update(func(status *Status) bool {
			if status.State != StatePending || status.CompletedItems == status.TotalItems {
				return false
			}
			status.State = StateRunning
			return true
		})
		report := func(index int, update ItemUpdate) bool {
			if index < 0 || index >= len(items) || update.State == 0 {
				return false
			}
			return operation.update(func(status *Status) bool {
				current := status.Items[index].State
				if update.State == ItemStateRunning && context.Cause(ctx) != nil {
					return false
				}
				if itemTerminal(current) || !validItemTransition(current, update.State) {
					return false
				}
				status.Items[index].State = update.State
				status.Items[index].NewResourceVersion = update.NewResourceVersion
				status.Items[index].Err = update.Err
				if itemTerminal(update.State) {
					status.CompletedItems++
					operation.completedOrder = append(operation.completedOrder, index)
				}
				return true
			})
		}
		runnerErr := run(ctx, report)
		operation.update(func(status *Status) bool {
			cause := context.Cause(ctx)
			for index := range status.Items {
				if itemTerminal(status.Items[index].State) {
					continue
				}
				switch {
				case cause != nil:
					status.Items[index].State = ItemStateCancelled
					status.Items[index].Err = cause
				case runnerErr != nil:
					status.Items[index].State = ItemStateFailed
					status.Items[index].Err = runnerErr
				default:
					status.Items[index].State = ItemStateFailed
					status.Items[index].Err = errors.New("operation worker exited without reporting a result")
				}
				status.CompletedItems++
				operation.completedOrder = append(operation.completedOrder, index)
			}
			status.State = aggregateState(status.Items, cause)
			if status.State == StateFailed || status.State == StateCancelled {
				status.Err = firstOperationError(status.Items, runnerErr, cause)
			}
			return true
		})
	}()
	return operation, nil
}

func validItemTransition(current, next ItemState) bool {
	switch current {
	case ItemStatePending:
		return next == ItemStateRunning || itemTerminal(next)
	case ItemStateRunning:
		return itemTerminal(next)
	default:
		return false
	}
}

func itemTerminal(value ItemState) bool {
	return value == ItemStateSucceeded || value == ItemStateFailed || value == ItemStateSkipped || value == ItemStateCancelled
}

func aggregateState(items []ItemStatus, cause error) State {
	var succeeded, failed, cancelled uint32
	for _, item := range items {
		switch item.State {
		case ItemStateSucceeded:
			succeeded++
		case ItemStateFailed:
			failed++
		case ItemStateSkipped, ItemStateCancelled:
			cancelled++
		}
	}
	if succeeded == uint32(len(items)) {
		return StateSucceeded
	}
	if succeeded > 0 {
		return StatePartiallySucceeded
	}
	if failed > 0 {
		return StateFailed
	}
	if cancelled == uint32(len(items)) || cause != nil {
		return StateCancelled
	}
	return StateFailed
}

func firstOperationError(items []ItemStatus, values ...error) error {
	for _, value := range values {
		if value != nil {
			return value
		}
	}
	for _, item := range items {
		if item.Err != nil {
			return item.Err
		}
	}
	return nil
}

func (m *Manager) Get(operationID string) (*TrackedOperation, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.evictTerminalLocked(m.now())
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

// Close cancels every in-flight mutation and waits until each worker has
// released its request payload and published a terminal state.
func (m *Manager) Close() {
	_ = m.CloseContext(context.Background())
}

// RequestClose rejects new mutations and cancels every in-flight mutation
// without waiting for workers to return.
func (m *Manager) RequestClose() {
	m.mu.Lock()
	m.requestCloseLocked()
	m.mu.Unlock()
}

// CloseContext cancels every in-flight mutation and waits until each worker
// has released its request payload and published a terminal state, or until
// ctx ends. A worker that ignores cancellation remains owned by its existing
// goroutine; no detached waiter is created for a bounded shutdown.
func (m *Manager) CloseContext(ctx context.Context) error {
	if ctx == nil {
		return errors.New("operation manager close context must not be nil")
	}
	m.mu.Lock()
	m.requestCloseLocked()
	operations := make([]*TrackedOperation, 0, len(m.operations))
	for _, operation := range m.operations {
		operations = append(operations, operation)
	}
	m.mu.Unlock()
	for _, operation := range operations {
		if err := waitForOperationShutdown(ctx, operation.Done()); err != nil {
			return err
		}
	}
	return nil
}

func waitForOperationShutdown(ctx context.Context, done <-chan struct{}) error {
	select {
	case <-done:
		return nil
	default:
	}
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		// Prefer a concurrently published terminal state over reporting a
		// timeout after the requested cleanup actually completed.
		select {
		case <-done:
			return nil
		default:
			return context.Cause(ctx)
		}
	}
}

func (m *Manager) requestCloseLocked() {
	if m.closed {
		return
	}
	m.closed = true
	m.cancel(ErrManagerClosed)
}

func (m *Manager) recordTerminal(operationID string, operation *TrackedOperation) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if current, found := m.operations[operationID]; !found || current != operation {
		return
	}
	m.terminalOrder = append(m.terminalOrder, terminalOperation{
		id: operationID, operation: operation, finishedAt: m.now(),
	})
	m.evictTerminalLocked(m.now())
}

func (m *Manager) evictTerminalLocked(now time.Time) {
	for len(m.terminalOrder) > 0 {
		oldest := m.terminalOrder[0]
		overCount := m.maxTerminal >= 0 && len(m.terminalOrder) > m.maxTerminal
		expired := m.terminalRetention >= 0 && !now.Before(oldest.finishedAt.Add(m.terminalRetention))
		if !overCount && !expired {
			break
		}
		if current, found := m.operations[oldest.id]; found && current == oldest.operation {
			delete(m.operations, oldest.id)
		}
		m.terminalOrder[0] = terminalOperation{}
		m.terminalOrder = m.terminalOrder[1:]
	}
}

func (m *Manager) evictForCapacityLocked() {
	for m.maxTracked >= 0 && len(m.operations) >= m.maxTracked && len(m.terminalOrder) > 0 {
		oldest := m.terminalOrder[0]
		if current, found := m.operations[oldest.id]; found && current == oldest.operation {
			delete(m.operations, oldest.id)
		}
		m.terminalOrder[0] = terminalOperation{}
		m.terminalOrder = m.terminalOrder[1:]
	}
}
