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

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/watch"

	"github.com/charlie0129/kmgr/backend/internal/watcher"
)

func TestRuntimeSharesCompatiblePipelineAndDebouncesFinalRelease(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage("rv-1", "", pod("uid-a", "ns", "a", "Running", 0, nil, time.Time{}))}
	source := &fakeResourceSource{authority: "cluster-a", client: client}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: source, ReleaseDelay: 25 * time.Millisecond, BatchDelay: time.Millisecond,
		PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session-1", "view-1", 1))
	if err != nil {
		t.Fatal(err)
	}
	second, err := runtime.Open(openView("session-2", "view-2", 1))
	if err != nil {
		t.Fatal(err)
	}
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })
	if source.opens.Load() != 2 {
		t.Fatalf("source opens = %d, want one resolution per view", source.opens.Load())
	}

	first.Close()
	if client.lastWatch().stopped.Load() {
		t.Fatal("shared watch stopped while second consumer remained")
	}
	second.Close()
	time.Sleep(10 * time.Millisecond)
	third, err := runtime.Open(openView("session-1", "view-3", 1))
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(30 * time.Millisecond)
	if client.lastWatch().stopped.Load() {
		t.Fatal("watch stopped despite reacquire during debounce")
	}
	third.Close()
	eventually(t, time.Second, func() bool { return client.lastWatch().stopped.Load() })
}

