package view

import (
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/watcher"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
)

func TestRuntimeTableOpenIgnoresCompletedRawSearchHandoff(t *testing.T) {
	t.Parallel()
	raw := newSearchClient()
	raw.pages = []*unstructured.UnstructuredList{listPage(
		"search-rv", "", runtimeTableObject("raw-uid", "raw-search", "search-rv"),
	)}
	table := newRuntimeTableClient(runtimeTableObject("table-uid", "table-live", "table-rv"))
	source := &runtimeTableSource{authority: "cluster-a", raw: raw, table: table}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: source, BatchDelay: time.Millisecond, PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	var final SearchBatch
	err = runtime.Search(context.Background(), runtimeTableSearchQuery("raw-search"), func(batch SearchBatch) error {
		final = batch
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !final.Complete || !final.Reusable {
		t.Fatalf("raw search final = %#v", final)
	}
	runtime.mu.Lock()
	retainedSearchSnapshots := len(runtime.searchSnapshots)
	runtime.mu.Unlock()
	if retainedSearchSnapshots != 1 {
		t.Fatalf("retained search snapshots = %d, want 1", retainedSearchSnapshots)
	}

	subscription, err := runtime.Open(runtimeTableOpenRequest("table-view"))
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	schema, row, observedUIDs := waitForRuntimeTableRow(t, subscription, "table-uid")
	if schema == nil || len(schema.GetColumns()) != 2 ||
		schema.GetColumns()[0].GetTitle() != "Status" || schema.GetColumns()[1].GetTitle() != "Detail" {
		t.Fatalf("Table schema = %#v", schema)
	}
	if !rowContainsDisplay(row, "Ready") || !rowContainsDisplay(row, "secondary") {
		t.Fatalf("Table row omitted server cells: %#v", row)
	}
	if observedUIDs["raw-uid"] {
		t.Fatalf("Table Open consumed raw search row: %v", observedUIDs)
	}
	eventually(t, time.Second, func() bool { return table.watchTableCalls.Load() == 1 })
	if table.listTableCalls.Load() != 1 || table.rawListCalls.Load() != 0 || table.rawWatchCalls.Load() != 0 {
		t.Fatalf("Table view calls Table LIST=%d WATCH=%d raw LIST=%d WATCH=%d",
			table.listTableCalls.Load(), table.watchTableCalls.Load(), table.rawListCalls.Load(), table.rawWatchCalls.Load())
	}
	if raw.listCalls.Load() != 1 || raw.watchCalls.Load() != 0 {
		t.Fatalf("raw search client LIST=%d WATCH=%d", raw.listCalls.Load(), raw.watchCalls.Load())
	}
	if source.tableOpens.Load() != 1 || source.rawOpens.Load() != 1 {
		t.Fatalf("source opens raw=%d Table=%d", source.rawOpens.Load(), source.tableOpens.Load())
	}
	if source.tableObject != metav1.IncludeMetadata {
		t.Fatalf("default Table object policy = %q, want Metadata", source.tableObject)
	}
	runtime.mu.Lock()
	retainedSearchSnapshots = len(runtime.searchSnapshots)
	runtime.mu.Unlock()
	if retainedSearchSnapshots != 1 {
		t.Fatal("Table Open consumed the completed raw search snapshot")
	}
}

func TestRuntimeTableOpenIgnoresInProgressRawSearchHandoff(t *testing.T) {
	t.Parallel()
	raw := newSearchClient()
	raw.pages = []*unstructured.UnstructuredList{listPage(
		"search-rv", "", runtimeTableObject("raw-uid", "raw-search", "search-rv"),
	)}
	raw.firstPageGate = make(chan struct{})
	table := newRuntimeTableClient(runtimeTableObject("table-uid", "table-live", "table-rv"))
	source := &runtimeTableSource{authority: "cluster-a", raw: raw, table: table}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: source, BatchDelay: time.Millisecond, PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	searchDone := make(chan error, 1)
	go func() {
		searchDone <- runtime.Search(
			context.Background(), runtimeTableSearchQuery("raw-search"), func(SearchBatch) error { return nil },
		)
	}()
	eventually(t, time.Second, func() bool { return raw.listCalls.Load() == 1 })
	runtime.mu.Lock()
	var transient *transientSearchList
	for _, candidate := range runtime.transientSearchLists {
		transient = candidate
		break
	}
	runtime.mu.Unlock()
	if transient == nil {
		t.Fatal("raw search did not install an in-progress handoff")
	}

	subscription, err := runtime.Open(runtimeTableOpenRequest("table-view"))
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	_, _, observedUIDs := waitForRuntimeTableRow(t, subscription, "table-uid")
	if observedUIDs["raw-uid"] {
		t.Fatalf("Table Open joined in-progress raw search: %v", observedUIDs)
	}
	runtime.mu.Lock()
	joined := transient.view != nil
	runtime.mu.Unlock()
	if joined {
		t.Fatal("Table Open attached to the raw transient search coordinator")
	}
	if table.listTableCalls.Load() != 1 {
		t.Fatalf("Table LIST calls = %d, want 1", table.listTableCalls.Load())
	}
	close(raw.firstPageGate)
	select {
	case err := <-searchDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("raw search did not finish")
	}
}

func TestRuntimeTableOpenCatchupRefreshesInterveningServerCells(t *testing.T) {
	t.Parallel()
	table := newRuntimeTableClient(runtimeTableObject("table-uid", "table-live", "table-rv"))
	source := &runtimeTableSource{authority: "cluster-a", raw: newSearchClient(), table: table}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: source, BatchDelay: time.Millisecond, PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(runtimeTableOpenRequest("table-view-a"))
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	_, firstRow, _ := waitForRuntimeTableRow(t, first, "table-uid")
	if !rowContainsDisplay(firstRow, "Ready") {
		t.Fatalf("initial Table row = %#v", firstRow)
	}

	entry, runNumber := onlyRuntimeTableEntry(t, runtime)
	updated := runtimeTableObject("table-uid", "table-live", "table-rv-2")
	var injected atomic.Bool
	runtime.openHandoffHook = func() {
		if !injected.CompareAndSwap(false, true) {
			return
		}
		entry.store.Upsert(updated)
		entry.store.SetResourceVersion("table-rv-2")
		runtime.receiveBatch(entry, runNumber, watcher.Batch{
			Upserts: []*unstructured.Unstructured{updated}, ResourceVersion: "table-rv-2",
			SynchronizedAt: time.Now(),
			Table: &watcher.TableData{
				Columns: table.page.Columns,
				Cells: map[types.UID][]any{
					updated.GetUID(): {updated.GetName(), updated.GetNamespace(), "Updated", "new-detail", "1m"},
				},
			},
		})
	}
	second, err := runtime.Open(runtimeTableOpenRequest("table-view-b"))
	runtime.openHandoffHook = nil
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	if !injected.Load() {
		t.Fatal("intervening Table update was not injected")
	}
	row := waitForRuntimeTableDisplay(t, second, "table-uid", "Updated")
	if !rowContainsDisplay(row, "new-detail") {
		t.Fatalf("catch-up row omitted latest server cells: %#v", row)
	}
}

func TestRuntimeTableDisableRebuildsRowsWithoutStaleServerCells(t *testing.T) {
	t.Parallel()
	table := newRuntimeTableClient(runtimeTableObject("table-uid", "table-live", "table-rv"))
	source := &runtimeTableSource{authority: "cluster-a", raw: newSearchClient(), table: table}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: source, BatchDelay: time.Millisecond, PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	subscription, err := runtime.Open(runtimeTableOpenRequest("table-view"))
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	_, initial, _ := waitForRuntimeTableRow(t, subscription, "table-uid")
	if !rowContainsDisplay(initial, "Ready") {
		t.Fatalf("initial Table row = %#v", initial)
	}

	entry, runNumber := onlyRuntimeTableEntry(t, runtime)
	runtime.receiveBatch(entry, runNumber, watcher.Batch{
		ResourceVersion: "table-rv", SynchronizedAt: time.Now(),
		Table: &watcher.TableData{Disabled: true},
	})

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var rawSchema bool
	var replacement *kmgrv1.ResourceRow
	for !rawSchema || replacement == nil {
		events, err := subscription.Next(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if err := subscription.AcknowledgeDelivery(events); err != nil {
			t.Fatal(err)
		}
		for _, event := range events {
			if schema := event.GetSchema(); schema != nil && !schema.GetServerTable() {
				rawSchema = true
			}
			for _, row := range append(event.GetSnapshot().GetRows(), event.GetDelta().GetUpserts()...) {
				if row.GetIdentity().GetUid() == "table-uid" {
					replacement = row
				}
			}
		}
	}
	if rowContainsDisplay(replacement, "Ready") || rowContainsDisplay(replacement, "secondary") {
		t.Fatalf("raw fallback retained stale server cells: %#v", replacement)
	}
}

type runtimeTableSource struct {
	authority   string
	raw         watcher.ListerWatcher
	table       watcher.ListerWatcher
	rawOpens    atomic.Int64
	tableOpens  atomic.Int64
	tableObject metav1.IncludeObjectPolicy
}

func (s *runtimeTableSource) OpenResource(
	string,
	schema.GroupVersionResource,
	string,
) (string, watcher.ListerWatcher, error) {
	s.rawOpens.Add(1)
	return s.authority, s.raw, nil
}

func (s *runtimeTableSource) OpenTableResource(
	_ string,
	_ schema.GroupVersionResource,
	_ string,
	include metav1.IncludeObjectPolicy,
) (string, watcher.ListerWatcher, error) {
	// Runtime opens one table stream at a time in these fixtures. Record the
	// representation decision so the integration test proves it reaches the
	// source boundary.
	s.tableObject = include
	s.tableOpens.Add(1)
	return s.authority, s.table, nil
}

type runtimeTableClient struct {
	page            *watcher.TableList
	disabled        atomic.Bool
	listTableCalls  atomic.Int64
	watchTableCalls atomic.Int64
	rawListCalls    atomic.Int64
	rawWatchCalls   atomic.Int64
}

func newRuntimeTableClient(object *unstructured.Unstructured) *runtimeTableClient {
	columns := []metav1.TableColumnDefinition{
		{Name: "Name", Type: "string", Format: "name"},
		{Name: "Namespace", Type: "string"},
		{Name: "Status", Type: "string"},
		{Name: "Detail", Type: "string", Priority: 1},
		{Name: "Age", Type: "string"},
	}
	return &runtimeTableClient{page: &watcher.TableList{
		ResourceVersion: "table-rv", Objects: []*unstructured.Unstructured{object},
		Columns: columns, ServerTable: true,
		Cells: map[types.UID][]any{
			object.GetUID(): {object.GetName(), object.GetNamespace(), "Ready", "secondary", "1m"},
		},
	}}
}

func (c *runtimeTableClient) List(context.Context, metav1.ListOptions) (*unstructured.UnstructuredList, error) {
	c.rawListCalls.Add(1)
	return nil, errors.New("unexpected raw LIST")
}

func (c *runtimeTableClient) Watch(context.Context, metav1.ListOptions) (watch.Interface, error) {
	c.rawWatchCalls.Add(1)
	return nil, errors.New("unexpected raw WATCH")
}

func (c *runtimeTableClient) ListTable(context.Context, metav1.ListOptions) (*watcher.TableList, error) {
	c.listTableCalls.Add(1)
	return c.page, nil
}

func (c *runtimeTableClient) WatchTable(context.Context, metav1.ListOptions) (watch.Interface, error) {
	c.watchTableCalls.Add(1)
	return watch.NewRaceFreeFake(), nil
}

func (c *runtimeTableClient) TableEnabled() bool { return !c.disabled.Load() }
func (c *runtimeTableClient) DisableTable()      { c.disabled.Store(true) }

func runtimeTableObject(uid, name, resourceVersion string) *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "example.io/v1", "kind": "Widget",
		"metadata": map[string]any{
			"uid": uid, "namespace": "team-a", "name": name, "resourceVersion": resourceVersion,
		},
	}}
}

