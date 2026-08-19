package transport

import (
	"context"
	"errors"
	"math"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/object"
	"github.com/charlie0129/kmgr/backend/internal/operation"
	"github.com/charlie0129/kmgr/backend/internal/portforward"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/rest"
)

type serverRateLimitFactory struct {
	config *rest.Config
}

func (f *serverRateLimitFactory) New(config *rest.Config) (cluster.BackendClients, error) {
	f.config = rest.CopyConfig(config)
	return cluster.BackendClients{}, nil
}

func TestServerConfiguresKubernetesRateLimitBeforeSessionOpen(t *testing.T) {
	factory := &serverRateLimitFactory{}
	server, err := NewServer(strings.Repeat("a", 64), ServerOptions{
		Version: "test", ColumnsPath: t.TempDir() + "/columns.yaml",
		ClientFactory: factory, KubernetesQPS: 12.5, KubernetesBurst: 37,
	})
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	t.Cleanup(func() { server.Shutdown(time.Second) })
	catalog := serviceCatalog(t)
	session, err := server.sessions.Open(catalog, serviceContextID(t, catalog))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if factory.config == nil || factory.config.QPS != 12.5 || factory.config.Burst != 37 {
		t.Fatalf("factory rate limit = %#v", factory.config)
	}
	if factory.config.RateLimiter == nil || factory.config.RateLimiter.QPS() != 12.5 {
		t.Fatalf("factory shared limiter = %#v", factory.config.RateLimiter)
	}
	if session.RESTConfig().RateLimiter != factory.config.RateLimiter {
		t.Fatal("server session did not retain the configured authority limiter")
	}
}

func TestServerRejectsInvalidKubernetesRateLimit(t *testing.T) {
	for _, test := range []struct {
		name  string
		qps   float32
		burst int
	}{
		{name: "missing burst", qps: 1},
		{name: "missing QPS", burst: 1},
		{name: "negative QPS", qps: -1, burst: 1},
		{name: "NaN QPS", qps: float32(math.NaN()), burst: 1},
		{name: "infinite QPS", qps: float32(math.Inf(1)), burst: 1},
		{name: "negative burst", qps: 1, burst: -1},
	} {
		t.Run(test.name, func(t *testing.T) {
			server, err := NewServer(strings.Repeat("a", 64), ServerOptions{
				Version: "test", KubernetesQPS: test.qps, KubernetesBurst: test.burst,
			})
			if server != nil || err == nil {
				if server != nil {
					server.Shutdown(time.Second)
				}
				t.Fatalf("NewServer(%v/%d) = %#v, %v; want error", test.qps, test.burst, server, err)
			}
		})
	}
}

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
	oversizedWatch, err := client.WatchHealth(goodContext, &kmgrv1.WatchHealthRequest{
		Context: requestContext("oversized-health-stream"), StreamId: strings.Repeat("h", 257),
	})
	if err == nil {
		_, err = oversizedWatch.Recv()
	}
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("oversized stream ID status = %v, error = %v", status.Code(err), err)
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

	// Generations are process-wide and monotonic. Unique caller-controlled
	// stream IDs therefore do not accumulate in helper state.
	replacement, err := client.WatchHealth(goodContext, &kmgrv1.WatchHealthRequest{
		Context: requestContext("watch-health-replacement"), StreamId: "another-health-stream",
	})
	if err != nil {
		t.Fatal(err)
	}
	replacementState, err := replacement.Recv()
	if err != nil {
		t.Fatal(err)
	}
	if replacementState.GetState() != kmgrv1.HealthState_HEALTH_STATE_STOPPING ||
		replacementState.GetCursor().GetGeneration() != 2 ||
		replacementState.GetCursor().GetSequence() != 1 {
		t.Fatalf("replacement health event = %#v", replacementState)
	}
}

