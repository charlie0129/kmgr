package execstream

import (
	"context"
	"errors"
	"fmt"
	"sync"

	utilexec "k8s.io/client-go/util/exec"
)

const (
	DefaultMaxSessions         = 128
	DefaultOutputItems         = 2048
	DefaultOutputBytes         = 8 << 20
	DefaultOutputChunkBytes    = 64 << 10
	DefaultInputChunks         = 256
	DefaultInputBytes          = 1 << 20
	DefaultMaxCommandArguments = 256
	DefaultMaxCommandBytes     = 64 << 10
	DefaultGenerationHistory   = 1024
)

type Config struct {
	Resolver            Resolver
	MaxSessions         int
	OutputItems         int
	OutputBytes         int
	OutputChunkBytes    int
	InputChunks         int
	InputBytes          int
	MaxCommandArguments int
	MaxCommandBytes     int
	GenerationHistory   int
}

type sessionKey struct {
	clusterSessionID string
	execSessionID    string
}

type generationEntry struct {
	key        sessionKey
	generation uint64
}

// retainedExecSession shares one independently acquired cluster-session lease
// across overlapping generations of the same logical terminal window. The
// old generation remains subscribed after its remote process exits, allowing
// a replacement to start before the originating workspace's authority is
// released.
type retainedExecSession struct {
	contextName string
	runner      Runner
	release     func()
	releaseOnce sync.Once
	refs        int
}

func (s *retainedExecSession) releaseUnderlying() {
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
	key                sessionKey
	generation         uint64
	context            context.Context
	pod                Identity
	tty                bool
	cancel             context.CancelFunc
	input              *inputPipe
	resizes            *resizeQueue
	output             *outputQueue
	session            *retainedExecSession
	sessionReleased    bool
	producerDone       bool
	subscriptionClosed bool
}

type Manager struct {
	mu         sync.Mutex
	config     Config
	current    map[sessionKey]*operation
	operations map[*operation]struct{}
	latest     map[sessionKey]uint64
	history    []generationEntry
	closed     bool
}

func NewManager(config Config) (*Manager, error) {
	if config.Resolver == nil {
		return nil, errors.New("exec session resolver must not be nil")
	}
	applyConfigDefaults(&config)
	if config.MaxSessions <= 0 || config.OutputItems <= 0 || config.OutputBytes <= 0 ||
		config.OutputChunkBytes <= 0 || config.InputChunks <= 0 || config.InputBytes <= 0 ||
		config.MaxCommandArguments <= 0 || config.MaxCommandBytes <= 0 || config.GenerationHistory <= 0 {
		return nil, errors.New("exec stream limits must be positive")
	}
	config.OutputChunkBytes = min(config.OutputChunkBytes, config.OutputBytes)
	return &Manager{
		config: config, current: make(map[sessionKey]*operation),
		operations: make(map[*operation]struct{}), latest: make(map[sessionKey]uint64),
	}, nil
}

func applyConfigDefaults(config *Config) {
	if config.MaxSessions == 0 {
		config.MaxSessions = DefaultMaxSessions
	}
	if config.OutputItems == 0 {
		config.OutputItems = DefaultOutputItems
	}
	if config.OutputBytes == 0 {
		config.OutputBytes = DefaultOutputBytes
	}
	if config.OutputChunkBytes == 0 {
		config.OutputChunkBytes = DefaultOutputChunkBytes
	}
	if config.InputChunks == 0 {
		config.InputChunks = DefaultInputChunks
	}
	if config.InputBytes == 0 {
		config.InputBytes = DefaultInputBytes
	}
	if config.MaxCommandArguments == 0 {
		config.MaxCommandArguments = DefaultMaxCommandArguments
	}
	if config.MaxCommandBytes == 0 {
		config.MaxCommandBytes = DefaultMaxCommandBytes
	}
	if config.GenerationHistory == 0 {
		config.GenerationHistory = DefaultGenerationHistory
	}
}