func TestRuntimeReturnsWarmSnapshotBeforeResumeAndAvoidsRelist(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{listPage("rv-1", "", pod("uid-a", "ns", "a", "Running", 0, nil, time.Time{}))}
	source := &fakeResourceSource{authority: "cluster-a", client: client}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: source, ReleaseDelay: 5 * time.Millisecond, BatchDelay: time.Millisecond,
		SnapshotChunkSize: 1, PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session-1", "view-1", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, first, "uid-a")
	first.Close()
	eventually(t, time.Second, func() bool { return client.lastWatch().stopped.Load() })

	second, err := runtime.Open(openView("session-1", "view-2", 1))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	events, err := second.Next(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var freshness []kmgrv1.ViewFreshness
	var snapshotUIDs []string
	for _, event := range events {
		if event.GetStatus() != nil {
			freshness = append(freshness, event.GetStatus().GetFreshness())
		}
		for _, row := range event.GetSnapshot().GetRows() {
			snapshotUIDs = append(snapshotUIDs, row.GetIdentity().GetUid())
		}
	}
	if !slices.Contains(freshness, kmgrv1.ViewFreshness_VIEW_FRESHNESS_STALE) {
		t.Fatalf("first warm delivery freshness = %v, missing STALE", freshness)
	}
	if !slices.Contains(snapshotUIDs, "uid-a") {
		t.Fatalf("first warm delivery UIDs = %v", snapshotUIDs)
	}
	eventually(t, time.Second, func() bool { return client.watchCalls.Load() >= 2 })
	if client.listCalls.Load() != 1 {
		t.Fatalf("warm resume LIST calls = %d, want 1 initial LIST only", client.listCalls.Load())
	}
	if got := client.lastWatchResourceVersion(); got != "rv-1" {
		t.Fatalf("resume resourceVersion = %q, want rv-1", got)
	}
}

func TestRuntimeRelistKeepsWarmRowsUntilFinalPage(t *testing.T) {
	t.Parallel()
	client := newScriptedResource()
	client.listPages = []*unstructured.UnstructuredList{
		listPage("rv-1", "", pod("old-a", "ns", "old-a", "Running", 0, nil, time.Time{}), pod("old-b", "ns", "old-b", "Running", 0, nil, time.Time{})),
	}
	source := &fakeResourceSource{authority: "cluster-a", client: client}
	runtime, err := NewRuntime(RuntimeConfig{Source: source, ReleaseDelay: 5 * time.Millisecond, BatchDelay: time.Millisecond, PipelineTimeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	first, err := runtime.Open(openView("session-1", "view-1", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, first, "old-b")
	first.Close()
	eventually(t, time.Second, func() bool { return client.lastWatch().stopped.Load() })

	pageGate := make(chan struct{})
	client.mu.Lock()
	client.expireNextWatch = true
	client.listPages = []*unstructured.UnstructuredList{
		listPage("rv-2", "next", pod("new-a", "ns", "new-a", "Running", 0, nil, time.Time{})),
		listPage("rv-2", "", pod("old-a", "ns", "old-a", "Running", 0, nil, time.Time{})),
	}
	client.beforeListPage = map[int]chan struct{}{1: pageGate}
	client.mu.Unlock()

	second, err := runtime.Open(openView("session-1", "view-2", 1))
	if err != nil {
		t.Fatal(err)
	}
	waitForSnapshotUID(t, second, "old-b")
	eventually(t, time.Second, func() bool { return client.listCalls.Load() >= 2 })

	// The first relist page arrived, but old-b must not be removed until the
	// consistent second/final page commits reconciliation.
	time.Sleep(15 * time.Millisecond)
	second.mu.Lock()
	_, retained := second.rows["old-b"]
	second.mu.Unlock()
	if !retained {
		t.Fatal("cached old-b was removed before relist completed")
	}
	close(pageGate)
	eventually(t, time.Second, func() bool {
		second.mu.Lock()
		defer second.mu.Unlock()
		_, oldB := second.rows["old-b"]
		_, oldA := second.rows["old-a"]
		_, newA := second.rows["new-a"]
		return !oldB && oldA && newA
	})
}

func TestSlowSubscriptionFallsBackToBoundedSnapshot(t *testing.T) {
	t.Parallel()
	source := &fakeResourceSource{authority: "cluster-a", client: newScriptedResource()}
	runtime, err := NewRuntime(RuntimeConfig{Source: source, PendingRowLimit: 2, SnapshotChunkSize: 2, BatchDelay: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	subscription, err := runtime.Open(openView("session-1", "view-1", 1))
	if err != nil {
		t.Fatal(err)
	}
	// Drain the initial empty snapshot/status first.
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	_, _ = subscription.Next(ctx)
	cancel()

	objects := []*unstructured.Unstructured{
		pod("uid-1", "ns", "one", "Running", 0, nil, time.Time{}),
		pod("uid-2", "ns", "two", "Running", 0, nil, time.Time{}),
		pod("uid-3", "ns", "three", "Running", 0, nil, time.Time{}),
	}
	subscription.applyBatch(watcher.Batch{Upserts: objects})
	subscription.mu.Lock()
	if !subscription.resnapshot || len(subscription.pendingUpserts) != 0 {
		t.Fatalf("slow mailbox state: resnapshot=%v pending=%d", subscription.resnapshot, len(subscription.pendingUpserts))
	}
	subscription.signalLocked(true)
	subscription.mu.Unlock()

	ctx, cancel = context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	events, err := subscription.Next(ctx)
	if err != nil {
		t.Fatal(err)
	}
	chunks := 0
	rows := 0
	for _, event := range events {
		if event.GetSnapshot() != nil {
			chunks++
			rows += len(event.GetSnapshot().GetRows())
			if len(event.GetSnapshot().GetRows()) > 2 {
				t.Fatal("snapshot chunk exceeded configured bound")
			}
		}
	}
	if chunks != 2 || rows != 3 {
		t.Fatalf("snapshot chunks=%d rows=%d", chunks, rows)
	}
}

func TestStaleCancelCannotCloseReplacementGeneration(t *testing.T) {
	t.Parallel()
	source := &fakeResourceSource{authority: "cluster-a", client: newScriptedResource()}
	runtime, err := NewRuntime(RuntimeConfig{Source: source, ReleaseDelay: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	if _, err := runtime.Open(openView("session-1", "same", 1)); err != nil {
		t.Fatal(err)
	}
	secondRequest := openView("session-1", "same", 2)
	second, err := runtime.Open(secondRequest)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.Cancel("session-1", "same", 1) {
		t.Fatal("stale cancel reported success")
	}
	select {
	case <-second.done:
		t.Fatal("stale cancel closed replacement generation")
	default:
	}
}

type fakeResourceSource struct {
	authority string
	client    watcher.ListerWatcher
	opens     atomic.Int64
}

func (s *fakeResourceSource) OpenResource(string, schema.GroupVersionResource, string) (string, watcher.ListerWatcher, error) {
	s.opens.Add(1)
	return s.authority, s.client, nil
}

type scriptedResource struct {
	mu              sync.Mutex
	listPages       []*unstructured.UnstructuredList
	beforeListPage  map[int]chan struct{}
	listIndex       int
	expireNextWatch bool
	watches         []*controllableWatch
	watchRVs        []string
	listCalls       atomic.Int64
	watchCalls      atomic.Int64
}

func newScriptedResource() *scriptedResource {
	return &scriptedResource{listPages: []*unstructured.UnstructuredList{listPage("rv-empty", "")}}
}

func (c *scriptedResource) List(ctx context.Context, options metav1.ListOptions) (*unstructured.UnstructuredList, error) {
	call := int(c.listCalls.Add(1)) - 1
	c.mu.Lock()
	if options.Continue == "" {
		c.listIndex = 0
	}
	index := c.listIndex
	if index >= len(c.listPages) {
		index = len(c.listPages) - 1
	}
	page := c.listPages[index].DeepCopy()
	gate := c.beforeListPage[index]
	c.listIndex++
	c.mu.Unlock()
	_ = call
	if gate != nil {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-gate:
		}
	}
	return page, nil
}

func (c *scriptedResource) Watch(_ context.Context, options metav1.ListOptions) (watch.Interface, error) {
	c.watchCalls.Add(1)
	c.mu.Lock()
	defer c.mu.Unlock()
	stream := newControllableWatch()
	c.watches = append(c.watches, stream)
	c.watchRVs = append(c.watchRVs, options.ResourceVersion)
	if c.expireNextWatch {
		c.expireNextWatch = false
		stream.channel <- watch.Event{Type: watch.Error, Object: &metav1.Status{
			Status: metav1.StatusFailure, Reason: metav1.StatusReasonExpired, Code: 410,
		}}
	}
	return stream, nil
}

func (c *scriptedResource) lastWatch() *controllableWatch {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.watches) == 0 {
		return &controllableWatch{}
	}
	return c.watches[len(c.watches)-1]
}

func (c *scriptedResource) lastWatchResourceVersion() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.watchRVs) == 0 {
		return ""
	}
	return c.watchRVs[len(c.watchRVs)-1]
}

type controllableWatch struct {
	channel chan watch.Event
	stopped atomic.Bool
	once    sync.Once
}

func newControllableWatch() *controllableWatch {
	return &controllableWatch{channel: make(chan watch.Event, 32)}
}

func (w *controllableWatch) Stop() {
	w.once.Do(func() {
		w.stopped.Store(true)
		close(w.channel)
	})
}

func (w *controllableWatch) ResultChan() <-chan watch.Event { return w.channel }

func openView(sessionID, viewID string, generation uint64) *kmgrv1.OpenViewRequest {
	return &kmgrv1.OpenViewRequest{
		Context:    &kmgrv1.RequestContext{ClusterSessionId: sessionID},
		ViewId:     viewID,
		Generation: generation,
		Spec: &kmgrv1.ViewSpec{
			Resource:       &kmgrv1.ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
			NamespaceScope: &kmgrv1.NamespaceScope{Namespaces: []string{"ns"}},
			ColumnIds:      []string{"namespace", "name", "status"},
		},
	}
}

func listPage(resourceVersion, continueToken string, objects ...*unstructured.Unstructured) *unstructured.UnstructuredList {
	list := &unstructured.UnstructuredList{}
	list.SetResourceVersion(resourceVersion)
	list.SetContinue(continueToken)
	for _, object := range objects {
		list.Items = append(list.Items, *object.DeepCopy())
	}
	return list
}

func waitForSnapshotUID(t *testing.T, subscription *Subscription, uid string) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		events, err := subscription.Next(ctx)
		cancel()
		if err != nil && !errors.Is(err, context.DeadlineExceeded) {
			t.Fatal(err)
		}
		for _, event := range events {
			for _, row := range event.GetSnapshot().GetRows() {
				if row.GetIdentity().GetUid() == uid {
					return
				}
			}
			for _, row := range event.GetDelta().GetUpserts() {
				if row.GetIdentity().GetUid() == uid {
					return
				}
			}
		}
	}
	t.Fatalf("never observed UID %q", uid)
}

func eventually(t *testing.T, timeout time.Duration, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal(fmt.Sprintf("condition was not met within %s", timeout))
}
