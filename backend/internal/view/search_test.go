package view

import (
	"context"
	"errors"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/watch"

	"github.com/charlie0129/kmgr/backend/internal/watcher"
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
	secondPageGate chan struct{}
	watches        []*controllableWatch
	listCalls      atomic.Int64
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
	c.mu.Lock()
	defer c.mu.Unlock()
	if value := c.getObjects[name]; value != nil {
		return value.DeepCopy(), nil
	}
	return nil, errors.New("not found")
}

func (c *searchClient) lastWatchStopped() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.watches) != 0 && c.watches[len(c.watches)-1].stopped.Load()
}

var _ watcher.ListerWatcher = (*searchClient)(nil)
