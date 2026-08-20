package cluster

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/charlie0129/kmgr/backend/internal/apioperation"
)

func TestDescribeAPIOperationClassifiesKubernetesPaths(t *testing.T) {
	t.Parallel()
	tests := []struct {
		method, target string
		want           apiOperationDescriptor
	}{
		{
			http.MethodGet, "https://cluster.test/api/v1/pods?watch=true&labelSelector=secret",
			apiOperationDescriptor{operation: "WATCH", version: "v1", resource: "pods"},
		},
		{
			http.MethodGet, "https://cluster.test/api/v1/namespaces/default/pods",
			apiOperationDescriptor{
				operation: "LIST", version: "v1", resource: "pods", namespace: "default",
			},
		},
		{
			http.MethodDelete, "https://cluster.test/apis/apps/v1/namespaces/team/deployments/api",
			apiOperationDescriptor{
				operation: "DELETE", group: "apps", version: "v1", resource: "deployments",
				namespace: "team", name: "api",
			},
		},
		{
			http.MethodPut, "https://cluster.test/api/v1/nodes/node-a/status",
			apiOperationDescriptor{
				operation: "UPDATE", version: "v1", resource: "nodes", name: "node-a",
				subresource: "status",
			},
		},
		{
			http.MethodPut, "https://cluster.test/api/v1/namespaces/team/finalize",
			apiOperationDescriptor{
				operation: "UPDATE", version: "v1", resource: "namespaces", name: "team",
				subresource: "finalize",
			},
		},
		{
			http.MethodGet, "https://cluster.test/apis/apps/v1",
			apiOperationDescriptor{
				operation: "DISCOVER", group: "apps", version: "v1", resource: "API discovery",
			},
		},
		{
			http.MethodPost, "https://cluster.test/api/v1/namespaces/default/pods/api/exec",
			apiOperationDescriptor{
				operation: "CONNECT", version: "v1", resource: "pods", namespace: "default",
				name: "api", subresource: "exec",
			},
		},
	}
	for _, test := range tests {
		test := test
		t.Run(test.method+" "+test.target, func(t *testing.T) {
			t.Parallel()
			request, err := http.NewRequest(test.method, test.target, nil)
			if err != nil {
				t.Fatal(err)
			}
			if got := describeAPIOperation(request); got != test.want {
				t.Fatalf("describeAPIOperation() = %#v, want %#v", got, test.want)
			}
		})
	}
}

func TestActivityRoundTripperTracksOperationLifetimeAndRedactsPayloads(t *testing.T) {
	t.Parallel()
	activity := &APIActivity{}
	base := roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if _, err := io.Copy(io.Discard, request.Body); err != nil {
			t.Fatal(err)
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Body:       io.NopCloser(strings.NewReader("sensitive-response")),
			Request:    request,
		}, nil
	})
	request, err := http.NewRequestWithContext(
		context.Background(),
		http.MethodPatch,
		"https://cluster.test/apis/apps/v1/namespaces/team/deployments/api?fieldSelector=sensitive-selector",
		bytes.NewBufferString("sensitive-request"),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer sensitive-token")
	response, err := (&activityRoundTripper{base: base, activity: activity}).RoundTrip(request)
	if err != nil {
		t.Fatal(err)
	}

	active := activity.OperationActivitySnapshot(0)
	if len(active.Active) != 1 || len(active.Completed) != 0 {
		t.Fatalf("active snapshot = %#v", active)
	}
	record := active.Active[0]
	if record.Operation != "PATCH" || record.Resource != "deployments" ||
		record.Namespace != "team" || record.Name != "api" ||
		record.HTTPStatusCode != http.StatusOK ||
		record.BytesSent != uint64(len("sensitive-request")) {
		t.Fatalf("active operation = %#v", record)
	}
	buffer := make([]byte, 4)
	if count, err := response.Body.Read(buffer); count != 4 || err != nil {
		t.Fatalf("response read = %d, %v", count, err)
	}
	if got := activity.OperationActivitySnapshot(0).Active[0].BytesReceived; got != 4 {
		t.Fatalf("received bytes = %d, want 4", got)
	}
	if err := response.Body.Close(); err != nil {
		t.Fatal(err)
	}

	completed := activity.OperationActivitySnapshot(0)
	if len(completed.Active) != 0 || len(completed.Completed) != 1 {
		t.Fatalf("completed snapshot = %#v", completed)
	}
	record = completed.Completed[0]
	if record.State != APIOperationStateFinished ||
		record.FinishedAtUnixNanos < record.StartedAtUnixNanos {
		t.Fatalf("completed operation = %#v", record)
	}
	presentation := fmt.Sprintf("%+v", completed)
	for _, sensitive := range []string{
		"sensitive-selector", "sensitive-token", "sensitive-request", "sensitive-response",
	} {
		if strings.Contains(presentation, sensitive) {
			t.Fatalf("operation snapshot retained %q: %s", sensitive, presentation)
		}
	}
	if next := activity.OperationActivitySnapshot(completed.CompletionCursor); len(next.Completed) != 0 {
		t.Fatalf("completed operation was retransmitted: %#v", next.Completed)
	}
}

