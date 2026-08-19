package watcher

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	k8sruntime "k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	metadataapi "k8s.io/client-go/metadata"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/util/flowcontrol"

	"github.com/charlie0129/kmgr/backend/internal/store"
)

func TestTablePipelineNegotiatesPaginatedListAndHeaderlessWatch(t *testing.T) {
	t.Parallel()
	columns := []metav1.TableColumnDefinition{
		{Name: "Name", Type: "string", Format: "name"},
		{Name: "Status", Type: "string"},
		{Name: "Replicas", Type: "integer", Priority: 1},
	}
	var requests requestLog
	handler := http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests.add(request)
		if got := request.Header.Get("Accept"); !strings.Contains(got, "as=Table") {
			t.Errorf("Table request Accept = %q", got)
		}
		if got := request.URL.Query().Get("includeObject"); got != string(metav1.IncludeObject) {
			t.Errorf("includeObject = %q, want %q", got, metav1.IncludeObject)
		}
		query := request.URL.Query()
		if query.Get("sendInitialEvents") != "" || query.Get("resourceVersionMatch") != "" {
			t.Errorf("Table pipeline attempted WatchList semantics: %v", query)
		}
		if query.Get("watch") == "true" {
			writeWatch(response,
				watchJSON("ADDED", tableJSON("101", "", nil,
					tableRow([]any{"gamma", "Ready", float64(3)}, widgetJSON("uid-c", "gamma", "101")),
				)),
				watchJSON("BOOKMARK", tableJSON("102", "", nil)),
			)
			return
		}
		switch query.Get("continue") {
		case "":
			writeTable(response, tableJSON("100", "next", columns,
				tableRow([]any{"alpha", "Ready", float64(1)}, widgetJSON("uid-a", "alpha", "90")),
			))
		case "next":
			writeTable(response, tableJSON("100", "", columns,
				tableRow([]any{"beta", "Pending", float64(2)}, widgetJSON("uid-b", "beta", "91")),
			))
		default:
			t.Errorf("unexpected continue token %q", query.Get("continue"))
			response.WriteHeader(http.StatusBadRequest)
		}
	})
	gvr := schema.GroupVersionResource{Group: "example.io", Version: "v1", Resource: "widgets"}
	client := newTableTestClient(t, handler, gvr, "team-a")
	uidStore := store.New()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var batchesMu sync.Mutex
	var batches []Batch
	pipeline := mustPipeline(t, PipelineConfig{
		Client: client, Store: uidStore, PageSize: 1, RetryDelay: noDelay,
		OnBatch: func(batch Batch) {
			batchesMu.Lock()
			batches = append(batches, batch)
			batchesMu.Unlock()
			if batch.Bookmark {
				cancel()
			}
		},
	})
	done := runPipeline(ctx, pipeline)
	assertRunCancelled(t, done)

	gotRequests := requests.snapshot()
	if len(gotRequests) != 3 {
		t.Fatalf("requests = %v, want two Table LIST pages and one Table WATCH", gotRequests)
	}
	wantPath := "/apis/example.io/v1/namespaces/team-a/widgets"
	for _, request := range gotRequests {
		if request.path != wantPath {
			t.Fatalf("request path = %q, want %q", request.path, wantPath)
		}
	}
	if gotRequests[0].query.Get("continue") != "" ||
		gotRequests[1].query.Get("continue") != "next" ||
		gotRequests[2].query.Get("watch") != "true" {
		t.Fatalf("request sequence = %v", gotRequests)
	}
	if uidStore.Len() != 3 || uidStore.ResourceVersion() != "102" {
		t.Fatalf("store len/RV = %d/%q, want 3/102", uidStore.Len(), uidStore.ResourceVersion())
	}

	batchesMu.Lock()
	gotBatches := append([]Batch(nil), batches...)
	batchesMu.Unlock()
	var watchCells []any
	for _, batch := range gotBatches {
		if batch.Table != nil && batch.Table.Cells["uid-c"] != nil {
			if len(batch.Table.Columns) != len(columns) {
				t.Fatalf("headerless WATCH retained %d columns, want %d", len(batch.Table.Columns), len(columns))
			}
			watchCells = batch.Table.Cells["uid-c"]
		}
	}
	if len(watchCells) != 3 || watchCells[1] != "Ready" {
		t.Fatalf("headerless WATCH cells = %#v", watchCells)
	}
}