func (m *Manager) Start(ctx context.Context, request StartRequest) (*Session, error) {
	if err := validateStart(request, m.config.MaxCommandArguments, m.config.MaxCommandBytes); err != nil {
		return nil, err
	}
	key := sessionKey{clusterSessionID: request.SessionID, execSessionID: request.ExecSessionID}

	// Prefer the prior generation's retained authority. SessionRegistry refuses
	// brand-new independent leases after a workspace closes, while an existing
	// terminal window is explicitly allowed to reconnect to a new process.
	m.mu.Lock()
	previous, err := m.checkStartLocked(key, request.Generation)
	if err != nil {
		m.mu.Unlock()
		return nil, err
	}
	if previous != nil && previous.session != nil && !previous.sessionReleased {
		previous.session.refs++
		op := m.newOperation(ctx, key, request.Generation, previous.session, request)
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
	if resolved.Runner == nil {
		return nil, ErrExecutorUnavailable
	}
	retained := &retainedExecSession{
		contextName: resolved.ContextName,
		runner:      resolved.Runner,
		release:     resolved.Release,
		refs:        1,
	}
	op := m.newOperation(ctx, key, request.Generation, retained, request)

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

func (m *Manager) checkStartLocked(key sessionKey, generation uint64) (*operation, error) {
	if m.closed {
		return nil, ErrSessionClosed
	}
	if latest := m.latest[key]; generation <= latest {
		return nil, fmt.Errorf("%w: generation %d is not newer than %d", ErrStaleGeneration, generation, latest)
	}
	previous := m.current[key]
	if previous == nil && len(m.current) >= m.config.MaxSessions {
		return nil, ErrTooManySessions
	}
	if len(m.operations) >= 2*m.config.MaxSessions {
		return nil, ErrTooManySessions
	}
	return previous, nil
}

func (m *Manager) newOperation(
	ctx context.Context,
	key sessionKey,
	generation uint64,
	session *retainedExecSession,
	request StartRequest,
) *operation {
	execContext, cancel := context.WithCancel(ctx)
	input := newInputPipe(m.config.InputChunks, m.config.InputBytes)
	if !request.Stdin {
		input.Close()
	}
	return &operation{
		key: key, generation: generation, context: execContext, pod: request.Pod, tty: request.TTY,
		cancel: cancel, input: input, session: session,
		resizes: newResizeQueue(request.InitialSize),
		output:  newOutputQueue(m.config.OutputItems, m.config.OutputBytes, m.config.OutputChunkBytes),
	}
}

func (m *Manager) installLocked(op *operation) {
	m.current[op.key] = op
	m.operations[op] = struct{}{}
	m.latest[op.key] = op.generation
	m.history = append(m.history, generationEntry{key: op.key, generation: op.generation})
	m.trimHistoryLocked()
}

func (m *Manager) begin(op *operation, request StartRequest) *Session {
	op.output.setStatus(Status{State: StateConnecting})
	go m.run(op.context, op, op.session.runner, request)
	return &Session{manager: m, operation: op}
}

func (m *Manager) run(ctx context.Context, op *operation, runner Runner, request StartRequest) {
	stopInput := op.input.CloseOnContext(ctx)
	defer func() {
		stopInput()
		op.input.Abort(ErrSessionClosed)
		op.resizes.Close()
	}()

	var runningOnce sync.Once
	options := RunOptions{
		Stdin: op.input, Stdout: op.output.writer(StreamStdout), TTY: request.TTY,
		Resizes: op.resizes,
		Started: func() { runningOnce.Do(func() { op.output.setStatus(Status{State: StateRunning}) }) },
	}
	if !request.TTY {
		// stderr must remain nil in TTY mode because Kubernetes multiplexes it
		// through the stdout terminal stream.
		options.Stderr = op.output.writer(StreamStderr)
	}
	err := runner.Run(ctx, request, options)

	status := terminalStatus(ctx, err)
	op.output.finish(status)
	m.detach(op)
}

func terminalStatus(ctx context.Context, err error) Status {
	if ctx.Err() != nil && !errors.Is(err, ErrOutputBackpressure) {
		return Status{State: StateCancelled, StatusReason: "Cancelled"}
	}
	if err == nil {
		code := int32(0)
		return Status{State: StateExited, ExitCode: &code, StatusReason: "Completed"}
	}
	var exitError utilexec.ExitError
	if errors.As(err, &exitError) && exitError.Exited() {
		code := int32(exitError.ExitStatus())
		return Status{State: StateExited, ExitCode: &code, StatusReason: "NonZeroExit"}
	}
	if errors.Is(err, ErrOutputBackpressure) {
		return Status{State: StateFailed, StatusReason: "OutputBackpressure", Err: err}
	}
	return Status{State: StateFailed, StatusReason: "ExecFailed", Err: err}
}

func (m *Manager) Cancel(clusterSessionID, execSessionID string, generation uint64) bool {
	key := sessionKey{clusterSessionID: clusterSessionID, execSessionID: execSessionID}
	m.mu.Lock()
	op := m.current[key]
	accepted := op != nil && op.generation == generation
	m.mu.Unlock()
	if accepted {
		op.cancel()
	}
	return accepted
}

func (m *Manager) detach(op *operation) {
	var release *retainedExecSession
	m.mu.Lock()
	op.producerDone = true
	if op.subscriptionClosed {
		delete(m.operations, op)
		if m.current[op.key] == op {
			delete(m.current, op.key)
		}
		release = m.releaseSessionRefLocked(op)
	}
	m.trimHistoryLocked()
	m.mu.Unlock()
	release.releaseUnderlying()
}

func (m *Manager) release(op *operation) {
	var release *retainedExecSession
	m.mu.Lock()
	if op.subscriptionClosed {
		m.mu.Unlock()
		return
	}
	op.subscriptionClosed = true
	if op.producerDone {
		delete(m.operations, op)
		if m.current[op.key] == op {
			delete(m.current, op.key)
		}
		release = m.releaseSessionRefLocked(op)
	}
	m.trimHistoryLocked()
	m.mu.Unlock()
	release.releaseUnderlying()
}

func (m *Manager) releaseSessionRefLocked(op *operation) *retainedExecSession {
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
			if m.latest[entry.key] == entry.generation && m.hasOperationLocked(entry.key) {
				continue
			}
			if m.latest[entry.key] == entry.generation {
				delete(m.latest, entry.key)
			}
			m.history = append(m.history[:index], m.history[index+1:]...)
			removed = true
			break
		}
		if !removed {
			return
		}
	}
}

