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
	key := resourceKey{authorityID: authority, version: "v1", resource: resourceName}
	entryStore := store.New()
	for index := range objectCount {
		object := &unstructured.Unstructured{}
		object.SetUID(types.UID(fmt.Sprintf("%s-%s-%d", authority, resourceName, index)))
		object.SetName(fmt.Sprintf("object-%d", index))
		entryStore.Upsert(object)
	}
	entryStore.SetResourceVersion("rv")
	entry := &resourceRuntime{
		key: key, store: entryStore, state: resourceIdle, accountingReady: true,
		subscribers: make(map[*Subscription]struct{}),
		dependents:  make(map[*Subscription]struct{}),
		lastStatus:  watcher.Status{ResourceVersion: "rv"},
	}
	runtime.mu.Lock()
	runtime.resources[key] = entry
	runtime.finalizeWarmLocked(entry)
	runtime.mu.Unlock()
	return entry
}
