package transport

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

func TestSecretMutationAndStreamLoggingNeverFormatsSensitiveValues(t *testing.T) {
	t.Parallel()
	const secretValue = "super-secret-raw-value"
	const bearerToken = "super-secret-launch-token"
	request := &kmgrv1.UpdateDataRequest{
		Context: &kmgrv1.RequestContext{RequestId: "request", ClusterSessionId: "session"},
		Identity: &kmgrv1.ResourceIdentity{
			ClusterSessionId: "session", Version: "v1", Resource: "secrets",
			Namespace: "production", Name: "credentials", Uid: "secret-uid",
		},
		Mutations: []*kmgrv1.DataMutation{{
			Type: kmgrv1.DataMutationType_DATA_MUTATION_TYPE_SET,
			Key:  "token", Value: []byte(secretValue),
		}},
	}
	ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs(
		"authorization", "Bearer "+bearerToken,
	))

	var output bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&output, &slog.HandlerOptions{Level: slog.LevelDebug}))
	response, err := unaryLoggingInterceptor(logger)(
		ctx,
		request,
		&grpc.UnaryServerInfo{FullMethod: "/kmgr.v1.OperationService/UpdateData"},
		func(_ context.Context, value any) (any, error) {
			if value != request {
				t.Fatal("interceptor replaced the request")
			}
			return &kmgrv1.StartOperationResponse{Accepted: true}, status.Error(codes.Internal, secretValue)
		},
	)
	if response == nil || status.Code(err) != codes.Internal {
		t.Fatalf("interceptor response/error = %#v / %v", response, err)
	}
	logged := output.String()
	for _, sensitive := range []string{secretValue, bearerToken, "credentials", "production", "token"} {
		if strings.Contains(logged, sensitive) {
			t.Fatalf("unary RPC log exposed %q: %s", sensitive, logged)
		}
	}
	if !strings.Contains(logged, "/kmgr.v1.OperationService/UpdateData") ||
		!strings.Contains(logged, "Internal") {
		t.Fatalf("unary RPC log lost safe method/status fields: %s", logged)
	}

	output.Reset()
	stream := sensitiveServerStream{ctx: ctx}
	err = streamLoggingInterceptor(logger)(
		[]byte(secretValue),
		stream,
		&grpc.StreamServerInfo{FullMethod: "/kmgr.v1.ExecService/Exec", IsClientStream: true, IsServerStream: true},
		func(any, grpc.ServerStream) error { return status.Error(codes.Aborted, secretValue) },
	)
	if status.Code(err) != codes.Aborted {
		t.Fatalf("stream interceptor error = %v", err)
	}
	logged = output.String()
	for _, sensitive := range []string{secretValue, bearerToken} {
		if strings.Contains(logged, sensitive) {
			t.Fatalf("stream RPC log exposed %q: %s", sensitive, logged)
		}
	}
	if !strings.Contains(logged, "/kmgr.v1.ExecService/Exec") || !strings.Contains(logged, "Aborted") {
		t.Fatalf("stream RPC log lost safe method/status fields: %s", logged)
	}
}

type sensitiveServerStream struct {
	ctx context.Context
}

func (s sensitiveServerStream) SetHeader(metadata.MD) error  { return nil }
func (s sensitiveServerStream) SendHeader(metadata.MD) error { return nil }
func (s sensitiveServerStream) SetTrailer(metadata.MD)       {}
func (s sensitiveServerStream) Context() context.Context     { return s.ctx }
func (s sensitiveServerStream) SendMsg(any) error            { return nil }
func (s sensitiveServerStream) RecvMsg(any) error            { return nil }
