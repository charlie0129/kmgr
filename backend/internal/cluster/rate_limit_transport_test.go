package cluster

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"sync/atomic"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	apihttpstream "k8s.io/apimachinery/pkg/util/httpstream"
	"k8s.io/client-go/rest"
	clientportforward "k8s.io/client-go/tools/portforward"
	"k8s.io/client-go/tools/remotecommand"
	clientgospdy "k8s.io/client-go/transport/spdy"
	streamhttp "k8s.io/streaming/pkg/httpstream"
)

func TestSupplementalRateLimitClassifiesOnlyWatchAndUpgradeRequests(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		url  string
		want int32
	}{
		{name: "ordinary list", url: "https://cluster.test/api/v1/pods", want: 0},
		{name: "ordinary request with watch false", url: "https://cluster.test/api/v1/pods?watch=false", want: 0},
		{name: "unrelated query", url: "https://cluster.test/api/v1/pods?notwatch=true", want: 0},
		{name: "watch", url: "https://cluster.test/api/v1/pods?watch=true", want: 1},
		{name: "WatchList", url: "https://cluster.test/api/v1/pods?watch=true&sendInitialEvents=true", want: 1},
		{name: "exec upgrade", url: "https://cluster.test/api/v1/namespaces/ns/pods/pod/exec", want: 1},
		{name: "port-forward upgrade", url: "https://cluster.test/api/v1/namespaces/ns/pods/pod/portforward", want: 1},
		{name: "trailing slash", url: "https://cluster.test/api/v1/namespaces/ns/pods/pod/exec/", want: 1},
		{name: "different final segment", url: "https://cluster.test/api/v1/namespaces/ns/pods/pod/executions", want: 0},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			limiter := &countingRateLimiter{}
			var calls atomic.Int32
			transport := &supplementalRateLimitRoundTripper{
				limiter: limiter,
				base: roundTripFunc(func(request *http.Request) (*http.Response, error) {
					calls.Add(1)
					return &http.Response{
						StatusCode: http.StatusOK, Body: http.NoBody, Request: request,
					}, nil
				}),
			}
			request, err := http.NewRequest(http.MethodGet, test.url, nil)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := transport.RoundTrip(request); err != nil {
				t.Fatal(err)
			}
			if got := limiter.waits.Load(); got != test.want {
				t.Fatalf("limiter waits = %d, want %d", got, test.want)
			}
			if got := calls.Load(); got != 1 {
				t.Fatalf("base transport calls = %d, want 1", got)
			}
		})
	}
}

func TestSupplementalRateLimitStopsCanceledRequestBeforeTransport(t *testing.T) {
	t.Parallel()
	limiter := &contextRateLimiter{wait: func(ctx context.Context) error {
		<-ctx.Done()
		return ctx.Err()
	}}
	var calls atomic.Int32
	transport := &supplementalRateLimitRoundTripper{
		limiter: limiter,
		base: roundTripFunc(func(request *http.Request) (*http.Response, error) {
			calls.Add(1)
			return nil, errors.New("base transport must not run")
		}),
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	request, err := http.NewRequestWithContext(
		ctx, http.MethodGet, "https://cluster.test/api/v1/pods?watch=true", nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := transport.RoundTrip(request); !errors.Is(err, context.Canceled) {
		t.Fatalf("RoundTrip error = %v, want context cancellation", err)
	}
	if got := limiter.waits.Load(); got != 1 {
		t.Fatalf("limiter waits = %d, want 1", got)
	}
	if got := calls.Load(); got != 0 {
		t.Fatalf("base transport calls = %d, want 0", got)
	}
}

func TestDefaultClientFactoryLimitsListWatchAndWatchListExactlyOnce(t *testing.T) {
	t.Parallel()
	requests := make(chan url.Values, 3)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		query := request.URL.Query()
		requests <- query
		writer.Header().Set("Content-Type", "application/json")
		if query.Get("watch") == "true" {
			writer.WriteHeader(http.StatusOK)
			return
		}
		_, _ = io.WriteString(writer, `{"apiVersion":"v1","kind":"PodList","items":[]}`)
	}))
	t.Cleanup(server.Close)

	limiter := &countingRateLimiter{}
	config := configWithSupplementalRateLimit(&rest.Config{
		Host: server.URL, QPS: 12.5, Burst: 37, RateLimiter: limiter,
	})
	clients, err := (DefaultClientFactory{}).New(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(clients.Close)
	pods := schema.GroupVersionResource{Version: "v1", Resource: "pods"}
	if _, err := clients.Dynamic.Resource(pods).List(context.Background(), metav1.ListOptions{}); err != nil {
		t.Fatalf("LIST: %v", err)
	}
	if got := limiter.waits.Load(); got != 1 {
		t.Fatalf("LIST limiter waits = %d, want one client-go wait and no supplemental wait", got)
	}

	ordinaryWatch, err := clients.Dynamic.Resource(pods).Watch(context.Background(), metav1.ListOptions{})
	if err != nil {
		t.Fatalf("WATCH: %v", err)
	}
	ordinaryWatch.Stop()
	if got := limiter.waits.Load(); got != 2 {
		t.Fatalf("WATCH limiter waits = %d, want one supplemental wait", got)
	}

	watchList, err := clients.Dynamic.Resource(pods).Watch(context.Background(), metav1.ListOptions{
		AllowWatchBookmarks:  true,
		ResourceVersionMatch: metav1.ResourceVersionMatchNotOlderThan,
		SendInitialEvents:    boolPointer(true),
	})
	if err != nil {
		t.Fatalf("WatchList: %v", err)
	}
	watchList.Stop()
	if got := limiter.waits.Load(); got != 3 {
		t.Fatalf("WatchList limiter waits = %d, want one supplemental wait", got)
	}

	for index, want := range []struct {
		watch       string
		initial     string
		description string
	}{
		{description: "LIST"},
		{watch: "true", description: "WATCH"},
		{watch: "true", initial: "true", description: "WatchList"},
	} {
		select {
		case got := <-requests:
			if got.Get("watch") != want.watch || got.Get("sendInitialEvents") != want.initial {
				t.Fatalf("request %d (%s) options = %#v", index, want.description, got)
			}
		default:
			t.Fatalf("request %d (%s) was not observed", index, want.description)
		}
	}
}

