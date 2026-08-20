// Package apioperation carries error-only observations from Kubernetes watch
// decoders back to the HTTP operation that owns the response stream. It does
// not inspect or retain response payloads.
package apioperation

import (
	"context"
	"sync"
)

type watchErrorObserverKey struct{}

// WatchErrorObserver associates one decoded watch.Error with the most recent
// HTTP operation started from its context. A Watch call may make more than one
// sequential HTTP attempt, so a later transport binding replaces an earlier
// one. Callers that fan out concurrent watches must create one observer per
// child request.
type WatchErrorObserver struct {
	mu     sync.RWMutex
	record func(error)
}

// WithWatchErrorObserver returns a derived context and its error observer.
// The observer is intentionally opt-in so ordinary LIST/GET payload paths add
// no synchronization or allocation.
func WithWatchErrorObserver(ctx context.Context) (context.Context, *WatchErrorObserver) {
	if ctx == nil {
		ctx = context.Background()
	}
	observer := &WatchErrorObserver{}
	return context.WithValue(ctx, watchErrorObserverKey{}, observer), observer
}

// WatchErrorObserverFromContext returns the observer installed for one Watch
// call, if any.
func WatchErrorObserverFromContext(ctx context.Context) *WatchErrorObserver {
	if ctx == nil {
		return nil
	}
	observer, _ := ctx.Value(watchErrorObserverKey{}).(*WatchErrorObserver)
	return observer
}

// Bind installs the operation-specific error recorder. The activity transport
// calls Bind when it starts an HTTP request from the observed Watch context.
func (o *WatchErrorObserver) Bind(record func(error)) {
	if o == nil {
		return
	}
	o.mu.Lock()
	o.record = record
	o.mu.Unlock()
}

// Observe forwards a decoded watch.Error without changing its Go error text.
func (o *WatchErrorObserver) Observe(err error) {
	if o == nil || err == nil {
		return
	}
	o.mu.RLock()
	record := o.record
	o.mu.RUnlock()
	if record != nil {
		record(err)
	}
}
