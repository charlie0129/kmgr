package execstream

import (
	"errors"
	"strings"
	"testing"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc/codes"
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
		request.Generation != 7 || request.Pod.UID != "pod-uid" || request.Container != "main" ||
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
		"terminal", 9, 42, "local", testStart(9).Pod,
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
		Delivery{Status: &Status{State: StateExited, ExitCode: &exitCode, StatusReason: "NonZeroExit"}},
		"terminal", 9, 43, "local", testStart(9).Pod,
	)
	converted := statusMessage.GetStatus()
	if converted.GetState() != kmgrv1.ExecConnectionState_EXEC_CONNECTION_STATE_EXITED ||
		converted.ExitCode == nil || converted.GetExitCode() != 23 || converted.GetStatusReason() != "NonZeroExit" {
		t.Fatalf("converted status = %#v", converted)
	}
}

func TestExecErrorsNeverExposeUnderlyingTransportText(t *testing.T) {
	t.Parallel()
	const secret = "do-not-expose-terminal-or-token-data"
	pod := testStart(1).Pod
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
