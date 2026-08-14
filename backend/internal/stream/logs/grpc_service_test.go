package logs

import (
	"bytes"
	"context"
	"errors"
	"io"
	"sync"
	"testing"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	corev1 "k8s.io/api/core/v1"
)

type workloadResolverFunc func(context.Context, string, []Identity, int) (SourceResolution, error)

func (f workloadResolverFunc) Resolve(
	ctx context.Context,
	sessionID string,
	identities []Identity,
	limit int,
) (SourceResolution, error) {
	return f(ctx, sessionID, identities, limit)
}

func TestStartFromProtoPreservesIdentityAndOptionalLogOptions(t *testing.T) {
	t.Parallel()
	sinceUnixMS := time.Now().Add(-time.Hour).UnixMilli()
	sinceSeconds := int64(60)
	tail := int64(100)
	limit := int64(1 << 20)
	convertedInvalid, err := startFromProto(&kmgrv1.StartLogsRequest{
		Context:     &kmgrv1.RequestContext{RequestId: "request", ClusterSessionId: "session-1"},
		LogStreamId: "logs", Generation: 8,
		Sources: []*kmgrv1.LogSource{{
			Identity: &kmgrv1.ResourceIdentity{
				ClusterSessionId: "session-1", Version: "v1", Resource: "pods",
				Namespace: "default", Name: "api-0", Uid: "uid-0",
			},
			SourceId: "source", SourceLabel: "default/api-0", Container: "main",
		}},
		Options: &kmgrv1.LogOptions{
			Follow: true, Previous: true, Timestamps: true,
			SinceUnixMs: &sinceUnixMS, SinceSeconds: &sinceSeconds,
			TailLines: &tail, ByteLimit: &limit,
		},
	})
	if err == nil {
		err = validateStart(convertedInvalid, DefaultMaxSourcesPerStream)
	}
	if !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("mutually exclusive since options error = %v", err)
	}

	request := &kmgrv1.StartLogsRequest{
		Context:     &kmgrv1.RequestContext{RequestId: "request", ClusterSessionId: "session-1"},
		LogStreamId: "logs", Generation: 8,
		Sources: []*kmgrv1.LogSource{{
			Identity: &kmgrv1.ResourceIdentity{
				ClusterSessionId: "session-1", Version: "v1", Resource: "pods",
				Namespace: "default", Name: "api-0", Uid: "uid-0",
			},
			SourceId: "source", SourceLabel: "default/api-0", Container: "main",
		}},
		Options: &kmgrv1.LogOptions{
			Follow: true, Previous: true, Timestamps: true,
			SinceSeconds: &sinceSeconds, TailLines: &tail, ByteLimit: &limit,
		},
	}
	converted, err := startFromProto(request)
	if err != nil {
		t.Fatalf("startFromProto: %v", err)
	}
	if converted.SessionID != "session-1" || converted.StreamID != "logs" || converted.Generation != 8 || len(converted.Sources) != 1 {
		t.Fatalf("converted request = %#v", converted)
	}
	if converted.Sources[0].Identity.UID != "uid-0" || converted.Sources[0].Container != "main" ||
		converted.Options.SinceSeconds == nil || *converted.Options.SinceSeconds != sinceSeconds ||
		converted.Options.TailLines == nil || *converted.Options.TailLines != tail ||
		converted.Options.ByteLimit == nil || *converted.Options.ByteLimit != limit {
		t.Fatalf("converted source/options = %#v / %#v", converted.Sources[0], converted.Options)
	}
}

func TestStartFromProtoRejectsDynamicWorkloadMembershipExplicitly(t *testing.T) {
	t.Parallel()
	_, err := startFromProto(&kmgrv1.StartLogsRequest{
		Options: &kmgrv1.LogOptions{FollowWorkloadMembership: true},
	})
	if status.Code(err) != codes.Unimplemented {
		t.Fatalf("error code = %v, want Unimplemented: %v", status.Code(err), err)
	}
}

func TestStructuredLogErrorRedactsPayloadAndPreservesIdentity(t *testing.T) {
	t.Parallel()
	secretPayload := "sensitive log payload"
	source := testSource("api")
	result := structuredLogError(errors.New(secretPayload), &source, "production")
	if result.GetMessage() == secretPayload || result.GetReason() == secretPayload {
		t.Fatal("raw log failure entered the structured error")
	}
	if result.GetContextName() != "production" || result.GetResource().GetUid() != "uid-api" {
		t.Fatalf("safe error context = %#v", result)
	}
}

