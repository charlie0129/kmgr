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

	consumers map[uint64]chan Snapshot
	nextID    uint64
	ctx       context.Context
	cancel    context.CancelFunc
	running   bool
	latest    Snapshot
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
		latest:    Snapshot{State: MeasurementUnavailable},
	}, nil
}

func (p *Provider) Subscribe() *Subscription {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.nextID++
	updates := make(chan Snapshot, 1)
	p.consumers[p.nextID] = updates
	if !p.latest.UpdatedAt.IsZero() || p.latest.Err != nil {
		updates <- cloneSnapshot(p.latest)
	}
	if !p.running {
		p.ctx, p.cancel = context.WithCancel(context.Background())
		p.running = true
		go p.run(p.ctx)
	}
	return &Subscription{provider: p, id: p.nextID, updates: updates}
}

func (s *Subscription) Updates() <-chan Snapshot { return s.updates }

func (s *Subscription) Close() {
	if s == nil || s.provider == nil {
		return
	}
	s.once.Do(func() { s.provider.unsubscribe(s.id) })
}

func (p *Provider) unsubscribe(id uint64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	updates := p.consumers[id]
	if updates == nil {
		return
	}
	delete(p.consumers, id)
	close(updates)
	if len(p.consumers) == 0 && p.cancel != nil {
		p.cancel()
		p.cancel = nil
		p.running = false
	}
}

func (p *Provider) ConsumerCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.consumers)
}

func (p *Provider) run(ctx context.Context) {
	backoff := p.interval
	for {
		started := p.now()
		samples, err := p.fetcher.Fetch(ctx)
		if ctx.Err() != nil {
			return
		}
		snapshot := Snapshot{UpdatedAt: started, Err: safeMetricsError(err)}
		if err == nil {
			snapshot.State = MeasurementCurrent
			snapshot.Samples = cloneSamples(samples)
			backoff = p.interval
		} else {
			snapshot.State = MeasurementUnavailable
			backoff = min(max(backoff*2, p.interval), 2*time.Minute)
		}
		p.publish(snapshot)
		timer := time.NewTimer(backoff)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}

func (p *Provider) publish(snapshot Snapshot) {
	p.mu.Lock()
	defer p.mu.Unlock()
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
	return fmt.Errorf("metrics provider unavailable: %T", err)
}
