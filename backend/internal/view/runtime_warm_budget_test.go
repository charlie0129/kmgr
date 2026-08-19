package view

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/store"
	"github.com/charlie0129/kmgr/backend/internal/systemmemory"
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

func TestWarmCacheTelemetryDistinguishesEvictionFromConsumptionAndClose(t *testing.T) {
	t.Parallel()
	runtime, err := NewRuntime(RuntimeConfig{
		Source:                      &fakeResourceSource{},
		WarmViewLimit:               3,
		WarmObjectLimit:             30,
		WarmByteLimit:               1 << 30,
		WarmViewLimitPerAuthority:   1,
		WarmObjectLimitPerAuthority: 10,
		WarmByteLimitPerAuthority:   1 << 30,
	})
	if err != nil {
		t.Fatal(err)
	}

	aPods := addWarmBudgetEntry(t, runtime, "cluster-a", "pods", 2)
	bPods := addWarmBudgetEntry(t, runtime, "cluster-b", "pods", 3)
	aNodes := addWarmBudgetEntry(t, runtime, "cluster-a", "nodes", 4)
	snapshot := runtime.WarmCacheTelemetrySnapshot()
	if snapshot.Global.RetainedViews != 2 ||
		snapshot.Global.RetainedObjects != 7 ||
		snapshot.Global.BudgetEvictions != 1 {
		t.Fatalf("global telemetry after authority eviction = %#v", snapshot.Global)
	}
	if got := snapshot.Authorities["cluster-a"]; got.RetainedViews != 1 ||
		got.RetainedObjects != 4 || got.BudgetEvictions != 1 {
		t.Fatalf("cluster-a telemetry = %#v", got)
	}
	if got := snapshot.Authorities["cluster-b"]; got.RetainedViews != 1 ||
		got.RetainedObjects != 3 || got.BudgetEvictions != 0 {
		t.Fatalf("cluster-b telemetry = %#v", got)
	}
	if snapshot.Global.RetainedBytes != uint64(runtime.warm.ByteCount()) ||
		snapshot.Authorities["cluster-a"].RetainedBytes !=
			uint64(runtime.warmByAuthority["cluster-a"].ByteCount()) {
		t.Fatal("telemetry did not report conservative retained-byte weights")
	}
	if runtime.resources[aPods.key] != nil ||
		runtime.resources[aNodes.key] != aNodes ||
		runtime.resources[bPods.key] != bPods {
		t.Fatal("telemetry fixture retained the wrong warm entries")
	}

	runtime.mu.Lock()
	if !runtime.removeWarmLocked(aNodes.key) {
		runtime.mu.Unlock()
		t.Fatal("normal warm-cache consumption did not remove cluster-a Nodes")
	}
	runtime.mu.Unlock()
	consumed := runtime.WarmCacheTelemetrySnapshot()
	if consumed.Global.RetainedViews != 1 ||
		consumed.Global.BudgetEvictions != 1 ||
		consumed.Authorities["cluster-a"].RetainedViews != 0 ||
		consumed.Authorities["cluster-a"].BudgetEvictions != 1 {
		t.Fatalf("normal consumption changed eviction accounting = %#v", consumed)
	}
	rejected := addWarmBudgetEntry(t, runtime, "cluster-c", "events", 11)
	afterRejection := runtime.WarmCacheTelemetrySnapshot()
	if runtime.resources[rejected.key] != nil ||
		afterRejection.Global.BudgetEvictions != consumed.Global.BudgetEvictions {
		t.Fatalf("oversized rejection counted as an eviction = %#v", afterRejection)
	}

	runtime.Close()
	closed := runtime.WarmCacheTelemetrySnapshot()
	if closed.Global.RetainedViews != 0 || closed.Global.RetainedObjects != 0 ||
		closed.Global.RetainedBytes != 0 || closed.Global.BudgetEvictions != 1 {
		t.Fatalf("closed global telemetry = %#v", closed.Global)
	}
	if closed.Authorities["cluster-a"].RetainedViews != 0 ||
		closed.Authorities["cluster-a"].BudgetEvictions != 1 {
		t.Fatalf("closed authority telemetry = %#v", closed.Authorities["cluster-a"])
	}
}

func TestWarmCacheTelemetryAttributesGlobalEvictionToRemovedAuthority(t *testing.T) {
	t.Parallel()
	runtime := newWarmBudgetRuntime(t, 2, 20, 2, 20)
	defer runtime.Close()
	addWarmBudgetEntry(t, runtime, "cluster-a", "pods", 1)
	addWarmBudgetEntry(t, runtime, "cluster-b", "pods", 1)
	addWarmBudgetEntry(t, runtime, "cluster-c", "pods", 1)

	snapshot := runtime.WarmCacheTelemetrySnapshot()
	if snapshot.Global.RetainedViews != 2 || snapshot.Global.BudgetEvictions != 1 {
		t.Fatalf("global telemetry = %#v", snapshot.Global)
	}
	if got := snapshot.Authorities["cluster-a"]; got.RetainedViews != 0 ||
		got.BudgetEvictions != 1 {
		t.Fatalf("evicted authority telemetry = %#v", got)
	}
	if snapshot.Authorities["cluster-b"].RetainedViews != 1 ||
		snapshot.Authorities["cluster-c"].RetainedViews != 1 {
		t.Fatalf("retained authority telemetry = %#v", snapshot.Authorities)
	}
}

