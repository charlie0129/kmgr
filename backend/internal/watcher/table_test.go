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
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
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
	client, err := NewTableResourceClient(config, gvr, "team-a", dynamicClient.Resource(gvr).Namespace("team-a"))
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
	client, err := NewTableResourceClient(config, gvr, namespace, fallback)
	if err != nil {
		t.Fatal(err)
	}
	return client
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
