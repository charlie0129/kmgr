package watcher

import (
	"context"
	"errors"
	"slices"
	"sync"
	"testing"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"

	"github.com/charlie0129/kmgr/backend/internal/store"
)

func TestNamespaceFanInPaginatesInCanonicalOrderAndPreservesSelectors(t *testing.T) {
	t.Parallel()
	a := &namespaceFanInTestClient{}
	b := &namespaceFanInTestClient{}
	a.list = func(_ context.Context, options metav1.ListOptions) (*unstructured.UnstructuredList, error) {
		switch options.Continue {
		case "":
			return namespaceFanInList("a-10", "a-next", namespaceFanInObject("a", "a-1", "a-1", "a-10")), nil
		case "a-next":
			return namespaceFanInList("a-10", "", namespaceFanInObject("a", "a-2", "a-2", "a-10")), nil
		default:
			t.Fatalf("namespace a continue = %q", options.Continue)
			return nil, nil
		}
	}
	b.list = func(_ context.Context, options metav1.ListOptions) (*unstructured.UnstructuredList, error) {
		if options.Continue != "" {
			t.Fatalf("namespace b continue = %q", options.Continue)
		}
		return namespaceFanInList("b-20", "", namespaceFanInObject("b", "b-1", "b-1", "b-20")), nil
	}
	client := mustNamespaceFanIn(t, []NamespaceStream{
		{Namespace: "b", Client: b},
		{Namespace: "a", Client: a},
	})
	options := metav1.ListOptions{LabelSelector: "app=api", FieldSelector: "status.phase=Running", Limit: 500}
	first, err := client.List(context.Background(), options)
	if err != nil {
		t.Fatal(err)
	}
	if got := namespaceFanInNames(first.Items); !slices.Equal(got, []string{"a/a-1", "b/b-1"}) {
		t.Fatalf("first page order = %v", got)
	}
	if first.GetContinue() == "" {
		t.Fatal("first page has no composite continuation")
	}
	wantCheckpoint := first.GetResourceVersion()
	if revisions, err := decodeNamespaceCheckpoint(wantCheckpoint, []string{"a", "b"}); err != nil ||
		!slices.Equal(revisions, []string{"a-10", "b-20"}) {
		t.Fatalf("first checkpoint = %v, %v", revisions, err)
	}

	options.Continue = first.GetContinue()
	second, err := client.List(context.Background(), options)
	if err != nil {
		t.Fatal(err)
	}
	if got := namespaceFanInNames(second.Items); !slices.Equal(got, []string{"a/a-2"}) {
		t.Fatalf("second page = %v", got)
	}
	if second.GetContinue() != "" || second.GetResourceVersion() != wantCheckpoint {
		t.Fatalf("second page continuation/RV = %q/%q", second.GetContinue(), second.GetResourceVersion())
	}
	if got := len(b.listOptions()); got != 1 {
		t.Fatalf("completed namespace b LIST calls = %d, want 1", got)
	}
	for namespace, calls := range map[string][]metav1.ListOptions{"a": a.listOptions(), "b": b.listOptions()} {
		for _, call := range calls {
			if call.LabelSelector != options.LabelSelector || call.FieldSelector != options.FieldSelector || call.Limit != 500 {
				t.Fatalf("namespace %s selectors/limit = %#v", namespace, call)
			}
		}
	}
}