func runtimeTableSearchQuery(query string) SearchQuery {
	return SearchQuery{
		SessionID: "palette", Resource: ResourceType{
			Group: "example.io", Version: "v1", Resource: "widgets", Kind: "Widget", Namespaced: true,
		},
		NamespaceScope: NamespaceScope{Namespaces: []string{"team-a"}}, Query: query,
		AllowPaginatedList: true,
	}
}

func runtimeTableOpenRequest(viewID string) *kmgrv1.OpenViewRequest {
	return &kmgrv1.OpenViewRequest{
		Context: &kmgrv1.RequestContext{RequestId: "table-open", ClusterSessionId: "workspace"},
		ViewId:  viewID, Generation: 1,
		Spec: &kmgrv1.ViewSpec{
			Resource: &kmgrv1.ResourceType{
				Group: "example.io", Version: "v1", Resource: "widgets", Kind: "Widget", Namespaced: true,
			},
			NamespaceScope: &kmgrv1.NamespaceScope{Namespaces: []string{"team-a"}},
		},
	}
}

func waitForRuntimeTableRow(
	t *testing.T,
	subscription *Subscription,
	wantUID string,
) (*kmgrv1.ViewSchema, *kmgrv1.ResourceRow, map[string]bool) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var gotSchema *kmgrv1.ViewSchema
	var gotRow *kmgrv1.ResourceRow
	observedUIDs := make(map[string]bool)
	for gotSchema == nil || gotRow == nil {
		events, err := subscription.Next(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if err := subscription.AcknowledgeDelivery(events); err != nil {
			t.Fatal(err)
		}
		for _, event := range events {
			if event.GetSchema() != nil && event.GetSchema().GetServerTable() {
				gotSchema = event.GetSchema()
			}
			rows := append(event.GetSnapshot().GetRows(), event.GetDelta().GetUpserts()...)
			for _, row := range rows {
				uid := row.GetIdentity().GetUid()
				observedUIDs[uid] = true
				if uid == wantUID {
					gotRow = row
				}
			}
		}
	}
	return gotSchema, gotRow, observedUIDs
}

