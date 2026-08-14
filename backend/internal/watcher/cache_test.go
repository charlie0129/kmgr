package watcher

import (
	"reflect"
	"testing"
	"time"
)

func TestWarmCacheEvictsLeastRecentlyUsedWithinBothBudgets(t *testing.T) {
	t.Parallel()
	cache := NewWarmCache[string, string](3, 5, 100)
	cache.Put("pods", entry("pods", 2))
	cache.Put("nodes", entry("nodes", 2))
	if _, ok := cache.Get("pods"); !ok {
		t.Fatal("pods unexpectedly absent")
	}
	evicted, admitted := cache.Put("deployments", entry("deployments", 2))
	if !admitted {
		t.Fatal("entry within object budget was rejected")
	}
	if !reflect.DeepEqual(evicted, []string{"nodes"}) {
		t.Fatalf("evicted = %v, want [nodes]", evicted)
	}
	if _, ok := cache.Get("nodes"); ok {
		t.Fatal("least recently used entry survived object budget")
	}
	if cache.Len() != 2 || cache.ObjectCount() != 4 {
		t.Fatalf("cache size = %d entries, %d objects", cache.Len(), cache.ObjectCount())
	}
}

func TestWarmCacheRejectsOversizedEntryWithoutEvictingUsefulData(t *testing.T) {
	t.Parallel()
	cache := NewWarmCache[string, string](2, 3, 100)
	cache.Put("pods", entry("pods", 2))
	_, admitted := cache.Put("huge", entry("huge", 10))
	if admitted {
		t.Fatal("oversized entry reported successful admission")
	}
	if _, ok := cache.Get("pods"); !ok {
		t.Fatal("oversized insertion evicted useful data")
	}
	if _, ok := cache.Get("huge"); ok {
		t.Fatal("oversized entry was cached")
	}
	if cache.Len() != 1 || cache.ObjectCount() != 2 {
		t.Fatalf("cache size after rejection = %d entries, %d objects", cache.Len(), cache.ObjectCount())
	}
	_, admitted = cache.Put("pods", entry("oversized replacement", 10))
	if admitted {
		t.Fatal("oversized replacement reported successful admission")
	}
	retained, ok := cache.Get("pods")
	if !ok || retained.Value != "pods" {
		t.Fatalf("entry after rejected replacement = %#v, present = %t", retained, ok)
	}
}

func TestWarmCacheUpdateAndRemoveMaintainObjectBudget(t *testing.T) {
	t.Parallel()
	cache := NewWarmCache[string, string](2, 10, 100)
	cache.Put("pods", entry("old", 6))
	cache.Put("pods", entry("new", 2))
	if got := cache.ObjectCount(); got != 2 {
		t.Fatalf("object count after replacement = %d", got)
	}
	if !cache.Remove("pods") || cache.Remove("pods") {
		t.Fatal("Remove result did not reflect presence")
	}
	if cache.ObjectCount() != 0 {
		t.Fatal("object count survived removal")
	}
	if cache.ByteCount() != 0 {
		t.Fatal("byte count survived removal")
	}
}

func TestWarmCacheEvictsAndRejectsByRetainedBytes(t *testing.T) {
	t.Parallel()
	cache := NewWarmCache[string, string](4, 100, 50)
	cache.Put("pods", weightedEntry("pods", 1, 30))

	evicted, admitted := cache.Put("nodes", weightedEntry("nodes", 1, 30))
	if !admitted || !reflect.DeepEqual(evicted, []string{"pods"}) {
		t.Fatalf("byte-budget insertion: admitted=%t evicted=%v", admitted, evicted)
	}
	if got := cache.ByteCount(); got != 30 {
		t.Fatalf("retained bytes = %d, want 30", got)
	}

	_, admitted = cache.Put("oversized", weightedEntry("oversized", 1, 51))
	if admitted {
		t.Fatal("entry larger than the byte budget was admitted")
	}
	if retained, ok := cache.Get("nodes"); !ok || retained.Value != "nodes" {
		t.Fatal("rejected byte-oversized entry disturbed useful data")
	}
}

func entry(value string, objects int) WarmEntry[string] {
	return weightedEntry(value, objects, int64(objects*10))
}

func weightedEntry(value string, objects int, bytes int64) WarmEntry[string] {
	return WarmEntry[string]{
		Value:            value,
		ObjectCount:      objects,
		ByteCount:        bytes,
		ResourceVersion:  "rv",
		LastSynchronized: time.Unix(1, 0),
		Complete:         true,
	}
}
