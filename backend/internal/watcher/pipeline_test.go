package watcher

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"

	"github.com/charlie0129/kmgr/backend/internal/store"
)

func TestPipelineWatchListStreamsSnapshotAndContinuesSameWatch(t *testing.T) {
	t.Parallel()

	var requests requestLog
	releaseEndBookmark := make(chan struct{})
	initialEventsWritten := make(chan struct{}, 1)
	handler := http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests.add(request)
		query := request.URL.Query()
		if query.Get("watch") != "true" || query.Get("sendInitialEvents") != "true" {
			t.Errorf("request is not WatchList: %v", query)
			response.WriteHeader(http.StatusBadRequest)
			return
		}
		if query.Get("allowWatchBookmarks") != "true" ||
			query.Get("resourceVersionMatch") != string(metav1.ResourceVersionMatchNotOlderThan) ||
			query.Get("resourceVersion") != "" || query.Get("continue") != "" || query.Get("limit") != "" {
			t.Errorf("WatchList consistency options = %v", query)
		}
		if query.Get("labelSelector") != "app=kmgr" ||
			query.Get("fieldSelector") != "spec.nodeName=worker-a" {
			t.Errorf("WatchList selectors = %v", query)
		}
		if query.Get("timeoutSeconds") != "30" {
			t.Errorf("WatchList timeoutSeconds = %q, want 30", query.Get("timeoutSeconds"))
		}

		writeWatch(response,
			watchJSON("ADDED", podJSON("uid-a", "a", "91")),
			watchJSON("ADDED", podJSON("uid-b", "b", "92")),
			watchJSON("ADDED", podJSON("uid-c", "c", "93")),
		)
		initialEventsWritten <- struct{}{}
		select {
		case <-releaseEndBookmark:
		case <-request.Context().Done():
			return
		}
		writeWatch(response,
			watchJSON("BOOKMARK", initialEventsEndBookmarkJSON("100", "true")),
			watchJSON("MODIFIED", podJSON("uid-c", "c", "101")),
			watchJSON("BOOKMARK", bookmarkJSON("102")),
		)
	})

	client := newWatchListDynamicResource(t, handler)
	uidStore := store.New()
	uidStore.Upsert(testObject("uid-stale", "stale", "80"))
	uidStore.SetResourceVersion("80")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	firstPage := make(chan Batch, 1)
	completed := make(chan Batch, 1)
	liveModified := make(chan Batch, 1)
	liveBookmark := make(chan Batch, 1)
	watchOpenStarted := make(chan struct{}, 1)
	watchOpenCompleted := make(chan struct{}, 1)
	var statusesMu sync.Mutex
	var statuses []Status
	pipeline := mustPipeline(t, PipelineConfig{
		Client:             client,
		Store:              uidStore,
		ForceRelist:        true,
		PageSize:           2,
		WatchListBatchSize: 2,
		WatchTimeout:       30 * time.Second,
		ListOptions: metav1.ListOptions{
			LabelSelector: "app=kmgr",
			FieldSelector: "spec.nodeName=worker-a",
		},
		RetryDelay: noDelay,
		OnWatchOpen: func() {
			watchOpenStarted <- struct{}{}
		},
		OnWatchOpenComplete: func() {
			watchOpenCompleted <- struct{}{}
		},
		OnStatus: func(status Status) {
			statusesMu.Lock()
			statuses = append(statuses, status)
			statusesMu.Unlock()
		},
		OnBatch: func(batch Batch) {
			switch {
			case batch.FromList && !batch.SnapshotComplete:
				firstPage <- batch
			case batch.SnapshotComplete:
				completed <- batch
			case len(batch.Upserts) == 1 && batch.Upserts[0].GetResourceVersion() == "101":
				liveModified <- batch
			case batch.Bookmark && batch.ResourceVersion == "102":
				liveBookmark <- batch
				cancel()
			}
		},
	})
	done := runPipeline(ctx, pipeline)

	receiveSignal(t, initialEventsWritten, "initial WatchList events")
	receiveSignal(t, watchOpenStarted, "WatchList open start callback")
	receiveSignal(t, watchOpenCompleted, "WatchList open completion before the initial bookmark")
	page := receiveBatch(t, firstPage, "first WatchList batch")
	if page.ListPage != 1 || page.ObjectsListed != 2 || len(page.Upserts) != 2 ||
		page.SnapshotComplete || page.ResourceVersion != "" {
		t.Fatalf("first WatchList batch = %#v", page)
	}
	if got := uidStore.ResourceVersion(); got != "" {
		t.Fatalf("store resourceVersion before end bookmark = %q, want empty", got)
	}
	if _, ok := snapshotObject(uidStore, "uid-stale"); !ok {
		t.Fatal("stale object was removed before the WatchList end bookmark")
	}
	close(releaseEndBookmark)

	final := receiveBatch(t, completed, "completed WatchList snapshot")
	if final.ListPage != 2 || final.ObjectsListed != 3 || len(final.Upserts) != 1 ||
		final.ResourceVersion != "100" || !final.FromList || !final.SnapshotComplete ||
		!slices.Contains(final.RemovedUIDs, types.UID("uid-stale")) {
		t.Fatalf("completed WatchList batch = %#v", final)
	}
	receiveBatch(t, liveModified, "same-stream live modification")
	receiveBatch(t, liveBookmark, "same-stream live bookmark")
	assertRunCancelled(t, done)

	if got := requests.snapshot(); len(got) != 1 {
		t.Fatalf("requests = %v, want one WatchList and no LIST", got)
	}
	if got := uidStore.ResourceVersion(); got != "102" {
		t.Fatalf("store resourceVersion = %q, want 102", got)
	}
	if uidStore.Len() != 3 {
		t.Fatalf("store length = %d, want 3", uidStore.Len())
	}
	if _, ok := snapshotObject(uidStore, "uid-stale"); ok {
		t.Fatal("stale object remained after WatchList reconciliation")
	}
	object, ok := snapshotObject(uidStore, "uid-c")
	if !ok || object.GetResourceVersion() != "101" {
		t.Fatalf("live object = %#v, want uid-c at resourceVersion 101", object)
	}

	statusesMu.Lock()
	gotStatuses := slices.Clone(statuses)
	statusesMu.Unlock()
	if len(gotStatuses) < 3 || gotStatuses[0].Phase != PhaseListing ||
		gotStatuses[1].Phase != PhaseResuming {
		t.Fatalf("statuses = %#v, want Listing, Resuming first", gotStatuses)
	}
	watching := gotStatuses[2]
	if watching.Phase != PhaseWatching || watching.ResourceVersion != "100" ||
		watching.PagesListed != 2 || watching.ObjectsListed != 3 || watching.Stale {
		t.Fatalf("Watching status = %#v", watching)
	}
}

