// Package watcher coordinates shared Kubernetes LIST/WATCH lifetimes.
package watcher

import (
	"context"
	"sync"
	"time"
)

// StartFunc runs one shared watcher until its context is cancelled. A key must
// describe all server-side compatibility dimensions (session, GVR, namespace,
// and selectors), not merely a display resource name.
type StartFunc[K comparable] func(context.Context, K)

// LeaseManager reference-counts active consumers and debounces cancellation
// after the final consumer leaves. It intentionally owns no warm-store data;
// stopping network activity must not erase cached state.
type LeaseManager[K comparable] struct {
	mu       sync.Mutex
	debounce time.Duration
	start    StartFunc[K]
	entries  map[K]*leaseEntry
}

type leaseEntry struct {
	references int
	generation uint64
	cancel     context.CancelFunc
	timer      *time.Timer
}

type Lease[K comparable] struct {
	manager *LeaseManager[K]
	key     K
	once    sync.Once
}

func NewLeaseManager[K comparable](debounce time.Duration, start StartFunc[K]) *LeaseManager[K] {
	if debounce < 0 {
		panic("watcher: negative debounce")
	}
	if start == nil {
		panic("watcher: nil start function")
	}
	return &LeaseManager[K]{
		debounce: debounce,
		start:    start,
		entries:  make(map[K]*leaseEntry),
	}
}

func (m *LeaseManager[K]) Acquire(key K) *Lease[K] {
	m.mu.Lock()
	entry := m.entries[key]
	if entry == nil {
		ctx, cancel := context.WithCancel(context.Background())
		entry = &leaseEntry{cancel: cancel, generation: 1}
		m.entries[key] = entry
		go m.start(ctx, key)
	} else if entry.timer != nil {
		entry.timer.Stop()
		entry.timer = nil
		entry.generation++
	}
	entry.references++
	m.mu.Unlock()

	return &Lease[K]{manager: m, key: key}
}

func (l *Lease[K]) Close() {
	if l == nil || l.manager == nil {
		return
	}
	l.once.Do(func() { l.manager.release(l.key) })
}

func (m *LeaseManager[K]) release(key K) {
	m.mu.Lock()
	defer m.mu.Unlock()
	entry := m.entries[key]
	if entry == nil || entry.references == 0 {
		return
	}
	entry.references--
	if entry.references != 0 {
		return
	}

	entry.generation++
	generation := entry.generation
	entry.timer = time.AfterFunc(m.debounce, func() {
		m.cancelIfUnused(key, generation)
	})
}

func (m *LeaseManager[K]) cancelIfUnused(key K, generation uint64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	entry := m.entries[key]
	if entry == nil || entry.references != 0 || entry.generation != generation {
		return
	}
	entry.cancel()
	delete(m.entries, key)
}

func (m *LeaseManager[K]) References(key K) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	if entry := m.entries[key]; entry != nil {
		return entry.references
	}
	return 0
}

func (m *LeaseManager[K]) ActiveCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.entries)
}

func (m *LeaseManager[K]) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for key, entry := range m.entries {
		if entry.timer != nil {
			entry.timer.Stop()
		}
		entry.cancel()
		delete(m.entries, key)
	}
}