func TestTableListFailureFallsBackToRawSameGVR(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name       string
		writeTable func(http.ResponseWriter)
	}{
		{
			name: "unsupported",
			writeTable: func(response http.ResponseWriter) {
				response.WriteHeader(http.StatusNotAcceptable)
			},
		},
		{
			name: "malformed",
			writeTable: func(response http.ResponseWriter) {
				writeTable(response, tableJSON("50", "", []metav1.TableColumnDefinition{{Name: "Name", Type: "string"}},
					map[string]any{"cells": []any{"broken"}},
				))
			},
		},
	} {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			options := metav1.ListOptions{
				LabelSelector: "app=kmgr",
				FieldSelector: "metadata.name=raw",
			}
			var requests requestLog
			handler := http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
				requests.add(request)
				if strings.Contains(request.Header.Get("Accept"), "as=Table") {
					test.writeTable(response)
					return
				}
				if request.URL.Query().Get("watch") == "true" {
					writeWatch(response, watchJSON("BOOKMARK", widgetJSON("", "", "52")))
					return
				}
				writeWidgetList(response, "51", widgetJSON("uid-raw", "raw", "51"))
			})
			gvr := schema.GroupVersionResource{Group: "example.io", Version: "v1", Resource: "widgets"}
			client := newTableTestClient(t, handler, gvr, "team-a")
			page, err := client.ListTable(context.Background(), options)
			if err != nil {
				t.Fatal(err)
			}
			if page.ServerTable || len(page.Objects) != 1 || page.Objects[0].GetUID() != "uid-raw" {
				t.Fatalf("fallback page = %#v", page)
			}
			if client.TableEnabled() {
				t.Fatal("Table remained enabled after negotiation failure")
			}
			watchOptions := options
			watchOptions.ResourceVersion = "51"
			stream, err := client.WatchTable(context.Background(), watchOptions)
			if err != nil {
				t.Fatal(err)
			}
			select {
			case <-stream.ResultChan():
			case <-time.After(time.Second):
				t.Fatal("raw fallback WATCH produced no event")
			}
			stream.Stop()

			got := requests.snapshot()
			if len(got) != 3 {
				t.Fatalf("requests = %v, want Table LIST, raw LIST, raw WATCH", got)
			}
			wantPath := "/apis/example.io/v1/namespaces/team-a/widgets"
			for _, request := range got {
				if request.path != wantPath {
					t.Fatalf("fallback changed GVR path: %v", got)
				}
			}
			if got[0].query.Get("includeObject") != "Object" ||
				got[1].query.Get("includeObject") != "" || got[2].query.Get("watch") != "true" {
				t.Fatalf("fallback request sequence = %v", got)
			}
			for _, request := range got {
				if request.query.Get("labelSelector") != options.LabelSelector ||
					request.query.Get("fieldSelector") != options.FieldSelector {
					t.Fatalf("fallback changed selectors: %v", got)
				}
			}
		})
	}
}

func TestTableResourceClientRequestsMetadataOnlyRepresentation(t *testing.T) {
	t.Parallel()
	var requests requestLog
	handler := http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests.add(request)
		if got := request.URL.Query().Get("includeObject"); got != string(metav1.IncludeMetadata) {
			t.Errorf("includeObject = %q, want Metadata", got)
		}
		writeTable(response, tableJSON("100", "", []metav1.TableColumnDefinition{
			{Name: "Name", Type: "string"}, {Name: "Status", Type: "string"},
		}, tableRow([]any{"alpha", "Ready"}, widgetJSON("uid-a", "alpha", "100"))))
	})
	gvr := schema.GroupVersionResource{Group: "example.io", Version: "v1", Resource: "widgets"}
	httpServer := httptest.NewServer(handler)
	t.Cleanup(httpServer.Close)
	config := &rest.Config{Host: httpServer.URL}
	dynamicClient, err := dynamic.NewForConfig(config)
	if err != nil {
		t.Fatal(err)
	}
	metadataClient, err := metadataapi.NewForConfig(config)
	if err != nil {
		t.Fatal(err)
	}
	client, err := NewTableResourceClient(
		config, gvr, "team-a", dynamicClient.Resource(gvr).Namespace("team-a"),
		metadataClient.Resource(gvr).Namespace("team-a"), metav1.IncludeMetadata,
	)
	if err != nil {
		t.Fatal(err)
	}
	page, err := client.ListTable(context.Background(), metav1.ListOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Objects) != 1 || page.Objects[0].GetUID() != "uid-a" ||
		page.Objects[0].GetName() != "alpha" || len(page.Cells[types.UID("uid-a")]) != 2 {
		t.Fatalf("metadata Table page = %#v", page)
	}
	if got := requests.snapshot(); len(got) != 1 {
		t.Fatalf("requests = %v", got)
	}
}