func TestPipelineUnsupportedWatchListFallsBackOnceAndStaysDisabled(t *testing.T) {
	t.Parallel()

	var requests requestLog
	var listRequests atomic.Int32
	var watchRequests atomic.Int32
	var watchListRequests atomic.Int32
	handler := http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests.add(request)
		query := request.URL.Query()
		if query.Get("labelSelector") != "app=api" || query.Get("fieldSelector") != "spec.nodeName=worker-a" {
			t.Errorf("selectors changed during fallback: %v", query)
		}
		if query.Get("sendInitialEvents") == "true" {
			watchListRequests.Add(1)
			writeAPIStatus(response, metav1.StatusReasonBadRequest, http.StatusBadRequest)
			return
		}
		if query.Get("watch") == "true" {
			switch watchRequests.Add(1) {
			case 1:
				writeWatch(response, watchJSON("ERROR", apiStatusJSON(
					metav1.StatusReasonExpired, http.StatusGone,
				)))
			case 2:
				writeWatch(response, watchJSON("BOOKMARK", bookmarkJSON("21")))
			default:
				t.Errorf("unexpected ordinary WATCH request %d", watchRequests.Load())
			}
			return
		}
		switch listRequests.Add(1) {
		case 1:
			writeList(response, "10", "", podJSON("uid-a", "a", "10"))
		case 2:
			writeList(response, "20", "", podJSON("uid-b", "b", "20"))
		default:
			t.Errorf("unexpected LIST request %d", listRequests.Load())
		}
	})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	uidStore := store.New()
	pipeline := mustPipeline(t, PipelineConfig{
		Client: newWatchListDynamicResource(t, handler),
		Store:  uidStore,
		ListOptions: metav1.ListOptions{
			LabelSelector: "app=api",
			FieldSelector: "spec.nodeName=worker-a",
		},
		RetryDelay: noDelay,
		OnBatch: func(batch Batch) {
			if batch.Bookmark && batch.ResourceVersion == "21" {
				cancel()
			}
		},
	})
	assertRunCancelled(t, runPipeline(ctx, pipeline))

	if watchListRequests.Load() != 1 || listRequests.Load() != 2 || watchRequests.Load() != 2 {
		t.Fatalf(
			"request counts = WatchList %d, LIST %d, WATCH %d; want 1/2/2",
			watchListRequests.Load(), listRequests.Load(), watchRequests.Load(),
		)
	}
	if !pipeline.watchListDisabled {
		t.Fatal("WatchList was not permanently disabled after unsupported semantics")
	}
	gotRequests := requests.snapshot()
	if len(gotRequests) != 5 || gotRequests[0].query.Get("sendInitialEvents") != "true" ||
		gotRequests[1].query.Get("watch") != "" ||
		gotRequests[2].query.Get("watch") != "true" ||
		gotRequests[3].query.Get("watch") != "" ||
		gotRequests[4].query.Get("watch") != "true" {
		t.Fatalf("fallback request sequence = %v", gotRequests)
	}
	if uidStore.Len() != 1 || uidStore.ResourceVersion() != "21" {
		t.Fatalf("store len/RV = %d/%q, want 1/21", uidStore.Len(), uidStore.ResourceVersion())
	}
	if _, ok := snapshotObject(uidStore, "uid-a"); ok {
		t.Fatal("first LIST object remained after the fallback relist")
	}
	if _, ok := snapshotObject(uidStore, "uid-b"); !ok {
		t.Fatal("second fallback LIST object was not retained")
	}
}

