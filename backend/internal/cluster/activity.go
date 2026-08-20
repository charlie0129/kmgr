package cluster

import (
	"net/http"
	"sync"
	"sync/atomic"
)

// APIConnectionHealth is a payload-free observation of the shared HTTP
// transport. It does not retain response bodies or headers.
type APIConnectionHealth uint32

const (
	APIConnectionUnknown APIConnectionHealth = iota
	APIConnectionConnected
	APIConnectionReconnecting
	APIConnectionAuthenticationFailed
)

// APIActivity is a process-local byte counter for one shared Kubernetes
// authority. It records lengths and the latest raw Go transport error, but
// never retains or inspects payloads.
// The response-body hot path only performs atomic additions. Connection
// streams sample these totals on a fixed interval, so payload reads never
// contend on a listener lock or perform per-read IPC coordination.
type APIActivity struct {
	received   atomic.Uint64
	sent       atomic.Uint64
	connection atomic.Pointer[apiConnectionActivitySnapshot]
	warm       atomic.Pointer[warmCacheActivitySnapshot]

	operationSequence   atomic.Uint64
	operationsMu        sync.RWMutex
	activeOperations    map[uint64]*trackedAPIOperation
	completedOperations apiOperationCompletionRing
	completionSequence  uint64
}

type APIActivitySnapshot struct {
	BytesReceived      uint64
	BytesSent          uint64
	ConnectionHealth   APIConnectionHealth
	ConnectionError    string
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

type apiConnectionActivitySnapshot struct {
	health       APIConnectionHealth
	errorMessage string
}

func (a *APIActivity) Snapshot() APIActivitySnapshot {
	if a == nil {
		return APIActivitySnapshot{}
	}
	snapshot := APIActivitySnapshot{
		BytesReceived: a.received.Load(),
		BytesSent:     a.sent.Load(),
	}
	if connection := a.connection.Load(); connection != nil {
		snapshot.ConnectionHealth = connection.health
		snapshot.ConnectionError = connection.errorMessage
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
func (a *APIActivity) ObserveRoundTrip(
	request *http.Request,
	statusCode int,
	roundTripErr error,
) {
	if a == nil {
		return
	}
	// Cancelling a LIST/WATCH because its consumer changed panels is not a
	// connection failure and must not make the shared authority reconnecting.
	if requestWasCancelled(request, roundTripErr) {
		return
	}
	next := APIConnectionConnected
	switch {
	case roundTripErr != nil || statusCode == 0 || statusCode >= http.StatusInternalServerError:
		next = APIConnectionReconnecting
	case statusCode == http.StatusUnauthorized:
		next = APIConnectionAuthenticationFailed
	}
	message := ""
	if next != APIConnectionConnected {
		message = apiOperationErrorMessage(
			requestContextError(request),
			roundTripErr,
			statusCode,
		)
	}
	a.connection.Store(&apiConnectionActivitySnapshot{
		health: next, errorMessage: message,
	})
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
