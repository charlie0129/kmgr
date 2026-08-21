package execstream

import (
	"context"
	"errors"
	"io"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protojson"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func TestExecProtoStartAndMonotonicEnvelope(t *testing.T) {
	t.Parallel()
	message := testProtoStart(7, 11)
	request, err := startFromProto(message)
	if err != nil {
		t.Fatalf("startFromProto: %v", err)
	}
	if request.SessionID != "cluster-session" || request.ExecSessionID != "terminal" ||
		request.Generation != 7 || request.Pod == nil || request.Pod.Pod.UID != "pod-uid" ||
		request.Pod.Container != "main" ||
		len(request.Command) != 1 || request.Command[0] != "/bin/sh" || !request.TTY || !request.Stdin ||
		request.InitialSize == nil || request.InitialSize.Columns != 80 || request.InitialSize.Rows != 24 {
		t.Fatalf("converted request = %#v", request)
	}

	lastSequence := message.GetSequence()
	next := &kmgrv1.ExecClientMessage{
		ExecSessionId: "terminal", Generation: 7, Sequence: 12,
		Payload: &kmgrv1.ExecClientMessage_Stdin{Stdin: []byte("hello")},
	}
	if err := validateClientEnvelope(next, request, &lastSequence); err != nil || lastSequence != 12 {
		t.Fatalf("valid envelope = sequence %d, error %v", lastSequence, err)
	}
	if err := validateClientEnvelope(next, request, &lastSequence); !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("duplicate sequence error = %v", err)
	}
	next.Sequence = 13
	next.Generation = 8
	if err := validateClientEnvelope(next, request, &lastSequence); !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("wrong generation error = %v", err)
	}
}

func TestDeliveryToProtoUsesCursorAndCopiesOutput(t *testing.T) {
	t.Parallel()
	data := []byte("terminal bytes")
	message := deliveryToProto(
		Delivery{Output: &Output{Kind: StreamStderr, Data: data}},
		"terminal", 9, 42, "local", testStart(9).targetIdentity(),
	)
	data[0] = 'X'
	if cursor := message.GetCursor(); cursor.GetStreamId() != "terminal" || cursor.GetGeneration() != 9 || cursor.GetSequence() != 42 {
		t.Fatalf("cursor = %#v", cursor)
	}
	if got := string(message.GetStderr()); got != "terminal bytes" || message.GetStdout() != nil {
		t.Fatalf("converted output = stderr %q stdout %q", got, message.GetStdout())
	}

	exitCode := int32(23)
	statusMessage := deliveryToProto(
		Delivery{Status: &Status{
			State: StateExited, ExitCode: &exitCode, StatusReason: "NonZeroExit",
			DroppedOutputItems: 7, DroppedOutputBytes: 8192,
		}},
		"terminal", 9, 43, "local", testStart(9).targetIdentity(),
	)
	converted := statusMessage.GetStatus()
	if converted.GetState() != kmgrv1.ExecConnectionState_EXEC_CONNECTION_STATE_EXITED ||
		converted.ExitCode == nil || converted.GetExitCode() != 23 ||
		converted.GetStatusReason() != "NonZeroExit" ||
		converted.GetDroppedOutputItems() != 7 || converted.GetDroppedOutputBytes() != 8192 {
		t.Fatalf("converted status = %#v", converted)
	}
}

func TestExecErrorsNeverExposeUnderlyingTransportText(t *testing.T) {
	t.Parallel()
	const secret = "do-not-expose-terminal-or-token-data"
	pod := testStart(1).targetIdentity()
	for _, underlying := range []error{
		errors.New(secret),
		apierrors.NewForbidden(schema.GroupResource{Resource: "pods"}, "api-0", errors.New(secret)),
	} {
		converted := structuredExecError(underlying, "local", pod)
		encoded, err := protojson.Marshal(converted)
		if err != nil {
			t.Fatalf("marshal structured error: %v", err)
		}
		if strings.Contains(string(encoded), secret) {
			t.Fatalf("structured error exposed underlying text: %s", encoded)
		}
	}
	convertedStatus := execStatusError(errors.New(secret))
	if status.Code(convertedStatus) != codes.Internal || strings.Contains(convertedStatus.Error(), secret) {
		t.Fatalf("gRPC error exposed underlying text: %v", convertedStatus)
	}
}