func TestWarmCacheAuthorityRetirementPrunesHistoryAndRejectsLateAdmission(t *testing.T) {
	t.Parallel()
	active := make(map[string]bool)
	runtime, err := NewRuntime(RuntimeConfig{
		Source:                      &fakeResourceSource{},
		WarmViewLimit:               2,
		WarmObjectLimit:             20,
		WarmByteLimit:               1 << 30,
		WarmViewLimitPerAuthority:   1,
		WarmObjectLimitPerAuthority: 10,
		WarmByteLimitPerAuthority:   1 << 30,
		WarmCacheAuthorityActive: func(authorityID string) bool {
			return active[authorityID]
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	for index := range 64 {
		authorityID := fmt.Sprintf("retired-%d", index)
		active[authorityID] = true
		addWarmBudgetEntry(t, runtime, authorityID, "pods", 1)
		addWarmBudgetEntry(t, runtime, authorityID, "nodes", 1)
		before := runtime.WarmCacheTelemetrySnapshot()
		if before.Authorities[authorityID].BudgetEvictions != 1 {
			t.Fatalf("authority %q did not record its true budget eviction", authorityID)
		}

		active[authorityID] = false
		runtime.RetireWarmCacheAuthority(authorityID)
		after := runtime.WarmCacheTelemetrySnapshot()
		if _, exists := after.Authorities[authorityID]; exists {
			t.Fatalf("retired authority %q remained in telemetry", authorityID)
		}
		if _, exists := runtime.warmBudgetEvictionsByAuthority[authorityID]; exists {
			t.Fatalf("retired authority %q remained in eviction history", authorityID)
		}
		late := addWarmBudgetEntry(t, runtime, authorityID, "events", 1)
		if runtime.resources[late.key] != nil {
			t.Fatalf("retired authority %q re-entered the warm cache", authorityID)
		}
	}

	snapshot := runtime.WarmCacheTelemetrySnapshot()
	if len(snapshot.Authorities) != 0 || len(runtime.warmBudgetEvictionsByAuthority) != 0 ||
		snapshot.Global.RetainedViews != 0 {
		t.Fatalf("retired authority history remained after reopen cycle = %#v", snapshot)
	}
	if snapshot.Global.BudgetEvictions != 64 {
		t.Fatalf("global true-eviction history = %d, want 64", snapshot.Global.BudgetEvictions)
	}

	active["reopened"] = true
	addWarmBudgetEntry(t, runtime, "reopened", "pods", 1)
	reopened := runtime.WarmCacheTelemetrySnapshot()
	if reopened.Authorities["reopened"].RetainedViews != 1 || len(reopened.Authorities) != 1 {
		t.Fatalf("reopened authority telemetry = %#v", reopened.Authorities)
	}
}

func TestWarmCacheObserverPublishesInitialChangesAndFinalZeroOutsideCacheLocks(t *testing.T) {
	t.Parallel()
	var mu sync.Mutex
	var snapshots []WarmCacheTelemetry
	updates := make(chan struct{}, 8)
	observer := func(snapshot WarmCacheTelemetry) {
		mu.Lock()
		snapshots = append(snapshots, snapshot)
		mu.Unlock()
		updates <- struct{}{}
	}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:                      &fakeResourceSource{},
		WarmViewLimit:               2,
		WarmObjectLimit:             20,
		WarmByteLimit:               1 << 30,
		WarmViewLimitPerAuthority:   2,
		WarmObjectLimitPerAuthority: 20,
		WarmByteLimitPerAuthority:   1 << 30,
		WarmCacheObserver:           observer,
	})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-updates:
	case <-time.After(time.Second):
		t.Fatal("initial cache budgets were not published")
	}
	addWarmBudgetEntry(t, runtime, "cluster", "pods", 2)
	select {
	case <-updates:
	case <-time.After(time.Second):
		t.Fatal("warm-cache admission did not wake observer")
	}
	runtime.Close()

	mu.Lock()
	defer mu.Unlock()
	if len(snapshots) < 3 {
		t.Fatalf("observer snapshots = %d, want initial/change/close", len(snapshots))
	}
	initial := snapshots[0]
	final := snapshots[len(snapshots)-1]
	if initial.Global.ViewLimit != 2 || initial.Global.RetainedViews != 0 {
		t.Fatalf("initial telemetry = %#v", initial)
	}
	if final.Global.RetainedViews != 0 || final.Global.RetainedObjects != 0 ||
		final.Global.RetainedBytes != 0 {
		t.Fatalf("final telemetry = %#v", final)
	}
}

func TestRuntimeWarmByteDefaultsAndNegativeValidation(t *testing.T) {
	t.Parallel()
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{}})
	if err != nil {
		t.Fatal(err)
	}
	total, err := systemmemory.Bytes()
	if err != nil {
		t.Fatal(err)
	}
	wantBytes, err := systemmemory.PercentageLimit(total, DefaultWarmMemoryPercent)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.warmByteLimit != wantBytes ||
		runtime.warmByteLimitPerAuthority != wantBytes {
		t.Fatalf(
			"warm byte defaults = %d/%d, want %d/%d (20%% of physical memory)",
			runtime.warmByteLimit, runtime.warmByteLimitPerAuthority,
			wantBytes, wantBytes,
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
		key: key, store: entryStore, state: resourceIdle, snapshotComplete: true,
		subscribers: make(map[*Subscription]struct{}),
		lastStatus:  watcher.Status{ResourceVersion: "rv"},
	}
}

func admitWarmBudgetEntry(runtime *Runtime, entry *resourceRuntime) {
	runtime.mu.Lock()
	runtime.resources[entry.key] = entry
	runtime.finalizeWarmLocked(entry)
	runtime.mu.Unlock()
}