func TestMetadataTableFailureKeepsFallbackListAndWatchMetadataOnly(t *testing.T) {
	t.Parallel()
	var (
		requests requestLog
		acceptMu sync.Mutex
		accepts  []string
	)
	handler := http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests.add(request)
		accept := request.Header.Get("Accept")
		acceptMu.Lock()
		accepts = append(accepts, accept)
		acceptMu.Unlock()
		if strings.Contains(accept, "as=Table") {
			response.WriteHeader(http.StatusNotAcceptable)
			return
		}
		if request.URL.Query().Get("watch") == "true" {
			if !strings.Contains(accept, "as=PartialObjectMetadata;") ||
				strings.Contains(accept, "as=PartialObjectMetadataList") {
				t.Errorf("metadata WATCH Accept = %q", accept)
			}
			writeWatch(response, watchJSON("ADDED", partialWidgetJSON("uid-watch", "watched", "52")))
			return
		}
		if !strings.Contains(accept, "as=PartialObjectMetadataList;") {
			t.Errorf("metadata LIST Accept = %q", accept)
		}
		response.Header().Set("Content-Type", "application/json")
		writeJSON(response, map[string]any{
			"apiVersion": "meta.k8s.io/v1",
			"kind":       "PartialObjectMetadataList",
			"metadata": map[string]any{
				"resourceVersion": "51",
				"continue":        "next",
			},
			"items": []any{partialWidgetJSON("uid-list", "listed", "51")},
		})
	})
	gvr := schema.GroupVersionResource{Group: "example.io", Version: "v1", Resource: "widgets"}
	client := newTableTestClientWithPolicy(t, handler, gvr, "team-a", metav1.IncludeMetadata)
	options := metav1.ListOptions{
		LabelSelector:        "app=kmgr",
		FieldSelector:        "metadata.name=listed",
		ResourceVersion:      "40",
		ResourceVersionMatch: metav1.ResourceVersionMatchNotOlderThan,
		Limit:                17,
	}
	page, err := client.ListTable(context.Background(), options)
	if err != nil {
		t.Fatal(err)
	}
	if client.TableEnabled() {
		t.Fatal("Table remained enabled after negotiation failure")
	}
	if page.ServerTable || page.ResourceVersion != "51" || page.Continue != "next" || len(page.Objects) != 1 {
		t.Fatalf("metadata fallback page = %#v", page)
	}
	listed := page.Objects[0]
	if listed.GetUID() != "uid-list" || listed.GetLabels()["app"] != "kmgr" ||
		listed.GetCreationTimestamp().Time.IsZero() {
		t.Fatalf("metadata fallback object = %#v", listed.Object)
	}
	if _, found := listed.Object["spec"]; found {
		t.Fatalf("metadata fallback LIST retained spec: %#v", listed.Object)
	}

	watchOptions := options
	watchOptions.ResourceVersion = "51"
	watchOptions.ResourceVersionMatch = ""
	watchOptions.Limit = 0
	watchOptions.AllowWatchBookmarks = true
	stream, err := client.WatchTable(context.Background(), watchOptions)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Stop()
	select {
	case event := <-stream.ResultChan():
		object, ok := event.Object.(*unstructured.Unstructured)
		if !ok || object.GetUID() != "uid-watch" || object.GetLabels()["app"] != "kmgr" {
			t.Fatalf("metadata fallback WATCH event = %#v", event)
		}
		if _, found := object.Object["spec"]; found {
			t.Fatalf("metadata fallback WATCH retained spec: %#v", object.Object)
		}
	case <-time.After(time.Second):
		t.Fatal("metadata fallback WATCH produced no event")
	}

	got := requests.snapshot()
	if len(got) != 3 {
		t.Fatalf("requests = %v, want Table LIST, metadata LIST, metadata WATCH", got)
	}
	wantPath := "/apis/example.io/v1/namespaces/team-a/widgets"
	for _, request := range got {
		if request.path != wantPath || request.query.Get("labelSelector") != options.LabelSelector ||
			request.query.Get("fieldSelector") != options.FieldSelector {
			t.Fatalf("fallback changed path or selectors: %v", got)
		}
	}
	if got[0].query.Get("includeObject") != string(metav1.IncludeMetadata) ||
		got[1].query.Get("includeObject") != "" || got[1].query.Get("limit") != "17" ||
		got[1].query.Get("resourceVersion") != "40" ||
		got[1].query.Get("resourceVersionMatch") != string(metav1.ResourceVersionMatchNotOlderThan) ||
		got[2].query.Get("watch") != "true" || got[2].query.Get("resourceVersion") != "51" ||
		got[2].query.Get("allowWatchBookmarks") != "true" {
		t.Fatalf("metadata fallback request sequence = %v", got)
	}
	acceptMu.Lock()
	gotAccepts := append([]string(nil), accepts...)
	acceptMu.Unlock()
	if len(gotAccepts) != 3 || strings.Contains(gotAccepts[1], "as=Table") ||
		strings.Contains(gotAccepts[2], "as=Table") {
		t.Fatalf("fallback Accept headers = %q", gotAccepts)
	}
}