func TestNamespaceFanInVectorResumeAdvancesOnlyEventNamespace(t *testing.T) {
	t.Parallel()
	aWatch := watch.NewRaceFreeFake()
	bWatch := watch.NewRaceFreeFake()
	a := &namespaceFanInTestClient{watchResult: aWatch}
	b := &namespaceFanInTestClient{watchResult: bWatch}
	client := mustNamespaceFanIn(t, []NamespaceStream{
		{Namespace: "b", Client: b},
		{Namespace: "a", Client: a},
	})
	checkpoint := mustNamespaceCheckpoint(t, []namespaceStreamState{
		{Namespace: "a", ResourceVersion: "a-10"},
		{Namespace: "b", ResourceVersion: "b-20"},
	})
	stream, err := client.Watch(context.Background(), metav1.ListOptions{
		ResourceVersion: checkpoint, LabelSelector: "app=api", FieldSelector: "spec.nodeName=n1",
	})
	if err != nil {
		t.Fatal(err)
	}
	aWatch.Add(namespaceFanInObject("a", "new", "a-new", "a-11"))
	event := namespaceFanInEvent(t, stream.ResultChan())
	wrapped, ok := event.Object.(*checkpointedWatchObject)
	if !ok {
		t.Fatalf("event object type = %T", event.Object)
	}
	object := wrapped.Object.(*unstructured.Unstructured)
	if object.GetResourceVersion() != "a-11" {
		t.Fatalf("underlying object RV = %q", object.GetResourceVersion())
	}
	if revisions, err := decodeNamespaceCheckpoint(wrapped.Checkpoint, []string{"a", "b"}); err != nil ||
		!slices.Equal(revisions, []string{"a-11", "b-20"}) {
		t.Fatalf("advanced checkpoint = %v, %v", revisions, err)
	}
	stream.Stop()

	aCalls, bCalls := a.watchOptions(), b.watchOptions()
	if len(aCalls) != 1 || len(bCalls) != 1 ||
		aCalls[0].ResourceVersion != "a-10" || bCalls[0].ResourceVersion != "b-20" {
		t.Fatalf("child resume RVs = %#v / %#v", aCalls, bCalls)
	}
	if aCalls[0].LabelSelector != "app=api" || bCalls[0].FieldSelector != "spec.nodeName=n1" {
		t.Fatalf("watch selectors were not preserved: %#v / %#v", aCalls[0], bCalls[0])
	}
}

func TestPipelineCompositeCheckpointKeepsRawAndTableObjectRVsNative(t *testing.T) {
	t.Parallel()
	checkpoint := mustNamespaceCheckpoint(t, []namespaceStreamState{
		{Namespace: "a", ResourceVersion: "a-11"},
		{Namespace: "b", ResourceVersion: "b-20"},
	})

	t.Run("raw", func(t *testing.T) {
		uidStore := store.New()
		var batch Batch
		pipeline := &Pipeline{store: uidStore, onBatch: func(value Batch) { batch = value }}
		object := namespaceFanInObject("a", "raw", "raw", "a-native-11")
		err := pipeline.applyWatchEvent(watch.Event{
			Type: watch.Added,
			Object: &checkpointedWatchObject{
				Object: object, Checkpoint: checkpoint,
			},
		}, &watchResult{})
		if err != nil {
			t.Fatal(err)
		}
		if got := uidStore.Snapshot()[0].GetResourceVersion(); got != "a-native-11" {
			t.Fatalf("stored raw object RV = %q", got)
		}
		if uidStore.ResourceVersion() != checkpoint || batch.ResourceVersion != checkpoint {
			t.Fatalf("raw store/batch checkpoints = %q/%q", uidStore.ResourceVersion(), batch.ResourceVersion)
		}
	})

	t.Run("table", func(t *testing.T) {
		uidStore := store.New()
		columns := []metav1.TableColumnDefinition{{Name: "Name", Type: "string"}}
		var batch Batch
		pipeline := &Pipeline{
			store: uidStore, tableColumns: columns, onBatch: func(value Batch) { batch = value },
		}
		object := namespaceFanInObject("a", "table", "table", "row-native-12")
		table := &metav1.Table{
			ListMeta:          metav1.ListMeta{ResourceVersion: "table-native-12"},
			ColumnDefinitions: columns,
			Rows: []metav1.TableRow{{
				Cells: []any{"table"}, Object: runtime.RawExtension{Object: object},
			}},
		}
		err := pipeline.applyWatchEvent(watch.Event{
			Type: watch.Modified,
			Object: &checkpointedWatchObject{
				Object: table, Checkpoint: checkpoint,
			},
		}, &watchResult{})
		if err != nil {
			t.Fatal(err)
		}
		if got := uidStore.Snapshot()[0].GetResourceVersion(); got != "row-native-12" {
			t.Fatalf("stored Table row object RV = %q", got)
		}
		if uidStore.ResourceVersion() != checkpoint || batch.ResourceVersion != checkpoint {
			t.Fatalf("Table store/batch checkpoints = %q/%q", uidStore.ResourceVersion(), batch.ResourceVersion)
		}
		if got := batch.Table.Cells["table"]; !slices.Equal(got, []any{"table"}) {
			t.Fatalf("Table cells = %#v", got)
		}
	})
}