func waitForRuntimeTableDisplay(
	t *testing.T,
	subscription *Subscription,
	wantUID, wantDisplay string,
) *kmgrv1.ResourceRow {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	for {
		events, err := subscription.Next(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if err := subscription.AcknowledgeDelivery(events); err != nil {
			t.Fatal(err)
		}
		for _, event := range events {
			for _, row := range append(event.GetSnapshot().GetRows(), event.GetDelta().GetUpserts()...) {
				if row.GetIdentity().GetUid() == wantUID && rowContainsDisplay(row, wantDisplay) {
					return row
				}
			}
		}
	}
}

func onlyRuntimeTableEntry(t *testing.T, runtime *Runtime) (*resourceRuntime, uint64) {
	t.Helper()
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	if len(runtime.resources) != 1 {
		t.Fatalf("resource runtimes = %d, want 1", len(runtime.resources))
	}
	for _, entry := range runtime.resources {
		return entry, entry.runNumber
	}
	t.Fatal("resource runtime is missing")
	return nil, 0
}

func rowContainsDisplay(row *kmgrv1.ResourceRow, value string) bool {
	for _, cell := range row.GetCells() {
		if strings.EqualFold(cell.GetDisplayText(), value) {
			return true
		}
	}
	return false
}

var _ TableResourceSource = (*runtimeTableSource)(nil)
var _ watcher.TableListerWatcher = (*runtimeTableClient)(nil)
