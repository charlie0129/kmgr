package view

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestViewServiceMethodsValidateRequestContext(t *testing.T) {
	t.Parallel()
	service := newViewContextService(t, newSearchClient())
	expired := time.Now().Add(-time.Second).UnixMilli()
	tests := []struct {
		name           string
		code           codes.Code
		requestContext *kmgrv1.RequestContext
		call           func(*kmgrv1.RequestContext) error
	}{
		{
			name: "cached search missing request ID", code: codes.InvalidArgument,
			requestContext: &kmgrv1.RequestContext{ClusterSessionId: "session"},
			call: func(ctx *kmgrv1.RequestContext) error {
				_, err := service.SearchCachedObjects(context.Background(), cachedSearchRequest(ctx))
				return err
			},
		},
		{
			name: "streaming search missing request ID", code: codes.InvalidArgument,
			requestContext: &kmgrv1.RequestContext{ClusterSessionId: "session"},
			call: func(ctx *kmgrv1.RequestContext) error {
				return service.SearchObjects(searchRequest(ctx), newViewTestStream[kmgrv1.SearchObjectsEvent](context.Background()))
			},
		},
		{
			name: "cancel search missing session", code: codes.InvalidArgument,
			requestContext: &kmgrv1.RequestContext{RequestId: "request"},
			call: func(ctx *kmgrv1.RequestContext) error {
				_, err := service.CancelSearch(context.Background(), &kmgrv1.CancelSearchRequest{
					Context: ctx, SearchId: "search", Generation: 1, QueryRevision: 1,
				})
				return err
			},
		},
		{
			name: "stream view missing request ID", code: codes.InvalidArgument,
			requestContext: &kmgrv1.RequestContext{ClusterSessionId: "session"},
			call: func(ctx *kmgrv1.RequestContext) error {
				request := openView("session", "view", 1)
				request.Context = ctx
				return service.StreamView(request, newViewTestStream[kmgrv1.ViewEvent](context.Background()))
			},
		},
		{
			name: "cancel view missing session", code: codes.InvalidArgument,
			requestContext: &kmgrv1.RequestContext{RequestId: "request"},
			call: func(ctx *kmgrv1.RequestContext) error {
				_, err := service.CancelView(context.Background(), &kmgrv1.CancelViewRequest{
					Context: ctx, ViewId: "view", Generation: 1,
				})
				return err
			},
		},
		{
			name: "cached search expired", code: codes.DeadlineExceeded,
			requestContext: &kmgrv1.RequestContext{
				RequestId: "request", ClusterSessionId: "session", DeadlineUnixMs: expired,
			},
			call: func(ctx *kmgrv1.RequestContext) error {
				_, err := service.SearchCachedObjects(context.Background(), cachedSearchRequest(ctx))
				return err
			},
		},
		{
			name: "streaming search expired", code: codes.DeadlineExceeded,
			requestContext: &kmgrv1.RequestContext{
				RequestId: "request", ClusterSessionId: "session", DeadlineUnixMs: expired,
			},
			call: func(ctx *kmgrv1.RequestContext) error {
				return service.SearchObjects(searchRequest(ctx), newViewTestStream[kmgrv1.SearchObjectsEvent](context.Background()))
			},
		},
		{
			name: "cancel search expired", code: codes.DeadlineExceeded,
			requestContext: &kmgrv1.RequestContext{
				RequestId: "request", ClusterSessionId: "session", DeadlineUnixMs: expired,
			},
			call: func(ctx *kmgrv1.RequestContext) error {
				_, err := service.CancelSearch(context.Background(), &kmgrv1.CancelSearchRequest{
					Context: ctx, SearchId: "search", Generation: 1, QueryRevision: 1,
				})
				return err
			},
		},
		{
			name: "stream view expired", code: codes.DeadlineExceeded,
			requestContext: &kmgrv1.RequestContext{
				RequestId: "request", ClusterSessionId: "session", DeadlineUnixMs: expired,
			},
			call: func(ctx *kmgrv1.RequestContext) error {
				request := openView("session", "view", 1)
				request.Context = ctx
				return service.StreamView(request, newViewTestStream[kmgrv1.ViewEvent](context.Background()))
			},
		},
		{
			name: "cancel view expired", code: codes.DeadlineExceeded,
			requestContext: &kmgrv1.RequestContext{
				RequestId: "request", ClusterSessionId: "session", DeadlineUnixMs: expired,
			},
			call: func(ctx *kmgrv1.RequestContext) error {
				_, err := service.CancelView(context.Background(), &kmgrv1.CancelViewRequest{
					Context: ctx, ViewId: "view", Generation: 1,
				})
				return err
			},
		},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			if err := test.call(test.requestContext); status.Code(err) != test.code {
				t.Fatalf("status code = %v, want %v (error %v)", status.Code(err), test.code, err)
			}
		})
	}
}

