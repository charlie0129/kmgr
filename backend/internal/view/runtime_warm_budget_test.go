package view

import (
	"fmt"
	"testing"

	"github.com/charlie0129/kmgr/backend/internal/store"
	"github.com/charlie0129/kmgr/backend/internal/watcher"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
)

func TestWarmCacheEnforcesPerAuthorityBudgetsWithoutEvictingAnotherCluster(t *testing.T) {
	t.Parallel()
	runtime := newWarmBudgetRuntime(t, 8, 9, 2, 6)
	defer runtime.Close()

	aPods := addWarmBudgetEntry(t, runtime, "cluster-a", "pods", 3)
	aNodes := addWarmBudgetEntry(t, runtime, "cluster-a", "nodes", 3)
	bPods := addWarmBudgetEntry(t, runtime, "cluster-b", "pods", 3)

	// Touch both cluster-a entries after cluster-b. Cluster-b is now oldest in
	// the global LRU, while Nodes remains oldest inside cluster-a. Local
	// eviction must be mirrored before global admission or cluster-b would be
	// evicted unnecessarily at the full nine-object global budget.
	runtime.mu.Lock()
	if _, ok := runtime.getWarmLocked(aNodes.key); !ok {
		runtime.mu.Unlock()
		t.Fatal("cluster-a Nodes cache was not admitted")
	}
	if _, ok := runtime.getWarmLocked(aPods.key); !ok {
		runtime.mu.Unlock()
		t.Fatal("cluster-a Pods cache was not admitted")
	}
	runtime.mu.Unlock()
	aServices := addWarmBudgetEntry(t, runtime, "cluster-a", "services", 3)

	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	if runtime.resources[aNodes.key] != nil {
		t.Fatal("cluster-a exceeded its own entry/object budget without local eviction")
	}
	if runtime.resources[aPods.key] != aPods || runtime.resources[aServices.key] != aServices {
		t.Fatal("cluster-a did not retain its two most recently used entries")
	}
	if runtime.resources[bPods.key] != bPods {
		t.Fatal("cluster-a pressure evicted cluster-b's warm entry")
	}
	if got := runtime.warm.Len(); got != 3 {
		t.Fatalf("global warm entries = %d, want 3", got)
	}
	if got := runtime.warm.ObjectCount(); got != 9 {
		t.Fatalf("global warm objects = %d, want 9", got)
	}
	if got := runtime.warmByAuthority["cluster-a"].Len(); got != 2 {
		t.Fatalf("cluster-a warm entries = %d, want 2", got)
	}
	if got := runtime.warmByAuthority["cluster-a"].ObjectCount(); got != 6 {
		t.Fatalf("cluster-a warm objects = %d, want 6", got)
	}
	if got := runtime.warmByAuthority["cluster-b"].Len(); got != 1 {
		t.Fatalf("cluster-b warm entries = %d, want 1", got)
	}
}

func TestWarmCacheGlobalEvictionIsRemovedFromAuthorityLRU(t *testing.T) {
	t.Parallel()
	runtime := newWarmBudgetRuntime(t, 2, 20, 2, 20)
	defer runtime.Close()

	aPods := addWarmBudgetEntry(t, runtime, "cluster-a", "pods", 1)
	bPods := addWarmBudgetEntry(t, runtime, "cluster-b", "pods", 1)
	cPods := addWarmBudgetEntry(t, runtime, "cluster-c", "pods", 1)

	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	if runtime.resources[aPods.key] != nil {
		t.Fatal("global LRU did not evict its least recently used entry")
	}
	if runtime.resources[bPods.key] != bPods || runtime.resources[cPods.key] != cPods {
		t.Fatal("global LRU evicted a newer authority entry")
	}
	if _, exists := runtime.warmByAuthority["cluster-a"]; exists {
		t.Fatal("global eviction left a ghost in cluster-a's authority cache")
	}
	if got := runtime.warm.Len(); got != 2 {
		t.Fatalf("global warm entries = %d, want 2", got)
	}
}

func TestWarmCacheRejectsEntryLargerThanAuthorityBudgetWithoutDisturbingPeers(t *testing.T) {
	t.Parallel()
	runtime := newWarmBudgetRuntime(t, 8, 40, 4, 3)
	defer runtime.Close()

	aPods := addWarmBudgetEntry(t, runtime, "cluster-a", "pods", 2)
	bPods := addWarmBudgetEntry(t, runtime, "cluster-b", "pods", 2)
	aHuge := addWarmBudgetEntry(t, runtime, "cluster-a", "events", 4)

	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	if runtime.resources[aHuge.key] != nil {
		t.Fatal("oversized authority entry remained retained outside the warm cache")
	}
	if runtime.resources[aPods.key] != aPods || runtime.resources[bPods.key] != bPods {
		t.Fatal("rejected entry disturbed useful warm data")
	}
	if got := runtime.warm.Len(); got != 2 {
		t.Fatalf("global warm entries after rejection = %d, want 2", got)
	}
}