func TestPipelineRequestWatchProgressFailureFallsBackAndDisablesSharedSemantics(t *testing.T) {
	t.Parallel()

	const serverMessage = "a watch stream was requested by the client but the required storage feature RequestWatchProgress is disabled"
	var watchLists atomic.Int32
	var lists atomic.Int32
	var watches atomic.Int32
	handler := http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		query := request.URL.Query()
		switch {
		case query.Get("sendInitialEvents") == "true":
			watchLists.Add(1)
			status := apiStatusJSON(metav1.StatusReasonInternalError, http.StatusInternalServerError)
			status["message"] = serverMessage
			writeWatch(response, watchJSON("ERROR", status))
		case query.Get("watch") == "true":
			watchNumber := watches.Add(1)
			writeWatch(response, watchJSON("BOOKMARK", bookmarkJSON(fmt.Sprintf("%d", 10+watchNumber))))
		default:
			listNumber := lists.Add(1)
			switch listNumber {
			case 1:
				writeList(response, "11", "next-1")
			case 2:
				if query.Get("continue") != "next-1" {
					t.Errorf("first fallback continuation = %q", query.Get("continue"))
				}
				writeList(response, "11", "")
			case 3:
				writeList(response, "12", "next-2")
			case 4:
				if query.Get("continue") != "next-2" {
					t.Errorf("second fallback continuation = %q", query.Get("continue"))
				}
				writeList(response, "12", "")
			default:
				t.Errorf("unexpected LIST request %d", listNumber)
				response.WriteHeader(http.StatusInternalServerError)
			}
		}
	})
	base := newDynamicResource(t, handler)
	sharedDisabled := &atomic.Bool{}

	run := func(wantBookmark string) *Pipeline {
		ctx, cancel := context.WithCancel(context.Background())
		pipeline := mustPipeline(t, PipelineConfig{
			Client: watchListSharedCapabilityClient{
				ListerWatcher: base,
				disabled:      sharedDisabled,
			},
			Store:      store.New(),
			RetryDelay: noDelay,
			OnBatch: func(batch Batch) {
				if batch.Bookmark && batch.ResourceVersion == wantBookmark {
					cancel()
				}
			},
		})
		assertRunCancelled(t, runPipeline(ctx, pipeline))
		return pipeline
	}

	first := run("11")
	if !first.watchListDisabled || !sharedDisabled.Load() {
		t.Fatal("RequestWatchProgress capability failure did not disable WatchList")
	}
	second := run("12")
	if !second.watchListDisabled && second.watchListEligible() {
		t.Fatal("second pipeline remained eligible for the shared disabled capability")
	}
	if watchLists.Load() != 1 || lists.Load() != 4 || watches.Load() != 2 {
		t.Fatalf(
			"request counts = WatchList %d, LIST %d, WATCH %d; want 1/4/2",
			watchLists.Load(), lists.Load(), watches.Load(),
		)
	}
}