func TestMetadataTableFallbackUsesProvidedSharedClient(t *testing.T) {
	t.Parallel()
	var requests requestLog
	handler := http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests.add(request)
		if !strings.Contains(request.Header.Get("Accept"), "as=Table") {
			t.Errorf("dynamic fallback was called with Accept %q", request.Header.Get("Accept"))
		}
		response.WriteHeader(http.StatusNotAcceptable)
	})
	gvr := schema.GroupVersionResource{Group: "example.io", Version: "v1", Resource: "widgets"}
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	config := &rest.Config{Host: server.URL}
	dynamicClient, err := dynamic.NewForConfig(config)
	if err != nil {
		t.Fatal(err)
	}
	provided := &tableMetadataFallbackStub{page: &metav1.PartialObjectMetadataList{
		ListMeta: metav1.ListMeta{ResourceVersion: "shared-rv"},
		Items: []metav1.PartialObjectMetadata{{ObjectMeta: metav1.ObjectMeta{
			Namespace: "team-a", Name: "shared", UID: "shared-uid", ResourceVersion: "shared-rv",
		}}},
	}}
	client, err := NewTableResourceClient(
		config, gvr, "team-a", dynamicClient.Resource(gvr).Namespace("team-a"),
		provided, metav1.IncludeMetadata,
	)
	if err != nil {
		t.Fatal(err)
	}
	page, err := client.ListTable(context.Background(), metav1.ListOptions{LabelSelector: "app=kmgr"})
	if err != nil {
		t.Fatal(err)
	}
	if provided.listCalls != 1 || provided.lastListOptions.LabelSelector != "app=kmgr" {
		t.Fatalf("provided metadata LIST calls/options = %d/%#v", provided.listCalls, provided.lastListOptions)
	}
	if len(page.Objects) != 1 || page.Objects[0].GetUID() != "shared-uid" {
		t.Fatalf("provided metadata fallback page = %#v", page)
	}
	if got := requests.snapshot(); len(got) != 1 {
		t.Fatalf("HTTP requests = %v, want only Table negotiation", got)
	}
}