func TestWarmCacheRejectsLargePayloadByByteBudgetWithoutDisturbingPeers(t *testing.T) {
	t.Parallel()
	small := newWarmBudgetEntry("cluster-a", "pods", "small")
	large := newWarmBudgetEntry("cluster-a", "configmaps", string(make([]byte, 64<<10)))
	smallBytes := small.store.RetainedBytes()
	largeBytes := large.store.RetainedBytes()
	if largeBytes <= smallBytes {
		t.Fatalf("large estimate = %d, small estimate = %d", largeBytes, smallBytes)
	}
	byteLimit := smallBytes + (largeBytes-smallBytes)/2

	runtime, err := NewRuntime(RuntimeConfig{
		Source:                      &fakeResourceSource{},
		WarmViewLimit:               8,
		WarmObjectLimit:             100,
		WarmByteLimit:               byteLimit,
		WarmViewLimitPerAuthority:   4,
		WarmObjectLimitPerAuthority: 100,
		WarmByteLimitPerAuthority:   byteLimit,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	admitWarmBudgetEntry(runtime, small)
	admitWarmBudgetEntry(runtime, large)

	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	if runtime.resources[small.key] != small {
		t.Fatal("byte-oversized entry disturbed useful warm data")
	}
	if runtime.resources[large.key] != nil {
		t.Fatal("entry larger than the retained-byte budget remained cached")
	}
	if got := runtime.warm.ByteCount(); got != smallBytes {
		t.Fatalf("global retained bytes = %d, want %d", got, smallBytes)
	}
	if got := runtime.warmByAuthority["cluster-a"].ByteCount(); got != smallBytes {
		t.Fatalf("authority retained bytes = %d, want %d", got, smallBytes)
	}
}

func TestWarmCacheEnforcesPerAuthorityByteBudgetWithoutEvictingAnotherCluster(t *testing.T) {
	t.Parallel()
	aPods := newWarmBudgetEntry("cluster-a", "pods", "")
	aNodes := newWarmBudgetEntry("cluster-a", "nodes", "")
	bPods := newWarmBudgetEntry("cluster-b", "pods", "")
	aPodsBytes := aPods.store.RetainedBytes()
	aNodesBytes := aNodes.store.RetainedBytes()
	bPodsBytes := bPods.store.RetainedBytes()
	authorityLimit := max(aPodsBytes, aNodesBytes)
	globalLimit := aPodsBytes + aNodesBytes + bPodsBytes

	runtime, err := NewRuntime(RuntimeConfig{
		Source:                      &fakeResourceSource{},
		WarmViewLimit:               8,
		WarmObjectLimit:             100,
		WarmByteLimit:               globalLimit,
		WarmViewLimitPerAuthority:   4,
		WarmObjectLimitPerAuthority: 100,
		WarmByteLimitPerAuthority:   authorityLimit,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	admitWarmBudgetEntry(runtime, aPods)
	admitWarmBudgetEntry(runtime, bPods)
	admitWarmBudgetEntry(runtime, aNodes)

	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	if runtime.resources[aPods.key] != nil {
		t.Fatal("authority byte pressure did not evict its least recently used entry")
	}
	if runtime.resources[aNodes.key] != aNodes || runtime.resources[bPods.key] != bPods {
		t.Fatal("authority byte pressure evicted a newer or different-cluster entry")
	}
	if got := runtime.warm.ByteCount(); got != aNodesBytes+bPodsBytes {
		t.Fatalf("global retained bytes = %d, want %d", got, aNodesBytes+bPodsBytes)
	}
	if got := runtime.warmByAuthority["cluster-a"].ByteCount(); got != aNodesBytes {
		t.Fatalf("cluster-a retained bytes = %d, want %d", got, aNodesBytes)
	}
}

func TestWarmCacheGlobalByteEvictionIsRemovedFromAuthorityLRU(t *testing.T) {
	t.Parallel()
	aPods := newWarmBudgetEntry("cluster-a", "pods", "")
	bPods := newWarmBudgetEntry("cluster-b", "pods", "")
	cPods := newWarmBudgetEntry("cluster-c", "pods", "")
	entryBytes := aPods.store.RetainedBytes()
	if bPods.store.RetainedBytes() != entryBytes || cPods.store.RetainedBytes() != entryBytes {
		t.Fatal("equal-shaped byte fixtures have different weights")
	}

	runtime, err := NewRuntime(RuntimeConfig{
		Source:                      &fakeResourceSource{},
		WarmViewLimit:               8,
		WarmObjectLimit:             100,
		WarmByteLimit:               2 * entryBytes,
		WarmViewLimitPerAuthority:   4,
		WarmObjectLimitPerAuthority: 100,
		WarmByteLimitPerAuthority:   2 * entryBytes,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	admitWarmBudgetEntry(runtime, aPods)
	admitWarmBudgetEntry(runtime, bPods)
	admitWarmBudgetEntry(runtime, cPods)

	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	if runtime.resources[aPods.key] != nil {
		t.Fatal("global byte LRU did not evict its oldest entry")
	}
	if runtime.resources[bPods.key] != bPods || runtime.resources[cPods.key] != cPods {
		t.Fatal("global byte LRU evicted a newer entry")
	}
	if _, exists := runtime.warmByAuthority["cluster-a"]; exists {
		t.Fatal("global byte eviction left an authority-cache ghost")
	}
}

func TestRuntimeWarmByteDefaultsAndNegativeValidation(t *testing.T) {
	t.Parallel()
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{}})
	if err != nil {
		t.Fatal(err)
	}
	if runtime.warmByteLimit != DefaultWarmByteLimit ||
		runtime.warmByteLimitPerAuthority != DefaultWarmByteLimitPerAuthority {
		t.Fatalf(
			"warm byte defaults = %d/%d, want %d/%d",
			runtime.warmByteLimit, runtime.warmByteLimitPerAuthority,
			DefaultWarmByteLimit, DefaultWarmByteLimitPerAuthority,
		)
	}
	runtime.Close()

	for _, config := range []RuntimeConfig{
		{Source: &fakeResourceSource{}, WarmByteLimit: -1},
		{Source: &fakeResourceSource{}, WarmByteLimitPerAuthority: -1},
	} {
		if invalid, err := NewRuntime(config); err == nil {
			invalid.Close()
			t.Fatal("negative warm byte limit was accepted")
		}
	}
}

func newWarmBudgetRuntime(
	t *testing.T,
	globalViews, globalObjects, authorityViews, authorityObjects int,
) *Runtime {
	t.Helper()
	runtime, err := NewRuntime(RuntimeConfig{
		Source:                      &fakeResourceSource{},
		WarmViewLimit:               globalViews,
		WarmObjectLimit:             globalObjects,
		WarmViewLimitPerAuthority:   authorityViews,
		WarmObjectLimitPerAuthority: authorityObjects,
	})
	if err != nil {
		t.Fatal(err)
	}
	return runtime
}

func addWarmBudgetEntry(
	t *testing.T,
	runtime *Runtime,
	authority, resourceName string,
	objectCount int,
) *resourceRuntime {
	t.Helper()
	entry := newWarmBudgetEntry(authority, resourceName, "")
	for index := range objectCount {
		if index == 0 {
			continue
		}
		object := &unstructured.Unstructured{}
		object.SetUID(types.UID(fmt.Sprintf("%s-%s-%d", authority, resourceName, index)))
		object.SetName(fmt.Sprintf("object-%d", index))
		entry.store.Upsert(object)
	}
	admitWarmBudgetEntry(runtime, entry)
	return entry
}

func newWarmBudgetEntry(authority, resourceName, payload string) *resourceRuntime {
	key := resourceKey{authorityID: authority, version: "v1", resource: resourceName}
	entryStore := store.New()
	object := &unstructured.Unstructured{Object: map[string]any{
		"metadata": map[string]any{
			"uid":  fmt.Sprintf("%s-%s-0", authority, resourceName),
			"name": "object-0",
		},
	}}
	if payload != "" {
		object.Object["data"] = map[string]any{"payload": payload}
	}
	entryStore.Upsert(object)
	entryStore.SetResourceVersion("rv")
	return &resourceRuntime{
		key: key, store: entryStore, state: resourceIdle, accountingReady: true,
		subscribers: make(map[*Subscription]struct{}),
		dependents:  make(map[*Subscription]struct{}),
		lastStatus:  watcher.Status{ResourceVersion: "rv"},
	}
}

func admitWarmBudgetEntry(runtime *Runtime, entry *resourceRuntime) {
	runtime.mu.Lock()
	runtime.resources[entry.key] = entry
	runtime.finalizeWarmLocked(entry)
	runtime.mu.Unlock()
}