func TestActivityRoundTripperMarksCancelledWatchWithRawContextError(t *testing.T) {
	t.Parallel()
	activity := &APIActivity{}
	ctx, cancel := context.WithCancel(context.Background())
	request, err := http.NewRequestWithContext(
		ctx, http.MethodGet, "https://cluster.test/api/v1/pods?watch=true", nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	base := roundTripFunc(func(request *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Body:       &operationTestReadCloser{},
			Request:    request,
		}, nil
	})
	response, err := (&activityRoundTripper{base: base, activity: activity}).RoundTrip(request)
	if err != nil {
		t.Fatal(err)
	}
	if active := activity.OperationActivitySnapshot(0).Active; len(active) != 1 ||
		active[0].Operation != "WATCH" {
		t.Fatalf("active watch = %#v", active)
	}
	cancel()
	if err := response.Body.Close(); err != nil {
		t.Fatal(err)
	}
	completed := activity.OperationActivitySnapshot(0).Completed
	if len(completed) != 1 || completed[0].State != APIOperationStateCancelled ||
		completed[0].ErrorMessage != context.Canceled.Error() {
		t.Fatalf("cancelled watch = %#v", completed)
	}
}

func TestActivityRoundTripperRetainsRawTransportFailure(t *testing.T) {
	t.Parallel()
	activity := &APIActivity{}
	request, err := http.NewRequest(http.MethodGet, "https://cluster.test/api/v1/nodes", nil)
	if err != nil {
		t.Fatal(err)
	}
	base := roundTripFunc(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("sensitive transport failure")
	})
	if _, err := (&activityRoundTripper{base: base, activity: activity}).RoundTrip(request); err == nil {
		t.Fatal("RoundTrip succeeded")
	}
	completed := activity.OperationActivitySnapshot(0).Completed
	if len(completed) != 1 || completed[0].State != APIOperationStateFailed ||
		completed[0].HTTPStatusCode != 0 ||
		completed[0].ErrorMessage != "sensitive transport failure" {
		t.Fatalf("transport failure = %#v", completed)
	}
}

func TestActivityRoundTripperCombinesKubernetesWatchAndGoStreamErrors(t *testing.T) {
	t.Parallel()
	const (
		serverMessage = "a watch stream was requested by the client but the required storage feature RequestWatchProgress is disabled"
		goMessage     = "http2: response body closed"
	)
	want := "Kubernetes server (InternalError, HTTP 500): " + serverMessage + "\nGo: " + goMessage
	serverError := &apierrors.StatusError{ErrStatus: metav1.Status{
		Status: metav1.StatusFailure, Message: serverMessage,
		Reason: metav1.StatusReasonInternalError, Code: http.StatusInternalServerError,
	}}

	for _, observeBeforeGoError := range []bool{true, false} {
		name := "server error before Go error"
		if !observeBeforeGoError {
			name = "server error after Go error"
		}
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			activity := &APIActivity{}
			ctx, observer := apioperation.WithWatchErrorObserver(context.Background())
			request, err := http.NewRequestWithContext(
				ctx, http.MethodGet,
				"https://cluster.test/api/v1/nodes?watch=true&sendInitialEvents=true",
				nil,
			)
			if err != nil {
				t.Fatal(err)
			}
			base := roundTripFunc(func(request *http.Request) (*http.Response, error) {
				return &http.Response{
					StatusCode: http.StatusOK,
					Body:       &operationErrorReadCloser{err: errors.New(goMessage)},
					Request:    request,
				}, nil
			})
			response, err := (&activityRoundTripper{base: base, activity: activity}).RoundTrip(request)
			if err != nil {
				t.Fatal(err)
			}
			if observeBeforeGoError {
				observer.Observe(serverError)
			}
			if _, err := response.Body.Read(make([]byte, 1)); err == nil || err.Error() != goMessage {
				t.Fatalf("body error = %v, want %q", err, goMessage)
			}

			first := activity.OperationActivitySnapshot(0)
			if len(first.Completed) != 1 {
				t.Fatalf("initial completion = %#v", first.Completed)
			}
			if !observeBeforeGoError {
				if first.Completed[0].ErrorMessage != goMessage {
					t.Fatalf("initial Go error = %q", first.Completed[0].ErrorMessage)
				}
				observer.Observe(serverError)
				first = activity.OperationActivitySnapshot(first.CompletionCursor)
				if len(first.Completed) != 1 {
					t.Fatalf("corrected completion = %#v", first.Completed)
				}
			}
			record := first.Completed[0]
			if record.State != APIOperationStateFailed || record.HTTPStatusCode != http.StatusOK ||
				record.ErrorMessage != want {
				t.Fatalf("combined completion = %#v, want error %q", record, want)
			}
		})
	}
}

func TestAPIOperationCompletionRingReportsBoundedLoss(t *testing.T) {
	t.Parallel()
	var ring apiOperationCompletionRing
	for sequence := uint64(1); sequence <= apiOperationCompletionCapacity+2; sequence++ {
		ring.append(completedAPIOperation{
			sequence: sequence,
			snapshot: APIOperationSnapshot{ID: sequence},
		})
	}
	records, dropped := ring.recordsAfter(0)
	if len(records) != apiOperationCompletionCapacity || dropped != 2 ||
		records[0].ID != 3 || records[len(records)-1].ID != apiOperationCompletionCapacity+2 {
		t.Fatalf(
			"bounded records = len %d, dropped %d, first %d, last %d",
			len(records), dropped, records[0].ID, records[len(records)-1].ID,
		)
	}
	records, dropped = ring.recordsAfter(apiOperationCompletionCapacity + 1)
	if len(records) != 1 || records[0].ID != apiOperationCompletionCapacity+2 || dropped != 0 {
		t.Fatalf("incremental records = %#v, dropped %d", records, dropped)
	}
}

type operationTestReadCloser struct{}

func (*operationTestReadCloser) Read([]byte) (int, error) { return 0, nil }
func (*operationTestReadCloser) Close() error             { return nil }

type operationErrorReadCloser struct{ err error }

func (r *operationErrorReadCloser) Read([]byte) (int, error) { return 0, r.err }
func (*operationErrorReadCloser) Close() error               { return nil }
