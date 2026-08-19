package watcher

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"slices"
	"sync"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"

	"github.com/charlie0129/kmgr/backend/internal/store"
)

func TestPipelineStreamsPaginatedListThenWatchesAndBookmarks(t *testing.T) {
	t.Parallel()

	var requests requestLog
	releaseSecondPage := make(chan struct{})
	secondPageRequested := make(chan struct{}, 1)
	handler := http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests.add(request)
		query := request.URL.Query()
		if query.Get("watch") == "true" {
			if query.Get("resourceVersion") != "100" {
				t.Errorf("watch resourceVersion = %q, want 100", query.Get("resourceVersion"))
			}
			if query.Get("allowWatchBookmarks") != "true" {
				t.Errorf("allowWatchBookmarks = %q, want true", query.Get("allowWatchBookmarks"))
			}
			if query.Get("timeoutSeconds") != "30" {
				t.Errorf("timeoutSeconds = %q, want 30", query.Get("timeoutSeconds"))
			}
			writeWatch(response,
				watchJSON("ADDED", podJSON("uid-d", "d", "101")),
				watchJSON("DELETED", podJSON("uid-b", "b", "102")),
				watchJSON("BOOKMARK", bookmarkJSON("103")),
			)
			return
		}

		if query.Get("limit") != "2" {
			t.Errorf("list limit = %q, want 2", query.Get("limit"))
		}
		if query.Get("labelSelector") != "app=kmgr" || query.Get("fieldSelector") != "status.phase=Running" {
			t.Errorf("selectors = label %q, field %q", query.Get("labelSelector"), query.Get("fieldSelector"))
		}
		switch query.Get("continue") {
		case "":
			writeList(response, "100", "next-page", podJSON("uid-a", "a", "90"), podJSON("uid-b", "b", "91"))
		case "next-page":
			secondPageRequested <- struct{}{}
			select {
			case <-releaseSecondPage:
			case <-request.Context().Done():
				return
			}
			writeList(response, "100", "", podJSON("uid-c", "c", "92"))
		default:
			t.Errorf("unexpected continue token %q", query.Get("continue"))
			response.WriteHeader(http.StatusBadRequest)
		}
	})
	client := newDynamicResource(t, handler)
	uidStore := store.New()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	firstPage := make(chan Batch, 1)
	bookmark := make(chan Batch, 1)
	pipeline := mustPipeline(t, PipelineConfig{
		Client:       client,
		Store:        uidStore,
		PageSize:     2,
		WatchTimeout: 30 * time.Second,
		ListOptions: metav1.ListOptions{
			LabelSelector: "app=kmgr",
			FieldSelector: "status.phase=Running",
		},
		RetryDelay: noDelay,
		OnBatch: func(batch Batch) {
			if batch.FromList && batch.ListPage == 1 {
				firstPage <- batch
			}
			if batch.Bookmark {
				bookmark <- batch
				cancel()
			}
		},
	})
	done := runPipeline(ctx, pipeline)

	page := receiveBatch(t, firstPage, "first progressive list page")
	if page.SnapshotComplete || page.ObjectsListed != 2 || len(page.Upserts) != 2 {
		t.Fatalf("first page batch = %#v", page)
	}
	receiveSignal(t, secondPageRequested, "second page request")
	if got := uidStore.Len(); got != 2 {
		t.Fatalf("store length while second page waits = %d, want 2", got)
	}
	if got := uidStore.ResourceVersion(); got != "" {
		t.Fatalf("resource version adopted before final page: %q", got)
	}
	close(releaseSecondPage)

	bookmarkBatch := receiveBatch(t, bookmark, "watch bookmark")
	if bookmarkBatch.ResourceVersion != "103" || !bookmarkBatch.Bookmark {
		t.Fatalf("bookmark batch = %#v", bookmarkBatch)
	}
	assertRunCancelled(t, done)
	if got := uidStore.ResourceVersion(); got != "103" {
		t.Fatalf("store resourceVersion = %q, want 103", got)
	}
	if got := uidStore.Len(); got != 3 {
		t.Fatalf("store length = %d, want 3", got)
	}
	if _, ok := snapshotObject(uidStore, "uid-d"); !ok {
		t.Fatal("watch ADDED object was not stored")
	}
	if _, ok := snapshotObject(uidStore, "uid-b"); ok {
		t.Fatal("watch DELETED object remained in the store")
	}

	gotRequests := requests.snapshot()
	if len(gotRequests) != 3 {
		t.Fatalf("requests = %v, want two LISTs and one WATCH", gotRequests)
	}
	if gotRequests[0].query.Get("continue") != "" || gotRequests[1].query.Get("continue") != "next-page" || gotRequests[2].query.Get("watch") != "true" {
		t.Fatalf("request sequence = %v", gotRequests)
	}
}

