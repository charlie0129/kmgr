package view

import (
	"context"
	"errors"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/metadata"

	"github.com/charlie0129/kmgr/backend/internal/watcher"
)

func TestExactNamespaceMetadataSearchFansInPaginatedListsAndReusesSnapshot(t *testing.T) {
	t.Parallel()
	releaseFirstPages := make(chan struct{})
	aStarted := make(chan struct{})
	bStarted := make(chan struct{})
	a := newPaginatedMetadataSearchClient(
		metadataSearchPage("rv-a", "a-next", metadataSearchIdentity("uid-a1", "a", "api-a1")),
		metadataSearchPage("rv-a", "", metadataSearchIdentity("uid-a2", "a", "api-a2")),
	)
	b := newPaginatedMetadataSearchClient(
		metadataSearchPage("rv-b", "", metadataSearchIdentity("uid-b", "b", "api-b")),
	)
	a.firstPageStarted, a.firstPageGate = aStarted, releaseFirstPages
	b.firstPageStarted, b.firstPageGate = bStarted, releaseFirstPages
	dynamic := newSearchClient()
	source := &namespaceMetadataSearchTestSource{
		authority: "cluster",
		dynamic:   dynamic,
		metadata: map[string]metadata.ResourceInterface{
			"a": a,
			"b": b,
		},
	}
	runtime, err := NewRuntime(RuntimeConfig{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	result := make(chan error, 1)
	var (
		batchMu  sync.Mutex
		progress []uint64
		final    SearchBatch
	)
	go func() {
		result <- runtime.Search(context.Background(), exactNamespaceSearchQuery(
			[]string{"b", "a", "b"}, "api",
		), func(batch SearchBatch) error {
			batchMu.Lock()
			progress = append(progress, batch.Examined)
			final = batch
			batchMu.Unlock()
			return nil
		})
	}()
	waitForSearchRequestStart(t, aStarted)
	waitForSearchRequestStart(t, bStarted)
	close(releaseFirstPages)
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("exact namespace search did not finish")
	}

	batchMu.Lock()
	gotProgress := slices.Clone(progress)
	gotFinal := final
	batchMu.Unlock()
	if !slices.Equal(gotProgress, []uint64{2, 3}) {
		t.Fatalf("progress = %v, want deterministic namespace/page order", gotProgress)
	}
	if !gotFinal.Complete || !gotFinal.Reusable || gotFinal.Examined != 3 || len(gotFinal.Results) != 3 {
		t.Fatalf("final batch = %#v", gotFinal)
	}
	if a.listCalls.Load() != 2 || b.listCalls.Load() != 1 || dynamic.listCalls.Load() != 0 {
		t.Fatalf(
			"LIST calls a/b/dynamic = %d/%d/%d, want 2/1/0",
			a.listCalls.Load(), b.listCalls.Load(), dynamic.listCalls.Load(),
		)
	}
	if got := source.openedMetadataNamespaces(); !slices.Equal(got, []string{"a", "b"}) {
		t.Fatalf("metadata namespaces = %v, want exact canonical streams", got)
	}

	var reused SearchBatch
	err = runtime.Search(context.Background(), exactNamespaceSearchQuery(
		[]string{"a", "b"}, "api-a2",
	), func(batch SearchBatch) error {
		reused = batch
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !reused.Complete || !reused.Reusable || len(reused.Results) != 1 ||
		reused.Results[0].GetIdentity().GetUid() != "uid-a2" {
		t.Fatalf("reused batch = %#v", reused)
	}
	if a.listCalls.Load() != 2 || b.listCalls.Load() != 1 {
		t.Fatalf("snapshot reuse issued another LIST: a/b = %d/%d", a.listCalls.Load(), b.listCalls.Load())
	}
}

func TestExactNamespaceMetadataSearchCancellationStopsChildPagination(t *testing.T) {
	t.Parallel()
	secondPageStarted := make(chan struct{})
	secondPageCanceled := make(chan struct{})
	a := newPaginatedMetadataSearchClient(
		metadataSearchPage("rv-a", "a-next", metadataSearchIdentity("uid-a1", "a", "match-a1")),
		metadataSearchPage("rv-a", "", metadataSearchIdentity("uid-a2", "a", "match-a2")),
	)
	a.secondPageStarted = secondPageStarted
	a.secondPageCanceled = secondPageCanceled
	a.secondPageGate = make(chan struct{})
	b := newPaginatedMetadataSearchClient(
		metadataSearchPage("rv-b", "", metadataSearchIdentity("uid-b", "b", "match-b")),
	)
	source := &namespaceMetadataSearchTestSource{
		authority: "cluster",
		dynamic:   newSearchClient(),
		metadata: map[string]metadata.ResourceInterface{
			"a": a,
			"b": b,
		},
	}
	runtime, err := NewRuntime(RuntimeConfig{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	ctx, cancel := context.WithCancel(context.Background())
	err = runtime.Search(ctx, exactNamespaceSearchQuery([]string{"a", "b"}, "match"), func(batch SearchBatch) error {
		if batch.Examined == 2 {
			waitForSearchRequestStart(t, secondPageStarted)
			cancel()
		}
		return nil
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Search error = %v, want context cancellation", err)
	}
	waitForSearchRequestStart(t, secondPageStarted)
	waitForSearchRequestStart(t, secondPageCanceled)
	if a.listCalls.Load() != 2 || b.listCalls.Load() != 1 {
		t.Fatalf("LIST calls after cancellation a/b = %d/%d", a.listCalls.Load(), b.listCalls.Load())
	}
}

func TestLargeNamespaceMetadataSearchUsesOneBroadListAndFiltersLocally(t *testing.T) {
	t.Parallel()
	broad := newPaginatedMetadataSearchClient(metadataSearchPage(
		"rv-broad", "",
		metadataSearchIdentity("uid-in", "a", "api-inside"),
		metadataSearchIdentity("uid-out", "outside", "api-outside"),
	))
	dynamic := newSearchClient()
	source := &namespaceMetadataSearchTestSource{
		authority: "cluster",
		dynamic:   dynamic,
		metadata:  map[string]metadata.ResourceInterface{"": broad},
	}
	runtime, err := NewRuntime(RuntimeConfig{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	namespaces := []string{"i", "h", "g", "f", "e", "d", "c", "b", "a"}
	var final SearchBatch
	err = runtime.Search(context.Background(), exactNamespaceSearchQuery(namespaces, "api"), func(batch SearchBatch) error {
		final = batch
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !final.Complete || final.Examined != 2 || len(final.Results) != 1 ||
		final.Results[0].GetIdentity().GetUid() != "uid-in" {
		t.Fatalf("broad locally-filtered batch = %#v", final)
	}
	if broad.listCalls.Load() != 1 || dynamic.listCalls.Load() != 0 {
		t.Fatalf("broad/dynamic LIST calls = %d/%d, want 1/0", broad.listCalls.Load(), dynamic.listCalls.Load())
	}
	if got := source.openedMetadataNamespaces(); !slices.Equal(got, []string{""}) {
		t.Fatalf("metadata namespaces = %q, want one all-namespaces client", got)
	}
}

func TestExactNamespaceMetadataSearchRejectsRepeatedChildContinuationToken(t *testing.T) {
	t.Parallel()
	a := newPaginatedMetadataSearchClient(
		metadataSearchPage("rv-a", "repeat", metadataSearchIdentity("uid-a1", "a", "api-a1")),
		metadataSearchPage("rv-a", "repeat", metadataSearchIdentity("uid-a2", "a", "api-a2")),
	)
	b := newPaginatedMetadataSearchClient(metadataSearchPage(
		"rv-b", "", metadataSearchIdentity("uid-b", "b", "api-b"),
	))
	runtime, err := NewRuntime(RuntimeConfig{Source: &namespaceMetadataSearchTestSource{
		authority: "cluster",
		dynamic:   newSearchClient(),
		metadata: map[string]metadata.ResourceInterface{
			"a": a,
			"b": b,
		},
	}})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	err = runtime.Search(context.Background(), exactNamespaceSearchQuery(
		[]string{"a", "b"}, "api",
	), func(SearchBatch) error { return nil })
	if err == nil || !strings.Contains(err.Error(), "repeated continue token") {
		t.Fatalf("Search error = %v, want repeated child continuation rejection", err)
	}
	if a.listCalls.Load() != 2 {
		t.Fatalf("namespace a LIST calls = %d, want 2", a.listCalls.Load())
	}
}

func exactNamespaceSearchQuery(namespaces []string, query string) SearchQuery {
	return SearchQuery{
		SessionID: "session",
		Resource: ResourceType{
			Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true,
		},
		NamespaceScope: NamespaceScope{Namespaces: slices.Clone(namespaces)},
		Query:          query, AllowPaginatedList: true,
	}
}

type namespaceMetadataSearchTestSource struct {
	mu         sync.Mutex
	authority  string
	dynamic    watcher.ListerWatcher
	metadata   map[string]metadata.ResourceInterface
	openedMeta []string
}

func (s *namespaceMetadataSearchTestSource) OpenResource(
	_ string,
	_ schema.GroupVersionResource,
	_ string,
) (string, watcher.ListerWatcher, error) {
	return s.authority, s.dynamic, nil
}

func (s *namespaceMetadataSearchTestSource) OpenMetadataSearchResource(
	_ string,
	_ schema.GroupVersionResource,
	namespace string,
) (string, metadata.ResourceInterface, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.openedMeta = append(s.openedMeta, namespace)
	client := s.metadata[namespace]
	if client == nil {
		return "", nil, errors.New("unexpected metadata namespace " + namespace)
	}
	return s.authority, client, nil
}

func (s *namespaceMetadataSearchTestSource) openedMetadataNamespaces() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.openedMeta)
}

type paginatedMetadataSearchClient struct {
	*metadataSearchTestClient
	mu                 sync.Mutex
	pages              []*metav1.PartialObjectMetadataList
	pageIndex          int
	firstPageStarted   chan struct{}
	firstPageGate      chan struct{}
	secondPageStarted  chan struct{}
	secondPageGate     chan struct{}
	secondPageCanceled chan struct{}
	firstStartedOnce   sync.Once
	secondStartedOnce  sync.Once
	secondCanceledOnce sync.Once
}

func newPaginatedMetadataSearchClient(
	pages ...*metav1.PartialObjectMetadataList,
) *paginatedMetadataSearchClient {
	return &paginatedMetadataSearchClient{
		metadataSearchTestClient: &metadataSearchTestClient{
			getObjects: make(map[string]*metav1.PartialObjectMetadata),
		},
		pages: pages,
	}
}

func (c *paginatedMetadataSearchClient) List(
	ctx context.Context,
	options metav1.ListOptions,
) (*metav1.PartialObjectMetadataList, error) {
	c.listCalls.Add(1)
	c.mu.Lock()
	if options.Continue == "" {
		c.pageIndex = 0
	}
	index := c.pageIndex
	c.pageIndex++
	page := c.pages[min(index, len(c.pages)-1)].DeepCopy()
	firstStarted, firstGate := c.firstPageStarted, c.firstPageGate
	secondStarted, secondGate, secondCanceled := c.secondPageStarted, c.secondPageGate, c.secondPageCanceled
	c.mu.Unlock()
	if index == 0 {
		if firstStarted != nil {
			c.firstStartedOnce.Do(func() { close(firstStarted) })
		}
		if firstGate != nil {
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-firstGate:
			}
		}
	}
	if index == 1 {
		if secondStarted != nil {
			c.secondStartedOnce.Do(func() { close(secondStarted) })
		}
		if secondGate != nil {
			select {
			case <-ctx.Done():
				if secondCanceled != nil {
					c.secondCanceledOnce.Do(func() { close(secondCanceled) })
				}
				return nil, ctx.Err()
			case <-secondGate:
			}
		}
	}
	return page, nil
}

func metadataSearchPage(
	resourceVersion string,
	continueToken string,
	objects ...metav1.PartialObjectMetadata,
) *metav1.PartialObjectMetadataList {
	result := &metav1.PartialObjectMetadataList{Items: slices.Clone(objects)}
	result.SetResourceVersion(resourceVersion)
	result.SetContinue(continueToken)
	return result
}

func metadataSearchIdentity(uid, namespace, name string) metav1.PartialObjectMetadata {
	return metav1.PartialObjectMetadata{ObjectMeta: metav1.ObjectMeta{
		UID: types.UID(uid), Namespace: namespace, Name: name, ResourceVersion: "object-rv",
	}}
}

func waitForSearchRequestStart(t *testing.T, started <-chan struct{}) {
	t.Helper()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for metadata LIST")
	}
}

var _ metadata.ResourceInterface = (*paginatedMetadataSearchClient)(nil)
