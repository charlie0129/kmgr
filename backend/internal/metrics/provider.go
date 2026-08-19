package metrics

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"
)

const DefaultRefreshInterval = 15 * time.Second

// Sample is deliberately provider-neutral. Exact resource keys are preserved;
// callers map CPU/memory or vendor resources to table cells without summing
// incomparable accelerators or huge-page sizes.
type Sample struct {
	MeasuredAt time.Time
	Resources  map[string]int64
}

type Snapshot struct {
	Samples   map[string]Sample
	State     MeasurementState
	UpdatedAt time.Time
	Err       error
}

type Fetcher interface {
	Fetch(context.Context) (map[string]Sample, error)
}

// Provider lazily refreshes one metrics source while it has consumers. A view
// can subscribe independently of base LIST/WATCH; failure never clears rows or
// delays resource availability.
type Provider struct {
	mu sync.Mutex

	fetcher  Fetcher
	interval time.Duration
	now      func() time.Time
	onIdle   func()

	consumers    map[uint64]chan Snapshot
	reservations int
	nextID       uint64
	ctx          context.Context
	cancel       context.CancelFunc
	refresh      chan struct{}
	running      bool
	activeRuns   int
	released     bool
	latest       Snapshot
}

// ProviderLease pins a shared provider between lookup and subscription. This
// matters for large warm views: projecting the initial rows can take long
// enough for an unpinned, zero-consumer provider to otherwise be evicted.
// Subscribe consumes the lease atomically; Close releases an unused lease.
type ProviderLease struct {
	provider *Provider
	once     sync.Once
}

type Subscription struct {
	provider *Provider
	id       uint64
	updates  <-chan Snapshot
	once     sync.Once
}

func NewProvider(fetcher Fetcher, refreshInterval time.Duration) (*Provider, error) {
	if fetcher == nil {
		return nil, errors.New("metrics fetcher must not be nil")
	}
	if refreshInterval < 0 {
		return nil, errors.New("metrics refresh interval must not be negative")
	}
	if refreshInterval == 0 {
		refreshInterval = DefaultRefreshInterval
	}
	return &Provider{
		fetcher: fetcher, interval: refreshInterval, now: time.Now,
		consumers: make(map[uint64]chan Snapshot),
		refresh:   make(chan struct{}, 1),
		latest:    Snapshot{State: MeasurementUnavailable},
	}, nil
}

// Acquire pins the provider until the returned lease is either subscribed or
// closed. A released provider cannot be reacquired.
func (p *Provider) Acquire() (*ProviderLease, error) {
	if p == nil {
		return nil, errors.New("metrics provider must not be nil")
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.released {
		return nil, errors.New("metrics provider has been released")
	}
	p.reservations++
	return &ProviderLease{provider: p}, nil
}

// SetIdleCallback installs the owner notification used by bounded provider
// caches. The callback is invoked without Provider.mu held after the final
// lease or consumer disappears.
func (p *Provider) SetIdleCallback(callback func()) error {
	if p == nil {
		return errors.New("metrics provider must not be nil")
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.released {
		return errors.New("metrics provider has been released")
	}
	p.onIdle = callback
	return nil
}

// Subscribe atomically turns this lookup lease into an active metrics
// subscription. It returns nil if Close or another Subscribe already consumed
// the lease.
func (l *ProviderLease) Subscribe() *Subscription {
	if l == nil {
		return nil
	}
	var subscription *Subscription
	l.once.Do(func() {
		provider := l.provider
		l.provider = nil
		if provider == nil {
			return
		}
		provider.mu.Lock()
		if provider.reservations > 0 {
			provider.reservations--
		}
		if !provider.released {
			subscription = provider.subscribeLocked()
		}
		provider.mu.Unlock()
	})
	return subscription
}

// Close releases a lease that was not converted to a subscription.
func (l *ProviderLease) Close() {
	if l == nil {
		return
	}
	l.once.Do(func() {
		provider := l.provider
		l.provider = nil
		if provider == nil {
			return
		}
		provider.mu.Lock()
		if provider.reservations > 0 {
			provider.reservations--
		}
		idle := provider.isIdleLocked()
		callback := provider.onIdle
		provider.mu.Unlock()
		if idle && callback != nil {
			callback()
		}
	})
}

func (p *Provider) Subscribe() *Subscription {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.released {
		updates := make(chan Snapshot)
		close(updates)
		return &Subscription{updates: updates}
	}
	return p.subscribeLocked()
}

func (p *Provider) subscribeLocked() *Subscription {
	p.nextID++
	updates := make(chan Snapshot, 1)
	p.consumers[p.nextID] = updates
	if !p.latest.UpdatedAt.IsZero() || p.latest.Err != nil {
		updates <- cloneSnapshot(p.latest)
	}
	if !p.running {
		p.ctx, p.cancel = context.WithCancel(context.Background())
		p.running = true
		p.activeRuns++
		go p.run(p.ctx)
	}
	return &Subscription{provider: p, id: p.nextID, updates: updates}
}

func (s *Subscription) Updates() <-chan Snapshot { return s.updates }

// RequestRefresh asks the shared provider to begin another fetch as soon as
// possible. Requests from multiple views coalesce into one wake-up, and a
// request received during a fetch schedules exactly one follow-up fetch. This
// lets a base-resource LIST/WATCH barrier obtain a metrics snapshot that is at
// least as new without opening a second provider or waiting for the periodic
// interval.
func (s *Subscription) RequestRefresh() {
	if s == nil || s.provider == nil {
		return
	}
	s.provider.requestRefresh()
}

func (p *Provider) requestRefresh() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.released || !p.running || len(p.consumers) == 0 {
		return
	}
	select {
	case p.refresh <- struct{}{}:
	default:
	}
}

func (s *Subscription) Close() {
	if s == nil || s.provider == nil {
		return
	}
	s.once.Do(func() { s.provider.unsubscribe(s.id) })
}

func (p *Provider) unsubscribe(id uint64) {
	p.mu.Lock()
	updates := p.consumers[id]
	if updates == nil {
		p.mu.Unlock()
		return
	}
	delete(p.consumers, id)
	close(updates)
	if len(p.consumers) == 0 && p.cancel != nil {
		p.cancel()
		p.cancel = nil
		p.running = false
	}
	idle := p.isIdleLocked()
	callback := p.onIdle
	p.mu.Unlock()
	if idle && callback != nil {
		callback()
	}
}

func (p *Provider) ConsumerCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.consumers)
}