func TestPipelineResumesWarmStoreWithoutList(t *testing.T) {
	t.Parallel()

	var requests requestLog
	handler := http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests.add(request)
		query := request.URL.Query()
		if query.Get("watch") != "true" {
			t.Error("warm resume issued a LIST")
			response.WriteHeader(http.StatusInternalServerError)
			return
		}
		if query.Get("resourceVersion") != "50" {
			t.Errorf("resume resourceVersion = %q, want 50", query.Get("resourceVersion"))
		}
		updated := podJSON("uid-warm", "warm", "51")
		updated["status"] = map[string]any{"phase": "Running"}
		writeWatch(response,
			watchJSON("MODIFIED", updated),
			watchJSON("BOOKMARK", bookmarkJSON("52")),
		)
	})
	client := newDynamicResource(t, handler)
	uidStore := store.New()
	uidStore.Upsert(testObject("uid-warm", "warm", "49"))
	uidStore.SetResourceVersion("50")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var phasesMu sync.Mutex
	var phases []Phase
	pipeline := mustPipeline(t, PipelineConfig{
		Client:     client,
		Store:      uidStore,
		RetryDelay: noDelay,
		OnStatus: func(status Status) {
			phasesMu.Lock()
			phases = append(phases, status.Phase)
			phasesMu.Unlock()
		},
		OnBatch: func(batch Batch) {
			if batch.Bookmark {
				cancel()
			}
		},
	})
	done := runPipeline(ctx, pipeline)
	assertRunCancelled(t, done)

	if got := requests.snapshot(); len(got) != 1 || got[0].query.Get("watch") != "true" {
		t.Fatalf("warm resume requests = %v, want one WATCH", got)
	}
	if got := uidStore.ResourceVersion(); got != "52" {
		t.Fatalf("store resourceVersion = %q, want 52", got)
	}
	object, ok := snapshotObject(uidStore, "uid-warm")
	if !ok {
		t.Fatal("warm object disappeared")
	}
	phase, _, _ := unstructured.NestedString(object.Object, "status", "phase")
	if phase != "Running" {
		t.Fatalf("updated phase = %q, want Running", phase)
	}
	phasesMu.Lock()
	gotPhases := slices.Clone(phases)
	phasesMu.Unlock()
	if !reflect.DeepEqual(gotPhases, []Phase{PhaseResuming, PhaseWatching}) {
		t.Fatalf("status phases = %v, want [resuming watching]", gotPhases)
	}
}