func TestSupplementalRateLimitSurvivesExecWebSocketToSPDYFallback(t *testing.T) {
	t.Parallel()
	methods := make(chan string, 2)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		methods <- request.Method
		http.Error(writer, "upgrade unavailable", http.StatusBadRequest)
	}))
	t.Cleanup(server.Close)

	limiter := &countingRateLimiter{}
	config := configWithSupplementalRateLimit(&rest.Config{
		Host: server.URL, QPS: 12.5, Burst: 37, RateLimiter: limiter,
	})
	requestURL, err := url.Parse(server.URL + "/api/v1/namespaces/ns/pods/pod/exec")
	if err != nil {
		t.Fatal(err)
	}
	webSocketExecutor, err := remotecommand.NewWebSocketExecutor(
		config, http.MethodGet, requestURL.String(),
	)
	if err != nil {
		t.Fatalf("construct WebSocket executor: %v", err)
	}
	spdyTransport, spdyUpgrader, err := clientgospdy.RoundTripperFor(config)
	if err != nil {
		t.Fatalf("construct SPDY transport: %v", err)
	}
	spdyExecutor, err := remotecommand.NewSPDYExecutorForTransports(
		spdyTransport, spdyUpgrader, http.MethodPost, requestURL,
	)
	if err != nil {
		t.Fatalf("construct SPDY executor: %v", err)
	}
	executor, err := remotecommand.NewFallbackExecutor(
		webSocketExecutor, spdyExecutor,
		func(err error) bool {
			return streamhttp.IsUpgradeFailure(err) || streamhttp.IsHTTPSProxyError(err)
		},
	)
	if err != nil {
		t.Fatalf("construct fallback executor: %v", err)
	}
	if err := executor.StreamWithContext(context.Background(), remotecommand.StreamOptions{}); err == nil {
		t.Fatal("rejected WebSocket and SPDY upgrades unexpectedly succeeded")
	}
	if got := limiter.waits.Load(); got != 2 {
		t.Fatalf("exec fallback limiter waits = %d, want one per upgrade attempt", got)
	}
	assertObservedMethods(t, methods, http.MethodGet, http.MethodPost)
}

func TestSupplementalRateLimitSurvivesPortForwardWebSocketToSPDYFallback(t *testing.T) {
	t.Parallel()
	methods := make(chan string, 2)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		methods <- request.Method
		http.Error(writer, "upgrade unavailable", http.StatusBadRequest)
	}))
	t.Cleanup(server.Close)

	limiter := &countingRateLimiter{}
	config := configWithSupplementalRateLimit(&rest.Config{
		Host: server.URL, QPS: 12.5, Burst: 37, RateLimiter: limiter,
	})
	requestURL, err := url.Parse(server.URL + "/api/v1/namespaces/ns/pods/pod/portforward")
	if err != nil {
		t.Fatal(err)
	}
	tunnelDialer, err := clientportforward.NewSPDYOverWebsocketDialer(requestURL, config)
	if err != nil {
		t.Fatalf("construct port-forward WebSocket dialer: %v", err)
	}
	spdyTransport, spdyUpgrader, err := clientgospdy.RoundTripperFor(config)
	if err != nil {
		t.Fatalf("construct port-forward SPDY transport: %v", err)
	}
	spdyDialer := clientgospdy.NewDialer(
		spdyUpgrader, &http.Client{Transport: spdyTransport}, http.MethodPost, requestURL,
	)
	dialer := clientportforward.NewFallbackDialer(
		tunnelDialer, spdyDialer,
		func(err error) bool {
			return apihttpstream.IsUpgradeFailure(err) || apihttpstream.IsHTTPSProxyError(err) ||
				streamhttp.IsUpgradeFailure(err) || streamhttp.IsHTTPSProxyError(err)
		},
	)
	if _, _, err := dialer.Dial("portforward.k8s.io"); err == nil {
		t.Fatal("rejected WebSocket and SPDY port-forward upgrades unexpectedly succeeded")
	}
	if got := limiter.waits.Load(); got != 2 {
		t.Fatalf("port-forward fallback limiter waits = %d, want one per upgrade attempt", got)
	}
	assertObservedMethods(t, methods, http.MethodGet, http.MethodPost)
}

func assertObservedMethods(t *testing.T, methods <-chan string, want ...string) {
	t.Helper()
	got := make([]string, 0, len(want))
	for range want {
		select {
		case method := <-methods:
			got = append(got, method)
		default:
			t.Fatalf("observed methods = %v, want %v", got, want)
		}
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("observed methods = %v, want %v", got, want)
	}
}

func boolPointer(value bool) *bool { return &value }

type contextRateLimiter struct {
	waits atomic.Int32
	wait  func(context.Context) error
}

func (*contextRateLimiter) TryAccept() bool { return true }
func (*contextRateLimiter) Stop()           {}
func (*contextRateLimiter) QPS() float32    { return 1 }
func (l *contextRateLimiter) Accept()       { l.waits.Add(1) }
func (l *contextRateLimiter) Wait(ctx context.Context) error {
	l.waits.Add(1)
	return l.wait(ctx)
}
