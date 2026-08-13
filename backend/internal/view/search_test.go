package view

import (
	"context"
	"errors"
	"fmt"
	"slices"
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
	"k8s.io/apimachinery/pkg/watch"

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

	result, err := runtime.SearchCached(CachedSearchQuery{
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

	result, err := runtime.SearchCached(CachedSearchQuery{
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

	result, err := runtime.SearchCached(CachedSearchQuery{
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

	result, err := runtime.SearchCached(CachedSearchQuery{
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

func TestExactSearchUsesDirectGet(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.getObjects["exact"] = pod("uid", "ns", "exact", "Running", 0, nil, time.Time{})
	runtime, err := NewRuntime(RuntimeConfig{Source: &fakeResourceSource{authority: "cluster", client: client}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	var batch SearchBatch
	err = runtime.Search(context.Background(), SearchQuery{
		SessionID: "session", Resource: ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: NamespaceScope{All: true}, Query: "ns/exact", AllowPaginatedList: true,
	}, func(value SearchBatch) error { batch = value; return nil })
	if err != nil {
		t.Fatal(err)
	}
	if !batch.UsedDirectGet || len(batch.Results) != 1 || client.listCalls.Load() != 0 || client.watchCalls.Load() != 0 {
		t.Fatalf("direct GET result=%#v list=%d watch=%d", batch, client.listCalls.Load(), client.watchCalls.Load())
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
	mu             sync.Mutex
	pages          []*unstructured.UnstructuredList
	pageIndex      int
	getObjects     map[string]*unstructured.Unstructured
	getErr         error
	secondPageGate chan struct{}
	watches        []*controllableWatch
	listCalls      atomic.Int64
	getCalls       atomic.Int64
	watchCalls     atomic.Int64
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
	page := c.pages[min(index, len(c.pages)-1)].DeepCopy()
	c.pageIndex++
	gate := c.secondPageGate
	c.mu.Unlock()
	if index == 1 && gate != nil {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-gate:
		}
	}
	return page, nil
}

func (c *searchClient) Watch(context.Context, metav1.ListOptions) (watch.Interface, error) {
	c.watchCalls.Add(1)
	stream := newControllableWatch()
	c.mu.Lock()
	c.watches = append(c.watches, stream)
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

func (c *searchClient) lastWatchStopped() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.watches) != 0 && c.watches[len(c.watches)-1].stopped.Load()
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
