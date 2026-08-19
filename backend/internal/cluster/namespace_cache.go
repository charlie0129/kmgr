package cluster

import (
	"context"
	"errors"
	"slices"
	"sync"
)

var errNamespaceNameCacheClosed = errors.New("namespace name cache is closed")

// namespaceNameCache belongs to one shared Kubernetes backend. The first
// caller waits for a coalesced LIST. Once a successful snapshot exists, callers
// receive a clone immediately while at most one refresh runs in the background.
// There is deliberately no TTL: each read is the refresh event, and the cache
// lives exactly as long as the shared backend.
type namespaceNameCache struct {
	mu sync.Mutex

	names  []string
	ready  bool
	flight *namespaceNameFlight
	closed bool
}

type namespaceNameFlight struct {
	done   chan struct{}
	cancel context.CancelFunc
	names  []string
	err    error
}

type namespaceNameLoader func(context.Context) ([]string, error)

func (c *namespaceNameCache) load(
	ctx context.Context,
	loader namespaceNameLoader,
) ([]string, error) {
	if ctx == nil {
		return nil, errors.New("namespace cache context must not be nil")
	}
	if loader == nil {
		return nil, errors.New("namespace cache loader must not be nil")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil, errNamespaceNameCacheClosed
	}
	if c.ready {
		cached := slices.Clone(c.names)
		if c.flight == nil {
			c.startLocked(ctx, loader)
		}
		c.mu.Unlock()
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		return cached, nil
	}
	if c.flight == nil {
		c.startLocked(ctx, loader)
	}
	flight := c.flight
	c.mu.Unlock()

	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-flight.done:
		if flight.err != nil {
			return nil, flight.err
		}
		return slices.Clone(flight.names), nil
	}
}

func (c *namespaceNameCache) startLocked(
	requestContext context.Context,
	loader namespaceNameLoader,
) {
	refreshContext, cancel := detachedRefreshContext(requestContext)
	flight := &namespaceNameFlight{done: make(chan struct{}), cancel: cancel}
	c.flight = flight
	go c.refresh(refreshContext, flight, loader)
}

func (c *namespaceNameCache) refresh(
	ctx context.Context,
	flight *namespaceNameFlight,
	loader namespaceNameLoader,
) {
	names, err := loader(ctx)
	flight.cancel()
	if err == nil {
		// ListNamespaces already produces this form. Normalizing again keeps the
		// cache's compact sorted-name contract independent of a future loader.
		names = sortedUnique(names)
	}

	c.mu.Lock()
	if c.closed && err == nil {
		names = nil
		err = errNamespaceNameCacheClosed
	}
	flight.err = err
	if err == nil {
		flight.names = slices.Clone(names)
		if !c.closed {
			c.names = slices.Clone(names)
			c.ready = true
		}
	}
	if c.flight == flight {
		c.flight = nil
	}
	close(flight.done)
	c.mu.Unlock()
}

func (c *namespaceNameCache) close() {
	if c == nil {
		return
	}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	c.names = nil
	c.ready = false
	flight := c.flight
	c.mu.Unlock()
	if flight != nil {
		flight.cancel()
	}
}

// detachedRefreshContext survives completion of the unary RPC that triggered
// a stale-while-refresh update, but it preserves that request's deadline. The
// cache additionally cancels it when its shared backend closes.
func detachedRefreshContext(ctx context.Context) (context.Context, context.CancelFunc) {
	base := context.WithoutCancel(ctx)
	if deadline, ok := ctx.Deadline(); ok {
		return context.WithDeadline(base, deadline)
	}
	return context.WithCancel(base)
}

// ListNamespacesCached returns the namespace-name catalog shared by all
// sessions backed by the same Kubernetes authority.
func (s *Session) ListNamespacesCached(ctx context.Context) ([]string, error) {
	if s == nil || s.backend == nil || s.Metadata() == nil {
		return nil, errors.New("cluster session metadata client is unavailable")
	}
	return s.backend.namespaceNames.load(ctx, func(refreshContext context.Context) ([]string, error) {
		return ListNamespaces(refreshContext, s)
	})
}
