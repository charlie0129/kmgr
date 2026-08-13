package transport

import (
	"context"
	"net"
	"strings"
	"testing"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
)

func TestServerAuthenticatesEveryRPC(t *testing.T) {
	t.Parallel()
	token := strings.Repeat("a", 64)
	server, err := NewServer(token, ServerOptions{Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	listener := bufconn.Listen(1024 * 1024)
	serveResult := make(chan error, 1)
	go func() { serveResult <- server.Serve(listener) }()
	t.Cleanup(func() {
		server.Shutdown(time.Second)
		_ = listener.Close()
		<-serveResult
	})

	connection, err := grpc.NewClient(
		"passthrough:///bufconn",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) { return listener.Dial() }),
	)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	client := kmgrv1.NewEngineServiceClient(connection)
	request := &kmgrv1.HealthRequest{Context: requestContext("health")}

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := client.Health(ctx, request); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("missing token status = %v, error = %v", status.Code(err), err)
	}
	badContext := metadata.AppendToOutgoingContext(ctx, AuthorizationMetadataKey, "Bearer "+strings.Repeat("b", 64))
	if _, err := client.Health(badContext, request); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("wrong token status = %v, error = %v", status.Code(err), err)
	}
	goodContext := metadata.AppendToOutgoingContext(ctx, AuthorizationMetadataKey, "Bearer "+token)
	health, err := client.Health(goodContext, request)
	if err != nil {
		t.Fatal(err)
	}
	if health.GetState() != kmgrv1.HealthState_HEALTH_STATE_READY {
		t.Fatalf("health = %#v", health)
	}

	watch, err := client.WatchHealth(goodContext, &kmgrv1.WatchHealthRequest{
		Context: requestContext("watch-health"), StreamId: "health-stream",
	})
	if err != nil {
		t.Fatal(err)
	}
	ready, err := watch.Recv()
	if err != nil {
		t.Fatal(err)
	}
	if ready.GetState() != kmgrv1.HealthState_HEALTH_STATE_READY ||
		ready.GetCursor().GetGeneration() != 1 || ready.GetCursor().GetSequence() != 1 {
		t.Fatalf("initial health event = %#v", ready)
	}
	ack, err := client.Shutdown(goodContext, &kmgrv1.ShutdownRequest{Context: requestContext("shutdown")})
	if err != nil || !ack.GetAccepted() {
		t.Fatalf("shutdown = %#v, %v", ack, err)
	}
	stopping, err := watch.Recv()
	if err != nil {
		t.Fatal(err)
	}
	if stopping.GetState() != kmgrv1.HealthState_HEALTH_STATE_STOPPING || stopping.GetCursor().GetSequence() != 2 {
		t.Fatalf("stopping health event = %#v", stopping)
	}
}
