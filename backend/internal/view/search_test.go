package view

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/metadata"

	"github.com/charlie0129/kmgr/backend/internal/store"
	"github.com/charlie0129/kmgr/backend/internal/watcher"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
)

func TestSearchRankingOrder(t *testing.T) {
	t.Parallel()
	objects := []*unstructured.Unstructured{
		pod("substring", "team", "my-api-copy", "Running", 0, nil, time.Time{}),
		pod("prefix", "team", "api-worker", "Running", 0, nil, time.Time{}),
		pod("exact", "team", "api", "Running", 0, nil, time.Time{}),
	}
	results := rankSearchObjects(SearchQuery{
		SessionID: "session", Resource: ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{All: true}, Query: "api",
	}, objects, 10, true)
	got := make([]string, 0, len(results))
	for _, result := range results {
		got = append(got, result.GetIdentity().GetUid())
	}
	if !slices.Equal(got, []string{"exact", "prefix", "substring"}) {
		t.Fatalf("ranking = %v", got)
	}
}

func TestCachedRootSearchUsesOnlyCurrentAuthorityWithoutOpeningResources(t *testing.T) {
	t.Parallel()
	source := &fakeResourceSource{
		authority: "unused", client: newSearchClient(),
		sessions: map[string]string{"session-a": "authority-a", "session-b": "authority-b"},
	}
	runtime, err := NewRuntime(RuntimeConfig{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	runtime.resources[resourceKey{authorityID: "authority-a", version: "v1", resource: "pods"}] = cachedSearchRuntime(
		pod("a", "team", "api-a", "Running", 0, nil, time.Time{}),
	)
	runtime.resources[resourceKey{authorityID: "authority-b", version: "v1", resource: "pods"}] = cachedSearchRuntime(
		pod("b", "team", "api-b", "Running", 0, nil, time.Time{}),
	)

	result, err := runtime.SearchCached(context.Background(), CachedSearchQuery{
		SessionID: "session-a", NamespaceScope: NamespaceScope{All: true},
		Query: "api", ResultLimit: 10, ExaminationLimit: 100,
	})
	if err != nil {
		t.Fatal(err)
	}
	if source.opens.Load() != 0 {
		t.Fatalf("cache-only search opened %d resources", source.opens.Load())
	}
	if len(result.Results) != 1 || result.Results[0].GetIdentity().GetUid() != "a" ||
		result.Results[0].GetIdentity().GetClusterSessionId() != "session-a" {
		t.Fatalf("authority-isolated results = %#v", result.Results)
	}
}

func TestCachedRootSearchIncludesKindMatchedObjectsWithoutNameMatch(t *testing.T) {
	t.Parallel()
	source := &fakeResourceSource{authority: "authority", client: newSearchClient()}
	runtime, err := NewRuntime(RuntimeConfig{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	runtime.resources[resourceKey{authorityID: "authority", version: "v1", resource: "pods"}] = cachedSearchRuntime(
		pod("pod-api", "team", "api", "Running", 0, nil, time.Time{}),
	)
	runtime.resources[resourceKey{authorityID: "authority", group: "example.io", version: "v1", resource: "widgets"}] = cachedSearchRuntime(
		pod("widget-worker", "team", "worker", "Running", 0, nil, time.Time{}),
	)

	result, err := runtime.SearchCached(context.Background(), CachedSearchQuery{
		SessionID: "session", NamespaceScope: NamespaceScope{All: true},
		Query: "pods", ResultLimit: 10, ExaminationLimit: 100,
		ResourceFilters: []ResourceType{{
			Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true,
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if source.opens.Load() != 0 {
		t.Fatalf("kind cache search opened %d resources", source.opens.Load())
	}
	if len(result.Results) != 1 || result.Results[0].GetIdentity().GetUid() != "pod-api" ||
		result.Results[0].GetDisplayText() != "api" || result.Results[0].GetDetailText() != "team · Pod" ||
		result.Results[0].GetRank() != 600 {
		t.Fatalf("kind-matched cached results = %#v", result.Results)
	}
}

func TestCachedRootSearchPrioritizesKindMatchedStoresBeforeExaminationLimit(t *testing.T) {
	t.Parallel()
	source := &fakeResourceSource{authority: "authority", client: newSearchClient()}
	runtime, err := NewRuntime(RuntimeConfig{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	// configmaps sorts before pods by the ordinary deterministic key. The
	// matched Pod store must still consume the first bounded examination slot.
	runtime.resources[resourceKey{authorityID: "authority", version: "v1", resource: "configmaps"}] = cachedSearchRuntime(
		pod("config", "team", "settings", "", 0, nil, time.Time{}),
	)
	runtime.resources[resourceKey{authorityID: "authority", version: "v1", resource: "pods"}] = cachedSearchRuntime(
		pod("pod-api", "team", "api", "Running", 0, nil, time.Time{}),
	)

	result, err := runtime.SearchCached(context.Background(), CachedSearchQuery{
		SessionID: "session", NamespaceScope: NamespaceScope{All: true},
		Query: "pods", ResultLimit: 10, ExaminationLimit: 1,
		ResourceFilters: []ResourceType{{
			Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true,
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !result.Truncated || result.Examined != 1 || len(result.Results) != 1 ||
		result.Results[0].GetIdentity().GetUid() != "pod-api" {
		t.Fatalf("prioritized kind result = %#v", result)
	}
}

func TestCachedRootSearchDoesNotTrustFilterNamespaceScopeBit(t *testing.T) {
	t.Parallel()
	source := &fakeResourceSource{authority: "authority", client: newSearchClient()}
	runtime, err := NewRuntime(RuntimeConfig{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	runtime.resources[resourceKey{authorityID: "authority", version: "v1", resource: "pods"}] = cachedSearchRuntime(
		pod("other-pod", "other", "api", "Running", 0, nil, time.Time{}),
	)

	result, err := runtime.SearchCached(context.Background(), CachedSearchQuery{
		SessionID: "session", NamespaceScope: NamespaceScope{Namespaces: []string{"team"}},
		Query: "pods", ResultLimit: 10, ExaminationLimit: 100,
		ResourceFilters: []ResourceType{{
			Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: false,
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Results) != 0 {
		t.Fatalf("malformed scope bit leaked out-of-scope Pod: %#v", result.Results)
	}
}

func TestCachedRootSearchValidatesResourceFilters(t *testing.T) {
	t.Parallel()
	source := &fakeResourceSource{authority: "authority", client: newSearchClient()}
	runtime, err := NewRuntime(RuntimeConfig{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	invalid := []CachedSearchQuery{
		{
			SessionID: "session", Query: "pods",
			ResourceFilters: []ResourceType{{Resource: "pods"}},
		},
		{
			SessionID: "session", Query: "pods",
			ResourceFilters: make([]ResourceType, MaximumCacheResourceFilters+1),
		},
	}
	for _, query := range invalid {
		if _, err := runtime.SearchCached(context.Background(), query); !errors.Is(err, ErrInvalidView) {
			t.Fatalf("invalid resource filters error = %v", err)
		}
	}
}

func TestCachedRootSearchDeduplicatesFullGVRAndUID(t *testing.T) {
	t.Parallel()
	source := &fakeResourceSource{authority: "authority", client: newSearchClient()}
	runtime, err := NewRuntime(RuntimeConfig{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	shared := pod("shared", "team", "api", "Running", 0, nil, time.Time{})
	runtime.resources[resourceKey{authorityID: "authority", version: "v1", resource: "pods", labels: "app=api"}] = cachedSearchRuntime(shared)
	runtime.resources[resourceKey{authorityID: "authority", version: "v1", resource: "pods", fields: "status.phase=Running"}] = cachedSearchRuntime(shared)
	runtime.resources[resourceKey{authorityID: "authority", group: "example.io", version: "v1", resource: "widgets"}] = cachedSearchRuntime(shared)

	result, err := runtime.SearchCached(context.Background(), CachedSearchQuery{
		SessionID: "session", NamespaceScope: NamespaceScope{All: true},
		Query: "api", ResultLimit: 10, ExaminationLimit: 100,
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Examined != 2 || len(result.Results) != 2 {
		t.Fatalf("full-GVR dedup result = %#v", result)
	}
	got := []string{
		result.Results[0].GetIdentity().GetGroup() + "/" + result.Results[0].GetIdentity().GetResource(),
		result.Results[1].GetIdentity().GetGroup() + "/" + result.Results[1].GetIdentity().GetResource(),
	}
	slices.Sort(got)
	if !slices.Equal(got, []string{"/pods", "example.io/widgets"}) {
		t.Fatalf("GVR identities = %v", got)
	}
}

func TestCachedRootSearchBoundsExaminationAndRanking(t *testing.T) {
	t.Parallel()
	source := &fakeResourceSource{authority: "authority", client: newSearchClient()}
	runtime, err := NewRuntime(RuntimeConfig{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	objects := make([]*unstructured.Unstructured, 0, 200)
	for index := range 200 {
		objects = append(objects, pod(
			fmt.Sprintf("uid-%03d", index), "team", fmt.Sprintf("api-%03d", index),
			"Running", 0, nil, time.Time{},
		))
	}
	runtime.resources[resourceKey{authorityID: "authority", version: "v1", resource: "pods"}] = cachedSearchRuntime(objects...)

	result, err := runtime.SearchCached(context.Background(), CachedSearchQuery{
		SessionID: "session", NamespaceScope: NamespaceScope{All: true},
		Query: "api", ResultLimit: 5, ExaminationLimit: 40,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !result.Truncated || result.Examined != 40 || len(result.Results) != 5 {
		t.Fatalf("bounded cached search = %#v", result)
	}
	if source.opens.Load() != 0 {
		t.Fatalf("bounded cached search opened %d resources", source.opens.Load())
	}
}

func TestCachedRootSearchHonorsNamespaceScopeAndRankOrder(t *testing.T) {
	t.Parallel()
	source := &fakeResourceSource{authority: "authority", client: newSearchClient()}
	runtime, err := NewRuntime(RuntimeConfig{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	runtime.resources[resourceKey{authorityID: "authority", version: "v1", resource: "pods"}] = cachedSearchRuntime(
		pod("substring", "team", "my-api-copy", "Running", 0, nil, time.Time{}),
		pod("prefix", "team", "api-worker", "Running", 0, nil, time.Time{}),
		pod("exact", "team", "api", "Running", 0, nil, time.Time{}),
		pod("other", "other", "api", "Running", 0, nil, time.Time{}),
	)

	result, err := runtime.SearchCached(context.Background(), CachedSearchQuery{
		SessionID: "session", NamespaceScope: NamespaceScope{Namespaces: []string{"team"}},
		Query: "api", ResultLimit: 10, ExaminationLimit: 100,
	})
	if err != nil {
		t.Fatal(err)
	}
	got := make([]string, 0, len(result.Results))
	for _, value := range result.Results {
		got = append(got, value.GetIdentity().GetUid())
	}
	if !slices.Equal(got, []string{"exact", "prefix", "substring"}) {
		t.Fatalf("scoped rank order = %v", got)
	}
}

func TestSearchCachedObjectsGRPCMapsEnvelopeResultsAndBounds(t *testing.T) {
	t.Parallel()
	source := &fakeResourceSource{authority: "authority", client: newSearchClient()}
	runtime, err := NewRuntime(RuntimeConfig{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	runtime.resources[resourceKey{authorityID: "authority", version: "v1", resource: "pods"}] = cachedSearchRuntime(
		pod("exact", "team", "api", "Running", 0, nil, time.Time{}),
		pod("prefix", "team", "api-worker", "Running", 0, nil, time.Time{}),
	)
	service, err := NewGRPCService(runtime)
	if err != nil {
		t.Fatal(err)
	}

	response, err := service.SearchCachedObjects(context.Background(), &kmgrv1.SearchCachedObjectsRequest{
		Context:          &kmgrv1.RequestContext{RequestId: "cached-request", ClusterSessionId: "session"},
		NamespaceScope:   &kmgrv1.NamespaceScope{Namespaces: []string{"team"}},
		Query:            "api",
		ResultLimit:      1,
		ExaminationLimit: 1,
		ResourceFilters: []*kmgrv1.ResourceType{{
			Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true,
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if response.GetRequestId() != "cached-request" || response.GetObjectsExamined() != 1 ||
		!response.GetExaminationTruncated() || len(response.GetResults()) != 1 || response.GetError() != nil {
		t.Fatalf("cache search response = %#v", response)
	}
	if source.opens.Load() != 0 {
		t.Fatalf("gRPC cached search opened %d resources", source.opens.Load())
	}
}

func TestSearchCachedObjectsGRPCReturnsStructuredSessionError(t *testing.T) {
	t.Parallel()
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{
		sessions: map[string]string{"known": "authority"}, client: newSearchClient(),
	}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	service, err := NewGRPCService(runtime)
	if err != nil {
		t.Fatal(err)
	}

	response, err := service.SearchCachedObjects(context.Background(), &kmgrv1.SearchCachedObjectsRequest{
		Context: &kmgrv1.RequestContext{RequestId: "unknown-request", ClusterSessionId: "unknown"},
		Query:   "api",
	})
	if err != nil {
		t.Fatal(err)
	}
	if response.GetRequestId() != "unknown-request" ||
		response.GetError().GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND ||
		response.GetError().GetReason() != "ClusterSessionNotFound" {
		t.Fatalf("structured session error = %#v", response)
	}
}

func TestSearchCachedObjectsGRPCRejectsInvalidEnvelope(t *testing.T) {
	t.Parallel()
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "authority", client: newSearchClient()}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	service, err := NewGRPCService(runtime)
	if err != nil {
		t.Fatal(err)
	}

	_, err = service.SearchCachedObjects(context.Background(), &kmgrv1.SearchCachedObjectsRequest{
		Context: &kmgrv1.RequestContext{RequestId: "request", ClusterSessionId: "session"},
	})
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("invalid envelope error = %v", err)
	}
}

func cachedSearchRuntime(objects ...*unstructured.Unstructured) *resourceRuntime {
	entry := &resourceRuntime{store: store.New()}
	for _, object := range objects {
		entry.store.Upsert(object)
	}
	return entry
}

func TestCachedSearchDoesNotWakeStoppedWatcher(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{listPage("rv-1", "", pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{}))}
	source := &fakeResourceSource{authority: "cluster-a", client: client}
	runtime, err := NewRuntime(RuntimeConfig{Source: source, ReleaseDelay: 5 * time.Millisecond, PipelineTimeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	subscription, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, subscription, "uid-a")
	subscription.Close()
	eventually(t, time.Second, func() bool { return client.lastWatchStopped() })
	watches := client.watchCalls.Load()

	var batches []SearchBatch
	err = runtime.Search(context.Background(), SearchQuery{
		SessionID: "session", Resource: ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{All: true}, Query: "api", ResultLimit: 10,
	}, func(batch SearchBatch) error {
		batches = append(batches, batch)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if client.watchCalls.Load() != watches {
		t.Fatalf("cached search started a watcher: before=%d after=%d", watches, client.watchCalls.Load())
	}
	if len(batches) == 0 || len(batches[0].Results) != 1 || !batches[0].Results[0].GetStale() {
		t.Fatalf("cached results = %#v", batches)
	}
}

func TestPartialSearchUsesPaginatedListWithoutWatch(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{
		listPage("rv-1", "next", pod("one", "ns", "api-one", "Running", 0, nil, time.Time{})),
		listPage("rv-1", "", pod("two", "ns", "api-two", "Running", 0, nil, time.Time{})),
	}
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	var progress []uint64
	err = runtime.Search(context.Background(), SearchQuery{
		SessionID: "session", Resource: ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{All: true}, Query: "api", AllowPaginatedList: true,
	}, func(batch SearchBatch) error {
		progress = append(progress, batch.Examined)
		if batch.Complete && (!batch.Reusable || len(batch.Results) != 2) {
			t.Fatalf("final batch = %#v", batch)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(progress, []uint64{1, 2}) {
		t.Fatalf("progress = %v", progress)
	}
	if client.watchCalls.Load() != 0 {
		t.Fatalf("transient search started %d watches", client.watchCalls.Load())
	}
}

func TestCompletedPaginatedSearchSeedsViewAndResumesWatch(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{
		listPage("rv-final", "next", pod("one", "ns", "api-one", "Running", 0, nil, time.Time{})),
		listPage("rv-final", "", pod("two", "ns", "api-two", "Running", 0, nil, time.Time{})),
	}
	source := &fakeResourceSource{authority: "cluster", client: client}
	runtime, err := NewRuntime(RuntimeConfig{Source: source, PipelineTimeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	var final SearchBatch
	err = runtime.Search(context.Background(), SearchQuery{
		SessionID:      "palette-session",
		Resource:       ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{Namespaces: []string{"ns"}},
		Query:          "api", AllowPaginatedList: true,
	}, func(batch SearchBatch) error {
		final = batch
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !final.Complete || !final.Reusable || client.listCalls.Load() != 2 || client.watchCalls.Load() != 0 {
		t.Fatalf("search final=%#v LIST=%d WATCH=%d", final, client.listCalls.Load(), client.watchCalls.Load())
	}

	// A different workspace session may consume the handoff when its backend
	// authority, GVR, namespace scope, and selectors are identical.
	subscription, err := runtime.Open(openView("view-session", "pods", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	events, err := subscription.Next(ctx)
	cancel()
	if err != nil {
		t.Fatal(err)
	}
	var snapshotUIDs []string
	for _, event := range events {
		for _, row := range event.GetSnapshot().GetRows() {
			snapshotUIDs = append(snapshotUIDs, row.GetIdentity().GetUid())
		}
	}
	if !slices.Contains(snapshotUIDs, "one") || !slices.Contains(snapshotUIDs, "two") {
		t.Fatalf("initial snapshot UIDs = %v", snapshotUIDs)
	}
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })
	eventually(t, time.Second, func() bool { return client.lastWatchResourceVersion() == "rv-final" })
	if client.listCalls.Load() != 2 {
		t.Fatalf("view repeated LIST; calls = %d", client.listCalls.Load())
	}
	if got := client.lastWatchResourceVersion(); got != "rv-final" {
		t.Fatalf("watch resourceVersion = %q, want rv-final", got)
	}
}

func TestCompletedPaginatedSearchSnapshotServesLaterQueryWithoutBeingConsumed(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{listPage(
		"rv-search", "",
		pod("alpha", "ns", "alpha", "Running", 0, nil, time.Time{}),
		pod("beta", "ns", "beta", "Running", 0, nil, time.Time{}),
	)}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster", client: client},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first := inProgressSearchQuery("alp")
	if err := runtime.Search(context.Background(), first, func(SearchBatch) error { return nil }); err != nil {
		t.Fatal(err)
	}
	if calls := client.listCalls.Load(); calls != 1 {
		t.Fatalf("first search LIST calls = %d, want 1", calls)
	}

	var readyCalls atomic.Int64
	second := inProgressSearchQuery("bet")
	second.sourceReady = func() { readyCalls.Add(1) }
	var final SearchBatch
	if err := runtime.Search(context.Background(), second, func(batch SearchBatch) error {
		final = batch
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if calls := client.listCalls.Load(); calls != 1 {
		t.Fatalf("snapshot-backed search repeated LIST; calls = %d", calls)
	}
	if readyCalls.Load() != 1 {
		t.Fatalf("source-ready calls = %d, want 1", readyCalls.Load())
	}
	if !final.Complete || !final.Reusable || final.Examined != 2 || len(final.Results) != 1 {
		t.Fatalf("snapshot-backed final = %#v", final)
	}
	if result := final.Results[0]; result.GetIdentity().GetName() != "beta" || !result.GetStale() {
		t.Fatalf("snapshot-backed result = %#v", result)
	}

	view, err := runtime.Open(openView("view-session", "pods", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer view.Close()
	waitForSnapshotUID(t, view, "beta")
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })
	eventually(t, time.Second, func() bool { return client.lastWatchResourceVersion() == "rv-search" })
	if calls := client.listCalls.Load(); calls != 1 {
		t.Fatalf("snapshot-backed search consumed view handoff; LIST calls = %d", calls)
	}
	if got := client.lastWatchResourceVersion(); got != "rv-search" {
		t.Fatalf("watch resourceVersion = %q, want rv-search", got)
	}
}

func TestMetadataSearchSnapshotCannotSeedFullObjectView(t *testing.T) {
	t.Parallel()
	dynamicClient := newSearchClient()
	dynamicClient.pages = []*unstructured.UnstructuredList{listPage(
		"full-rv", "", pod("beta-full", "ns", "beta", "Running", 0, nil, time.Time{}),
	)}
	metadataClient := &metadataSearchTestClient{page: &metav1.PartialObjectMetadataList{
		ListMeta: metav1.ListMeta{ResourceVersion: "metadata-rv"},
		Items: []metav1.PartialObjectMetadata{
			{ObjectMeta: metav1.ObjectMeta{Name: "alpha", Namespace: "ns", UID: "alpha"}},
			{ObjectMeta: metav1.ObjectMeta{Name: "beta", Namespace: "ns", UID: "beta"}},
		},
	}}
	runtime, err := NewRuntime(RuntimeConfig{Source: &metadataSearchTestSource{
		authority: "cluster", dynamic: dynamicClient, metadata: metadataClient,
	}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	if err := runtime.Search(context.Background(), inProgressSearchQuery("alp"), func(SearchBatch) error {
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	var final SearchBatch
	if err := runtime.Search(context.Background(), inProgressSearchQuery("bet"), func(batch SearchBatch) error {
		final = batch
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if metadataClient.listCalls.Load() != 1 || dynamicClient.listCalls.Load() != 0 {
		t.Fatalf(
			"search calls metadata LIST=%d dynamic LIST=%d",
			metadataClient.listCalls.Load(), dynamicClient.listCalls.Load(),
		)
	}
	if dynamicClient.getCalls.Load() != 1 {
		t.Fatalf("exact identity GET calls = %d, want 1", dynamicClient.getCalls.Load())
	}
	if !final.Complete || !final.Reusable || len(final.Results) != 1 ||
		final.Results[0].GetIdentity().GetName() != "beta" || !final.Results[0].GetStale() {
		t.Fatalf("metadata snapshot result = %#v", final)
	}

	view, err := runtime.Open(openView("view-session", "pods", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer view.Close()
	waitForSnapshotUID(t, view, "beta-full")
	if calls := dynamicClient.listCalls.Load(); calls != 1 {
		t.Fatalf("full-object view LIST calls = %d, want 1", calls)
	}
	runtime.mu.Lock()
	metadataSnapshots := 0
	for key := range runtime.searchSnapshots {
		if key.metadataOnly {
			metadataSnapshots++
		}
	}
	runtime.mu.Unlock()
	if metadataSnapshots != 1 {
		t.Fatalf("retained metadata-only snapshots = %d, want 1", metadataSnapshots)
	}
}

func TestCompletedMetadataSnapshotPrecedesSpeculativeExactGet(t *testing.T) {
	t.Parallel()
	dynamicClient := newSearchClient()
	metadataClient := &metadataSearchTestClient{page: &metav1.PartialObjectMetadataList{
		ListMeta: metav1.ListMeta{ResourceVersion: "metadata-rv"},
		Items: []metav1.PartialObjectMetadata{
			{ObjectMeta: metav1.ObjectMeta{Name: "alpha", Namespace: "ns", UID: "alpha"}},
			{ObjectMeta: metav1.ObjectMeta{Name: "beta", Namespace: "ns", UID: "beta"}},
		},
	}}
	runtime, err := NewRuntime(RuntimeConfig{Source: &metadataSearchTestSource{
		authority: "cluster", dynamic: dynamicClient, metadata: metadataClient,
	}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	if err := runtime.Search(context.Background(), inProgressSearchQuery("alp"), func(SearchBatch) error {
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if dynamicClient.getCalls.Load() != 1 || metadataClient.listCalls.Load() != 1 {
		t.Fatalf(
			"cold search calls GET=%d metadata LIST=%d, want 1/1",
			dynamicClient.getCalls.Load(), metadataClient.listCalls.Load(),
		)
	}

	// A direct GET here would fail the search. The complete metadata snapshot
	// should instead answer this exact-looking bare query without any API call.
	dynamicClient.getErr = apierrors.NewForbidden(
		schema.GroupResource{Resource: "pods"}, "beta", errors.New("unexpected GET"),
	)
	var final SearchBatch
	if err := runtime.Search(context.Background(), inProgressSearchQuery("beta"), func(batch SearchBatch) error {
		final = batch
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if dynamicClient.getCalls.Load() != 1 || metadataClient.listCalls.Load() != 1 {
		t.Fatalf(
			"snapshot search calls GET=%d metadata LIST=%d, want 1/1",
			dynamicClient.getCalls.Load(), metadataClient.listCalls.Load(),
		)
	}
	if !final.Complete || !final.Reusable || final.UsedDirectGet || len(final.Results) != 1 ||
		final.Results[0].GetIdentity().GetName() != "beta" || !final.Results[0].GetStale() {
		t.Fatalf("snapshot-backed exact-looking result = %#v", final)
	}
}

func TestViewJoinsSearchBeforeFirstPageWithoutDuplicateList(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{
		listPage("rv-final", "next", pod("one", "ns", "api-one", "Running", 0, nil, time.Time{})),
		listPage("rv-final", "", pod("two", "ns", "api-two", "Running", 0, nil, time.Time{})),
	}
	client.firstPageGate = make(chan struct{})
	client.secondPageGate = make(chan struct{})
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	searchDone := make(chan error, 1)
	go func() {
		searchDone <- runtime.Search(context.Background(), inProgressSearchQuery("api"), func(SearchBatch) error { return nil })
	}()
	eventually(t, time.Second, func() bool { return client.listCalls.Load() == 1 })
	subscription, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	close(client.firstPageGate)
	waitForSnapshotUID(t, subscription, "one")
	eventually(t, time.Second, func() bool { return client.listCalls.Load() == 2 })
	if client.listCalls.Load() != 2 || client.watchCalls.Load() != 0 {
		t.Fatalf("mid-list calls LIST=%d WATCH=%d", client.listCalls.Load(), client.watchCalls.Load())
	}
	close(client.secondPageGate)
	if err := <-searchDone; err != nil {
		t.Fatal(err)
	}
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })
	eventually(t, time.Second, func() bool { return client.lastWatchResourceVersion() == "rv-final" })
	if client.listCalls.Load() != 2 {
		t.Fatalf("final LIST=%d watch RV=%q", client.listCalls.Load(), client.lastWatchResourceVersion())
	}
}

func TestViewJoinsSearchMidListAndReceivesExistingAndProgressiveRows(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{
		listPage("rv-final", "next", pod("one", "ns", "api-one", "Running", 0, nil, time.Time{})),
		listPage("rv-final", "", pod("two", "ns", "api-two", "Running", 0, nil, time.Time{})),
	}
	client.secondPageGate = make(chan struct{})
	firstEmitted := make(chan struct{})
	var firstOnce sync.Once
	searchDone := make(chan error, 1)
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	go func() {
		searchDone <- runtime.Search(context.Background(), inProgressSearchQuery("api"), func(batch SearchBatch) error {
			if batch.Examined >= 1 {
				firstOnce.Do(func() { close(firstEmitted) })
			}
			return nil
		})
	}()
	<-firstEmitted
	subscription, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	waitForSnapshotUID(t, subscription, "one")
	close(client.secondPageGate)
	waitForSnapshotUID(t, subscription, "two")
	if err := <-searchDone; err != nil {
		t.Fatal(err)
	}
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })
	eventually(t, time.Second, func() bool { return client.lastWatchResourceVersion() == "rv-final" })
	if client.listCalls.Load() != 2 {
		t.Fatalf("LIST=%d watch RV=%q", client.listCalls.Load(), client.lastWatchResourceVersion())
	}
}

func TestSearchCancellationAfterViewJoinsDoesNotCancelSharedList(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{
		listPage("rv-final", "next", pod("one", "ns", "api-one", "Running", 0, nil, time.Time{})),
		listPage("rv-final", "", pod("two", "ns", "api-two", "Running", 0, nil, time.Time{})),
	}
	client.secondPageGate = make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	firstEmitted := make(chan struct{})
	searchDone := make(chan error, 1)
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	go func() {
		searchDone <- runtime.Search(ctx, inProgressSearchQuery("api"), func(batch SearchBatch) error {
			if batch.Examined == 1 {
				close(firstEmitted)
			}
			return nil
		})
	}()
	<-firstEmitted
	subscription, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	cancel()
	if err := <-searchDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("Search error = %v", err)
	}
	close(client.secondPageGate)
	waitForSnapshotUID(t, subscription, "two")
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })
	eventually(t, time.Second, func() bool { return client.lastWatchResourceVersion() == "rv-final" })
	if client.listCalls.Load() != 2 {
		t.Fatalf("LIST=%d watch RV=%q", client.listCalls.Load(), client.lastWatchResourceVersion())
	}
}

func TestViewCancellationWhileSearchContinuesRetainsCompletedSnapshot(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{
		listPage("rv-final", "next", pod("one", "ns", "api-one", "Running", 0, nil, time.Time{})),
		listPage("rv-final", "", pod("two", "ns", "api-two", "Running", 0, nil, time.Time{})),
	}
	client.secondPageGate = make(chan struct{})
	firstEmitted := make(chan struct{})
	var firstOnce sync.Once
	searchDone := make(chan error, 1)
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	var final SearchBatch
	go func() {
		searchDone <- runtime.Search(context.Background(), inProgressSearchQuery("api"), func(batch SearchBatch) error {
			final = batch
			if batch.Examined >= 1 {
				firstOnce.Do(func() { close(firstEmitted) })
			}
			return nil
		})
	}()
	<-firstEmitted
	subscription, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, subscription, "one")
	subscription.Close()
	close(client.secondPageGate)
	if err := <-searchDone; err != nil {
		t.Fatal(err)
	}
	if !final.Complete || !final.Reusable || client.watchCalls.Load() != 0 {
		t.Fatalf("final=%#v WATCH=%d", final, client.watchCalls.Load())
	}
	request := openView("session", "second", 1)
	second, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	waitForSnapshotUID(t, second, "two")
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })
	eventually(t, time.Second, func() bool { return client.lastWatchResourceVersion() == "rv-final" })
	if client.listCalls.Load() != 2 {
		t.Fatalf("LIST=%d watch RV=%q", client.listCalls.Load(), client.lastWatchResourceVersion())
	}
}

func inProgressSearchQuery(query string) SearchQuery {
	return SearchQuery{
		SessionID:      "session",
		Resource:       ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{Namespaces: []string{"ns"}},
		Query:          query, AllowPaginatedList: true,
	}
}

func TestCompletedSearchSnapshotRequiresExactLogicalScopeAndSelectors(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		mutate func(*kmgrv1.OpenViewRequest)
	}{
		{
			name: "different multi-namespace scope",
			mutate: func(request *kmgrv1.OpenViewRequest) {
				request.Spec.NamespaceScope = &kmgrv1.NamespaceScope{Namespaces: []string{"a", "c"}}
			},
		},
		{
			name: "label selector",
			mutate: func(request *kmgrv1.OpenViewRequest) {
				request.Spec.NamespaceScope = &kmgrv1.NamespaceScope{Namespaces: []string{"b", "a"}}
				request.Spec.LabelSelector = "app=api"
			},
		},
		{
			name: "field selector",
			mutate: func(request *kmgrv1.OpenViewRequest) {
				request.Spec.NamespaceScope = &kmgrv1.NamespaceScope{Namespaces: []string{"a", "b"}}
				request.Spec.FieldSelector = "status.phase=Running"
			},
		},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			client := newSearchClient()
			client.pages = []*unstructured.UnstructuredList{listPage(
				"search-rv", "", pod("one", "a", "api", "Running", 0, nil, time.Time{}),
			)}
			runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
			if err != nil {
				t.Fatal(err)
			}
			defer runtime.Close()
			err = runtime.Search(context.Background(), SearchQuery{
				SessionID:      "session",
				Resource:       ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
				NamespaceScope: NamespaceScope{Namespaces: []string{"a", "b"}},
				Query:          "api", AllowPaginatedList: true,
			}, func(SearchBatch) error { return nil })
			if err != nil {
				t.Fatal(err)
			}

			client.setPages(listPage("view-rv", ""))
			request := openView("session", "view", 1)
			test.mutate(request)
			subscription, err := runtime.Open(request)
			if err != nil {
				t.Fatal(err)
			}
			defer subscription.Close()
			eventually(t, time.Second, func() bool { return client.listCalls.Load() == 2 })
		})
	}
}

func TestInProgressSearchMismatchDoesNotJoin(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{
		listPage("search-rv", "next", pod("one", "a", "api", "Running", 0, nil, time.Time{})),
		listPage("search-rv", ""),
	}
	client.secondPageGate = make(chan struct{})
	firstEmitted := make(chan struct{})
	var firstOnce sync.Once
	searchDone := make(chan error, 1)
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	query := inProgressSearchQuery("api")
	query.NamespaceScope = NamespaceScope{Namespaces: []string{"a", "b"}}
	go func() {
		searchDone <- runtime.Search(context.Background(), query, func(batch SearchBatch) error {
			if batch.Examined >= 1 {
				firstOnce.Do(func() { close(firstEmitted) })
			}
			return nil
		})
	}()
	<-firstEmitted
	request := openView("session", "view", 1)
	request.Spec.NamespaceScope = &kmgrv1.NamespaceScope{Namespaces: []string{"a", "c"}}
	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	// The mismatched view owns an independent normal LIST while the palette
	// search remains blocked on its second page.
	eventually(t, time.Second, func() bool { return client.listCalls.Load() >= 3 })
	close(client.secondPageGate)
	if err := <-searchDone; err != nil {
		t.Fatal(err)
	}
}

func TestInProgressSharedListFailureFallsBackToNormalViewList(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		pages []*unstructured.UnstructuredList
		want  string
	}{
		{name: "changed resource version", pages: []*unstructured.UnstructuredList{
			listPage("one", "next", pod("one", "ns", "api-one", "Running", 0, nil, time.Time{})),
			listPage("two", "", pod("two", "ns", "api-two", "Running", 0, nil, time.Time{})),
		}, want: "resourceVersion changed"},
		{name: "repeated token", pages: []*unstructured.UnstructuredList{
			listPage("one", "same", pod("one", "ns", "api-one", "Running", 0, nil, time.Time{})),
			listPage("one", "same"),
		}, want: "repeated continue token"},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			baseClient := newSearchClient()
			baseClient.pages = test.pages
			baseClient.secondPageGate = make(chan struct{})
			client := &handoffFailureClient{searchClient: baseClient, fallback: listPage(
				"fallback-rv", "", pod("fallback", "ns", "api-fallback", "Running", 0, nil, time.Time{}),
			)}
			firstEmitted := make(chan struct{})
			searchDone := make(chan error, 1)
			runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
			if err != nil {
				t.Fatal(err)
			}
			defer runtime.Close()
			go func() {
				searchDone <- runtime.Search(context.Background(), inProgressSearchQuery("api"), func(batch SearchBatch) error {
					if batch.Examined == 1 {
						close(firstEmitted)
					}
					return nil
				})
			}()
			<-firstEmitted
			subscription, err := runtime.Open(openView("session", "view", 1))
			if err != nil {
				t.Fatal(err)
			}
			defer subscription.Close()
			close(client.searchClient.secondPageGate)
			if err := <-searchDone; err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Search error = %v, want %q", err, test.want)
			}
			// The partial store is discarded; the normal pipeline owns a new
			// authoritative LIST/WATCH lifecycle rather than watching from the
			// invalid transient resourceVersion.
			eventually(t, time.Second, func() bool { return client.listCalls.Load() >= 3 })
			eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })
			waitForSnapshotUID(t, subscription, "fallback")
			if client.lastWatchResourceVersion() == "one" || client.lastWatchResourceVersion() == "two" {
				t.Fatalf("view watched from invalid transient RV %q", client.lastWatchResourceVersion())
			}
		})
	}
}

func TestInProgressSharedListFailureFallbackEmitsNoViewError(t *testing.T) {
	t.Parallel()
	base := newSearchClient()
	base.pages = []*unstructured.UnstructuredList{
		listPage("one", "next", pod("partial", "ns", "api-partial", "Running", 0, nil, time.Time{})),
		listPage("two", ""),
	}
	base.secondPageGate = make(chan struct{})
	client := &handoffFailureClient{searchClient: base, fallback: listPage(
		"fallback", "", pod("authoritative", "ns", "api-final", "Running", 0, nil, time.Time{}),
	)}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster", client: client}, BatchDelay: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	first := make(chan struct{})
	searchDone := make(chan error, 1)
	go func() {
		searchDone <- runtime.Search(context.Background(), inProgressSearchQuery("api"), func(batch SearchBatch) error {
			if batch.Examined == 1 {
				close(first)
			}
			return nil
		})
	}()
	<-first
	subscription, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	close(base.secondPageGate)
	if err := <-searchDone; err == nil {
		t.Fatal("Search unexpectedly succeeded")
	}
	waitForSnapshotUID(t, subscription, "authoritative")
	eventually(t, time.Second, func() bool {
		subscription.mu.Lock()
		defer subscription.mu.Unlock()
		return subscription.rows["partial"] == nil && subscription.rows["authoritative"] != nil
	})
	subscription.mu.Lock()
	defer subscription.mu.Unlock()
	if subscription.pendingError != nil {
		t.Fatalf("transparent fallback left view error %#v", subscription.pendingError)
	}
}

func TestInProgressSharedListSlowViewConsumerIsBounded(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	pages := make([]*unstructured.UnstructuredList, 0, 20)
	for index := range 20 {
		continuation := ""
		if index != 19 {
			continuation = fmt.Sprintf("next-%d", index)
		}
		pages = append(pages, listPage(
			"rv", continuation,
			pod(fmt.Sprintf("uid-%d", index), "ns", fmt.Sprintf("api-%d", index), "Running", 0, nil, time.Time{}),
		))
	}
	client.pages = pages
	client.firstPageGate = make(chan struct{})
	searchDone := make(chan error, 1)
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster", client: client}, PendingRowLimit: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	go func() {
		searchDone <- runtime.Search(context.Background(), inProgressSearchQuery("api"), func(SearchBatch) error { return nil })
	}()
	eventually(t, time.Second, func() bool { return client.listCalls.Load() == 1 })
	subscription, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	close(client.firstPageGate)
	if err := <-searchDone; err != nil {
		t.Fatal(err)
	}
	subscription.mu.Lock()
	defer subscription.mu.Unlock()
	if len(subscription.pendingUpserts)+len(subscription.pendingRemoved) > 2 || !subscription.resnapshot {
		t.Fatalf("slow mailbox upserts=%d removed=%d resnapshot=%v",
			len(subscription.pendingUpserts), len(subscription.pendingRemoved), subscription.resnapshot)
	}
}

func TestViewCancelThenCompatibleViewRejoinsInProgressList(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{
		listPage("rv", "next", pod("one", "ns", "api-one", "Running", 0, nil, time.Time{})),
		listPage("rv", "", pod("two", "ns", "api-two", "Running", 0, nil, time.Time{})),
	}
	client.secondPageGate = make(chan struct{})
	firstEmitted := make(chan struct{})
	var once sync.Once
	searchDone := make(chan error, 1)
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	go func() {
		searchDone <- runtime.Search(context.Background(), inProgressSearchQuery("api"), func(batch SearchBatch) error {
			if batch.Examined >= 1 {
				once.Do(func() { close(firstEmitted) })
			}
			return nil
		})
	}()
	<-firstEmitted
	first, err := runtime.Open(openView("session", "first", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, first, "one")
	first.Close()
	second, err := runtime.Open(openView("session", "second", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	waitForSnapshotUID(t, second, "one")
	close(client.secondPageGate)
	waitForSnapshotUID(t, second, "two")
	if err := <-searchDone; err != nil {
		t.Fatal(err)
	}
	eventually(t, time.Second, func() bool { return client.lastWatchResourceVersion() == "rv" })
	if client.listCalls.Load() != 2 {
		t.Fatalf("LIST calls = %d, want 2", client.listCalls.Load())
	}
}

func TestCompatibleSearchJoinsInProgressListWithReplay(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{
		listPage("rv", "next", pod("alpha", "ns", "alpha", "Running", 0, nil, time.Time{}),
			pod("beta", "ns", "beta", "Running", 0, nil, time.Time{})),
		listPage("rv", "", pod("beta-2", "ns", "beta-worker", "Running", 0, nil, time.Time{})),
	}
	client.secondPageGate = make(chan struct{})
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	firstPage := make(chan struct{})
	firstDone := make(chan error, 1)
	firstCtx, cancelFirst := context.WithCancel(context.Background())
	go func() {
		firstDone <- runtime.Search(firstCtx, inProgressSearchQuery("alpha"), func(batch SearchBatch) error {
			if batch.Examined == 2 {
				close(firstPage)
			}
			return nil
		})
	}()
	<-firstPage
	eventually(t, time.Second, func() bool { return client.listCalls.Load() == 2 })

	var finalMu sync.Mutex
	var final SearchBatch
	secondReady := make(chan struct{})
	secondDone := make(chan error, 1)
	go func() {
		query := inProgressSearchQuery("beta")
		query.sourceReady = func() { close(secondReady) }
		secondDone <- runtime.Search(context.Background(), query, func(batch SearchBatch) error {
			finalMu.Lock()
			final = batch
			finalMu.Unlock()
			return nil
		})
	}()
	<-secondReady
	cancelFirst()
	if err := <-firstDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("first Search error = %v", err)
	}
	eventually(t, time.Second, func() bool {
		finalMu.Lock()
		defer finalMu.Unlock()
		return len(final.Results) == 1
	})
	close(client.secondPageGate)
	if err := <-secondDone; err != nil {
		t.Fatal(err)
	}
	finalMu.Lock()
	defer finalMu.Unlock()
	if !final.Complete || final.Examined != 3 || len(final.Results) != 2 || client.listCalls.Load() != 2 {
		t.Fatalf("joined final=%#v LIST=%d", final, client.listCalls.Load())
	}
}

func TestFailedPeerEmitDoesNotRevokeSharedSearchSnapshot(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{
		listPage("rv", "next", pod("one", "ns", "api-one", "Running", 0, nil, time.Time{})),
		listPage("rv", "", pod("two", "ns", "api-two", "Running", 0, nil, time.Time{})),
	}
	client.secondPageGate = make(chan struct{})
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	firstPage := make(chan struct{})
	goodDone := make(chan error, 1)
	go func() {
		goodDone <- runtime.Search(context.Background(), inProgressSearchQuery("api"), func(batch SearchBatch) error {
			if batch.Examined == 1 {
				select {
				case <-firstPage:
				default:
					close(firstPage)
				}
			}
			return nil
		})
	}()
	<-firstPage
	wantErr := errors.New("peer stream failed")
	badAttached := make(chan struct{})
	var badOnce sync.Once
	badDone := make(chan error, 1)
	go func() {
		badDone <- runtime.Search(context.Background(), inProgressSearchQuery("api"), func(batch SearchBatch) error {
			if !batch.Complete {
				badOnce.Do(func() { close(badAttached) })
			}
			if batch.Complete {
				return wantErr
			}
			return nil
		})
	}()
	<-badAttached
	close(client.secondPageGate)
	if err := <-goodDone; err != nil {
		t.Fatal(err)
	}
	if err := <-badDone; !errors.Is(err, wantErr) {
		t.Fatalf("failed peer error = %v", err)
	}
	view, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer view.Close()
	waitForSnapshotUID(t, view, "two")
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })
	eventually(t, time.Second, func() bool { return client.lastWatchResourceVersion() == "rv" })
	if client.listCalls.Load() != 2 || client.lastWatchResourceVersion() != "rv" {
		t.Fatalf("shared snapshot lost: LIST=%d watchRV=%q", client.listCalls.Load(), client.lastWatchResourceVersion())
	}
}

func TestTransientSearchDetachIsIdempotentForSnapshotAcknowledgement(t *testing.T) {
	t.Parallel()
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: newSearchClient()}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	key := searchSnapshotKey{
		resource:       resourceKey{authorityID: "cluster", version: "v1", resource: "pods", namespace: "ns"},
		namespaceScope: "namespaces:ns",
	}
	transient := &transientSearchList{
		key: key, store: store.New(), done: make(chan struct{}), terminal: true,
		searches: make(map[*transientSearchAttachment]struct{}), progress: make(chan struct{}, 1),
		reusablePending: 2,
	}
	first := &transientSearchAttachment{}
	second := &transientSearchAttachment{}
	transient.searches[first] = struct{}{}
	transient.searches[second] = struct{}{}
	runtime.mu.Lock()
	runtime.transientSearchLists[key] = transient
	runtime.mu.Unlock()

	runtime.detachTransientSearch(transient, first)
	runtime.detachTransientSearch(transient, first)
	runtime.mu.Lock()
	pending := transient.reusablePending
	_, secondAttached := transient.searches[second]
	runtime.mu.Unlock()
	if pending != 1 || !secondAttached {
		t.Fatalf("double detach pending=%d secondAttached=%v", pending, secondAttached)
	}
}

func TestTerminalReplayRaceRemovesProvisionalSearchAttachment(t *testing.T) {
	t.Parallel()
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster", client: newSearchClient()},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	attachment := &transientSearchAttachment{replaying: true}
	transient := &transientSearchList{
		terminal: true, searches: map[*transientSearchAttachment]struct{}{attachment: {}},
		progress: make(chan struct{}, 1), reusablePending: 1,
	}
	runtime.mu.Lock()
	joined := runtime.completeTransientSearchReplayLocked(
		transient, attachment, nil, 1, "rv",
	)
	pending := transient.reusablePending
	remaining := len(transient.searches)
	runtime.mu.Unlock()
	if joined || attachment.replaying || remaining != 0 || pending != 0 {
		t.Fatalf(
			"terminal replay joined=%v replaying=%v attachments=%d pending=%d",
			joined, attachment.replaying, remaining, pending,
		)
	}
}

func TestFinalSharedListDeliveryKeepsDetachAndReopenOnOnePipeline(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{listPage(
		"rv-final", "", pod("one", "ns", "api-one", "Running", 0, nil, time.Time{}),
	)}
	client.firstPageGate = make(chan struct{})
	var releaseListOnce sync.Once
	releaseList := func() { releaseListOnce.Do(func() { close(client.firstPageGate) }) }
	defer releaseList()
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster", client: client},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	projectionStarted := make(chan struct{})
	releaseProjection := make(chan struct{})
	var projectionStartedOnce sync.Once
	var releaseProjectionOnce sync.Once
	unblockProjection := func() { releaseProjectionOnce.Do(func() { close(releaseProjection) }) }
	defer unblockProjection()

	finalBatch := make(chan SearchBatch, 1)
	searchDone := make(chan error, 1)
	go func() {
		searchDone <- runtime.Search(
			context.Background(), inProgressSearchQuery("api"),
			func(batch SearchBatch) error {
				if batch.Complete {
					finalBatch <- batch
				}
				return nil
			},
		)
	}()
	eventually(t, time.Second, func() bool { return client.listCalls.Load() == 1 })
	first, err := runtime.Open(openView("session", "first", 1))
	if err != nil {
		t.Fatal(err)
	}
	// Make the final LIST batch flush one already-pending full projection. The
	// expensive portion of runProjection executes without Subscription.mu, so
	// this holds the coordinator's final-delivery gate while still allowing the
	// close handoff latch to retire and detach the first subscription.
	first.mu.Lock()
	first.projectionResnapshot = true
	first.projector.now = func() time.Time {
		projectionStartedOnce.Do(func() { close(projectionStarted) })
		<-releaseProjection
		return time.Unix(100, 0)
	}
	first.mu.Unlock()
	releaseList()
	select {
	case <-projectionStarted:
	case <-time.After(time.Second):
		t.Fatal("final shared-LIST projection did not start")
	}
	runtime.mu.Lock()
	transient := first.resource.transientSearchList
	terminal := transient != nil && transient.terminal && transient.view == first.resource
	resourceVersion := first.resource.store.ResourceVersion()
	runtime.mu.Unlock()
	if !terminal || resourceVersion != "rv-final" {
		t.Fatalf("final delivery gate terminal=%t resourceVersion=%q, want terminal rv-final", terminal, resourceVersion)
	}

	closeDone := make(chan struct{})
	go func() {
		first.Close()
		close(closeDone)
	}()
	select {
	case <-closeDone:
	case <-time.After(time.Second):
		t.Fatal("first subscription did not detach while final projection was blocked")
	}
	runtime.mu.Lock()
	firstDetached := runtime.views[first.key] == nil
	runtime.mu.Unlock()
	if !firstDetached {
		t.Fatal("first subscription close completed without detaching its view")
	}
	second, err := runtime.Open(openView("session", "second", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	if got := client.listCalls.Load(); got != 1 {
		t.Fatalf("reopen during final delivery issued %d LISTs, want 1", got)
	}
	unblockProjection()
	select {
	case err := <-searchDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("shared search did not finish after final projection was released")
	}
	var batch SearchBatch
	select {
	case batch = <-finalBatch:
	case <-time.After(time.Second):
		t.Fatal("shared search omitted its final batch")
	}
	if !batch.Reusable {
		t.Fatal("completed shared LIST did not advertise its reusable view store")
	}
	waitForSnapshotUID(t, second, "one")
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })
	eventually(t, time.Second, func() bool { return client.lastWatchResourceVersion() == "rv-final" })
	if got := client.lastWatchResourceVersion(); got != "rv-final" {
		t.Fatalf("replacement WATCH resourceVersion = %q, want rv-final", got)
	}
	if got := client.listCalls.Load(); got != 1 {
		t.Fatalf("final LIST calls = %d, want 1", got)
	}
}

func TestRuntimeCloseUnblocksSearchWhenListIgnoresCancellation(t *testing.T) {
	t.Parallel()
	client := &cancellationIgnoringSearchClient{
		started: make(chan struct{}), release: make(chan struct{}),
		page: listPage("rv", "", pod("one", "ns", "api", "Running", 0, nil, time.Time{})),
	}
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		done <- runtime.Search(context.Background(), inProgressSearchQuery("api"), func(SearchBatch) error { return nil })
	}()
	<-client.started
	runtime.Close()
	select {
	case err := <-done:
		if !errors.Is(err, ErrViewClosed) {
			t.Fatalf("Search error = %v, want ErrViewClosed", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Runtime.Close stranded Search")
	}
	close(client.release)
}

func TestOverflowedSharedListDropsStoreAfterViewCloses(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{
		listPage("rv", "next", pod("one", "ns", "api-one", "Running", 0, nil, time.Time{}),
			pod("two", "ns", "api-two", "Running", 0, nil, time.Time{})),
		listPage("rv", "", pod("three", "ns", "api-three", "Running", 0, nil, time.Time{})),
	}
	client.secondPageGate = make(chan struct{})
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster", client: client}, SearchSnapshotObjectLimit: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	client.firstPageGate = make(chan struct{})
	first := make(chan struct{})
	searchDone := make(chan error, 1)
	go func() {
		searchDone <- runtime.Search(context.Background(), inProgressSearchQuery("api"), func(batch SearchBatch) error {
			if batch.Examined == 2 {
				close(first)
			}
			return nil
		})
	}()
	eventually(t, time.Second, func() bool { return client.listCalls.Load() == 1 })
	view, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	close(client.firstPageGate)
	<-first
	waitForSnapshotUID(t, view, "one")
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		for _, transient := range runtime.transientSearchLists {
			if transient.view == view.resource && !transient.storeBounded {
				return true
			}
		}
		return false
	})
	view.Close()
	runtime.mu.Lock()
	transient := runtime.transientSearchLists[searchSnapshotKey{
		resource:       resourceKey{authorityID: "cluster", version: "v1", resource: "pods", namespace: "ns"},
		namespaceScope: "namespaces:ns",
	}]
	dropped := transient != nil && transient.store == nil && !transient.joinable
	runtime.mu.Unlock()
	if !dropped {
		t.Fatal("overflowed transient store remained joinable after its view closed")
	}
	close(client.secondPageGate)
	if err := <-searchDone; err != nil {
		t.Fatal(err)
	}
}

func TestCompletedSearchSnapshotCanonicalizesNamespaceOrder(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{listPage(
		"search-rv", "", pod("one", "a", "api", "Running", 0, nil, time.Time{}),
	)}
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	err = runtime.Search(context.Background(), SearchQuery{
		SessionID:      "session",
		Resource:       ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{Namespaces: []string{"b", "a", "a"}},
		Query:          "api", AllowPaginatedList: true,
	}, func(SearchBatch) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	request := openView("session", "view", 1)
	request.Spec.NamespaceScope = &kmgrv1.NamespaceScope{Namespaces: []string{"a", "b"}}
	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	waitForSnapshotUID(t, subscription, "one")
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })
	eventually(t, time.Second, func() bool { return client.lastWatchResourceVersion() == "search-rv" })
	if client.listCalls.Load() != 1 || client.lastWatchResourceVersion() != "search-rv" {
		t.Fatalf("LIST=%d watch RV=%q", client.listCalls.Load(), client.lastWatchResourceVersion())
	}
}

func TestCompletedSearchSnapshotRequiresExactAuthorityAndGVR(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name        string
		searchKey   searchSnapshotKey
		request     *kmgrv1.OpenViewRequest
		authorityID string
	}{
		{
			name: "authority",
			searchKey: searchSnapshotKey{resource: resourceKey{
				authorityID: "other-cluster", version: "v1", resource: "pods", namespace: "ns",
			}, namespaceScope: "namespaces:ns"},
			request: openView("session", "view", 1), authorityID: "cluster",
		},
		{
			name: "group",
			searchKey: searchSnapshotKey{resource: resourceKey{
				authorityID: "cluster", group: "example.io", version: "v1", resource: "pods", namespace: "ns",
			}, namespaceScope: "namespaces:ns"},
			request: openView("session", "view", 1), authorityID: "cluster",
		},
		{
			name: "version",
			searchKey: searchSnapshotKey{resource: resourceKey{
				authorityID: "cluster", version: "v2", resource: "pods", namespace: "ns",
			}, namespaceScope: "namespaces:ns"},
			request: openView("session", "view", 1), authorityID: "cluster",
		},
		{
			name: "resource",
			searchKey: searchSnapshotKey{resource: resourceKey{
				authorityID: "cluster", version: "v1", resource: "widgets", namespace: "ns",
			}, namespaceScope: "namespaces:ns"},
			request: openView("session", "view", 1), authorityID: "cluster",
		},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			client := newSearchClient()
			client.pages = []*unstructured.UnstructuredList{listPage("view-rv", "")}
			runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: test.authorityID, client: client}})
			if err != nil {
				t.Fatal(err)
			}
			defer runtime.Close()
			candidate := store.New()
			candidate.Upsert(pod("one", "ns", "api", "Running", 0, nil, time.Time{}))
			candidate.SetResourceVersion("search-rv")
			if _, retained := runtime.installSearchSnapshot(test.searchKey, candidate); !retained {
				t.Fatal("mismatched snapshot was not retained for test")
			}
			subscription, err := runtime.Open(test.request)
			if err != nil {
				t.Fatal(err)
			}
			defer subscription.Close()
			eventually(t, time.Second, func() bool { return client.listCalls.Load() == 1 })
			if client.lastWatchResourceVersion() == "search-rv" {
				t.Fatal("mismatched snapshot seeded view")
			}
		})
	}
}

func TestEmptyNamespacedSearchScopeMatchesDefaultViewScope(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{listPage(
		"search-rv", "", pod("one", "default", "api", "Running", 0, nil, time.Time{}),
	)}
	source := &namespaceRecordingSearchSource{authority: "cluster", client: client}
	runtime, err := NewRuntime(RuntimeConfig{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	err = runtime.Search(context.Background(), SearchQuery{
		SessionID: "session",
		Resource:  ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		Query:     "api", AllowPaginatedList: true,
	}, func(SearchBatch) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	request := openView("session", "view", 1)
	request.Spec.NamespaceScope = nil
	subscription, err := runtime.Open(request)
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	waitForSnapshotUID(t, subscription, "one")
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })
	eventually(t, time.Second, func() bool { return client.lastWatchResourceVersion() == "search-rv" })
	if got := source.openedNamespaces(); !slices.Equal(got, []string{"default", "default"}) {
		t.Fatalf("search/view server namespaces = %v", got)
	}
	if client.listCalls.Load() != 1 || client.lastWatchResourceVersion() != "search-rv" {
		t.Fatalf("LIST=%d watch RV=%q", client.listCalls.Load(), client.lastWatchResourceVersion())
	}
}

func TestOversizedSearchSnapshotIsAbandonedAndNotReusable(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{
		listPage("rv", "next",
			pod("one", "ns", "api-one", "Running", 0, nil, time.Time{}),
			pod("two", "ns", "api-two", "Running", 0, nil, time.Time{}),
		),
		listPage("rv", "", pod("three", "ns", "api-three", "Running", 0, nil, time.Time{})),
	}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster", client: client}, SearchSnapshotObjectLimit: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	var final SearchBatch
	err = runtime.Search(context.Background(), SearchQuery{
		SessionID:      "session",
		Resource:       ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{Namespaces: []string{"ns"}},
		Query:          "api", AllowPaginatedList: true,
	}, func(batch SearchBatch) error { final = batch; return nil })
	if err != nil {
		t.Fatal(err)
	}
	if final.Reusable || len(runtime.searchSnapshots) != 0 || runtime.searchSnapshotObjects != 0 {
		t.Fatalf("oversized final=%#v snapshots=%d objects=%d", final, len(runtime.searchSnapshots), runtime.searchSnapshotObjects)
	}
	if len(final.Results) != 3 || final.Examined != 3 {
		t.Fatalf("bounded search result was lost: %#v", final)
	}
}

func TestExpiredSearchSnapshotFallsBackToList(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{listPage(
		"search-rv", "", pod("one", "ns", "api", "Running", 0, nil, time.Time{}),
	)}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster", client: client}, SearchSnapshotTTL: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	err = runtime.Search(context.Background(), SearchQuery{
		SessionID:      "session",
		Resource:       ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{Namespaces: []string{"ns"}}, Query: "api", AllowPaginatedList: true,
	}, func(SearchBatch) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	eventually(t, time.Second, func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		return len(runtime.searchSnapshots) == 0 && runtime.searchSnapshotObjects == 0
	})
	client.setPages(listPage("view-rv", ""))
	subscription, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	eventually(t, time.Second, func() bool { return client.listCalls.Load() == 2 })
}

func TestSearchSnapshotIsSingleUse(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{listPage(
		"search-rv", "", pod("one", "ns", "api", "Running", 0, nil, time.Time{}),
	)}
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	err = runtime.Search(context.Background(), SearchQuery{
		SessionID:      "session",
		Resource:       ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{Namespaces: []string{"ns"}}, Query: "api", AllowPaginatedList: true,
	}, func(SearchBatch) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	key := searchSnapshotKey{resource: resourceKey{
		authorityID: "cluster", version: "v1", resource: "pods", namespace: "ns",
	}, namespaceScope: canonicalNamespaceScope(
		ResourceType{Version: "v1", Resource: "pods", Namespaced: true},
		NamespaceScope{Namespaces: []string{"ns"}},
	)}
	runtime.mu.Lock()
	first := runtime.consumeSearchSnapshotLocked(key)
	second := runtime.consumeSearchSnapshotLocked(key)
	objects := runtime.searchSnapshotObjects
	runtime.mu.Unlock()
	if first == nil || second != nil || objects != 0 || first.expirationTimer != nil {
		t.Fatalf("single-use first=%p second=%p objects=%d timer=%v", first, second, objects, first.expirationTimer)
	}
}

func TestSearchSnapshotBudgetsEvictOldest(t *testing.T) {
	t.Parallel()
	runtime, err := NewRuntime(RuntimeConfig{
		Source:              &fakeResourceSource{authority: "cluster", client: newSearchClient()},
		SearchSnapshotLimit: 2, SearchSnapshotObjectLimit: 3,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	install := func(resource string, count int) (searchSnapshotKey, bool) {
		key := searchSnapshotKey{resource: resourceKey{
			authorityID: "cluster", version: "v1", resource: resource,
		}, namespaceScope: "cluster"}
		candidate := store.New()
		for index := range count {
			candidate.Upsert(pod(
				fmt.Sprintf("%s-%d", resource, index), "", fmt.Sprintf("%s-%d", resource, index),
				"Running", 0, nil, time.Time{},
			))
		}
		candidate.SetResourceVersion("rv")
		_, retained := runtime.installSearchSnapshot(key, candidate)
		return key, retained
	}
	first, retained := install("first", 1)
	if !retained {
		t.Fatal("first snapshot was not retained")
	}
	second, retained := install("second", 1)
	if !retained {
		t.Fatal("second snapshot was not retained")
	}
	third, retained := install("third", 1)
	if !retained {
		t.Fatal("third snapshot was not retained")
	}
	runtime.mu.Lock()
	if runtime.searchSnapshots[first] != nil || runtime.searchSnapshots[second] == nil ||
		runtime.searchSnapshots[third] == nil || runtime.searchSnapshotObjects != 2 {
		t.Fatalf("entry eviction snapshots=%v objects=%d", runtime.searchSnapshots, runtime.searchSnapshotObjects)
	}
	runtime.mu.Unlock()

	fourth, retained := install("fourth", 2)
	if !retained {
		t.Fatal("new aggregate-budget snapshot was unexpectedly evicted")
	}
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	if runtime.searchSnapshots[second] != nil || runtime.searchSnapshots[third] == nil ||
		runtime.searchSnapshots[fourth] == nil || runtime.searchSnapshotObjects != 3 {
		t.Fatalf("object eviction snapshots=%v objects=%d", runtime.searchSnapshots, runtime.searchSnapshotObjects)
	}
}

func TestSearchFinalEmitFailureRevokesSnapshot(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{listPage(
		"rv", "", pod("one", "ns", "api", "Running", 0, nil, time.Time{}),
	)}
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	wantErr := errors.New("stream closed")
	err = runtime.Search(context.Background(), SearchQuery{
		SessionID:      "session",
		Resource:       ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{Namespaces: []string{"ns"}}, Query: "api", AllowPaginatedList: true,
	}, func(batch SearchBatch) error {
		if !batch.Reusable {
			t.Fatal("final batch did not offer retained snapshot")
		}
		return wantErr
	})
	if !errors.Is(err, wantErr) {
		t.Fatalf("Search error = %v", err)
	}
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	if len(runtime.searchSnapshots) != 0 || runtime.searchSnapshotObjects != 0 {
		t.Fatalf("failed emit retained snapshots=%d objects=%d", len(runtime.searchSnapshots), runtime.searchSnapshotObjects)
	}
}

func TestSearchRejectsInvalidListSnapshots(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		pages []*unstructured.UnstructuredList
		want  string
	}{
		{name: "nil page", pages: []*unstructured.UnstructuredList{nil}, want: "nil page"},
		{name: "missing resource version", pages: []*unstructured.UnstructuredList{listPage("", "")}, want: "no resourceVersion"},
		{name: "changing resource version", pages: []*unstructured.UnstructuredList{
			listPage("one", "next", pod("one", "ns", "api-one", "Running", 0, nil, time.Time{})),
			listPage("two", "", pod("two", "ns", "api-two", "Running", 0, nil, time.Time{})),
		}, want: "resourceVersion changed"},
		{name: "missing UID", pages: []*unstructured.UnstructuredList{
			listPage("rv", "", pod("", "ns", "api", "Running", 0, nil, time.Time{})),
		}, want: "has no UID"},
		{name: "repeated continue token", pages: []*unstructured.UnstructuredList{
			listPage("rv", "same"), listPage("rv", "same"),
		}, want: "repeated continue token"},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			client := newSearchClient()
			client.pages = test.pages
			runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
			if err != nil {
				t.Fatal(err)
			}
			defer runtime.Close()
			err = runtime.Search(context.Background(), SearchQuery{
				SessionID:      "session",
				Resource:       ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
				NamespaceScope: NamespaceScope{All: true}, Query: "api", AllowPaginatedList: true,
			}, func(SearchBatch) error { return nil })
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Search error = %v, want %q", err, test.want)
			}
			runtime.mu.Lock()
			defer runtime.mu.Unlock()
			if len(runtime.searchSnapshots) != 0 || runtime.searchSnapshotObjects != 0 {
				t.Fatalf("invalid LIST retained snapshots=%d objects=%d", len(runtime.searchSnapshots), runtime.searchSnapshotObjects)
			}
		})
	}
}

func TestRuntimeCloseClearsSearchSnapshots(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{listPage(
		"rv", "", pod("one", "ns", "api", "Running", 0, nil, time.Time{}),
	)}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "cluster", client: client}, SearchSnapshotTTL: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	err = runtime.Search(context.Background(), SearchQuery{
		SessionID:      "session",
		Resource:       ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{Namespaces: []string{"ns"}}, Query: "api", AllowPaginatedList: true,
	}, func(SearchBatch) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	runtime.Close()
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	if len(runtime.searchSnapshots) != 0 || runtime.searchSnapshotObjects != 0 {
		t.Fatalf("Close retained snapshots=%d objects=%d", len(runtime.searchSnapshots), runtime.searchSnapshotObjects)
	}
}

func TestExactSearchUsesDirectGet(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.getObjects["exact"] = pod("uid", "ns", "exact", "Running", 0, nil, time.Time{})
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	var readyCalls atomic.Int64
	var batch SearchBatch
	query := SearchQuery{
		SessionID: "session", Resource: ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{All: true}, Query: "ns/exact", AllowPaginatedList: true,
		sourceReady: func() { readyCalls.Add(1) },
	}
	err = runtime.Search(context.Background(), query, func(value SearchBatch) error { batch = value; return nil })
	if err != nil {
		t.Fatal(err)
	}
	if !batch.UsedDirectGet || len(batch.Results) != 1 || readyCalls.Load() != 1 ||
		client.listCalls.Load() != 0 || client.watchCalls.Load() != 0 {
		t.Fatalf(
			"direct GET result=%#v ready=%d list=%d watch=%d",
			batch, readyCalls.Load(), client.listCalls.Load(), client.watchCalls.Load(),
		)
	}
}

func TestNamespacedPartialSearchFallsBackAfterExactGetNotFound(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{
		listPage("rv", "", pod("worker", "team", "api-worker", "Running", 0, nil, time.Time{})),
	}
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	var final SearchBatch
	err = runtime.Search(context.Background(), SearchQuery{
		SessionID: "session", Resource: ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{Namespaces: []string{"team"}}, Query: "api", AllowPaginatedList: true,
	}, func(batch SearchBatch) error {
		final = batch
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if client.getCalls.Load() != 1 || client.listCalls.Load() != 1 || client.watchCalls.Load() != 0 {
		t.Fatalf("calls = GET %d LIST %d WATCH %d", client.getCalls.Load(), client.listCalls.Load(), client.watchCalls.Load())
	}
	if !final.Complete || final.UsedDirectGet || len(final.Results) != 1 || final.Results[0].GetIdentity().GetName() != "api-worker" {
		t.Fatalf("fallback result = %#v", final)
	}
}

func TestClusterScopedPartialSearchFallsBackAfterExactGetNotFound(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{
		listPage("rv", "", pod("worker", "", "worker-a", "Running", 0, nil, time.Time{})),
	}
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	var final SearchBatch
	err = runtime.Search(context.Background(), SearchQuery{
		SessionID: "session", Resource: ResourceType{Version: "v1", Resource: "nodes", Kind: "Node"},
		NamespaceScope: NamespaceScope{All: true}, Query: "work", AllowPaginatedList: true,
	}, func(batch SearchBatch) error {
		final = batch
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if client.getCalls.Load() != 1 || client.listCalls.Load() != 1 || client.watchCalls.Load() != 0 {
		t.Fatalf("calls = GET %d LIST %d WATCH %d", client.getCalls.Load(), client.listCalls.Load(), client.watchCalls.Load())
	}
	if !final.Complete || final.UsedDirectGet || len(final.Results) != 1 || final.Results[0].GetIdentity().GetName() != "worker-a" {
		t.Fatalf("fallback result = %#v", final)
	}
}

func TestExactSearchDoesNotHideNonNotFoundErrors(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		err   error
		check func(error) bool
	}{
		{
			name: "forbidden",
			err: apierrors.NewForbidden(
				schema.GroupResource{Resource: "pods"}, "api", errors.New("denied"),
			),
			check: apierrors.IsForbidden,
		},
		{name: "transport", err: errors.New("connection failed"), check: func(err error) bool {
			return err != nil && err.Error() == "connection failed"
		}},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			client := newSearchClient()
			client.getErr = test.err
			client.pages = []*unstructured.UnstructuredList{
				listPage("rv", "", pod("would-match", "team", "api-worker", "Running", 0, nil, time.Time{})),
			}
			runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
			if err != nil {
				t.Fatal(err)
			}
			defer runtime.Close()
			err = runtime.Search(context.Background(), SearchQuery{
				SessionID: "session", Resource: ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
				NamespaceScope: NamespaceScope{Namespaces: []string{"team"}}, Query: "api", AllowPaginatedList: true,
			}, func(SearchBatch) error { return nil })
			if !test.check(err) {
				t.Fatalf("Search error = %v", err)
			}
			if client.getCalls.Load() != 1 || client.listCalls.Load() != 0 || client.watchCalls.Load() != 0 {
				t.Fatalf("calls = GET %d LIST %d WATCH %d", client.getCalls.Load(), client.listCalls.Load(), client.watchCalls.Load())
			}
		})
	}
}

func TestExactSearchRejectsNamespaceOutsideScopeBeforeGet(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{
		listPage("rv", "", pod("allowed", "allowed", "api", "Running", 0, nil, time.Time{})),
	}
	source := &namespaceRecordingSearchSource{authority: "cluster", client: client}
	runtime, err := NewRuntime(RuntimeConfig{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	var final SearchBatch
	err = runtime.Search(context.Background(), SearchQuery{
		SessionID: "session", Resource: ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{Namespaces: []string{"allowed"}}, Query: "other/api", AllowPaginatedList: true,
	}, func(batch SearchBatch) error {
		final = batch
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if client.getCalls.Load() != 0 || client.listCalls.Load() != 1 {
		t.Fatalf("calls = GET %d LIST %d", client.getCalls.Load(), client.listCalls.Load())
	}
	if got := source.openedNamespaces(); !slices.Equal(got, []string{"allowed"}) {
		t.Fatalf("opened namespaces = %v", got)
	}
	if !final.Complete || len(final.Results) != 0 {
		t.Fatalf("out-of-scope result = %#v", final)
	}
}

func TestSearchProgressRemainsMonotonicAcrossCacheAndList(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{listPage(
		"cached-rv", "",
		pod("cached-a", "ns", "api-cached-a", "Running", 0, nil, time.Time{}),
		pod("cached-b", "ns", "api-cached-b", "Running", 0, nil, time.Time{}),
	)}
	runtime, err := NewRuntime(RuntimeConfig{
		Source:       &fakeResourceSource{authority: "cluster", client: client},
		ReleaseDelay: 5 * time.Millisecond, PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	subscription, err := runtime.Open(openView("session", "view", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, subscription, "cached-a")
	subscription.Close()
	eventually(t, time.Second, func() bool { return client.lastWatchStopped() })

	client.setPages(
		listPage("list-rv", "next", pod("listed-a", "ns", "api-listed-a", "Running", 0, nil, time.Time{})),
		listPage("list-rv", "", pod("listed-b", "ns", "api-listed-b", "Running", 0, nil, time.Time{})),
	)
	var progress []uint64
	err = runtime.Search(context.Background(), SearchQuery{
		SessionID: "session", Resource: ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{All: true}, Query: "api", AllowPaginatedList: true,
	}, func(batch SearchBatch) error {
		progress = append(progress, batch.Examined)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(progress, []uint64{2, 3, 4}) {
		t.Fatalf("progress = %v", progress)
	}
}

func TestBoundedSearchResultsRetainsOnlyBestLimit(t *testing.T) {
	t.Parallel()
	const limit = 7
	retained := newBoundedSearchResults(limit)
	resource := ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true}
	for index := range 10_000 {
		value := pod(fmt.Sprintf("uid-%05d", index), "team", fmt.Sprintf("api-%05d", index), "Running", 0, nil, time.Time{})
		retained.Add(makeSearchResult("session", resource, value, float64(index), false))
		if len(retained.values) > limit {
			t.Fatalf("retained %d candidates after item %d", len(retained.values), index)
		}
	}
	results := retained.Sorted()
	if len(results) != limit || results[0].GetRank() != 9_999 || results[limit-1].GetRank() != 9_993 {
		t.Fatalf("bounded results = %#v", results)
	}
}

func TestPaginatedSearchNeverEmitsMoreThanResultLimit(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	pages := make([]*unstructured.UnstructuredList, 0, 4)
	for pageIndex := range 4 {
		objects := make([]*unstructured.Unstructured, 0, 75)
		for index := range 75 {
			ordinal := pageIndex*75 + index
			objects = append(objects, pod(
				fmt.Sprintf("uid-%03d", ordinal), "team", fmt.Sprintf("api-%03d", 299-ordinal),
				"Running", 0, nil, time.Time{},
			))
		}
		continuation := ""
		if pageIndex < 3 {
			continuation = fmt.Sprintf("page-%d", pageIndex+1)
		}
		pages = append(pages, listPage("rv", continuation, objects...))
	}
	client.pages = pages
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	var final SearchBatch
	err = runtime.Search(context.Background(), SearchQuery{
		SessionID: "session", Resource: ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{All: true}, Query: "api", ResultLimit: 5, AllowPaginatedList: true,
	}, func(batch SearchBatch) error {
		if len(batch.Results) > 5 {
			t.Fatalf("emitted %d results", len(batch.Results))
		}
		final = batch
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !final.Complete || len(final.Results) != 5 || final.Examined != 300 {
		t.Fatalf("final bounded batch = %#v", final)
	}
}

func TestPaginatedSearchCancellation(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.pages = []*unstructured.UnstructuredList{
		listPage("rv", "next", pod("one", "ns", "one-match", "Running", 0, nil, time.Time{})),
		listPage("rv", "", pod("two", "ns", "two-match", "Running", 0, nil, time.Time{})),
	}
	client.secondPageGate = make(chan struct{})
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	ctx, cancel := context.WithCancel(context.Background())
	err = runtime.Search(ctx, SearchQuery{
		SessionID: "session", Resource: ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{All: true}, Query: "match", AllowPaginatedList: true,
	}, func(batch SearchBatch) error {
		if batch.Examined == 1 {
			cancel()
		}
		return nil
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Search error = %v, want cancellation", err)
	}
}

type searchClient struct {
	mu                    sync.Mutex
	pages                 []*unstructured.UnstructuredList
	pageIndex             int
	getObjects            map[string]*unstructured.Unstructured
	getErr                error
	firstPageGate         chan struct{}
	secondPageGate        chan struct{}
	watches               []*controllableWatch
	watchResourceVersions []string
	listCalls             atomic.Int64
	getCalls              atomic.Int64
	watchCalls            atomic.Int64
}

type metadataSearchTestSource struct {
	authority string
	dynamic   watcher.ListerWatcher
	metadata  metadata.ResourceInterface
}

func (s *metadataSearchTestSource) OpenResource(
	string,
	schema.GroupVersionResource,
	string,
) (string, watcher.ListerWatcher, error) {
	return s.authority, s.dynamic, nil
}

func (s *metadataSearchTestSource) OpenMetadataSearchResource(
	string,
	schema.GroupVersionResource,
	string,
) (string, metadata.ResourceInterface, error) {
	return s.authority, s.metadata, nil
}

type metadataSearchTestClient struct {
	page      *metav1.PartialObjectMetadataList
	listCalls atomic.Int64
}

func (c *metadataSearchTestClient) List(
	context.Context,
	metav1.ListOptions,
) (*metav1.PartialObjectMetadataList, error) {
	c.listCalls.Add(1)
	return c.page.DeepCopy(), nil
}

func (*metadataSearchTestClient) Delete(
	context.Context,
	string,
	metav1.DeleteOptions,
	...string,
) error {
	return errors.New("unexpected metadata delete")
}

func (*metadataSearchTestClient) DeleteCollection(
	context.Context,
	metav1.DeleteOptions,
	metav1.ListOptions,
) error {
	return errors.New("unexpected metadata delete collection")
}

func (*metadataSearchTestClient) Get(
	context.Context,
	string,
	metav1.GetOptions,
	...string,
) (*metav1.PartialObjectMetadata, error) {
	return nil, errors.New("unexpected metadata get")
}

func (*metadataSearchTestClient) Watch(
	context.Context,
	metav1.ListOptions,
) (watch.Interface, error) {
	return nil, errors.New("unexpected metadata watch")
}

func (*metadataSearchTestClient) Patch(
	context.Context,
	string,
	types.PatchType,
	[]byte,
	metav1.PatchOptions,
	...string,
) (*metav1.PartialObjectMetadata, error) {
	return nil, errors.New("unexpected metadata patch")
}

// handoffFailureClient lets a transient paginated LIST fail validation once,
// then gives the fallback watcher pipeline a valid authoritative snapshot.
type handoffFailureClient struct {
	*searchClient
	fallback *unstructured.UnstructuredList
}

type cancellationIgnoringSearchClient struct {
	started chan struct{}
	release chan struct{}
	page    *unstructured.UnstructuredList
	once    sync.Once
}

func (c *cancellationIgnoringSearchClient) List(context.Context, metav1.ListOptions) (*unstructured.UnstructuredList, error) {
	first := false
	c.once.Do(func() {
		first = true
		close(c.started)
	})
	if first {
		<-c.release
	}
	return c.page.DeepCopy(), nil
}

func (c *cancellationIgnoringSearchClient) Get(context.Context, string, metav1.GetOptions, ...string) (*unstructured.Unstructured, error) {
	return nil, apierrors.NewNotFound(schema.GroupResource{Resource: "pods"}, "api")
}

func (*cancellationIgnoringSearchClient) Watch(context.Context, metav1.ListOptions) (watch.Interface, error) {
	return newControllableWatch(), nil
}

func (c *handoffFailureClient) List(ctx context.Context, options metav1.ListOptions) (*unstructured.UnstructuredList, error) {
	if c.listCalls.Load() >= int64(len(c.pages)) {
		c.listCalls.Add(1)
		return c.fallback.DeepCopy(), nil
	}
	return c.searchClient.List(ctx, options)
}

func (c *searchClient) lastWatchResourceVersion() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.watches) == 0 {
		return ""
	}
	if len(c.watchResourceVersions) == 0 {
		return ""
	}
	return c.watchResourceVersions[len(c.watchResourceVersions)-1]
}

func (c *searchClient) lastWatchStopped() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.watches) != 0 && c.watches[len(c.watches)-1].stopped.Load()
}

func newSearchClient() *searchClient {
	return &searchClient{
		pages:      []*unstructured.UnstructuredList{listPage("rv-empty", "")},
		getObjects: make(map[string]*unstructured.Unstructured),
	}
}

func (c *searchClient) List(ctx context.Context, options metav1.ListOptions) (*unstructured.UnstructuredList, error) {
	c.listCalls.Add(1)
	c.mu.Lock()
	if options.Continue == "" {
		c.pageIndex = 0
	}
	index := c.pageIndex
	var page *unstructured.UnstructuredList
	if candidate := c.pages[min(index, len(c.pages)-1)]; candidate != nil {
		page = candidate.DeepCopy()
	}
	c.pageIndex++
	gate := c.secondPageGate
	if index == 0 {
		gate = c.firstPageGate
	}
	c.mu.Unlock()
	if gate != nil {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-gate:
		}
	}
	return page, nil
}

func (c *searchClient) Watch(_ context.Context, options metav1.ListOptions) (watch.Interface, error) {
	c.watchCalls.Add(1)
	stream := newControllableWatch()
	c.mu.Lock()
	c.watches = append(c.watches, stream)
	c.watchResourceVersions = append(c.watchResourceVersions, options.ResourceVersion)
	c.mu.Unlock()
	return stream, nil
}

func (c *searchClient) Get(_ context.Context, name string, _ metav1.GetOptions, _ ...string) (*unstructured.Unstructured, error) {
	c.getCalls.Add(1)
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.getErr != nil {
		return nil, c.getErr
	}
	if value := c.getObjects[name]; value != nil {
		return value.DeepCopy(), nil
	}
	return nil, apierrors.NewNotFound(schema.GroupResource{Resource: "objects"}, name)
}

func (c *searchClient) setPages(pages ...*unstructured.UnstructuredList) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.pages = pages
	c.pageIndex = 0
}

var _ watcher.ListerWatcher = (*searchClient)(nil)

type namespaceRecordingSearchSource struct {
	mu         sync.Mutex
	authority  string
	client     watcher.ListerWatcher
	namespaces []string
}

func (s *namespaceRecordingSearchSource) OpenResource(
	_ string,
	_ schema.GroupVersionResource,
	namespace string,
) (string, watcher.ListerWatcher, error) {
	s.mu.Lock()
	s.namespaces = append(s.namespaces, namespace)
	s.mu.Unlock()
	return s.authority, s.client, nil
}

func (s *namespaceRecordingSearchSource) openedNamespaces() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.namespaces)
}