func TestPipelineExpiredResumeRelistsWithoutRemovingWarmRowsEarly(t *testing.T) {
	t.Parallel()

	var requests requestLog
	var watchCount int
	var watchMu sync.Mutex
	releaseLastPage := make(chan struct{})
	lastPageRequested := make(chan struct{}, 1)
	handler := http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests.add(request)
		query := request.URL.Query()
		if query.Get("watch") == "true" {
			watchMu.Lock()
			watchCount++
			currentWatch := watchCount
			watchMu.Unlock()
			switch currentWatch {
			case 1:
				if query.Get("resourceVersion") != "10" {
					t.Errorf("resume resourceVersion = %q, want 10", query.Get("resourceVersion"))
				}
				writeExpired(response)
			case 2:
				if query.Get("resourceVersion") != "20" {
					t.Errorf("post-list watch resourceVersion = %q, want 20", query.Get("resourceVersion"))
				}
				writeWatch(response, watchJSON("BOOKMARK", bookmarkJSON("21")))
			default:
				t.Errorf("unexpected watch number %d", currentWatch)
				response.WriteHeader(http.StatusInternalServerError)
			}
			return
		}

		switch query.Get("continue") {
		case "":
			writeList(response, "20", "last-page", podJSON("uid-keep", "keep", "18"))
		case "last-page":
			lastPageRequested <- struct{}{}
			select {
			case <-releaseLastPage:
			case <-request.Context().Done():
				return
			}
			writeList(response, "20", "", podJSON("uid-new", "new", "19"))
		default:
			t.Errorf("unexpected continue token %q", query.Get("continue"))
			response.WriteHeader(http.StatusBadRequest)
		}
	})
	client := newDynamicResource(t, handler)
	uidStore := store.New()
	uidStore.Upsert(testObject("uid-keep", "keep", "9"))
	uidStore.Upsert(testObject("uid-stale", "stale", "9"))
	uidStore.SetResourceVersion("10")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	firstRelistPage := make(chan Batch, 1)
	finalRelistPage := make(chan Batch, 1)
	pipeline := mustPipeline(t, PipelineConfig{
		Client:     client,
		Store:      uidStore,
		PageSize:   1,
		RetryDelay: noDelay,
		OnBatch: func(batch Batch) {
			if batch.FromList && batch.ListPage == 1 {
				firstRelistPage <- batch
			}
			if batch.FromList && batch.SnapshotComplete {
				finalRelistPage <- batch
			}
			if batch.Bookmark {
				cancel()
			}
		},
	})
	done := runPipeline(ctx, pipeline)

	receiveBatch(t, firstRelistPage, "first relist page")
	receiveSignal(t, lastPageRequested, "last relist page request")
	if _, ok := snapshotObject(uidStore, "uid-stale"); !ok {
		t.Fatal("cached row was removed before the relist completed")
	}
	if got := uidStore.ResourceVersion(); got != "" {
		t.Fatalf("incomplete relist retained resumable resourceVersion %q", got)
	}
	close(releaseLastPage)

	finalBatch := receiveBatch(t, finalRelistPage, "completed relist")
	if !reflect.DeepEqual(finalBatch.RemovedUIDs, []types.UID{"uid-stale"}) {
		t.Fatalf("final relist removals = %v, want [uid-stale]", finalBatch.RemovedUIDs)
	}
	assertRunCancelled(t, done)
	if _, ok := snapshotObject(uidStore, "uid-stale"); ok {
		t.Fatal("stale cached row survived the completed relist")
	}
	if _, ok := snapshotObject(uidStore, "uid-new"); !ok {
		t.Fatal("last relist page was not applied")
	}
	if got := uidStore.ResourceVersion(); got != "21" {
		t.Fatalf("resourceVersion = %q, want bookmark 21", got)
	}

	gotRequests := requests.snapshot()
	if len(gotRequests) != 4 {
		t.Fatalf("request count = %d, want resume WATCH, two LISTs, WATCH", len(gotRequests))
	}
	wants := []struct {
		watch bool
		rv    string
		cont  string
	}{
		{watch: true, rv: "10"},
		{cont: ""},
		{cont: "last-page"},
		{watch: true, rv: "20"},
	}
	for index, want := range wants {
		got := gotRequests[index].query
		if (got.Get("watch") == "true") != want.watch || got.Get("resourceVersion") != want.rv || got.Get("continue") != want.cont {
			t.Fatalf("request %d query = %v, want watch=%v rv=%q continue=%q", index, got, want.watch, want.rv, want.cont)
		}
	}
}

func TestPipelineReconnectsFromBookmarkAndCancellationInterruptsBackoff(t *testing.T) {
	t.Parallel()

	var requests requestLog
	var watchMu sync.Mutex
	watchCount := 0
	handler := http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests.add(request)
		if request.URL.Query().Get("watch") != "true" {
			t.Error("reconnect test unexpectedly listed")
			response.WriteHeader(http.StatusInternalServerError)
			return
		}
		watchMu.Lock()
		watchCount++
		currentWatch := watchCount
		watchMu.Unlock()
		if currentWatch == 1 {
			writeWatch(response, watchJSON("BOOKMARK", bookmarkJSON("2")))
			return
		}
		response.Header().Set("Content-Type", "application/json")
		response.WriteHeader(http.StatusOK)
	})
	client := newDynamicResource(t, handler)
	uidStore := store.New()
	uidStore.Upsert(testObject("uid-warm", "warm", "1"))
	uidStore.SetResourceVersion("1")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	longBackoff := make(chan struct{})
	var attemptsMu sync.Mutex
	var attempts []int
	pipeline := mustPipeline(t, PipelineConfig{
		Client: client,
		Store:  uidStore,
		RetryDelay: func(attempt int) time.Duration {
			attemptsMu.Lock()
			attempts = append(attempts, attempt)
			attemptsMu.Unlock()
			if attempt == 1 {
				close(longBackoff)
				return time.Hour
			}
			return 0
		},
	})
	done := runPipeline(ctx, pipeline)
	receiveSignal(t, longBackoff, "second reconnect backoff")
	cancelledAt := time.Now()
	cancel()
	assertRunCancelled(t, done)
	if elapsed := time.Since(cancelledAt); elapsed > time.Second {
		t.Fatalf("cancellation took %s while waiting in backoff", elapsed)
	}

	gotRequests := requests.snapshot()
	if len(gotRequests) != 2 {
		t.Fatalf("watch request count = %d, want 2", len(gotRequests))
	}
	if gotRequests[0].query.Get("resourceVersion") != "1" || gotRequests[1].query.Get("resourceVersion") != "2" {
		t.Fatalf("watch resourceVersions = %q then %q, want 1 then bookmarked 2",
			gotRequests[0].query.Get("resourceVersion"), gotRequests[1].query.Get("resourceVersion"))
	}
	attemptsMu.Lock()
	gotAttempts := slices.Clone(attempts)
	attemptsMu.Unlock()
	if !reflect.DeepEqual(gotAttempts, []int{0, 1}) {
		t.Fatalf("retry attempts = %v, want [0 1]", gotAttempts)
	}
}