func TestPipelineMalformedWatchListSafelyFallsBackToList(t *testing.T) {
	t.Parallel()

	prefix := []map[string]any{
		watchJSON("ADDED", podJSON("uid-partial-a", "partial-a", "1")),
		watchJSON("ADDED", podJSON("uid-partial-b", "partial-b", "2")),
	}
	tests := []struct {
		name   string
		events []map[string]any
	}{
		{name: "stream closes before end bookmark", events: prefix},
		{
			name: "end bookmark has no resource version",
			events: append(slices.Clone(prefix),
				watchJSON("BOOKMARK", initialEventsEndBookmarkJSON("", "true"))),
		},
		{
			name: "end bookmark annotation is not true",
			events: append(slices.Clone(prefix),
				watchJSON("BOOKMARK", initialEventsEndBookmarkJSON("10", "false"))),
		},
		{
			name: "initial modified event",
			events: append(slices.Clone(prefix),
				watchJSON("MODIFIED", podJSON("uid-modified", "modified", "3"))),
		},
		{
			name: "initial object has no UID",
			events: append(slices.Clone(prefix),
				watchJSON("ADDED", podJSON("", "missing-uid", "3"))),
		},
		{
			name: "initial object has no resource version",
			events: append(slices.Clone(prefix),
				watchJSON("ADDED", podJSON("uid-missing-rv", "missing-rv", ""))),
		},
		{
			name: "duplicate initial UID",
			events: append(slices.Clone(prefix),
				watchJSON("ADDED", podJSON("uid-partial-a", "duplicate", "3"))),
		},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			var requests requestLog
			handler := http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
				requests.add(request)
				query := request.URL.Query()
				switch {
				case query.Get("sendInitialEvents") == "true":
					writeWatch(response, test.events...)
				case query.Get("watch") == "true":
					writeWatch(response, watchJSON("BOOKMARK", bookmarkJSON("201")))
				default:
					writeList(response, "200", "", podJSON("uid-good", "good", "200"))
				}
			})

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			uidStore := store.New()
			uidStore.Upsert(testObject("uid-stale", "stale", "0"))
			uidStore.SetResourceVersion("0")
			pipeline := mustPipeline(t, PipelineConfig{
				Client:      newWatchListDynamicResource(t, handler),
				Store:       uidStore,
				ForceRelist: true,
				PageSize:    1,
				RetryDelay:  noDelay,
				OnBatch: func(batch Batch) {
					if batch.Bookmark && batch.ResourceVersion == "201" {
						cancel()
					}
				},
			})
			assertRunCancelled(t, runPipeline(ctx, pipeline))

			gotRequests := requests.snapshot()
			if len(gotRequests) != 3 || gotRequests[0].query.Get("sendInitialEvents") != "true" ||
				gotRequests[1].query.Get("watch") != "" ||
				gotRequests[2].query.Get("watch") != "true" {
				t.Fatalf("fallback request sequence = %v", gotRequests)
			}
			if !pipeline.watchListDisabled {
				t.Fatal("malformed WatchList did not permanently disable the fast path")
			}
			if uidStore.Len() != 1 || uidStore.ResourceVersion() != "201" {
				t.Fatalf("store len/RV = %d/%q, want 1/201", uidStore.Len(), uidStore.ResourceVersion())
			}
			if _, ok := snapshotObject(uidStore, "uid-good"); !ok {
				t.Fatal("fallback LIST did not establish its authoritative snapshot")
			}
			for _, uid := range []types.UID{"uid-stale", "uid-partial-a", "uid-partial-b"} {
				if _, ok := snapshotObject(uidStore, uid); ok {
					t.Fatalf("non-authoritative object %q remained after fallback LIST", uid)
				}
			}
		})
	}
}