func TestServerShutdownDeadlineIncludesStubbornManagerDrains(t *testing.T) {
	server, err := NewServer(strings.Repeat("a", 64), ServerOptions{Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	server.forwards.Close()

	running := &shutdownTestRunningForward{
		release: make(chan struct{}), closeCalled: make(chan struct{}),
	}
	forwarder := &shutdownTestForwarder{running: running, started: make(chan struct{})}
	forwardManager, err := portforward.NewManager(portforward.Config{
		Sessions: shutdownTestSessionResolver{session: portforward.Session{
			ContextName: "context",
			Resolver:    shutdownTestTargetResolver{},
			Forwarder:   forwarder,
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	server.forwards = forwardManager

	operationStarted := make(chan struct{})
	operationCancelled := make(chan struct{})
	operationRelease := make(chan struct{})
	var releaseOnce sync.Once
	releaseWorkers := func() {
		releaseOnce.Do(func() {
			close(operationRelease)
			close(running.release)
		})
	}
	t.Cleanup(func() {
		releaseWorkers()
		server.operations.Close()
		forwardManager.Close()
	})
	tracked, err := server.operations.StartOne(
		context.Background(), "stubborn-operation", "delete",
		object.Identity{
			SessionID: "session", Version: "v1", Resource: "pods",
			Namespace: "default", Name: "pod", UID: "pod-uid",
		},
		func(ctx context.Context) (string, error) {
			close(operationStarted)
			<-ctx.Done()
			close(operationCancelled)
			<-operationRelease
			return "", context.Cause(ctx)
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := forwardManager.Start(portforward.StartRequest{
		ID: "stubborn-forward",
		Target: portforward.Identity{
			SessionID: "session", Version: "v1", Resource: "pods",
			Namespace: "default", Name: "pod", UID: types.UID("pod-uid"),
		},
		RemotePort: 8080,
	}); err != nil {
		t.Fatal(err)
	}
	<-operationStarted
	<-forwarder.started

	const shutdownTimeout = 30 * time.Millisecond
	begin := time.Now()
	shutdownReturned := make(chan time.Duration, 1)
	go func() {
		server.Shutdown(shutdownTimeout)
		shutdownReturned <- time.Since(begin)
	}()
	var elapsed time.Duration
	select {
	case elapsed = <-shutdownReturned:
	case <-time.After(500 * time.Millisecond):
		releaseWorkers()
		<-shutdownReturned
		t.Fatal("Shutdown did not return within a bounded interval")
	}
	if elapsed > 500*time.Millisecond {
		t.Fatalf("Shutdown elapsed = %v, want the %v global deadline to bound manager drains", elapsed, shutdownTimeout)
	}
	select {
	case <-operationCancelled:
	case <-time.After(time.Second):
		t.Fatal("Shutdown did not cancel the stubborn operation")
	}
	select {
	case <-running.closeCalled:
	case <-time.After(time.Second):
		t.Fatal("Shutdown did not close the stubborn running forward")
	}
	select {
	case <-tracked.Done():
		t.Fatal("stubborn operation finished before its worker was released")
	default:
	}
	select {
	case <-server.Done():
	default:
		t.Fatal("Shutdown did not publish the engine stopping state")
	}
	if _, err := server.operations.StartOne(
		context.Background(), "late-operation", "delete",
		object.Identity{
			SessionID: "session", Version: "v1", Resource: "pods",
			Namespace: "default", Name: "pod", UID: "pod-uid",
		},
		func(context.Context) (string, error) { return "", nil },
	); !errors.Is(err, operation.ErrManagerClosed) {
		t.Fatalf("operation start after timed-out shutdown error = %v", err)
	}

	releaseWorkers()
	server.operations.Close()
	forwardManager.Close()
}

type shutdownTestSessionResolver struct {
	session portforward.Session
}

func (r shutdownTestSessionResolver) ResolveSession(string) (portforward.Session, error) {
	return r.session, nil
}

type shutdownTestTargetResolver struct{}

func (shutdownTestTargetResolver) Resolve(
	_ context.Context,
	target portforward.Identity,
	remotePort uint16,
) (portforward.ResolvedTarget, error) {
	return portforward.ResolvedTarget{Pod: target, RemotePort: remotePort}, nil
}

type shutdownTestForwarder struct {
	running *shutdownTestRunningForward
	started chan struct{}
	once    sync.Once
}

func (f *shutdownTestForwarder) Start(
	context.Context,
	portforward.ForwardRequest,
) (portforward.RunningForward, error) {
	f.once.Do(func() { close(f.started) })
	return f.running, nil
}

type shutdownTestRunningForward struct {
	release     chan struct{}
	closeCalled chan struct{}
	closeOnce   sync.Once
}

func (*shutdownTestRunningForward) LocalPort() uint16 { return 12345 }
func (f *shutdownTestRunningForward) Wait() error {
	<-f.release
	return nil
}
func (f *shutdownTestRunningForward) Close() error {
	f.closeOnce.Do(func() { close(f.closeCalled) })
	return nil
}
