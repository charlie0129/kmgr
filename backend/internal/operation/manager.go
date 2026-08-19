package operation

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/charlie0129/kmgr/backend/internal/object"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
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
	OperationID         string
	Operation           string
	SessionID           string
	ContextName         string
	Identity            object.Identity
	State               State
	CompletedItems      uint32
	TotalItems          uint32
	Items               []ItemStatus
	AggregateOnly       bool
	RetainedItemResults uint32
	OmittedItemResults  uint32
	Err                 error
	Revision            uint64

	// Aggregate-only counters never leave the engine. They replace the dense
	// one-status-per-identity array for token-backed operations.
	succeededItems    uint32
	failedItems       uint32
	cancelledItems    uint32
	retainedItemBytes int
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
	if o.status.AggregateOnly {
		if offset < 0 || offset > len(o.status.Items) {
			offset = 0
		}
		if maxItems < 1 {
			maxItems = 1
		}
		end := min(offset+maxItems, len(o.status.Items))
		items := append([]ItemStatus(nil), o.status.Items[offset:end]...)
		summary := o.status
		summary.Items = nil
		return summary, items, end, o.changed
	}
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
		if status.AggregateOnly {
			// Aggregate operations deliberately do not retain the queue/running
			// state of every identity. Exact pending-only cancellation is therefore
			// unavailable; callers may still request ordinary operation cancellation.
			return false
		}
		for index := range status.Items {
			if status.Items[index].State != ItemStatePending {
				continue
			}
			status.Items[index].State = ItemStateCancelled
			status.Items[index].Err = context.Canceled
			status.CompletedItems++
			status.RetainedItemResults++
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

// AggregateReporter atomically claims work and reports terminal results
// without assigning a dense manager index to every identity. Running reports
// are claims only; terminal failures/cancellations may be retained as bounded
// detail deltas, while successful identities are represented by counters.
type AggregateReporter func(identity object.Identity, update ItemUpdate) bool
type AggregateRunner func(context.Context, AggregateReporter) error

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
	DefaultMaxTrackedOperations   = 512
	DefaultMaxTerminalOperations  = 256
	DefaultTerminalRetention      = 15 * time.Minute
	DefaultMaxAggregateResults    = 256
	DefaultMaxAggregateBytes      = 1 << 20
	maxAggregateErrorTextBytes    = 16 << 10
	aggregateItemSlotBytes        = 256
	aggregateTextErrorBytes       = 64
	aggregateAPIStatusFixedBytes  = 1 << 10
	aggregateAPIStatusCauseBytes  = 128
	maxAggregateAPIStatusCauses   = 64
	maxAggregateStatusReasonBytes = 256
	maxAggregateStatusDetailBytes = 2 << 10
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

	operation, ctx, finish, err := m.register(parent, Status{
		OperationID: operationID, Operation: operationName, SessionID: identities[0].SessionID,
		Identity: identities[0], State: StatePending, TotalItems: uint32(len(items)),
		Items: items, Revision: 1,
	})
	if err != nil {
		return nil, err
	}

	go func() {
		defer finish()
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
					status.RetainedItemResults++
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
				status.RetainedItemResults++
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

// StartAggregate tracks high-cardinality work by counters plus a bounded set
// of useful non-success details. It never allocates one manager slot per item.
func (m *Manager) StartAggregate(
	parent context.Context,
	operationID string,
	operationName string,
	sessionID string,
	totalItems uint32,
	run AggregateRunner,
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
	if sessionID == "" {
		return nil, errors.New("operation session ID must not be empty")
	}
	if totalItems == 0 {
		return nil, errors.New("operation must contain at least one item")
	}
	if run == nil {
		return nil, errors.New("aggregate operation runner must not be nil")
	}

	operation, ctx, finish, err := m.register(parent, Status{
		OperationID: operationID, Operation: operationName, SessionID: sessionID,
		State: StatePending, TotalItems: totalItems, AggregateOnly: true, Revision: 1,
	})
	if err != nil {
		return nil, err
	}

	go func() {
		defer finish()
		operation.update(func(status *Status) bool {
			if status.State != StatePending {
				return false
			}
			status.State = StateRunning
			return true
		})
		report := func(identity object.Identity, update ItemUpdate) bool {
			if update.State == ItemStateRunning {
				return context.Cause(ctx) == nil
			}
			if !itemTerminal(update.State) || identity.Validate() != nil {
				return false
			}
			return operation.update(func(status *Status) bool {
				if status.CompletedItems >= status.TotalItems {
					return false
				}
				status.CompletedItems++
				switch update.State {
				case ItemStateSucceeded:
					status.succeededItems++
				case ItemStateFailed:
					status.failedItems++
				case ItemStateSkipped, ItemStateCancelled:
					status.cancelledItems++
				}
				if update.State != ItemStateSucceeded {
					item := ItemStatus{
						Identity: identity, State: update.State,
						NewResourceVersion: update.NewResourceVersion,
					}
					newCapacity, capacityBytes := aggregateItemCapacityGrowth(status.Items)
					remainingBytes := DefaultMaxAggregateBytes - status.retainedItemBytes
					minimumItemBytes := capacityBytes + retainedAggregateItemDynamicBytes(item)
					if len(status.Items) < DefaultMaxAggregateResults &&
						minimumItemBytes <= remainingBytes {
						item.Err = snapshotAggregateError(update.Err)
						itemBytes := capacityBytes + retainedAggregateItemDynamicBytes(item)
						if itemBytes > remainingBytes {
							status.OmittedItemResults++
							return true
						}
						if newCapacity > cap(status.Items) {
							resized := make([]ItemStatus, len(status.Items), newCapacity)
							copy(resized, status.Items)
							status.Items = resized
						}
						status.Items = append(status.Items, item)
						status.retainedItemBytes += itemBytes
						status.RetainedItemResults++
					} else {
						status.OmittedItemResults++
					}
				}
				return true
			})
		}
		runnerErr := run(ctx, report)
		runnerErrSnapshot := snapshotAggregateError(runnerErr)
		operation.update(func(status *Status) bool {
			cause := context.Cause(ctx)
			causeSnapshot := snapshotAggregateError(cause)
			remaining := status.TotalItems - status.CompletedItems
			if remaining > 0 {
				status.CompletedItems += remaining
				status.OmittedItemResults += remaining
				if cause != nil {
					status.cancelledItems += remaining
				} else {
					status.failedItems += remaining
				}
			}
			status.State = aggregateCounterState(status, cause)
			if status.State != StateSucceeded {
				status.Err = firstOperationError(
					status.Items, runnerErrSnapshot, causeSnapshot,
				)
				if status.Err == nil {
					status.Err = errors.New("one or more operation items did not succeed")
				}
			}
			return true
		})
	}()
	return operation, nil
}

// register installs common operation lifetime and capacity ownership. The
// returned finish function must run exactly once from the operation goroutine.
func (m *Manager) register(
	parent context.Context,
	initial Status,
) (*TrackedOperation, context.Context, func(), error) {
	// Keep the caller as the direct parent so its exact Deadline remains
	// visible to Kubernetes. Manager shutdown is the second cancellation
	// source and is bridged with its original cause.
	operationParent, releaseParent := context.WithCancelCause(parent)
	stopManager := context.AfterFunc(m.ctx, func() {
		releaseParent(context.Cause(m.ctx))
	})
	ctx, cancel := context.WithCancel(operationParent)
	operation := &TrackedOperation{
		status: initial, done: make(chan struct{}), changed: make(chan struct{}), cancel: cancel,
	}
	reject := func(err error) (*TrackedOperation, context.Context, func(), error) {
		stopManager()
		releaseParent(context.Canceled)
		cancel()
		return nil, nil, nil, err
	}
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return reject(ErrManagerClosed)
	}
	m.evictTerminalLocked(m.now())
	if _, duplicate := m.operations[initial.OperationID]; duplicate {
		m.mu.Unlock()
		return reject(fmt.Errorf("operation ID %q already exists", initial.OperationID))
	}
	m.evictForCapacityLocked()
	if m.maxTracked >= 0 && len(m.operations) >= m.maxTracked {
		m.mu.Unlock()
		return reject(ErrManagerFull)
	}
	m.operations[initial.OperationID] = operation
	m.mu.Unlock()
	finish := func() {
		stopManager()
		releaseParent(context.Canceled)
		cancel()
		m.recordTerminal(initial.OperationID, operation)
		close(operation.done)
	}
	return operation, ctx, finish, nil
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

func aggregateCounterState(status *Status, cause error) State {
	if status == nil || status.CompletedItems != status.TotalItems {
		return StateFailed
	}
	if status.succeededItems == status.TotalItems {
		return StateSucceeded
	}
	if status.succeededItems > 0 {
		return StatePartiallySucceeded
	}
	if status.failedItems > 0 {
		return StateFailed
	}
	if status.cancelledItems == status.TotalItems || cause != nil {
		return StateCancelled
	}
	return StateFailed
}

// aggregateItemSlotBytes is deliberately larger than ItemStatus on supported
// architectures. Explicit capacity growth plus this reservation accounts for
// the complete slice backing allocation, including unused capacity, instead
// of assuming append capacity equals the current result count.
func aggregateItemCapacityGrowth(items []ItemStatus) (int, int) {
	if len(items) < cap(items) {
		return cap(items), 0
	}
	if cap(items) >= DefaultMaxAggregateResults {
		return cap(items), 0
	}
	newCapacity := max(1, cap(items)*2)
	newCapacity = min(newCapacity, DefaultMaxAggregateResults)
	return newCapacity, (newCapacity - cap(items)) * aggregateItemSlotBytes
}

func retainedAggregateItemBytes(item ItemStatus) int {
	return aggregateItemSlotBytes + retainedAggregateItemDynamicBytes(item)
}

func retainedAggregateItemDynamicBytes(item ItemStatus) int {
	bytes := len(item.Identity.SessionID) + len(item.Identity.Group) + len(item.Identity.Version) +
		len(item.Identity.Resource) + len(item.Identity.Namespace) + len(item.Identity.Name) +
		len(item.Identity.UID) + len(item.NewResourceVersion)
	if item.Err != nil {
		bytes += retainedAggregateErrorBytes(item.Err)
	}
	return bytes
}

type aggregateRetainedError interface {
	error
	aggregateRetainedBytes() int
}

type aggregateTextError struct {
	text string
}

func (e *aggregateTextError) Error() string { return e.text }

func (e *aggregateTextError) aggregateRetainedBytes() int {
	return aggregateTextErrorBytes + len(e.text)
}

type aggregateAPIStatusSnapshot struct {
	text      string
	status    metav1.Status
	textBytes int
}

var _ apierrors.APIStatus = (*aggregateAPIStatusSnapshot)(nil)

func (e *aggregateAPIStatusSnapshot) Error() string { return e.text }

func (e *aggregateAPIStatusSnapshot) Status() metav1.Status {
	result := e.status
	if e.status.Details != nil {
		details := *e.status.Details
		details.Causes = append([]metav1.StatusCause(nil), e.status.Details.Causes...)
		result.Details = &details
	}
	return result
}

func (e *aggregateAPIStatusSnapshot) aggregateRetainedBytes() int {
	causeCapacity := 0
	if e.status.Details != nil {
		causeCapacity = cap(e.status.Details.Causes)
	}
	return aggregateAPIStatusFixedBytes +
		causeCapacity*aggregateAPIStatusCauseBytes + e.textBytes
}

func retainedAggregateErrorBytes(err error) int {
	if retained, ok := err.(aggregateRetainedError); ok {
		return retained.aggregateRetainedBytes()
	}
	// Safe process-wide sentinels allocate no per-operation payload. Charging
	// one text-error header and their message is conservative and keeps this
	// helper safe if another bounded error type reaches it later.
	return aggregateTextErrorBytes + len(err.Error())
}

// snapshotAggregateError severs every reference to a concrete provider error
// before aggregate status can retain it. Kubernetes statuses preserve only
// bounded machine semantics and safe detail fields; ordinary errors become
// owned bounded text. Raw API messages, response bodies, and other hidden
// payloads never enter retained operation state.
func snapshotAggregateError(err error) error {
	if err == nil {
		return nil
	}
	switch {
	case errors.Is(err, context.Canceled):
		return context.Canceled
	case errors.Is(err, context.DeadlineExceeded):
		return context.DeadlineExceeded
	case errors.Is(err, ErrManagerClosed):
		return ErrManagerClosed
	case errors.Is(err, ErrManagerFull):
		return ErrManagerFull
	case errors.Is(err, object.ErrInvalidIdentity):
		return object.ErrInvalidIdentity
	case errors.Is(err, object.ErrInvalidYAML):
		return object.ErrInvalidYAML
	case errors.Is(err, object.ErrYAMLForceOwnershipUnsupported):
		return object.ErrYAMLForceOwnershipUnsupported
	case errors.Is(err, object.ErrUnsupportedDataObject):
		return object.ErrUnsupportedDataObject
	case errors.Is(err, object.ErrSessionNotFound):
		return object.ErrSessionNotFound
	}
	var apiStatus apierrors.APIStatus
	if errors.As(err, &apiStatus) {
		return newAggregateAPIStatusSnapshot(apiStatus.Status())
	}
	return &aggregateTextError{text: boundedAggregateErrorText(err.Error())}
}

type aggregateErrorTextBudget struct {
	remaining int
	used      int
}

func (b *aggregateErrorTextBudget) take(value string, fieldLimit int) string {
	limit := min(b.remaining, fieldLimit)
	if limit <= 0 || value == "" {
		return ""
	}
	result := boundedOwnedUTF8Text(value, limit)
	b.remaining -= len(result)
	b.used += len(result)
	return result
}

func newAggregateAPIStatusSnapshot(source metav1.Status) error {
	budget := aggregateErrorTextBudget{remaining: maxAggregateErrorTextBytes}
	result := &aggregateAPIStatusSnapshot{}
	result.text = budget.take(
		safeAggregateAPIStatusText(source.Reason, source.Code),
		maxAggregateErrorTextBytes,
	)
	result.status = metav1.Status{
		Status: metav1.StatusFailure,
		Reason: metav1.StatusReason(budget.take(
			string(source.Reason), maxAggregateStatusReasonBytes,
		)),
		Code: source.Code,
	}
	if source.Details != nil {
		sourceDetails := source.Details
		details := &metav1.StatusDetails{
			Name:  budget.take(sourceDetails.Name, maxAggregateStatusDetailBytes),
			Group: budget.take(sourceDetails.Group, maxAggregateStatusDetailBytes),
			Kind:  budget.take(sourceDetails.Kind, maxAggregateStatusDetailBytes),
			UID: types.UID(budget.take(
				string(sourceDetails.UID), maxAggregateStatusDetailBytes,
			)),
			RetryAfterSeconds: sourceDetails.RetryAfterSeconds,
		}
		causeLimit := min(len(sourceDetails.Causes), maxAggregateAPIStatusCauses)
		details.Causes = make([]metav1.StatusCause, 0, causeLimit)
		for _, sourceCause := range sourceDetails.Causes[:causeLimit] {
			cause := metav1.StatusCause{
				Type: metav1.CauseType(budget.take(
					string(sourceCause.Type), maxAggregateStatusReasonBytes,
				)),
				Field: budget.take(sourceCause.Field, maxAggregateStatusDetailBytes),
			}
			if cause.Type == "" && cause.Field == "" {
				continue
			}
			details.Causes = append(details.Causes, cause)
		}
		result.status.Details = details
	}
	result.textBytes = budget.used
	return result
}

func safeAggregateAPIStatusText(reason metav1.StatusReason, code int32) string {
	switch reason {
	case metav1.StatusReasonForbidden:
		return "Kubernetes API request was forbidden."
	case metav1.StatusReasonUnauthorized:
		return "Kubernetes API request was unauthorized."
	case metav1.StatusReasonNotFound:
		return "Kubernetes API resource was not found."
	case metav1.StatusReasonConflict:
		return "Kubernetes API resource changed concurrently."
	case metav1.StatusReasonInvalid, metav1.StatusReasonBadRequest:
		return "Kubernetes API request was invalid."
	default:
		if code > 0 {
			return fmt.Sprintf("Kubernetes API request failed with HTTP status %d.", code)
		}
		return "Kubernetes API request failed."
	}
}

func boundedAggregateErrorText(value string) string {
	return boundedOwnedUTF8Text(value, maxAggregateErrorTextBytes)
}

func boundedOwnedUTF8Text(value string, maximumBytes int) string {
	const suffix = "... [truncated]"
	if maximumBytes <= 0 || value == "" {
		return ""
	}
	truncated := len(value) > maximumBytes
	limit := len(value)
	marker := ""
	if truncated {
		limit = maximumBytes
		if maximumBytes > len(suffix) {
			marker = suffix
			limit -= len(marker)
		}
		for limit > 0 && !utf8.RuneStart(value[limit]) {
			limit--
		}
	}
	bounded := strings.ToValidUTF8(value[:limit], "\uFFFD")
	if truncated {
		bounded += marker
	}
	if len(bounded) > maximumBytes {
		marker = ""
		limit = maximumBytes
		if maximumBytes > len(suffix) {
			marker = suffix
			limit -= len(marker)
		}
		for limit > 0 && !utf8.RuneStart(bounded[limit]) {
			limit--
		}
		bounded = bounded[:limit] + marker
	}
	return strings.Clone(bounded)
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