func TestWatchListInitialEventsRequireUnstructuredObjects(t *testing.T) {
	t.Parallel()
	metadata := &metav1.PartialObjectMetadata{ObjectMeta: metav1.ObjectMeta{
		UID: "uid", ResourceVersion: "10",
	}}
	if _, err := initialWatchListObject(metadata); err == nil {
		t.Fatal("typed initial object was accepted instead of unstructured data")
	}
	if _, err := initialWatchListBookmark(metadata); err == nil {
		t.Fatal("typed initial bookmark was accepted instead of unstructured data")
	}
}

func TestPipelineWatchListCancellationDoesNotFallBack(t *testing.T) {
	t.Parallel()

	var requests requestLog
	streamStarted := make(chan struct{}, 1)
	handler := http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests.add(request)
		if request.URL.Query().Get("sendInitialEvents") != "true" {
			t.Errorf("request after WatchList cancellation = %v", request.URL.Query())
			response.WriteHeader(http.StatusInternalServerError)
			return
		}
		writeWatch(response, watchJSON("ADDED", podJSON("uid-pending", "pending", "1")))
		streamStarted <- struct{}{}
		<-request.Context().Done()
	})

	ctx, cancel := context.WithCancel(context.Background())
	pipeline := mustPipeline(t, PipelineConfig{
		Client:     newWatchListDynamicResource(t, handler),
		Store:      store.New(),
		RetryDelay: noDelay,
	})
	done := runPipeline(ctx, pipeline)
	receiveSignal(t, streamStarted, "WatchList stream")
	cancel()
	assertRunCancelled(t, done)

	if got := requests.snapshot(); len(got) != 1 || got[0].query.Get("sendInitialEvents") != "true" {
		t.Fatalf("requests after cancellation = %v, want only the WatchList", got)
	}
	if pipeline.watchListDisabled {
		t.Fatal("cancellation permanently disabled WatchList")
	}
}

func TestPipelineWatchListDoesNotBroadenAuthorizationOrTransientFailures(t *testing.T) {
	t.Parallel()

	t.Run("forbidden is terminal", func(t *testing.T) {
		t.Parallel()
		var requests requestLog
		client := newWatchListDynamicResource(t, http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
			requests.add(request)
			writeAPIStatus(response, metav1.StatusReasonForbidden, http.StatusForbidden)
		}))
		pipeline := mustPipeline(t, PipelineConfig{
			Client: client, Store: store.New(), RetryDelay: noDelay,
		})
		err := pipeline.Run(context.Background())
		if !apierrors.IsForbidden(err) {
			t.Fatalf("Run error = %v, want Forbidden", err)
		}
		if got := requests.snapshot(); len(got) != 1 || got[0].query.Get("sendInitialEvents") != "true" {
			t.Fatalf("requests = %v, want one WatchList and no LIST", got)
		}
		if pipeline.watchListDisabled {
			t.Fatal("Forbidden response disabled WatchList compatibility")
		}
	})

	t.Run("transient failure retries WatchList", func(t *testing.T) {
		t.Parallel()
		var requests requestLog
		var watchLists atomic.Int32
		client := newWatchListDynamicResource(t, http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
			requests.add(request)
			if request.URL.Query().Get("sendInitialEvents") != "true" {
				t.Errorf("transient WatchList failure broadened to request %v", request.URL.Query())
				response.WriteHeader(http.StatusInternalServerError)
				return
			}
			switch watchLists.Add(1) {
			case 1:
				writeAPIStatus(response, metav1.StatusReasonInternalError, http.StatusInternalServerError)
			case 2:
				writeWatch(response,
					watchJSON("BOOKMARK", initialEventsEndBookmarkJSON("10", "true")),
					watchJSON("BOOKMARK", bookmarkJSON("11")),
				)
			default:
				t.Errorf("unexpected WatchList request %d", watchLists.Load())
			}
		}))
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		var retries atomic.Int32
		pipeline := mustPipeline(t, PipelineConfig{
			Client: client,
			Store:  store.New(),
			RetryDelay: func(int) time.Duration {
				retries.Add(1)
				return 0
			},
			OnBatch: func(batch Batch) {
				if batch.Bookmark && batch.ResourceVersion == "11" {
					cancel()
				}
			},
		})
		assertRunCancelled(t, runPipeline(ctx, pipeline))
		if watchLists.Load() != 2 || retries.Load() != 1 {
			t.Fatalf("WatchList/retry counts = %d/%d, want 2/1", watchLists.Load(), retries.Load())
		}
		if got := requests.snapshot(); len(got) != 2 {
			t.Fatalf("requests = %v, want two WatchLists and no LIST", got)
		}
		if pipeline.watchListDisabled {
			t.Fatal("transient response disabled WatchList compatibility")
		}
	})
}