func TestDisabledMetadataTablePipelinePreservesWatchList(t *testing.T) {
	t.Parallel()
	var requests requestLog
	handler := http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests.add(request)
		accept := request.Header.Get("Accept")
		query := request.URL.Query()
		if strings.Contains(accept, "as=Table") || !strings.Contains(accept, "as=PartialObjectMetadata;") {
			t.Errorf("disabled Table WatchList Accept = %q", accept)
		}
		if query.Get("watch") != "true" || query.Get("sendInitialEvents") != "true" ||
			query.Get("resourceVersionMatch") != string(metav1.ResourceVersionMatchNotOlderThan) ||
			query.Get("allowWatchBookmarks") != "true" || query.Get("limit") != "" {
			t.Errorf("disabled Table WatchList query = %v", query)
		}
		writeWatch(response,
			watchJSON("ADDED", partialWidgetJSON("uid-a", "alpha", "70")),
			watchJSON("BOOKMARK", initialEventsEndBookmarkJSON("71", "true")),
		)
	})
	gvr := schema.GroupVersionResource{Group: "example.io", Version: "v1", Resource: "widgets"}
	client := newTableTestClientWithPolicy(t, handler, gvr, "team-a", metav1.IncludeMetadata)
	client.DisableTable()
	uidStore := store.New()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	pipeline := mustPipeline(t, PipelineConfig{
		Client: client,
		Store:  uidStore,
		ListOptions: metav1.ListOptions{
			LabelSelector: "app=kmgr",
		},
		RetryDelay: noDelay,
		OnBatch: func(batch Batch) {
			if batch.SnapshotComplete {
				cancel()
			}
		},
	})
	assertRunCancelled(t, runPipeline(ctx, pipeline))
	if uidStore.Len() != 1 || uidStore.ResourceVersion() != "71" {
		t.Fatalf("metadata WatchList store len/RV = %d/%q", uidStore.Len(), uidStore.ResourceVersion())
	}
	object, found := snapshotObject(uidStore, "uid-a")
	if !found || object.GetLabels()["app"] != "kmgr" || object.GetCreationTimestamp().Time.IsZero() {
		t.Fatalf("metadata WatchList object = %#v, found %v", object, found)
	}
	if _, found := object.Object["spec"]; found {
		t.Fatalf("metadata WatchList retained spec: %#v", object.Object)
	}
	got := requests.snapshot()
	if len(got) != 1 || got[0].path != "/apis/example.io/v1/namespaces/team-a/widgets" ||
		got[0].query.Get("labelSelector") != "app=kmgr" {
		t.Fatalf("disabled Table WatchList requests = %v", got)
	}
}

func TestDecodeTableObjectAcceptsTypedPartialObjectMetadata(t *testing.T) {
	t.Parallel()
	metadata := &metav1.PartialObjectMetadata{
		TypeMeta: metav1.TypeMeta{APIVersion: "meta.k8s.io/v1", Kind: "PartialObjectMetadata"},
		ObjectMeta: metav1.ObjectMeta{
			Namespace: "team-a", Name: "alpha", UID: "uid-a", ResourceVersion: "100",
			Labels: map[string]string{"app": "api"},
		},
	}
	object, err := decodeTableObject(&metav1.TableRow{
		Object: k8sruntime.RawExtension{Object: metadata},
	})
	if err != nil {
		t.Fatal(err)
	}
	if object.GetUID() != "uid-a" || object.GetLabels()["app"] != "api" {
		t.Fatalf("decoded metadata object = %#v", object)
	}
}

func TestTableResourceClientRetainsAuthorityRateLimiter(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	t.Cleanup(server.Close)
	limiter := flowcontrol.NewTokenBucketRateLimiter(12.5, 37)
	config := &rest.Config{Host: server.URL, RateLimiter: limiter}
	gvr := schema.GroupVersionResource{Group: "example.io", Version: "v1", Resource: "widgets"}
	dynamicClient, err := dynamic.NewForConfig(config)
	if err != nil {
		t.Fatalf("construct fallback client: %v", err)
	}
	client, err := NewTableResourceClient(
		config, gvr, "team-a", dynamicClient.Resource(gvr).Namespace("team-a"), nil, metav1.IncludeObject,
	)
	if err != nil {
		t.Fatalf("NewTableResourceClient: %v", err)
	}
	if got := client.rest.GetRateLimiter(); got != limiter {
		t.Fatal("Table REST config replaced the authority-wide limiter")
	}
}

