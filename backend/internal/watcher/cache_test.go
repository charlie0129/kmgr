package watcher

import (
	"reflect"
	"testing"
	"time"
)

func TestWarmCacheEvictsLeastRecentlyUsedWithinBothBudgets(t *testing.T) {
	t.Parallel()
	cache := NewWarmCache[string, string](3, 5)
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
	cache := NewWarmCache[string, string](2, 3)
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
	cache := NewWarmCache[string, string](2, 10)
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
}

func entry(value string, objects int) WarmEntry[string] {
	return WarmEntry[string]{
		Value:            value,
		ObjectCount:      objects,
		ResourceVersion:  "rv",
		LastSynchronized: time.Unix(1, 0),
		Complete:         true,
	}
}
