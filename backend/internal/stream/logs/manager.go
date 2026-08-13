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

type operation struct {
	key                streamKey
	generation         uint64
	contextName        string
	cancel             context.CancelFunc
	queue              *recordQueue
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
	resolved, err := m.config.Resolver.Resolve(request.SessionID)
	if err != nil {
		return nil, err
	}
	if resolved.Opener == nil {
		return nil, ErrLogClientUnavailable
	}

	key := streamKey{sessionID: request.SessionID, streamID: request.StreamID}
	streamContext, cancel := context.WithCancel(ctx)
	op := &operation{
		key: key, generation: request.Generation, contextName: resolved.ContextName, cancel: cancel,
		queue: newRecordQueue(queueConfig{
			maxRecords: m.config.QueueRecords, maxBytes: m.config.QueueBytes,
			maxRecordBytes: m.config.MaxRecordBytes,
			batchRecords:   m.config.BatchRecords, batchBytes: m.config.BatchBytes,
		}),
	}

	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		cancel()
		return nil, ErrStreamClosed
	}
	if latest := m.latest[key]; request.Generation <= latest {
		m.mu.Unlock()
		cancel()
		return nil, fmt.Errorf("%w: generation %d is not newer than %d", ErrStaleGeneration, request.Generation, latest)
	}
	previous := m.streams[key]
	if len(m.operations) >= m.config.MaxStreams {
		m.mu.Unlock()
		cancel()
		return nil, ErrTooManyStreams
	}
	m.streams[key] = op
	m.operations[op] = struct{}{}
	m.latest[key] = request.Generation
	m.history = append(m.history, generationEntry{key: key, generation: request.Generation})
	m.trimHistoryLocked()
	m.mu.Unlock()
	if previous != nil {
		previous.cancel()
	}

	op.queue.setStatus(Status{State: StateConnecting})
	go m.run(streamContext, op, resolved.Opener, request)
	return &Subscription{manager: m, operation: op}, nil
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
	m.mu.Lock()
	defer m.mu.Unlock()
	op.producerDone = true
	if m.streams[op.key] == op {
		delete(m.streams, op.key)
	}
	if op.subscriptionClosed {
		delete(m.operations, op)
	}
	m.trimHistoryLocked()
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
	for op := range m.operations {
		operations = append(operations, op)
	}
	m.mu.Unlock()
	for _, op := range operations {
		op.cancel()
	}
}

func (m *Manager) Active() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.operations)
}

func (m *Manager) release(op *operation) {
	m.mu.Lock()
	defer m.mu.Unlock()
	op.subscriptionClosed = true
	if op.producerDone {
		delete(m.operations, op)
	}
	if m.streams[op.key] == op {
		delete(m.streams, op.key)
	}
	m.trimHistoryLocked()
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
	if s == nil || s.operation == nil {
		return ""
	}
	return s.operation.contextName
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
