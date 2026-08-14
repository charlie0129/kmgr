package portforward

import (
	"context"
	"errors"
	"net"
	"sort"
	"sync"
	"time"
)

const (
	DefaultInitialBackoff         = 250 * time.Millisecond
	DefaultMaxBackoff             = 15 * time.Second
	DefaultTerminalRetention      = 24 * time.Hour
	DefaultRetainedTerminalLimit  = 256
	DefaultSubscriberPendingLimit = 64
)

type Config struct {
	Sessions               SessionResolver
	Backoff                Backoff
	Now                    func() time.Time
	TerminalRetention      time.Duration
	RetainedTerminalLimit  int
	SubscriberPendingLimit int
}

type entry struct {
	mu         sync.RWMutex
	request    StartRequest
	snapshot   Snapshot
	cancel     context.CancelFunc
	runDone    chan struct{}
	revision   uint64
	restarting bool
}

func (e *entry) Snapshot() Snapshot {
	e.mu.RLock()
	defer e.mu.RUnlock()
	result := e.snapshot
	if result.ResolvedPod != nil {
		copy := *result.ResolvedPod
		result.ResolvedPod = &copy
	}
	return result
}

type subscription struct {
	id      uint64
	ready   chan struct{}
	limit   int
	mu      sync.Mutex
	pending []managerUpdate
	resync  bool
}

type managerUpdate struct {
	snapshot  Snapshot
	removedID string
}

type updateBatch struct {
	updates []managerUpdate
	resync  bool
}

func (s *subscription) enqueue(update managerUpdate) {
	if update.removedID == "" && update.snapshot.ID == "" {
		return
	}
	s.mu.Lock()
	if !s.resync {
		if len(s.pending) >= s.limit {
			s.pending = s.pending[:0]
			s.resync = true
		} else {
			s.pending = append(s.pending, update)
		}
	}
	s.mu.Unlock()
	select {
	case s.ready <- struct{}{}:
	default:
	}
}

func (s *subscription) drain() updateBatch {
	s.mu.Lock()
	result := updateBatch{resync: s.resync}
	if !s.resync {
		result.updates = append([]managerUpdate(nil), s.pending...)
	}
	s.pending = s.pending[:0]
	s.resync = false
	s.mu.Unlock()
	return result
}

type Manager struct {
	mu       sync.RWMutex
	config   Config
	entries  map[string]*entry
	watchers map[uint64]*subscription
	nextID   uint64
	closed   bool
}

func NewManager(config Config) (*Manager, error) {
	if config.Sessions == nil {
		return nil, errors.New("port-forward session resolver must not be nil")
	}
	if config.Backoff == nil {
		config.Backoff = exponentialBackoff{initial: DefaultInitialBackoff, maximum: DefaultMaxBackoff}
	}
	if config.Now == nil {
		config.Now = time.Now
	}
	if config.TerminalRetention < 0 || config.RetainedTerminalLimit < 0 || config.SubscriberPendingLimit < 0 {
		return nil, errors.New("port-forward retention and pending limits must not be negative")
	}
	if config.TerminalRetention == 0 {
		config.TerminalRetention = DefaultTerminalRetention
	}
	if config.RetainedTerminalLimit == 0 {
		config.RetainedTerminalLimit = DefaultRetainedTerminalLimit
	}
	if config.SubscriberPendingLimit == 0 {
		config.SubscriberPendingLimit = DefaultSubscriberPendingLimit
	}
	return &Manager{
		config: config, entries: make(map[string]*entry), watchers: make(map[uint64]*subscription),
	}, nil
}

func (m *Manager) Start(request StartRequest) (Snapshot, error) {
	if err := request.normalize(); err != nil {
		return Snapshot{}, err
	}
	m.pruneTerminalEntries(m.config.Now())
	session, err := m.config.Sessions.ResolveSession(request.Target.SessionID)
	if err != nil {
		return Snapshot{}, err
	}
	releaseSession := true
	defer func() {
		if releaseSession && session.Release != nil {
			session.Release()
		}
	}()
	if session.Resolver == nil || session.Forwarder == nil {
		return Snapshot{}, errors.New("port-forward session is incomplete")
	}
	ctx, cancel := context.WithCancel(context.Background())
	now := m.config.Now()
	current := &entry{
		request: request, cancel: cancel, runDone: make(chan struct{}), revision: 1,
		snapshot: Snapshot{
			ID: request.ID, ContextName: session.ContextName, Target: request.Target,
			RemotePort: request.RemotePort, LocalPort: request.LocalPort, BindAddress: request.BindAddress,
			Label: request.Label, NonLoopbackBind: !isLoopback(request.BindAddress), State: StateStarting,
			StartedAt: now, UpdatedAt: now,
		},
	}
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		cancel()
		return Snapshot{}, ErrManagerClosed
	}
	if _, duplicate := m.entries[request.ID]; duplicate {
		m.mu.Unlock()
		cancel()
		return Snapshot{}, ErrDuplicatePortForward
	}
	m.entries[request.ID] = current
	m.mu.Unlock()
	m.publish(managerUpdate{snapshot: current.Snapshot()})
	go m.run(ctx, current, current.revision, session)
	releaseSession = false
	return current.Snapshot(), nil
}