func (m *Manager) hasOperationLocked(key sessionKey) bool {
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
	releases := make([]*retainedExecSession, 0, len(m.operations))
	for operation := range m.operations {
		operations = append(operations, operation)
		operation.subscriptionClosed = true
		if operation.producerDone {
			delete(m.operations, operation)
			if release := m.releaseSessionRefLocked(operation); release != nil {
				releases = append(releases, release)
			}
		}
	}
	clear(m.current)
	m.trimHistoryLocked()
	m.mu.Unlock()
	for _, operation := range operations {
		operation.cancel()
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

type Session struct {
	manager   *Manager
	operation *operation
	closeOnce sync.Once
}

func (s *Session) SendStdin(data []byte) error {
	if s == nil || s.operation == nil {
		return ErrSessionClosed
	}
	return s.operation.input.Send(data)
}

func (s *Session) CloseStdin() {
	if s != nil && s.operation != nil {
		s.operation.input.Close()
	}
}

func (s *Session) Resize(size TerminalSize) error {
	if s == nil || s.operation == nil {
		return ErrSessionClosed
	}
	if !s.operation.tty {
		return fmt.Errorf("%w: resize requires a TTY", ErrInvalidRequest)
	}
	return s.operation.resizes.Send(size)
}

func (s *Session) Cancel() {
	if s != nil && s.operation != nil {
		s.operation.cancel()
	}
}

func (s *Session) Next(ctx context.Context) (Delivery, error) {
	if s == nil || s.operation == nil {
		return Delivery{}, ErrSessionClosed
	}
	return s.operation.output.next(ctx)
}

func (s *Session) Stats() OutputStats {
	if s == nil || s.operation == nil {
		return OutputStats{}
	}
	return s.operation.output.stats()
}

// Done closes when this generation is cancelled by its window, by manager
// shutdown, or by a newer accepted generation. Consumers arm it after sending
// terminal process status so replacement cleanup cannot suppress that status.
func (s *Session) Done() <-chan struct{} {
	if s == nil || s.operation == nil || s.operation.context == nil {
		return nil
	}
	return s.operation.context.Done()
}

func (s *Session) ContextName() string {
	if s == nil || s.operation == nil || s.operation.session == nil {
		return ""
	}
	return s.operation.session.contextName
}

func (s *Session) Pod() Identity {
	if s == nil || s.operation == nil {
		return Identity{}
	}
	return s.operation.pod
}

func (s *Session) Close() {
	if s == nil || s.operation == nil {
		return
	}
	s.closeOnce.Do(func() {
		s.operation.cancel()
		s.manager.release(s.operation)
	})
}