// RetainedSampleCount reports the size of the last warm snapshot. Owners use
// it only for cache budgeting; it does not clone or expose sample data.
func (p *Provider) RetainedSampleCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.latest.Samples)
}

// ReleaseIdle permanently releases an idle provider from its owner cache. It
// drops the potentially large warm snapshot immediately. The fetcher is
// cleared once every already-canceled run goroutine has exited, avoiding a
// race with an in-flight Fetch call while still releasing old client graphs.
func (p *Provider) ReleaseIdle() bool {
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.released || !p.isIdleLocked() {
		return false
	}
	p.released = true
	p.onIdle = nil
	p.latest = Snapshot{State: MeasurementUnavailable}
	if p.activeRuns == 0 {
		p.fetcher = nil
	}
	return true
}

func (p *Provider) isIdleLocked() bool {
	return len(p.consumers) == 0 && p.reservations == 0
}

func (p *Provider) run(ctx context.Context) {
	defer func() {
		p.mu.Lock()
		p.activeRuns--
		if p.released && p.activeRuns == 0 {
			p.fetcher = nil
		}
		p.mu.Unlock()
	}()
	backoff := p.interval
	for {
		started := p.now()
		p.mu.Lock()
		fetcher := p.fetcher
		released := p.released
		p.mu.Unlock()
		if released || fetcher == nil {
			return
		}
		samples, err := fetcher.Fetch(ctx)
		if ctx.Err() != nil {
			return
		}
		snapshot := Snapshot{UpdatedAt: started, Err: safeMetricsError(err)}
		if err == nil {
			snapshot.State = MeasurementCurrent
			snapshot.Samples = cloneSamples(samples)
			backoff = p.interval
		} else {
			p.mu.Lock()
			latest := cloneSnapshot(p.latest)
			p.mu.Unlock()
			if (latest.State == MeasurementCurrent || latest.State == MeasurementStale) && latest.Samples != nil {
				snapshot.State = MeasurementStale
				snapshot.Samples = latest.Samples
			} else {
				snapshot.State = MeasurementUnavailable
			}
			backoff = min(max(backoff*2, p.interval), 2*time.Minute)
		}
		p.publish(snapshot)
		timer := time.NewTimer(backoff)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-p.refresh:
			timer.Stop()
		case <-timer.C:
		}
	}
}

func (p *Provider) publish(snapshot Snapshot) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.released {
		return
	}
	p.latest = cloneSnapshot(snapshot)
	for _, consumer := range p.consumers {
		copy := cloneSnapshot(snapshot)
		select {
		case consumer <- copy:
		default:
			// Slow views need only the newest metrics sample. Drop the queued
			// snapshot and replace it without growing memory.
			select {
			case <-consumer:
			default:
			}
			select {
			case consumer <- copy:
			default:
			}
		}
	}
}

func cloneSnapshot(value Snapshot) Snapshot {
	value.Samples = cloneSamples(value.Samples)
	return value
}

func cloneSamples(values map[string]Sample) map[string]Sample {
	if values == nil {
		return nil
	}
	result := make(map[string]Sample, len(values))
	for identity, sample := range values {
		resources := make(map[string]int64, len(sample.Resources))
		for name, value := range sample.Resources {
			resources[name] = value
		}
		sample.Resources = resources
		result[identity] = sample
	}
	return result
}

// safeMetricsError intentionally drops provider payload text, which could
// contain untrusted API response details. UI tooltips need a category, not a
// dump of the response body.
func safeMetricsError(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, ErrMetricsAPIForbidden) {
		return ErrMetricsAPIForbidden
	}
	if errors.Is(err, ErrMetricsAPIUnavailable) {
		return ErrMetricsAPIUnavailable
	}
	return fmt.Errorf("metrics provider unavailable: %T", err)
}
