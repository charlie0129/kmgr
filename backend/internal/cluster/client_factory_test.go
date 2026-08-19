package cluster

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/rest"
)

type countingRateLimiter struct {
	waits atomic.Int32
}

func (*countingRateLimiter) TryAccept() bool { return true }
func (*countingRateLimiter) Stop()           {}
func (*countingRateLimiter) QPS() float32    { return 12.5 }

func (l *countingRateLimiter) Accept() {
	l.waits.Add(1)
}

func (l *countingRateLimiter) Wait(context.Context) error {
	l.waits.Add(1)
	return nil
}

func TestDefaultClientFactorySharesConfiguredRateLimiterAcrossClients(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		switch request.URL.Path {
		case "/apis/metrics.k8s.io/v1beta1/pods":
			_, _ = writer.Write([]byte(`{"apiVersion":"metrics.k8s.io/v1beta1","kind":"PodMetricsList","items":[]}`))
		case "/version":
			_, _ = writer.Write([]byte(`{}`))
		default:
			_, _ = writer.Write([]byte(`{"apiVersion":"v1","kind":"PodList","items":[]}`))
		}
	}))
	t.Cleanup(server.Close)

	limiter := &countingRateLimiter{}
	clients, err := (DefaultClientFactory{}).New(&rest.Config{
		Host: server.URL, QPS: 12.5, Burst: 37, RateLimiter: limiter,
	})
	if err != nil {
		t.Fatalf("construct backend clients: %v", err)
	}
	t.Cleanup(clients.Close)
	if clients.Discovery.RESTClient().GetRateLimiter() != limiter ||
		clients.Core.RESTClient().GetRateLimiter() != limiter ||
		clients.Metrics.RESTClient().GetRateLimiter() != limiter {
		t.Fatal("an inspectable REST client replaced the configured limiter")
	}

	ctx := context.Background()
	pods := schema.GroupVersionResource{Version: "v1", Resource: "pods"}
	_, _ = clients.Dynamic.Resource(pods).List(ctx, metav1.ListOptions{})
	_, _ = clients.Metadata.Resource(pods).List(ctx, metav1.ListOptions{})
	_, _ = clients.Core.Pods("").List(ctx, metav1.ListOptions{})
	_, _ = clients.Metrics.PodMetricses("").List(ctx, metav1.ListOptions{})
	_, _ = clients.Discovery.RESTClient().Get().AbsPath("/version").DoRaw(ctx)
	if got := limiter.waits.Load(); got != 5 {
		t.Fatalf("shared limiter waits = %d, want one for each of five clients", got)
	}
}
