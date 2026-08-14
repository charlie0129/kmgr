package logs

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
)

const (
	DefaultMaxStreams          = 256
	DefaultMaxSourcesPerStream = 128
	DefaultQueueRecords        = 4096
	DefaultQueueBytes          = 8 << 20
	DefaultMaxRecordBytes      = 256 << 10
	DefaultBatchRecords        = 128
	DefaultBatchBytes          = 512 << 10
	DefaultGenerationHistory   = 1024
)

type Config struct {
	Resolver            Resolver
	MaxStreams          int
	MaxSourcesPerStream int
	QueueRecords        int
	QueueBytes          int
	MaxRecordBytes      int
	BatchRecords        int
	BatchBytes          int
	GenerationHistory   int
}

type streamKey struct {
	sessionID string
	streamID  string
}

type generationEntry struct {
	key        streamKey
	generation uint64
}

// retainedLogSession shares one independently acquired cluster-session lease
// across overlapping generations of the same logical log window. refs is
// protected by Manager.mu. The underlying release is invoked once after every
// producer and subscription using the session has finished.
type retainedLogSession struct {
	contextName string
	opener      SourceOpener
	release     func()
	releaseOnce sync.Once
	refs        int
}

func (s *retainedLogSession) releaseUnderlying() {
	if s == nil {
		return
	}
	s.releaseOnce.Do(func() {
		if s.release != nil {
			s.release()
		}
	})
}

type operation struct {
	key                streamKey
	generation         uint64
	context            context.Context
	cancel             context.CancelFunc
	done               <-chan struct{}
	queue              *recordQueue
	session            *retainedLogSession
	sessionReleased    bool
	producerDone       bool
	subscriptionClosed bool
}

type Manager struct {
	mu         sync.Mutex
	config     Config
	streams    map[streamKey]*operation
	operations map[*operation]struct{}
	latest     map[streamKey]uint64
	history    []generationEntry
	closed     bool
}

func NewManager(config Config) (*Manager, error) {
	if config.Resolver == nil {
		return nil, errors.New("log session resolver must not be nil")
	}
	applyConfigDefaults(&config)
	if config.MaxStreams <= 0 || config.MaxSourcesPerStream <= 0 || config.QueueRecords <= 0 ||
		config.QueueBytes <= 0 || config.MaxRecordBytes <= 0 || config.BatchRecords <= 0 ||
		config.BatchBytes <= 0 || config.GenerationHistory <= 0 {
		return nil, errors.New("log stream limits must be positive")
	}
	config.MaxRecordBytes = min(config.MaxRecordBytes, config.QueueBytes, config.BatchBytes)
	return &Manager{
		config: config, streams: make(map[streamKey]*operation), operations: make(map[*operation]struct{}),
		latest: make(map[streamKey]uint64),
	}, nil
}

func applyConfigDefaults(config *Config) {
	if config.MaxStreams == 0 {
		config.MaxStreams = DefaultMaxStreams
	}
	if config.MaxSourcesPerStream == 0 {
		config.MaxSourcesPerStream = DefaultMaxSourcesPerStream
	}
	if config.QueueRecords == 0 {
		config.QueueRecords = DefaultQueueRecords
	}
	if config.QueueBytes == 0 {
		config.QueueBytes = DefaultQueueBytes
	}
	if config.MaxRecordBytes == 0 {
		config.MaxRecordBytes = DefaultMaxRecordBytes
	}
	if config.BatchRecords == 0 {
		config.BatchRecords = DefaultBatchRecords
	}
	if config.BatchBytes == 0 {
		config.BatchBytes = DefaultBatchBytes
	}
	if config.GenerationHistory == 0 {
		config.GenerationHistory = DefaultGenerationHistory
	}
}

func (m *Manager) Start(ctx context.Context, request StartRequest) (*Subscription, error) {
	if err := validateStart(request, m.config.MaxSourcesPerStream); err != nil {
		return nil, err
	}
	key := streamKey{sessionID: request.SessionID, streamID: request.StreamID}

	// Prefer an existing generation's retained authority. This is what lets a
	// log window change options after its originating workspace has closed:
	// SessionRegistry intentionally refuses brand-new leases at that point.
	m.mu.Lock()
	previous, err := m.checkStartLocked(key, request.Generation)
	if err != nil {
		m.mu.Unlock()
		return nil, err
	}
	if previous != nil && previous.session != nil && !previous.sessionReleased {
		previous.session.refs++
		op := m.newOperation(ctx, key, request.Generation, previous.session)
		m.installLocked(op)
		m.mu.Unlock()
		previous.cancel()
		return m.begin(op, request), nil
	}
	m.mu.Unlock()

	resolved, err := m.config.Resolver.Resolve(request.SessionID)
	if err != nil {
		return nil, err
	}
	releaseResolved := true
	defer func() {
		if releaseResolved && resolved.Release != nil {
			resolved.Release()
		}
	}()
	if resolved.Opener == nil {
		return nil, ErrLogClientUnavailable
	}
	session := &retainedLogSession{
		contextName: resolved.ContextName,
		opener:      resolved.Opener,
		release:     resolved.Release,
		refs:        1,
	}
	op := m.newOperation(ctx, key, request.Generation, session)

	// Resolve runs without Manager.mu, so revalidate against starts that may
	// have won the race while the external session acquisition was in flight.
	m.mu.Lock()
	previous, err = m.checkStartLocked(key, request.Generation)
	if err != nil {
		m.mu.Unlock()
		op.cancel()
		return nil, err
	}
	m.installLocked(op)
	m.mu.Unlock()
	if previous != nil {
		previous.cancel()
	}
	releaseResolved = false
	return m.begin(op, request), nil
}