func TestPipelineExpiredWatchListRelistsWithWatchList(t *testing.T) {
	t.Parallel()

	var requests requestLog
	var watchLists atomic.Int32
	client := newWatchListDynamicResource(t, http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests.add(request)
		if request.URL.Query().Get("sendInitialEvents") != "true" {
			t.Errorf("expired WatchList recovered with non-WatchList request: %v", request.URL.Query())
			response.WriteHeader(http.StatusInternalServerError)
			return
		}
		switch watchLists.Add(1) {
		case 1:
			writeWatch(response,
				watchJSON("ADDED", podJSON("uid-old", "old", "9")),
				watchJSON("BOOKMARK", initialEventsEndBookmarkJSON("10", "true")),
				watchJSON("ERROR", apiStatusJSON(metav1.StatusReasonExpired, http.StatusGone)),
			)
		case 2:
			writeWatch(response,
				watchJSON("ADDED", podJSON("uid-new", "new", "19")),
				watchJSON("BOOKMARK", initialEventsEndBookmarkJSON("20", "true")),
				watchJSON("BOOKMARK", bookmarkJSON("21")),
			)
		default:
			t.Errorf("unexpected WatchList request %d", watchLists.Load())
		}
	}))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	uidStore := store.New()
	pipeline := mustPipeline(t, PipelineConfig{
		Client: client,
		Store:  uidStore,
		OnBatch: func(batch Batch) {
			if batch.Bookmark && batch.ResourceVersion == "21" {
				cancel()
			}
		},
		RetryDelay: noDelay,
	})
	assertRunCancelled(t, runPipeline(ctx, pipeline))

	if watchLists.Load() != 2 {
		t.Fatalf("WatchList requests = %d, want 2", watchLists.Load())
	}
	if got := requests.snapshot(); len(got) != 2 {
		t.Fatalf("requests = %v, want two WatchLists and no LIST", got)
	}
	if pipeline.watchListDisabled {
		t.Fatal("post-synchronization expiry disabled WatchList")
	}
	if uidStore.Len() != 1 || uidStore.ResourceVersion() != "21" {
		t.Fatalf("store len/RV = %d/%q, want 1/21", uidStore.Len(), uidStore.ResourceVersion())
	}
	if _, ok := snapshotObject(uidStore, "uid-old"); ok {
		t.Fatal("expired WatchList object remained after WatchList relist")
	}
	if _, ok := snapshotObject(uidStore, "uid-new"); !ok {
		t.Fatal("WatchList relist object was not retained")
	}
}

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