func TestCompletedExecRPCStaysAliveForReplacementUntilWindowCancellation(t *testing.T) {
	t.Parallel()
	var releases atomic.Int32
	manager, err := NewManager(Config{Resolver: ResolverFunc(func(string) (ResolvedSession, error) {
		return ResolvedSession{
			ContextName: "local",
			Runner: runnerFunc(func(_ context.Context, _ StartRequest, options RunOptions) error {
				if options.Started != nil {
					options.Started()
				}
				return nil
			}),
			Release: func() { releases.Add(1) },
		}, nil
	})})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(manager.Close)
	service, err := NewGRPCService(manager)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	stream := newCapturedExecServerStream(ctx)
	stream.incoming <- testProtoStart(1, 1)
	done := make(chan error, 1)
	go func() { done <- service.Exec(stream) }()

	for {
		select {
		case event := <-stream.outgoing:
			if event.GetStatus().GetState() == kmgrv1.ExecConnectionState_EXEC_CONNECTION_STATE_EXITED {
				goto terminalReceived
			}
		case <-time.After(2 * time.Second):
			t.Fatal("timed out waiting for terminal exec status")
		}
	}

terminalReceived:
	select {
	case err := <-done:
		t.Fatalf("Exec returned while its terminal window remained open: %v", err)
	default:
	}
	if releases.Load() != 0 {
		t.Fatalf("completed process released retained terminal authority: %d", releases.Load())
	}
	cancel()
	select {
	case err := <-done:
		if status.Code(err) != codes.Canceled {
			t.Fatalf("Exec after window cancellation = %v, want cancelled", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Exec did not end after window cancellation")
	}
	waitFor(t, func() bool { return releases.Load() == 1 }, "retained RPC authority release")
}

func TestAcceptedReplacementRetiresCompletedPriorRPCAndSharesAuthority(t *testing.T) {
	t.Parallel()
	var resolves atomic.Int32
	var releases atomic.Int32
	manager, err := NewManager(Config{Resolver: ResolverFunc(func(string) (ResolvedSession, error) {
		resolves.Add(1)
		return ResolvedSession{
			ContextName: "local",
			Runner: runnerFunc(func(_ context.Context, _ StartRequest, options RunOptions) error {
				if options.Started != nil {
					options.Started()
				}
				return nil
			}),
			Release: func() { releases.Add(1) },
		}, nil
	})})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(manager.Close)
	service, err := NewGRPCService(manager)
	if err != nil {
		t.Fatal(err)
	}

	firstContext, cancelFirst := context.WithCancel(context.Background())
	defer cancelFirst()
	first := newCapturedExecServerStream(firstContext)
	first.incoming <- testProtoStart(1, 1)
	firstDone := make(chan error, 1)
	go func() { firstDone <- service.Exec(first) }()
	waitForExecState(t, first, kmgrv1.ExecConnectionState_EXEC_CONNECTION_STATE_EXITED)
	select {
	case err := <-firstDone:
		t.Fatalf("first RPC returned before replacement: %v", err)
	default:
	}

	secondContext, cancelSecond := context.WithCancel(context.Background())
	defer cancelSecond()
	second := newCapturedExecServerStream(secondContext)
	second.incoming <- testProtoStart(2, 1)
	secondDone := make(chan error, 1)
	go func() { secondDone <- service.Exec(second) }()
	select {
	case err := <-firstDone:
		if err != nil {
			t.Fatalf("prior RPC retirement: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("accepted replacement did not retire completed prior RPC")
	}
	if firstContext.Err() != nil {
		t.Fatalf("test cancelled the prior transport instead of backend replacement: %v", firstContext.Err())
	}
	if resolves.Load() != 1 || releases.Load() != 0 {
		t.Fatalf("replacement resolve/release counts = %d/%d, want 1/0", resolves.Load(), releases.Load())
	}
	cancelFirst()

	waitForExecState(t, second, kmgrv1.ExecConnectionState_EXEC_CONNECTION_STATE_EXITED)
	cancelSecond()
	select {
	case err := <-secondDone:
		if status.Code(err) != codes.Canceled {
			t.Fatalf("replacement RPC cancellation = %v, want cancelled", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("replacement RPC did not end after window cancellation")
	}
	waitFor(t, func() bool { return releases.Load() == 1 }, "shared replacement authority release")
}

func TestExecRPCPreservesApplicationDeadlineStatus(t *testing.T) {
	t.Parallel()
	manager, err := NewManager(Config{Resolver: ResolverFunc(func(string) (ResolvedSession, error) {
		return ResolvedSession{
			ContextName: "local",
			Runner: runnerFunc(func(ctx context.Context, _ StartRequest, options RunOptions) error {
				if options.Started != nil {
					options.Started()
				}
				<-ctx.Done()
				return ctx.Err()
			}),
		}, nil
	})})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(manager.Close)
	service, err := NewGRPCService(manager)
	if err != nil {
		t.Fatal(err)
	}
	streamContext, cancelStream := context.WithCancel(context.Background())
	defer cancelStream()
	stream := newCapturedExecServerStream(streamContext)
	start := testProtoStart(1, 1)
	start.GetStart().GetContext().DeadlineUnixMs = time.Now().Add(100 * time.Millisecond).UnixMilli()
	stream.incoming <- start
	done := make(chan error, 1)
	go func() { done <- service.Exec(stream) }()
	select {
	case err := <-done:
		if status.Code(err) != codes.DeadlineExceeded {
			t.Fatalf("deadline status = %v, want deadline exceeded", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Exec did not stop at its application deadline")
	}
	cancelStream()
}

func waitForExecState(
	t *testing.T,
	stream *capturedExecServerStream,
	state kmgrv1.ExecConnectionState,
) {
	t.Helper()
	for {
		select {
		case event := <-stream.outgoing:
			if event.GetStatus().GetState() == state {
				return
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("timed out waiting for exec state %s", state)
		}
	}
}

type capturedExecServerStream struct {
	ctx      context.Context
	incoming chan *kmgrv1.ExecClientMessage
	outgoing chan *kmgrv1.ExecServerMessage
}

func newCapturedExecServerStream(ctx context.Context) *capturedExecServerStream {
	return &capturedExecServerStream{
		ctx: ctx, incoming: make(chan *kmgrv1.ExecClientMessage, 8),
		outgoing: make(chan *kmgrv1.ExecServerMessage, 16),
	}
}

func (s *capturedExecServerStream) Recv() (*kmgrv1.ExecClientMessage, error) {
	select {
	case value := <-s.incoming:
		return value, nil
	case <-s.ctx.Done():
		return nil, s.ctx.Err()
	}
}

func (s *capturedExecServerStream) Send(value *kmgrv1.ExecServerMessage) error {
	select {
	case s.outgoing <- value:
		return nil
	case <-s.ctx.Done():
		return s.ctx.Err()
	}
}

func (s *capturedExecServerStream) SetHeader(metadata.MD) error  { return nil }
func (s *capturedExecServerStream) SendHeader(metadata.MD) error { return nil }
func (s *capturedExecServerStream) SetTrailer(metadata.MD)       {}
func (s *capturedExecServerStream) Context() context.Context     { return s.ctx }
func (s *capturedExecServerStream) SendMsg(any) error            { return nil }
func (s *capturedExecServerStream) RecvMsg(any) error            { return io.EOF }

func testProtoStart(generation, sequence uint64) *kmgrv1.ExecClientMessage {
	return &kmgrv1.ExecClientMessage{
		ExecSessionId: "terminal", Generation: generation, Sequence: sequence,
		Payload: &kmgrv1.ExecClientMessage_Start{Start: &kmgrv1.ExecStart{
			Context:       &kmgrv1.RequestContext{RequestId: "request", ClusterSessionId: "cluster-session"},
			ExecSessionId: "terminal", Generation: generation,
			Pod: &kmgrv1.ResourceIdentity{
				ClusterSessionId: "cluster-session", Version: "v1", Resource: "pods",
				Namespace: "default", Name: "api-0", Uid: "pod-uid",
			},
			Container: "main", Command: []string{"/bin/sh"}, Tty: true, Stdin: true,
			InitialColumns: 80, InitialRows: 24,
		}},
	}
}