func (m *Manager) checkStartLocked(key streamKey, generation uint64) (*operation, error) {
	if m.closed {
		return nil, ErrStreamClosed
	}
	if latest := m.latest[key]; generation <= latest {
		return nil, fmt.Errorf("%w: generation %d is not newer than %d", ErrStaleGeneration, generation, latest)
	}
	previous := m.streams[key]
	if previous == nil && len(m.streams) >= m.config.MaxStreams {
		return nil, ErrTooManyStreams
	}
	// A replacement briefly overlaps the generation it cancels. Bound even a
	// client that repeatedly replaces faster than old RPCs can unwind.
	if len(m.operations) >= 2*m.config.MaxStreams {
		return nil, ErrTooManyStreams
	}
	return previous, nil
}

func (m *Manager) newOperation(
	ctx context.Context,
	key streamKey,
	generation uint64,
	session *retainedLogSession,
) *operation {
	streamContext, cancel := context.WithCancel(ctx)
	return &operation{
		key: key, generation: generation, context: streamContext, cancel: cancel,
		done: streamContext.Done(), session: session,
		queue: newRecordQueue(queueConfig{
			maxRecords: m.config.QueueRecords, maxBytes: m.config.QueueBytes,
			maxRecordBytes: m.config.MaxRecordBytes,
			batchRecords:   m.config.BatchRecords, batchBytes: m.config.BatchBytes,
		}),
	}
}

func (m *Manager) installLocked(op *operation) {
	m.streams[op.key] = op
	m.operations[op] = struct{}{}
	m.latest[op.key] = op.generation
	m.history = append(m.history, generationEntry{key: op.key, generation: op.generation})
	m.trimHistoryLocked()
}

func (m *Manager) begin(op *operation, request StartRequest) *Subscription {
	op.queue.setStatus(Status{State: StateConnecting})
	go m.run(op.context, op, op.session.opener, request)
	return &Subscription{manager: m, operation: op}
}

func (m *Manager) run(ctx context.Context, op *operation, opener SourceOpener, request StartRequest) {
	var wait sync.WaitGroup
	var failures atomic.Int32
	wait.Add(len(request.Sources))
	for index := range request.Sources {
		source := request.Sources[index]
		go func() {
			defer wait.Done()
			if m.runSource(ctx, op.queue, opener, source, request.Options) {
				failures.Add(1)
			}
		}()
	}
	wait.Wait()

	status := Status{State: StateCompleted}
	discard := false
	if ctx.Err() != nil {
		status.State = StateCancelled
		discard = true
	} else if failures.Load() > 0 {
		status.State = StateFailed
	}
	op.queue.finish(status, discard)
	m.detach(op)
}

// runSource returns true only for a source failure, not normal cancellation.
func (m *Manager) runSource(
	ctx context.Context,
	queue *recordQueue,
	opener SourceOpener,
	source Source,
	options Options,
) bool {
	copySource := source
	queue.setStatus(Status{State: StateConnecting, SourceID: source.ID, Source: &copySource})
	reader, err := opener.Open(ctx, source, options.podLogOptions(source.Container))
	if err != nil {
		if ctx.Err() != nil {
			queue.setStatus(Status{State: StateCancelled, SourceID: source.ID, Source: &copySource})
			return false
		}
		queue.setStatus(Status{State: StateFailed, SourceID: source.ID, Source: &copySource, Err: err})
		return true
	}
	queue.setStatus(Status{State: StateStreaming, SourceID: source.ID, Source: &copySource})
	queue.setStatus(Status{State: StateStreaming})
	err = readRecords(ctx, reader, source.ID, options.Timestamps, m.config.MaxRecordBytes, queue.enqueue)
	if ctx.Err() != nil {
		queue.setStatus(Status{State: StateCancelled, SourceID: source.ID, Source: &copySource})
		return false
	}
	if err != nil {
		queue.setStatus(Status{State: StateFailed, SourceID: source.ID, Source: &copySource, Err: err})
		return true
	}
	queue.setStatus(Status{State: StateCompleted, SourceID: source.ID, Source: &copySource})
	return false
}