func TestPipelineTerminatesPermanentListAPIErrors(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		reason metav1.StatusReason
		code   int
		match  func(error) bool
	}{
		{name: "bad request", reason: metav1.StatusReasonBadRequest, code: http.StatusBadRequest, match: apierrors.IsBadRequest},
		{name: "invalid", reason: metav1.StatusReasonInvalid, code: http.StatusUnprocessableEntity, match: apierrors.IsInvalid},
		{name: "forbidden", reason: metav1.StatusReasonForbidden, code: http.StatusForbidden, match: apierrors.IsForbidden},
		{name: "unauthorized", reason: metav1.StatusReasonUnauthorized, code: http.StatusUnauthorized, match: apierrors.IsUnauthorized},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var requests atomic.Int32
			client := newDynamicResource(t, http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
				if requests.Add(1) > 1 {
					cancel()
				}
				writeAPIStatus(response, test.reason, test.code)
			}))
			var retryCalls atomic.Int32
			pipeline := mustPipeline(t, PipelineConfig{
				Client: client,
				Store:  store.New(),
				RetryDelay: func(int) time.Duration {
					retryCalls.Add(1)
					return 0
				},
			})

			err := pipeline.Run(ctx)
			if !test.match(err) {
				t.Fatalf("Run error = %v, want %s status", err, test.reason)
			}
			if got := requests.Load(); got != 1 {
				t.Fatalf("LIST requests = %d, want 1", got)
			}
			if got := retryCalls.Load(); got != 0 {
				t.Fatalf("retry-delay calls = %d, want 0", got)
			}
		})
	}
}

func TestPipelineTerminatesPermanentWatchAPIErrors(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		write func(http.ResponseWriter)
		match func(error) bool
	}{
		{
			name: "watch open forbidden",
			write: func(response http.ResponseWriter) {
				writeAPIStatus(response, metav1.StatusReasonForbidden, http.StatusForbidden)
			},
			match: apierrors.IsForbidden,
		},
		{
			name: "watch error event invalid",
			write: func(response http.ResponseWriter) {
				writeWatch(response, watchJSON("ERROR", apiStatusJSON(
					metav1.StatusReasonInvalid, http.StatusUnprocessableEntity,
				)))
			},
			match: apierrors.IsInvalid,
		},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var requests atomic.Int32
			client := newDynamicResource(t, http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
				if request.URL.Query().Get("watch") != "true" {
					t.Error("warm pipeline issued a LIST")
				}
				if request.URL.Query().Get("labelSelector") != "app=kmgr" ||
					request.URL.Query().Get("fieldSelector") != "metadata.name=api" {
					t.Errorf("watch selectors = %v", request.URL.Query())
				}
				if requests.Add(1) > 1 {
					cancel()
				}
				test.write(response)
			}))
			uidStore := store.New()
			uidStore.Upsert(testObject("uid-warm", "api", "10"))
			uidStore.SetResourceVersion("10")
			var retryCalls atomic.Int32
			pipeline := mustPipeline(t, PipelineConfig{
				Client: client,
				Store:  uidStore,
				ListOptions: metav1.ListOptions{
					LabelSelector: "app=kmgr",
					FieldSelector: "metadata.name=api",
				},
				RetryDelay: func(int) time.Duration {
					retryCalls.Add(1)
					return 0
				},
			})

			err := pipeline.Run(ctx)
			if !test.match(err) {
				t.Fatalf("Run error = %v, want terminal Kubernetes status", err)
			}
			if got := requests.Load(); got != 1 {
				t.Fatalf("WATCH requests = %d, want 1", got)
			}
			if got := retryCalls.Load(); got != 0 {
				t.Fatalf("retry-delay calls = %d, want 0", got)
			}
		})
	}
}

