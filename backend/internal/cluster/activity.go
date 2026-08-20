package cluster

import (
	"net/http"
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
// The response-body hot path only performs atomic additions. Connection
// streams sample these totals on a fixed interval, so payload reads never
// contend on a listener lock or perform per-read IPC coordination.
type APIActivity struct {
	received atomic.Uint64
	sent     atomic.Uint64
	health   atomic.Uint32
	warm     atomic.Pointer[warmCacheActivitySnapshot]
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
	RetainedViews    uint64
	RetainedObjects  uint64
	RetainedBytes    uint64
	EvictableViews   uint64
	EvictableObjects uint64
	EvictableBytes   uint64
	ViewLimit        uint64
	ObjectLimit      uint64
	ByteLimit        uint64
	BudgetEvictions  uint64
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
	a.health.Store(uint32(next))
}

func (a *APIActivity) AddReceived(bytes uint64) {
	if a == nil || bytes == 0 {
		return
	}
	a.received.Add(bytes)
}

func (a *APIActivity) AddSent(bytes uint64) {
	if a == nil || bytes == 0 {
		return
	}
	a.sent.Add(bytes)
}