type loggedRequest struct {
	path  string
	query url.Values
}

func (r loggedRequest) String() string {
	return r.path + "?" + r.query.Encode()
}

type requestLog struct {
	mu       sync.Mutex
	requests []loggedRequest
}

func (l *requestLog) add(request *http.Request) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.requests = append(l.requests, loggedRequest{
		path:  request.URL.Path,
		query: request.URL.Query(),
	})
}

func (l *requestLog) snapshot() []loggedRequest {
	l.mu.Lock()
	defer l.mu.Unlock()
	return slices.Clone(l.requests)
}

func newDynamicResource(t *testing.T, handler http.Handler) ListerWatcher {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	client, err := dynamic.NewForConfig(&rest.Config{Host: server.URL})
	if err != nil {
		t.Fatalf("create dynamic client: %v", err)
	}
	return client.Resource(schema.GroupVersionResource{Version: "v1", Resource: "pods"})
}

func mustPipeline(t *testing.T, config PipelineConfig) *Pipeline {
	t.Helper()
	pipeline, err := NewPipeline(config)
	if err != nil {
		t.Fatalf("NewPipeline: %v", err)
	}
	return pipeline
}

func runPipeline(ctx context.Context, pipeline *Pipeline) <-chan error {
	done := make(chan error, 1)
	go func() {
		done <- pipeline.Run(ctx)
	}()
	return done
}

func assertRunCancelled(t *testing.T, done <-chan error) {
	t.Helper()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Run returned %v, want context.Canceled", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for pipeline cancellation")
	}
}

func receiveBatch(t *testing.T, channel <-chan Batch, description string) Batch {
	t.Helper()
	select {
	case batch := <-channel:
		return batch
	case <-time.After(3 * time.Second):
		t.Fatalf("timed out waiting for %s", description)
		return Batch{}
	}
}

func receiveSignal(t *testing.T, channel <-chan struct{}, description string) {
	t.Helper()
	select {
	case <-channel:
	case <-time.After(3 * time.Second):
		t.Fatalf("timed out waiting for %s", description)
	}
}

func noDelay(int) time.Duration { return 0 }

func writeList(response http.ResponseWriter, resourceVersion, continueToken string, items ...map[string]any) {
	response.Header().Set("Content-Type", "application/json")
	writeJSON(response, map[string]any{
		"apiVersion": "v1",
		"kind":       "PodList",
		"metadata": map[string]any{
			"resourceVersion": resourceVersion,
			"continue":        continueToken,
		},
		"items": items,
	})
}

func writeWatch(response http.ResponseWriter, events ...map[string]any) {
	response.Header().Set("Content-Type", "application/json")
	for _, event := range events {
		writeJSON(response, event)
		if flusher, ok := response.(http.Flusher); ok {
			flusher.Flush()
		}
	}
}

func writeExpired(response http.ResponseWriter) {
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(http.StatusGone)
	writeJSON(response, map[string]any{
		"apiVersion": "v1",
		"kind":       "Status",
		"status":     "Failure",
		"message":    "too old resource version",
		"reason":     "Expired",
		"code":       http.StatusGone,
	})
}

func writeJSON(writer io.Writer, value any) {
	_ = json.NewEncoder(writer).Encode(value)
}

func watchJSON(eventType string, object map[string]any) map[string]any {
	return map[string]any{"type": eventType, "object": object}
}

func bookmarkJSON(resourceVersion string) map[string]any {
	return map[string]any{
		"apiVersion": "v1",
		"kind":       "Pod",
		"metadata":   map[string]any{"resourceVersion": resourceVersion},
	}
}

func podJSON(uid, name, resourceVersion string) map[string]any {
	return map[string]any{
		"apiVersion": "v1",
		"kind":       "Pod",
		"metadata": map[string]any{
			"uid":             uid,
			"namespace":       "default",
			"name":            name,
			"resourceVersion": resourceVersion,
		},
	}
}

func testObject(uid types.UID, name, resourceVersion string) *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: podJSON(string(uid), name, resourceVersion)}
}

func snapshotObject(values *store.UIDStore, uid types.UID) (*unstructured.Unstructured, bool) {
	for _, object := range values.Snapshot() {
		if object.GetUID() == uid {
			return object, true
		}
	}
	return nil, false
}