func (m *Manager) Stop(id, sessionID string) bool {
	current := m.lookup(id, sessionID)
	if current == nil {
		return false
	}
	current.mu.RLock()
	cancel := current.cancel
	current.mu.RUnlock()
	cancel()
	return true
}

func (m *Manager) Restart(id, sessionID string) bool {
	current := m.lookup(id, sessionID)
	if current == nil {
		return false
	}
	current.mu.Lock()
	if current.restarting || (current.snapshot.State != StateFailed && current.snapshot.State != StateStopped) {
		current.mu.Unlock()
		return false
	}
	current.restarting = true
	revision := current.revision
	current.mu.Unlock()

	session, err := m.config.Sessions.ResolveSession(current.request.Target.SessionID)
	if err != nil || session.Resolver == nil || session.Forwarder == nil {
		if err == nil && session.Release != nil {
			session.Release()
		}
		current.mu.Lock()
		if current.revision == revision {
			current.restarting = false
		}
		current.mu.Unlock()
		return false
	}

	ctx, cancel := context.WithCancel(context.Background())
	m.mu.Lock()
	current.mu.Lock()
	if m.closed || m.entries[id] != current || current.revision != revision || !current.restarting ||
		(current.snapshot.State != StateFailed && current.snapshot.State != StateStopped) {
		current.restarting = false
		current.mu.Unlock()
		m.mu.Unlock()
		cancel()
		if session.Release != nil {
			session.Release()
		}
		return false
	}
	current.cancel = cancel
	current.runDone = make(chan struct{})
	current.revision++
	revision = current.revision
	current.restarting = false
	current.snapshot.State = StateStarting
	current.snapshot.LastError = nil
	current.snapshot.UpdatedAt = m.config.Now()
	current.mu.Unlock()
	m.mu.Unlock()
	m.publish(managerUpdate{snapshot: current.Snapshot()})
	go m.run(ctx, current, revision, session)
	return true
}

func (m *Manager) List(sessionID string, includeStopped bool) []Snapshot {
	m.pruneTerminalEntries(m.config.Now())
	m.mu.RLock()
	values := make([]*entry, 0, len(m.entries))
	for _, value := range m.entries {
		values = append(values, value)
	}
	m.mu.RUnlock()
	result := make([]Snapshot, 0, len(values))
	for _, value := range values {
		current := value.Snapshot()
		if sessionID != "" && current.Target.SessionID != sessionID {
			continue
		}
		if !includeStopped && current.State == StateStopped {
			continue
		}
		result = append(result, current)
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].StartedAt.Equal(result[j].StartedAt) {
			return result[i].ID < result[j].ID
		}
		return result[i].StartedAt.Before(result[j].StartedAt)
	})
	return result
}

func (m *Manager) subscribe() (*subscription, func()) {
	m.mu.Lock()
	m.nextID++
	value := &subscription{
		id: m.nextID, ready: make(chan struct{}, 1), limit: m.config.SubscriberPendingLimit,
		pending: make([]managerUpdate, 0, m.config.SubscriberPendingLimit),
	}
	m.watchers[value.id] = value
	m.mu.Unlock()
	var once sync.Once
	return value, func() {
		once.Do(func() {
			m.mu.Lock()
			delete(m.watchers, value.id)
			m.mu.Unlock()
		})
	}
}

func (m *Manager) Close() {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return
	}
	m.closed = true
	entries := make([]*entry, 0, len(m.entries))
	for _, value := range m.entries {
		entries = append(entries, value)
	}
	clear(m.watchers)
	m.mu.Unlock()
	for _, value := range entries {
		value.mu.RLock()
		cancel := value.cancel
		value.mu.RUnlock()
		cancel()
	}
	for _, value := range entries {
		value.mu.RLock()
		done := value.runDone
		value.mu.RUnlock()
		<-done
	}
}