func newTableTestClient(
	t *testing.T,
	handler http.Handler,
	gvr schema.GroupVersionResource,
	namespace string,
) *TableResourceClient {
	t.Helper()
	return newTableTestClientWithPolicy(t, handler, gvr, namespace, metav1.IncludeObject)
}

func newTableTestClientWithPolicy(
	t *testing.T,
	handler http.Handler,
	gvr schema.GroupVersionResource,
	namespace string,
	include metav1.IncludeObjectPolicy,
) *TableResourceClient {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	config := &rest.Config{Host: server.URL}
	dynamicClient, err := dynamic.NewForConfig(config)
	if err != nil {
		t.Fatal(err)
	}
	var fallback ListerWatcher = dynamicClient.Resource(gvr)
	if namespace != "" {
		fallback = dynamicClient.Resource(gvr).Namespace(namespace)
	}
	var metadataFallback metadataapi.ResourceInterface
	if include == metav1.IncludeMetadata {
		metadataClient, metadataErr := metadataapi.NewForConfig(config)
		if metadataErr != nil {
			t.Fatal(metadataErr)
		}
		resourceClient := metadataClient.Resource(gvr)
		if namespace == "" {
			metadataFallback = resourceClient
		} else {
			metadataFallback = resourceClient.Namespace(namespace)
		}
	}
	client, err := NewTableResourceClient(config, gvr, namespace, fallback, metadataFallback, include)
	if err != nil {
		t.Fatal(err)
	}
	return client
}

type tableMetadataFallbackStub struct {
	metadataapi.ResourceInterface
	page            *metav1.PartialObjectMetadataList
	listCalls       int
	lastListOptions metav1.ListOptions
}

func (c *tableMetadataFallbackStub) List(
	_ context.Context,
	options metav1.ListOptions,
) (*metav1.PartialObjectMetadataList, error) {
	c.listCalls++
	c.lastListOptions = options
	return c.page.DeepCopy(), nil
}

func partialWidgetJSON(uid, name, resourceVersion string) map[string]any {
	return map[string]any{
		"apiVersion": "meta.k8s.io/v1",
		"kind":       "PartialObjectMetadata",
		"metadata": map[string]any{
			"uid": uid, "namespace": "team-a", "name": name, "resourceVersion": resourceVersion,
			"creationTimestamp": "2026-08-19T08:00:00Z",
			"labels":            map[string]any{"app": "kmgr"},
		},
		// A malformed endpoint returning extra fields still cannot leak them
		// through the typed metadata-client boundary.
		"spec": map[string]any{"payload": "must-not-enter-store"},
	}
}

func tableJSON(
	resourceVersion, continueToken string,
	columns []metav1.TableColumnDefinition,
	rows ...map[string]any,
) map[string]any {
	value := map[string]any{
		"apiVersion": "meta.k8s.io/v1",
		"kind":       "Table",
		"metadata": map[string]any{
			"resourceVersion": resourceVersion,
			"continue":        continueToken,
		},
		"rows": rows,
	}
	if columns != nil {
		value["columnDefinitions"] = columns
	}
	return value
}

func tableRow(cells []any, object map[string]any) map[string]any {
	return map[string]any{"cells": cells, "object": object}
}

func widgetJSON(uid, name, resourceVersion string) map[string]any {
	return map[string]any{
		"apiVersion": "example.io/v1",
		"kind":       "Widget",
		"metadata": map[string]any{
			"uid": uid, "namespace": "team-a", "name": name, "resourceVersion": resourceVersion,
		},
	}
}

func writeTable(response http.ResponseWriter, value map[string]any) {
	response.Header().Set("Content-Type", "application/json")
	writeJSON(response, value)
}

func writeWidgetList(response http.ResponseWriter, resourceVersion string, items ...map[string]any) {
	response.Header().Set("Content-Type", "application/json")
	writeJSON(response, map[string]any{
		"apiVersion": "example.io/v1", "kind": "WidgetList",
		"metadata": map[string]any{"resourceVersion": resourceVersion}, "items": items,
	})
}