func TestResolveLogSourcesReturnsActionableBoundedFailure(t *testing.T) {
	t.Parallel()
	manager := testManager(t, openerFunc(func(context.Context, Source, corev1.PodLogOptions) (io.ReadCloser, error) {
		return io.NopCloser(bytes.NewReader(nil)), nil
	}), nil)
	service, err := NewGRPCService(manager, workloadResolverFunc(func(
		context.Context, string, []Identity, int,
	) (SourceResolution, error) {
		return SourceResolution{}, &TooManyResolvedPodsError{Limit: 128}
	}))
	if err != nil {
		t.Fatal(err)
	}
	response, err := service.ResolveLogSources(context.Background(), &kmgrv1.ResolveLogSourcesRequest{
		Context: &kmgrv1.RequestContext{RequestId: "resolve-1", ClusterSessionId: "session-1"},
		Resources: []*kmgrv1.ResourceIdentity{{
			ClusterSessionId: "session-1", Group: "apps", Version: "v1", Resource: "deployments",
			Namespace: "team", Name: "web", Uid: "deployment-uid",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if response.GetRequestId() != "resolve-1" || response.GetError().GetReason() != "TooManyResolvedPods" ||
		response.GetError().GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_RESOURCE_EXHAUSTED ||
		response.GetError().GetSafeDetails()["maximum_pods"] != "128" {
		t.Fatalf("resolution response = %#v", response)
	}
}

func TestCompletedStreamRPCStaysAliveUntilWindowCancellation(t *testing.T) {
	t.Parallel()
	manager := testManager(t, openerFunc(func(context.Context, Source, corev1.PodLogOptions) (io.ReadCloser, error) {
		return io.NopCloser(bytes.NewBufferString("ready\n")), nil
	}), nil)
	service, err := NewGRPCService(manager)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stream := newCapturedLogServerStream(ctx)
	done := make(chan error, 1)
	go func() {
		done <- service.StreamLogs(&kmgrv1.StartLogsRequest{
			Context:     &kmgrv1.RequestContext{RequestId: "logs-1", ClusterSessionId: "session-1"},
			LogStreamId: "logs", Generation: 1,
			Sources: []*kmgrv1.LogSource{{
				Identity: &kmgrv1.ResourceIdentity{
					ClusterSessionId: "session-1", Version: "v1", Resource: "pods",
					Namespace: "default", Name: "pod-a", Uid: "uid-a",
				},
				SourceId: "a", SourceLabel: "default/pod-a", Container: "main",
			}},
		}, stream)
	}()

	for {
		select {
		case event := <-stream.events:
			if event.GetStatus().GetSourceId() == "" &&
				isTerminal(stateFromProtoForTest(event.GetStatus().GetState())) {
				goto terminalReceived
			}
		case <-time.After(2 * time.Second):
			t.Fatal("timed out waiting for terminal event")
		}
	}

terminalReceived:
	select {
	case err := <-done:
		t.Fatalf("StreamLogs returned while its window was still open: %v", err)
	default:
	}
	if !manager.Cancel("session-1", "logs", 1) {
		t.Fatal("completed retained generation rejected window cancellation")
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("StreamLogs after window cancellation: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("StreamLogs did not end after window cancellation")
	}
}

func stateFromProtoForTest(value kmgrv1.LogStreamState) State {
	switch value {
	case kmgrv1.LogStreamState_LOG_STREAM_STATE_COMPLETED:
		return StateCompleted
	case kmgrv1.LogStreamState_LOG_STREAM_STATE_CANCELLED:
		return StateCancelled
	case kmgrv1.LogStreamState_LOG_STREAM_STATE_FAILED:
		return StateFailed
	default:
		return StateConnecting
	}
}

type capturedLogServerStream struct {
	ctx     context.Context
	events  chan *kmgrv1.LogEvent
	mu      sync.Mutex
	header  metadata.MD
	trailer metadata.MD
}

func newCapturedLogServerStream(ctx context.Context) *capturedLogServerStream {
	return &capturedLogServerStream{ctx: ctx, events: make(chan *kmgrv1.LogEvent, 32)}
}

func (s *capturedLogServerStream) Send(event *kmgrv1.LogEvent) error {
	s.events <- event
	return nil
}

func (s *capturedLogServerStream) SetHeader(value metadata.MD) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.header = metadata.Join(s.header, value)
	return nil
}

func (s *capturedLogServerStream) SendHeader(value metadata.MD) error {
	return s.SetHeader(value)
}

func (s *capturedLogServerStream) SetTrailer(value metadata.MD) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.trailer = metadata.Join(s.trailer, value)
}

func (s *capturedLogServerStream) Context() context.Context { return s.ctx }
func (s *capturedLogServerStream) SendMsg(any) error        { return nil }
func (s *capturedLogServerStream) RecvMsg(any) error        { return io.EOF }