func (m *Manager) run(ctx context.Context, current *entry, revision uint64, session Session) {
	current.mu.RLock()
	done := current.runDone
	current.mu.RUnlock()
	defer func() {
		if session.Release != nil {
			session.Release()
		}
		close(done)
		m.pruneTerminalEntries(m.config.Now())
	}()
	request := current.request
	for attempt := 0; ; attempt++ {
		resolved, err := session.Resolver.Resolve(ctx, request.Target, request.RemotePort)
		pod := resolved.Pod
		if err == nil && request.Target.IsPod() && pod.UID != request.Target.UID {
			err = ErrPodRecreated
		}
		if err != nil {
			if ctx.Err() != nil {
				m.transition(current, revision, StateStopped, nil, nil, 0)
				return
			}
			// A direct Pod forward may outlive transient API and transport
			// failures, but it must never attach to a same-name replacement.
			if request.Target.IsPod() && errors.Is(err, ErrPodRecreated) {
				m.transition(current, revision, StateFailed, err, nil, 0)
				return
			}
			m.transition(current, revision, StateReconnecting, err, nil, 0)
			if m.config.Backoff.Wait(ctx, attempt) != nil {
				m.transition(current, revision, StateStopped, nil, nil, 0)
				return
			}
			continue
		}
		running, err := session.Forwarder.Start(ctx, ForwardRequest{
			Pod: pod, RemotePort: resolved.RemotePort, LocalPort: current.Snapshot().LocalPort,
			BindAddress: request.BindAddress,
		})
		if err == nil {
			m.transition(current, revision, StateListening, nil, &pod, running.LocalPort())
			waitResult := make(chan error, 1)
			go func() { waitResult <- running.Wait() }()
			select {
			case err = <-waitResult:
			case <-ctx.Done():
				_ = running.Close()
				err = <-waitResult
			}
			_ = running.Close()
		}
		if ctx.Err() != nil {
			m.transition(current, revision, StateStopped, nil, &pod, 0)
			return
		}
		// The concrete client performs a second UID check after upgrading the
		// name-addressed Kubernetes stream but before binding locally. A direct
		// Pod mismatch at that seam is terminal just like a resolver mismatch.
		if request.Target.IsPod() && errors.Is(err, ErrPodRecreated) {
			m.transition(current, revision, StateFailed, err, &pod, 0)
			return
		}
		m.transition(current, revision, StateReconnecting, err, &pod, 0)
		if m.config.Backoff.Wait(ctx, attempt) != nil {
			m.transition(current, revision, StateStopped, nil, &pod, 0)
			return
		}
	}
}

func (m *Manager) transition(
	current *entry,
	revision uint64,
	state State,
	err error,
	pod *Identity,
	localPort uint16,
) {
	current.mu.Lock()
	if current.revision != revision {
		current.mu.Unlock()
		return
	}
	current.snapshot.State = state
	current.snapshot.LastError = err
	if pod != nil {
		copy := *pod
		current.snapshot.ResolvedPod = &copy
	}
	if localPort != 0 {
		current.snapshot.LocalPort = localPort
	}
	current.snapshot.UpdatedAt = m.config.Now()
	snapshot := current.snapshot
	current.mu.Unlock()
	m.publish(managerUpdate{snapshot: snapshot})
}

func (m *Manager) publish(update managerUpdate) {
	m.mu.RLock()
	watchers := make([]*subscription, 0, len(m.watchers))
	for _, watcher := range m.watchers {
		watchers = append(watchers, watcher)
	}
	m.mu.RUnlock()
	for _, watcher := range watchers {
		watcher.enqueue(update)
	}
}

func (m *Manager) pruneTerminalEntries(now time.Time) {
	type candidate struct {
		id        string
		updatedAt time.Time
		expired   bool
	}
	cutoff := now.Add(-m.config.TerminalRetention)
	m.mu.Lock()
	candidates := make([]candidate, 0, len(m.entries))
	for id, current := range m.entries {
		current.mu.RLock()
		snapshot, done := current.snapshot, current.runDone
		current.mu.RUnlock()
		if snapshot.State != StateFailed && snapshot.State != StateStopped {
			continue
		}
		select {
		case <-done:
			candidates = append(candidates, candidate{
				id: id, updatedAt: snapshot.UpdatedAt, expired: !snapshot.UpdatedAt.After(cutoff),
			})
		default:
		}
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].updatedAt.Equal(candidates[j].updatedAt) {
			return candidates[i].id < candidates[j].id
		}
		return candidates[i].updatedAt.Before(candidates[j].updatedAt)
	})
	removeCount := max(0, len(candidates)-m.config.RetainedTerminalLimit)
	removed := make([]string, 0, removeCount)
	for index, value := range candidates {
		if !value.expired && index >= removeCount {
			continue
		}
		if current := m.entries[value.id]; current != nil {
			delete(m.entries, value.id)
			removed = append(removed, value.id)
		}
	}
	m.mu.Unlock()
	for _, id := range removed {
		m.publish(managerUpdate{removedID: id})
	}
}

func (m *Manager) lookup(id, sessionID string) *entry {
	m.mu.RLock()
	current := m.entries[id]
	m.mu.RUnlock()
	if current == nil || (sessionID != "" && current.Snapshot().Target.SessionID != sessionID) {
		return nil
	}
	return current
}

type exponentialBackoff struct {
	initial time.Duration
	maximum time.Duration
}

func (b exponentialBackoff) Wait(ctx context.Context, attempt int) error {
	delay := b.initial
	for range min(attempt, 16) {
		delay *= 2
		if delay >= b.maximum {
			delay = b.maximum
			break
		}
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func isLoopback(value string) bool {
	ip := net.ParseIP(value)
	return ip != nil && ip.IsLoopback()
}