func TestPipelineRetriesTransientListAndWatchAPIErrors(t *testing.T) {
	t.Parallel()
	t.Run("list too many requests", func(t *testing.T) {
		t.Parallel()
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		var listRequests atomic.Int32
		var watchRequests atomic.Int32
		client := newDynamicResource(t, http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
			if request.URL.Query().Get("watch") == "true" {
				watchRequests.Add(1)
				writeWatch(response, watchJSON("BOOKMARK", bookmarkJSON("12")))
				return
			}
			switch listRequests.Add(1) {
			case 1:
				writeAPIStatus(response, metav1.StatusReasonTooManyRequests, http.StatusTooManyRequests)
			case 2:
				writeList(response, "11", "", podJSON("uid", "api", "11"))
			default:
				cancel()
				writeAPIStatus(response, metav1.StatusReasonInternalError, http.StatusInternalServerError)
			}
		}))
		var retryCalls atomic.Int32
		pipeline := mustPipeline(t, PipelineConfig{
			Client: client,
			Store:  store.New(),
			RetryDelay: func(int) time.Duration {
				retryCalls.Add(1)
				return 0
			},
			OnBatch: func(batch Batch) {
				if batch.Bookmark {
					cancel()
				}
			},
		})
		assertRunCancelled(t, runPipeline(ctx, pipeline))
		if listRequests.Load() != 2 || watchRequests.Load() != 1 || retryCalls.Load() != 1 {
			t.Fatalf("requests/retries = LIST %d, WATCH %d, retry %d; want 2/1/1",
				listRequests.Load(), watchRequests.Load(), retryCalls.Load())
		}
	})

	for _, test := range []struct {
		name  string
		write func(http.ResponseWriter)
	}{
		{
			name: "watch open server error",
			write: func(response http.ResponseWriter) {
				writeAPIStatus(response, metav1.StatusReasonInternalError, http.StatusInternalServerError)
			},
		},
		{
			name: "watch timeout event",
			write: func(response http.ResponseWriter) {
				writeWatch(response, watchJSON("ERROR", apiStatusJSON(
					metav1.StatusReasonTimeout, http.StatusGatewayTimeout,
				)))
			},
		},
	} {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var watchRequests atomic.Int32
			client := newDynamicResource(t, http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
				if request.URL.Query().Get("watch") != "true" {
					t.Error("warm pipeline issued a LIST")
				}
				if watchRequests.Add(1) == 1 {
					test.write(response)
					return
				}
				writeWatch(response, watchJSON("BOOKMARK", bookmarkJSON("12")))
			}))
			uidStore := store.New()
			uidStore.Upsert(testObject("uid-warm", "api", "10"))
			uidStore.SetResourceVersion("10")
			var retryCalls atomic.Int32
			pipeline := mustPipeline(t, PipelineConfig{
				Client: client,
				Store:  uidStore,
				RetryDelay: func(int) time.Duration {
					retryCalls.Add(1)
					return 0
				},
				OnBatch: func(batch Batch) {
					if batch.Bookmark {
						cancel()
					}
				},
			})
			assertRunCancelled(t, runPipeline(ctx, pipeline))
			if watchRequests.Load() != 2 || retryCalls.Load() != 1 {
				t.Fatalf("WATCH requests/retries = %d/%d, want 2/1",
					watchRequests.Load(), retryCalls.Load())
			}
		})
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

type watchListSupportedClient struct{ ListerWatcher }

func (watchListSupportedClient) SupportsWatchListSemantics() bool { return true }

type watchListSharedCapabilityClient struct {
	ListerWatcher
	disabled *atomic.Bool
}

func (c watchListSharedCapabilityClient) SupportsWatchListSemantics() bool {
	return c.disabled != nil && !c.disabled.Load()
}

func (c watchListSharedCapabilityClient) DisableWatchListSemantics() {
	if c.disabled != nil {
		c.disabled.Store(true)
	}
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

func newWatchListDynamicResource(t *testing.T, handler http.Handler) ListerWatcher {
	t.Helper()
	return watchListSupportedClient{ListerWatcher: newDynamicResource(t, handler)}
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

func writeAPIStatus(response http.ResponseWriter, reason metav1.StatusReason, code int) {
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(code)
	writeJSON(response, apiStatusJSON(reason, code))
}

func apiStatusJSON(reason metav1.StatusReason, code int) map[string]any {
	return map[string]any{
		"apiVersion": "v1",
		"kind":       "Status",
		"status":     "Failure",
		"message":    "Kubernetes API request failed",
		"reason":     string(reason),
		"code":       code,
	}
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

func initialEventsEndBookmarkJSON(resourceVersion, annotation string) map[string]any {
	return map[string]any{
		"apiVersion": "meta.k8s.io/v1",
		"kind":       "PartialObjectMetadata",
		"metadata": map[string]any{
			"resourceVersion": resourceVersion,
			"annotations": map[string]any{
				metav1.InitialEventsAnnotationKey: annotation,
			},
		},
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
