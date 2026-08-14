package watcher

import (
	"container/list"
	"sync"
	"time"
)

type WarmEntry[V any] struct {
	Value            V
	ObjectCount      int
	ByteCount        int64
	ResourceVersion  string
	LastSynchronized time.Time
	Complete         bool
}

// WarmCache is a bounded LRU measured by entries, Kubernetes object count, and
// a conservative retained-byte estimate supplied by its owner. It performs no
// background work and therefore never implies freshness.
type WarmCache[K comparable, V any] struct {
	mu         sync.Mutex
	maxEntries int
	maxObjects int
	maxBytes   int64
	objects    int
	bytes      int64
	lru        *list.List
	byKey      map[K]*list.Element
}

type cacheItem[K comparable, V any] struct {
	key   K
	entry WarmEntry[V]
}

func NewWarmCache[K comparable, V any](maxEntries, maxObjects int, maxBytes int64) *WarmCache[K, V] {
	if maxEntries <= 0 || maxObjects <= 0 || maxBytes <= 0 {
		panic("watcher: warm cache limits must be positive")
	}
	return &WarmCache[K, V]{
		maxEntries: maxEntries,
		maxObjects: maxObjects,
		maxBytes:   maxBytes,
		lru:        list.New(),
		byKey:      make(map[K]*list.Element),
	}
}

// Put returns the keys evicted from least to most recently used and whether
// the new entry was admitted. An entry larger than either aggregate budget is
// rejected rather than evicting every useful cache entry for a value that
// still cannot fit. Rejection leaves the cache unchanged, including any prior
// entry under the same key.
func (c *WarmCache[K, V]) Put(key K, entry WarmEntry[V]) (evicted []K, admitted bool) {
	if entry.ObjectCount < 0 || entry.ByteCount < 0 {
		panic("watcher: negative warm-cache weight")
	}
	c.mu.Lock()
	defer c.mu.Unlock()

	if entry.ObjectCount > c.maxObjects || entry.ByteCount > c.maxBytes {
		return nil, false
	}
	if element := c.byKey[key]; element != nil {
		item := element.Value.(*cacheItem[K, V])
		c.objects -= item.entry.ObjectCount
		c.bytes -= item.entry.ByteCount
		c.lru.Remove(element)
		delete(c.byKey, key)
	}

	for len(c.byKey) >= c.maxEntries || entry.ObjectCount > c.maxObjects-c.objects ||
		entry.ByteCount > c.maxBytes-c.bytes {
		element := c.lru.Back()
		item := element.Value.(*cacheItem[K, V])
		c.lru.Remove(element)
		delete(c.byKey, item.key)
		c.objects -= item.entry.ObjectCount
		c.bytes -= item.entry.ByteCount
		evicted = append(evicted, item.key)
	}

	item := &cacheItem[K, V]{key: key, entry: entry}
	c.byKey[key] = c.lru.PushFront(item)
	c.objects += entry.ObjectCount
	c.bytes += entry.ByteCount
	return evicted, true
}

func (c *WarmCache[K, V]) Get(key K) (WarmEntry[V], bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	element := c.byKey[key]
	if element == nil {
		var zero WarmEntry[V]
		return zero, false
	}
	c.lru.MoveToFront(element)
	return element.Value.(*cacheItem[K, V]).entry, true
}

func (c *WarmCache[K, V]) Remove(key K) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	element := c.byKey[key]
	if element == nil {
		return false
	}
	item := element.Value.(*cacheItem[K, V])
	c.objects -= item.entry.ObjectCount
	c.bytes -= item.entry.ByteCount
	c.lru.Remove(element)
	delete(c.byKey, key)
	return true
}

func (c *WarmCache[K, V]) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.byKey)
}

func (c *WarmCache[K, V]) ObjectCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.objects
}

func (c *WarmCache[K, V]) ByteCount() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.bytes
}