func TestNamespaceTableFanInMergesCellsAndFallsBackCoherently(t *testing.T) {
	t.Parallel()
	columns := []metav1.TableColumnDefinition{{Name: "Name", Type: "string"}}
	a := newNamespaceFanInTableClient("a", "a-10", columns)
	b := newNamespaceFanInTableClient("b", "b-20", columns)
	client := mustNamespaceFanIn(t, []NamespaceStream{
		{Namespace: "b", Client: b},
		{Namespace: "a", Client: a},
	})
	tableClient, ok := client.(TableListerWatcher)
	if !ok {
		t.Fatalf("all-Table fan-in type = %T", client)
	}
	page, err := tableClient.ListTable(context.Background(), metav1.ListOptions{LabelSelector: "app=api"})
	if err != nil {
		t.Fatal(err)
	}
	if !page.ServerTable || !reflectTableColumns(page.Columns, columns) || len(page.Cells) != 2 ||
		!slices.Equal(namespaceFanInObjectNames(page.Objects), []string{"a/a", "b/b"}) {
		t.Fatalf("merged Table page = %#v", page)
	}

	// A child that silently downgrades its Table watch makes the complete fan-in
	// expire. Pipeline will relist through ListTable's disabled/raw path, which
	// emits TableData.Disabled and clears every stale server-cell sidecar.
	a.fallbackWatch = true
	stream, err := tableClient.WatchTable(context.Background(), metav1.ListOptions{ResourceVersion: page.ResourceVersion})
	if stream != nil || !apierrors.IsResourceExpired(err) {
		t.Fatalf("mixed Table watch = %T, %v; want resource expired", stream, err)
	}
	if tableClient.TableEnabled() {
		t.Fatal("Table fan-in remained enabled after mixed watch")
	}
	rawPage, err := tableClient.ListTable(context.Background(), metav1.ListOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if rawPage.ServerTable || len(rawPage.Cells) != 0 || a.rawListCalls() == 0 || b.rawListCalls() == 0 {
		t.Fatalf("coherent raw relist = %#v; raw calls %d/%d", rawPage, a.rawListCalls(), b.rawListCalls())
	}
}

func TestNamespaceFanInRejectsDuplicateNamespacesUIDsAndCancelsMergedWatch(t *testing.T) {
	t.Parallel()
	client := &namespaceFanInTestClient{}
	if _, err := NewNamespaceFanIn([]NamespaceStream{
		{Namespace: "a", Client: client}, {Namespace: "a", Client: client},
	}); err == nil {
		t.Fatal("duplicate namespace was accepted")
	}

	duplicateUID := types.UID("same")
	a := &namespaceFanInTestClient{listResult: namespaceFanInList(
		"a-1", "", namespaceFanInObject("a", "a", duplicateUID, "a-1"),
	)}
	b := &namespaceFanInTestClient{listResult: namespaceFanInList(
		"b-1", "", namespaceFanInObject("b", "b", duplicateUID, "b-1"),
	)}
	merged := mustNamespaceFanIn(t, []NamespaceStream{{Namespace: "a", Client: a}, {Namespace: "b", Client: b}})
	if _, err := merged.List(context.Background(), metav1.ListOptions{}); err == nil {
		t.Fatal("cross-namespace duplicate UID was accepted")
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := merged.Watch(ctx, metav1.ListOptions{}); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled Watch error = %v", err)
	}
}

type namespaceFanInTestClient struct {
	mu          sync.Mutex
	list        func(context.Context, metav1.ListOptions) (*unstructured.UnstructuredList, error)
	listResult  *unstructured.UnstructuredList
	watchResult watch.Interface
	lists       []metav1.ListOptions
	watches     []metav1.ListOptions
}

func (c *namespaceFanInTestClient) List(
	ctx context.Context,
	options metav1.ListOptions,
) (*unstructured.UnstructuredList, error) {
	c.mu.Lock()
	c.lists = append(c.lists, options)
	callback, result := c.list, c.listResult
	c.mu.Unlock()
	if callback != nil {
		return callback(ctx, options)
	}
	return result, nil
}

func (c *namespaceFanInTestClient) Watch(
	_ context.Context,
	options metav1.ListOptions,
) (watch.Interface, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.watches = append(c.watches, options)
	return c.watchResult, nil
}

func (c *namespaceFanInTestClient) listOptions() []metav1.ListOptions {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]metav1.ListOptions(nil), c.lists...)
}

func (c *namespaceFanInTestClient) watchOptions() []metav1.ListOptions {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]metav1.ListOptions(nil), c.watches...)
}

type namespaceFanInTableClient struct {
	*namespaceFanInTestClient
	mu            sync.Mutex
	namespace     string
	revision      string
	columns       []metav1.TableColumnDefinition
	disabled      bool
	fallbackWatch bool
	tableWatch    *watch.RaceFreeFakeWatcher
}