func TestViewServiceUnaryResponsesEchoValidatedRequestID(t *testing.T) {
	t.Parallel()
	service := newViewContextService(t, newSearchClient())
	requestContext := viewTestRequestContext("cached-identity")
	cached, err := service.SearchCachedObjects(context.Background(), cachedSearchRequest(requestContext))
	if err != nil || cached.GetRequestId() != "cached-identity" {
		t.Fatalf("cached response = %#v, error = %v", cached, err)
	}

	cancelSearch, err := service.CancelSearch(context.Background(), &kmgrv1.CancelSearchRequest{
		Context:  viewTestRequestContext("cancel-search-identity"),
		SearchId: "absent", Generation: 1, QueryRevision: 1,
	})
	if err != nil || cancelSearch.GetRequestId() != "cancel-search-identity" || cancelSearch.GetAccepted() {
		t.Fatalf("cancel search response = %#v, error = %v", cancelSearch, err)
	}

	cancelView, err := service.CancelView(context.Background(), &kmgrv1.CancelViewRequest{
		Context: viewTestRequestContext("cancel-view-identity"), ViewId: "absent", Generation: 1,
	})
	if err != nil || cancelView.GetRequestId() != "cancel-view-identity" || cancelView.GetAccepted() {
		t.Fatalf("cancel view response = %#v, error = %v", cancelView, err)
	}
}

func TestStreamViewApplicationDeadlineClosesConsumer(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.firstPageGate = make(chan struct{})
	service := newViewContextService(t, client)
	request := openView("session", "deadline-view", 1)
	request.Context.RequestId = "deadline-request"
	request.Context.DeadlineUnixMs = time.Now().Add(40 * time.Millisecond).UnixMilli()
	stream := newViewTestStream[kmgrv1.ViewEvent](context.Background())

	if err := service.StreamView(request, stream); status.Code(err) != codes.DeadlineExceeded {
		t.Fatalf("stream error = %v, want deadline exceeded", err)
	}
	service.runtime.mu.Lock()
	_, retained := service.runtime.views[viewKey{sessionID: "session", viewID: "deadline-view"}]
	service.runtime.mu.Unlock()
	if retained {
		t.Fatal("deadline-expired stream retained its view consumer")
	}
}

func TestRuntimeOpenRejectsMissingRequestIDAndExpiredDeadline(t *testing.T) {
	t.Parallel()
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{authority: "authority", client: newSearchClient()},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	missingID := openView("session", "missing-id", 1)
	missingID.Context.RequestId = ""
	if _, err := runtime.Open(missingID); !errors.Is(err, ErrInvalidView) {
		t.Fatalf("missing request ID error = %v", err)
	}
	expired := openView("session", "expired", 1)
	expired.Context.DeadlineUnixMs = time.Now().Add(-time.Second).UnixMilli()
	if _, err := runtime.Open(expired); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expired request error = %v", err)
	}
}

func TestSearchObjectsApplicationDeadlineCancelsRuntimeWork(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.firstPageGate = make(chan struct{})
	service := newViewContextService(t, client)
	request := searchRequest(viewTestRequestContext("deadline-search"))
	request.Context.DeadlineUnixMs = time.Now().Add(40 * time.Millisecond).UnixMilli()
	stream := newViewTestStream[kmgrv1.SearchObjectsEvent](context.Background())

	if err := service.SearchObjects(request, stream); status.Code(err) != codes.DeadlineExceeded {
		t.Fatalf("search error = %v, want deadline exceeded", err)
	}
	service.searchMu.Lock()
	active := len(service.searches)
	service.searchMu.Unlock()
	if active != 0 {
		t.Fatalf("deadline-expired search retained %d registrations", active)
	}
}

