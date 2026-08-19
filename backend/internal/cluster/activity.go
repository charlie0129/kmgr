package cluster

import (
	"net/http"
	"sync"
	"sync/atomic"
)

// APIConnectionHealth is a payload-free observation of the shared HTTP
// transport. It deliberately does not retain response bodies, URLs, headers,
// or raw error strings.
type APIConnectionHealth uint32

const (
	APIConnectionUnknown APIConnectionHealth = iota
	APIConnectionConnected
	APIConnectionReconnecting
	APIConnectionAuthenticationFailed
)

// APIActivity is a process-local byte counter for one shared Kubernetes
// authority. It records lengths only and never retains or inspects payloads.
// Notify channels are edge-triggered hints; readers always load totals and
// therefore cannot lose accounting when events are coalesced.
type APIActivity struct {
	received atomic.Uint64
	sent     atomic.Uint64
	health   atomic.Uint32
	warm     atomic.Pointer[warmCacheActivitySnapshot]

	mu        sync.Mutex
	listeners map[chan struct{}]struct{}
}

type APIActivitySnapshot struct {
	BytesReceived      uint64
	BytesSent          uint64
	ConnectionHealth   APIConnectionHealth
	AuthorityWarmCache WarmCacheUsage
	GlobalWarmCache    WarmCacheUsage
}

// WarmCacheUsage contains aggregate process-memory accounting only. It never
// carries an authority ID, Kubernetes identity, query key, or selector.
type WarmCacheUsage struct {
	RetainedViews   uint64
	RetainedObjects uint64
	RetainedBytes   uint64
	ViewLimit       uint64
	ObjectLimit     uint64
	ByteLimit       uint64
	BudgetEvictions uint64
}

type warmCacheActivitySnapshot struct {
	generation uint64
	authority  WarmCacheUsage
	global     WarmCacheUsage
}

func (a *APIActivity) Snapshot() APIActivitySnapshot {
	if a == nil {
		return APIActivitySnapshot{}
	}
	snapshot := APIActivitySnapshot{
		BytesReceived:    a.received.Load(),
		BytesSent:        a.sent.Load(),
		ConnectionHealth: APIConnectionHealth(a.health.Load()),
	}
	if warm := a.warm.Load(); warm != nil {
		snapshot.AuthorityWarmCache = warm.authority
		snapshot.GlobalWarmCache = warm.global
	}
	return snapshot
}

// setWarmCacheUsage replaces the current aggregate warm-cache accounting when
// generation is newer than the installed value. Registry publication happens
// outside its ownership lock, so the generation guard prevents a delayed old
// callback from overwriting a newer snapshot. Readers remain lock-free.
func (a *APIActivity) setWarmCacheUsage(
	generation uint64,
	authority, global WarmCacheUsage,
) {
	if a == nil {
		return
	}
	next := &warmCacheActivitySnapshot{
		generation: generation,
		authority:  authority,
		global:     global,
	}
	for {
		previous := a.warm.Load()
		if previous != nil && previous.generation >= generation {
			return
		}
		if !a.warm.CompareAndSwap(previous, next) {
			continue
		}
		if previous == nil || previous.authority != authority || previous.global != global {
			a.notify()
		}
		return
	}
}

// ObserveRoundTrip records only a coarse connection outcome. Authorization
// failures other than 401 are resource-specific and still prove the API server
// is reachable; 5xx responses and transport failures indicate reconnecting.
func (a *APIActivity) ObserveRoundTrip(statusCode int, roundTripErr error) {
	if a == nil {
		return
	}
	next := APIConnectionConnected
	switch {
	case roundTripErr != nil || statusCode == 0 || statusCode >= http.StatusInternalServerError:
		next = APIConnectionReconnecting
	case statusCode == http.StatusUnauthorized:
		next = APIConnectionAuthenticationFailed
	}
	previous := APIConnectionHealth(a.health.Swap(uint32(next)))
	if previous != next {
		a.notify()
	}
}

func (a *APIActivity) AddReceived(bytes uint64) {
	if a == nil || bytes == 0 {
		return
	}
	a.received.Add(bytes)
	a.notify()
}

func (a *APIActivity) AddSent(bytes uint64) {
	if a == nil || bytes == 0 {
		return
	}
	a.sent.Add(bytes)
	a.notify()
}

// Subscribe returns a coalescing activity hint and an idempotent cancellation
// closure. Consumers must read Snapshot after every hint.
func (a *APIActivity) Subscribe() (<-chan struct{}, func()) {
	if a == nil {
		closed := make(chan struct{})
		close(closed)
		return closed, func() {}
	}
	updates := make(chan struct{}, 1)
	a.mu.Lock()
	if a.listeners == nil {
		a.listeners = make(map[chan struct{}]struct{})
	}
	a.listeners[updates] = struct{}{}
	a.mu.Unlock()
	var once sync.Once
	return updates, func() {
		once.Do(func() {
			a.mu.Lock()
			delete(a.listeners, updates)
			a.mu.Unlock()
		})
	}
}

func (a *APIActivity) notify() {
	a.mu.Lock()
	defer a.mu.Unlock()
	for listener := range a.listeners {
		select {
		case listener <- struct{}{}:
		default:
		}
	}
}