func newNamespaceFanInTableClient(
	namespace, revision string,
	columns []metav1.TableColumnDefinition,
) *namespaceFanInTableClient {
	client := &namespaceFanInTableClient{
		namespaceFanInTestClient: &namespaceFanInTestClient{},
		namespace:                namespace, revision: revision, columns: columns,
		tableWatch: watch.NewRaceFreeFake(),
	}
	client.namespaceFanInTestClient.listResult = namespaceFanInList(
		revision, "", namespaceFanInObject(namespace, namespace, types.UID(namespace), revision),
	)
	return client
}

func (c *namespaceFanInTableClient) TableEnabled() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return !c.disabled
}

func (c *namespaceFanInTableClient) DisableTable() {
	c.mu.Lock()
	c.disabled = true
	c.mu.Unlock()
}

func (c *namespaceFanInTableClient) ListTable(
	ctx context.Context,
	options metav1.ListOptions,
) (*TableList, error) {
	if !c.TableEnabled() {
		page, err := c.List(ctx, options)
		return &TableList{
			ResourceVersion: page.GetResourceVersion(), Continue: page.GetContinue(),
			Objects: unstructuredListObjects(page),
		}, err
	}
	object := namespaceFanInObject(c.namespace, c.namespace, types.UID(c.namespace), c.revision)
	return &TableList{
		ResourceVersion: c.revision,
		Objects:         []*unstructured.Unstructured{object},
		Columns:         append([]metav1.TableColumnDefinition(nil), c.columns...),
		Cells:           map[types.UID][]any{object.GetUID(): {c.namespace}},
		ServerTable:     true,
	}, nil
}

func (c *namespaceFanInTableClient) WatchTable(
	_ context.Context,
	options metav1.ListOptions,
) (watch.Interface, error) {
	c.mu.Lock()
	fallback := c.fallbackWatch
	if fallback {
		c.disabled = true
	}
	c.mu.Unlock()
	c.namespaceFanInTestClient.mu.Lock()
	c.namespaceFanInTestClient.watches = append(c.namespaceFanInTestClient.watches, options)
	c.namespaceFanInTestClient.mu.Unlock()
	return c.tableWatch, nil
}

func (c *namespaceFanInTableClient) rawListCalls() int {
	return len(c.listOptions())
}

func mustNamespaceFanIn(t *testing.T, streams []NamespaceStream) ListerWatcher {
	t.Helper()
	client, err := NewNamespaceFanIn(streams)
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func mustNamespaceCheckpoint(t *testing.T, states []namespaceStreamState) string {
	t.Helper()
	checkpoint, err := encodeNamespaceCheckpoint(states)
	if err != nil {
		t.Fatal(err)
	}
	return checkpoint
}

func namespaceFanInObject(
	namespace, name string,
	uid types.UID,
	resourceVersion string,
) *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1",
		"kind":       "Pod",
		"metadata": map[string]any{
			"namespace":       namespace,
			"name":            name,
			"uid":             string(uid),
			"resourceVersion": resourceVersion,
		},
	}}
}

func namespaceFanInList(
	resourceVersion, continuation string,
	objects ...*unstructured.Unstructured,
) *unstructured.UnstructuredList {
	result := &unstructured.UnstructuredList{Items: make([]unstructured.Unstructured, len(objects))}
	for index, object := range objects {
		result.Items[index] = *object
	}
	result.SetResourceVersion(resourceVersion)
	result.SetContinue(continuation)
	return result
}

func namespaceFanInNames(objects []unstructured.Unstructured) []string {
	result := make([]string, len(objects))
	for index := range objects {
		result[index] = objects[index].GetNamespace() + "/" + objects[index].GetName()
	}
	return result
}

func namespaceFanInObjectNames(objects []*unstructured.Unstructured) []string {
	result := make([]string, len(objects))
	for index, object := range objects {
		result[index] = object.GetNamespace() + "/" + object.GetName()
	}
	return result
}

func namespaceFanInEvent(t *testing.T, events <-chan watch.Event) watch.Event {
	t.Helper()
	select {
	case event, ok := <-events:
		if !ok {
			t.Fatal("watch closed before event")
		}
		return event
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for watch event")
		return watch.Event{}
	}
}

func reflectTableColumns(left, right []metav1.TableColumnDefinition) bool {
	return slices.EqualFunc(left, right, func(a, b metav1.TableColumnDefinition) bool {
		return a.Name == b.Name && a.Type == b.Type && a.Format == b.Format && a.Priority == b.Priority
	})
}