func TestSearchObjectsStreamsStructuredKubernetesStatusFailure(t *testing.T) {
	t.Parallel()
	client := newSearchClient()
	client.getErr = &apierrors.StatusError{ErrStatus: metav1.Status{
		Status: metav1.StatusFailure, Reason: metav1.StatusReasonInvalid, Code: 422,
		Message: "must-not-cross-the-protocol-boundary",
		Details: &metav1.StatusDetails{
			Group: "apps", Kind: "Deployment", Name: "api",
			Causes: []metav1.StatusCause{{
				Type: metav1.CauseTypeFieldValueInvalid, Field: "spec.replicas",
				Message: "must-not-cross-the-protocol-boundary",
			}},
		},
	}}
	service := newViewContextService(t, client)
	request := searchRequest(viewTestRequestContext("status-search"))
	request.Query = "team/api"
	stream := newViewTestStream[kmgrv1.SearchObjectsEvent](context.Background())

	if err := service.SearchObjects(request, stream); err != nil {
		t.Fatal(err)
	}
	stream.mu.Lock()
	defer stream.mu.Unlock()
	if len(stream.values) != 1 {
		t.Fatalf("streamed %d events, want one failure", len(stream.values))
	}
	failure := stream.values[0].GetError()
	if failure.GetHttpStatusCode() != 422 || failure.GetReason() != "Invalid" ||
		failure.GetKubernetesStatus().GetGroup() != "apps" ||
		failure.GetKubernetesStatus().GetKind() != "Deployment" ||
		failure.GetKubernetesStatus().GetName() != "api" ||
		len(failure.GetKubernetesStatus().GetCauses()) != 1 ||
		failure.GetKubernetesStatus().GetCauses()[0].GetField() != "spec.replicas" {
		t.Fatalf("structured search failure = %#v", failure)
	}
	if failure.GetKubernetesStatus().GetMessage() != "" ||
		failure.GetKubernetesStatus().GetCauses()[0].GetMessage() != "" {
		t.Fatalf("raw Kubernetes messages crossed the protocol: %#v", failure)
	}
}

func newViewContextService(t *testing.T, client *searchClient) *GRPCService {
	t.Helper()
	runtime, err := NewRuntime(RuntimeConfig{
		Source:     &fakeResourceSource{authority: "authority", client: client},
		BatchDelay: time.Millisecond, PipelineTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(runtime.Close)
	service, err := NewGRPCService(runtime)
	if err != nil {
		t.Fatal(err)
	}
	return service
}

func viewTestRequestContext(requestID string) *kmgrv1.RequestContext {
	return &kmgrv1.RequestContext{
		RequestId: requestID, ClusterSessionId: "session",
		DeadlineUnixMs: time.Now().Add(time.Second).UnixMilli(),
	}
}

func cachedSearchRequest(requestContext *kmgrv1.RequestContext) *kmgrv1.SearchCachedObjectsRequest {
	return &kmgrv1.SearchCachedObjectsRequest{Context: requestContext, Query: "api"}
}

func searchRequest(requestContext *kmgrv1.RequestContext) *kmgrv1.SearchObjectsRequest {
	return &kmgrv1.SearchObjectsRequest{
		Context: requestContext, SearchId: "search", Generation: 1, QueryRevision: 1,
		Resource:       &kmgrv1.ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		NamespaceScope: &kmgrv1.NamespaceScope{AllNamespaces: true},
		Query:          "api", AllowPaginatedList: true,
	}
}

type viewTestStream[T any] struct {
	grpc.ServerStream
	ctx    context.Context
	mu     sync.Mutex
	values []*T
}

func newViewTestStream[T any](ctx context.Context) *viewTestStream[T] {
	return &viewTestStream[T]{ctx: ctx}
}

func (s *viewTestStream[T]) Context() context.Context { return s.ctx }
func (s *viewTestStream[T]) Send(value *T) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.values = append(s.values, value)
	return nil
}
func (s *viewTestStream[T]) SetHeader(metadata.MD) error  { return nil }
func (s *viewTestStream[T]) SendHeader(metadata.MD) error { return nil }
func (s *viewTestStream[T]) SetTrailer(metadata.MD)       {}
func (s *viewTestStream[T]) SendMsg(any) error            { return errors.New("unexpected SendMsg") }
func (s *viewTestStream[T]) RecvMsg(any) error            { return errors.New("unexpected RecvMsg") }

var _ grpc.ServerStreamingServer[kmgrv1.ViewEvent] = (*viewTestStream[kmgrv1.ViewEvent])(nil)
var _ grpc.ServerStreamingServer[kmgrv1.SearchObjectsEvent] = (*viewTestStream[kmgrv1.SearchObjectsEvent])(nil)