func (m *Manager) Cancel(sessionID, streamID string, generation uint64) bool {
	key := streamKey{sessionID: sessionID, streamID: streamID}
	m.mu.Lock()
	op := m.streams[key]
	accepted := op != nil && op.generation == generation
	m.mu.Unlock()
	if accepted {
		op.cancel()
	}
	return accepted
}

func (m *Manager) detach(op *operation) {
	var release *retainedLogSession
	m.mu.Lock()
	op.producerDone = true
	if op.subscriptionClosed {
		delete(m.operations, op)
		if m.streams[op.key] == op {
			delete(m.streams, op.key)
		}
		release = m.releaseSessionRefLocked(op)
	}
	m.trimHistoryLocked()
	m.mu.Unlock()
	release.releaseUnderlying()
}

func (m *Manager) releaseSessionRefLocked(op *operation) *retainedLogSession {
	if op == nil || op.session == nil || op.sessionReleased {
		return nil
	}
	op.sessionReleased = true
	if op.session.refs > 0 {
		op.session.refs--
	}
	if op.session.refs == 0 {
		return op.session
	}
	return nil
}

func (m *Manager) trimHistoryLocked() {
	for len(m.history) > m.config.GenerationHistory {
		removed := false
		for index, entry := range m.history {
			latest := m.latest[entry.key]
			if latest == entry.generation && m.hasOperationLocked(entry.key) {
				continue
			}
			if latest == entry.generation {
				delete(m.latest, entry.key)
			}
			m.history = append(m.history[:index], m.history[index+1:]...)
			removed = true
			break
		}
		if !removed {
			// MaxStreams bounds the temporary excess while all entries are active.
			return
		}
	}
}

func (m *Manager) hasOperationLocked(key streamKey) bool {
	for operation := range m.operations {
		if operation.key == key {
			return true
		}
	}
	return false
}

func (m *Manager) Close() {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return
	}
	m.closed = true
	operations := make([]*operation, 0, len(m.operations))
	releases := make([]*retainedLogSession, 0, len(m.operations))
	for op := range m.operations {
		operations = append(operations, op)
		op.subscriptionClosed = true
		if op.producerDone {
			delete(m.operations, op)
			if release := m.releaseSessionRefLocked(op); release != nil {
				releases = append(releases, release)
			}
		}
	}
	clear(m.streams)
	m.trimHistoryLocked()
	m.mu.Unlock()
	for _, op := range operations {
		op.cancel()
	}
	for _, release := range releases {
		release.releaseUnderlying()
	}
}

func (m *Manager) Active() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.operations)
}

func (m *Manager) release(op *operation) {
	var release *retainedLogSession
	m.mu.Lock()
	if op.subscriptionClosed {
		m.mu.Unlock()
		return
	}
	op.subscriptionClosed = true
	if op.producerDone {
		delete(m.operations, op)
		release = m.releaseSessionRefLocked(op)
		if m.streams[op.key] == op {
			delete(m.streams, op.key)
		}
	}
	m.trimHistoryLocked()
	m.mu.Unlock()
	release.releaseUnderlying()
}

type Subscription struct {
	manager   *Manager
	operation *operation
	closeOnce sync.Once
}

func (s *Subscription) Next(ctx context.Context) (Delivery, error) {
	if s == nil || s.operation == nil {
		return Delivery{}, ErrStreamClosed
	}
	return s.operation.queue.next(ctx)
}

func (s *Subscription) Stats() QueueStats {
	if s == nil || s.operation == nil {
		return QueueStats{}
	}
	return s.operation.queue.stats()
}

func (s *Subscription) ContextName() string {
	if s == nil || s.operation == nil || s.operation.session == nil {
		return ""
	}
	return s.operation.session.contextName
}

// Done closes when the subscription is cancelled, replaced by a newer
// generation, or its parent request context ends. Producer completion alone
// deliberately does not close it: a completed log window may still restart
// with different options using the retained cluster-session lease.
func (s *Subscription) Done() <-chan struct{} {
	if s == nil || s.operation == nil || s.operation.done == nil {
		done := make(chan struct{})
		close(done)
		return done
	}
	return s.operation.done
}

func (s *Subscription) Close() {
	if s == nil || s.operation == nil {
		return
	}
	s.closeOnce.Do(func() {
		s.operation.cancel()
		s.manager.release(s.operation)
	})
}
