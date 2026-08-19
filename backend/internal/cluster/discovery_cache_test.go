package cluster

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestDiscoveryCacheIsSharedByBackendAndRefreshes(t *testing.T) {
	t.Parallel()
	var discoveryCycles atomic.Int64
	handler := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api":
			discoveryCycles.Add(1)
			writeDiscoveryJSON(t, writer, &metav1.APIVersions{Versions: []string{"v1"}})
		case "/apis":
			writeDiscoveryJSON(t, writer, &metav1.APIGroupList{Groups: []metav1.APIGroup{
				{
					Name:             "metrics.k8s.io",
					Versions:         []metav1.GroupVersionForDiscovery{{GroupVersion: "metrics.k8s.io/v1beta1", Version: "v1beta1"}},
					PreferredVersion: metav1.GroupVersionForDiscovery{GroupVersion: "metrics.k8s.io/v1beta1", Version: "v1beta1"},
				},
				{
					Name:             "broken.example.io",
					Versions:         []metav1.GroupVersionForDiscovery{{GroupVersion: "broken.example.io/v1", Version: "v1"}},
					PreferredVersion: metav1.GroupVersionForDiscovery{GroupVersion: "broken.example.io/v1", Version: "v1"},
				},
			}})
		case "/api/v1":
			writeDiscoveryJSON(t, writer, &metav1.APIResourceList{
				GroupVersion: "v1",
				APIResources: []metav1.APIResource{{
					Name: "pods", Kind: "Pod", Namespaced: true,
					Verbs: metav1.Verbs{"list", "watch"}, ShortNames: []string{"po"}, Categories: []string{"all"},
				}},
			})
		case "/apis/metrics.k8s.io/v1beta1":
			writeDiscoveryJSON(t, writer, &metav1.APIResourceList{
				GroupVersion: "metrics.k8s.io/v1beta1",
				APIResources: []metav1.APIResource{{
					Name: "pods", Kind: "PodMetrics", Namespaced: true, Verbs: metav1.Verbs{"list"},
				}},
			})
		case "/apis/broken.example.io/v1":
			http.Error(writer, "unavailable", http.StatusServiceUnavailable)
		default:
			http.NotFound(writer, request)
		}
	})

	first := discoveryTestSession(t, handler)
	sibling := &Session{backend: first.backend}
	if available, known := first.CachedMetricsAPIAvailability(); available || known {
		t.Fatalf("uncached metrics availability = (%t, %t), want (false, false)", available, known)
	}
	initial, err := first.DiscoverResourcesCached(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	if !initial.PotentiallyIncomplete || !initial.MetricsAPIAvailable {
		t.Fatalf("initial discovery = %#v", initial)
	}
	if available, known := sibling.CachedMetricsAPIAvailability(); !available || !known {
		t.Fatalf("cached metrics availability = (%t, %t), want (true, true)", available, known)
	}
	if cycles := discoveryCycles.Load(); cycles != 1 {
		t.Fatalf("discovery cycles after initial request = %d, want 1", cycles)
	}

	// Mutating one returned value must not corrupt the backend's cached copy.
	initial.Resources[0].Resource = "mutated"
	initial.Resources[0].Verbs[0] = "mutated"
	initial.Resources[0].ShortNames[0] = "mutated"
	initial.Resources[0].Categories[0] = "mutated"
	initial.Failures[0].Target = "mutated"

	cached, err := sibling.DiscoverResourcesCached(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	if cycles := discoveryCycles.Load(); cycles != 1 {
		t.Fatalf("same-backend cache caused %d discovery cycles, want 1", cycles)
	}
	if cached.Resources[0].Resource != "pods" || cached.Resources[0].Verbs[0] != "list" ||
		cached.Resources[0].ShortNames[0] != "po" || cached.Resources[0].Categories[0] != "all" ||
		cached.Failures[0].Target != "broken.example.io/v1" {
		t.Fatalf("caller mutation reached cached discovery: %#v", cached)
	}

	if _, err := sibling.DiscoverResourcesCached(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	if cycles := discoveryCycles.Load(); cycles != 2 {
		t.Fatalf("refresh discovery cycles = %d, want 2", cycles)
	}
	if _, err := first.DiscoverResourcesCached(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if cycles := discoveryCycles.Load(); cycles != 2 {
		t.Fatalf("post-refresh cached discovery cycles = %d, want 2", cycles)
	}

	independent := discoveryTestSession(t, handler)
	if _, err := independent.DiscoverResourcesCached(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if cycles := discoveryCycles.Load(); cycles != 3 {
		t.Fatalf("distinct backend discovery cycles = %d, want 3", cycles)
	}
}

func TestDiscoveryCacheCoalescesConcurrentMisses(t *testing.T) {
	t.Parallel()
	requestStarted := make(chan struct{})
	releaseRequest := make(chan struct{})
	var startOnce sync.Once
	var discoveryCycles atomic.Int64
	handler := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api":
			discoveryCycles.Add(1)
			startOnce.Do(func() { close(requestStarted) })
			select {
			case <-releaseRequest:
			case <-request.Context().Done():
				return
			}
			writeDiscoveryJSON(t, writer, &metav1.APIVersions{Versions: []string{"v1"}})
		case "/apis":
			writeDiscoveryJSON(t, writer, &metav1.APIGroupList{})
		case "/api/v1":
			writeDiscoveryJSON(t, writer, &metav1.APIResourceList{
				GroupVersion: "v1",
				APIResources: []metav1.APIResource{{
					Name: "pods", Kind: "Pod", Namespaced: true, Verbs: metav1.Verbs{"list"},
				}},
			})
		default:
			http.NotFound(writer, request)
		}
	})

	first := discoveryTestSession(t, handler)
	sibling := &Session{backend: first.backend}
	const callers = 8
	start := make(chan struct{})
	results := make(chan ResourceDiscovery, callers)
	resultErrors := make(chan error, callers)
	for index := range callers {
		session := first
		if index%2 != 0 {
			session = sibling
		}
		go func() {
			<-start
			result, err := session.DiscoverResourcesCached(context.Background(), false)
			results <- result
			resultErrors <- err
		}()
	}
	close(start)
	select {
	case <-requestStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("discovery request did not start")
	}
	close(releaseRequest)

	for range callers {
		if err := <-resultErrors; err != nil {
			t.Fatal(err)
		}
		result := <-results
		if len(result.Resources) != 1 || result.Resources[0].Resource != "pods" {
			t.Fatalf("discovery result = %#v", result)
		}
	}
	if cycles := discoveryCycles.Load(); cycles != 1 {
		t.Fatalf("concurrent cache misses caused %d discovery cycles, want 1", cycles)
	}
}

func TestDiscoveryCacheCoalescesConcurrentFailures(t *testing.T) {
	t.Parallel()
	backend := &sharedBackend{}
	releaseLoad := make(chan struct{})
	loadStarted := make(chan struct{})
	var startOnce sync.Once
	var loads atomic.Int64
	sentinel := errors.New("discovery unavailable")
	load := func(ctx context.Context) (ResourceDiscovery, error) {
		loads.Add(1)
		startOnce.Do(func() { close(loadStarted) })
		select {
		case <-releaseLoad:
			return ResourceDiscovery{}, sentinel
		case <-ctx.Done():
			return ResourceDiscovery{}, ctx.Err()
		}
	}

	const callers = 8
	start := make(chan struct{})
	var ready sync.WaitGroup
	ready.Add(callers)
	resultErrors := make(chan error, callers)
	for range callers {
		go func() {
			<-start
			ready.Done()
			_, err := backend.discovery.resolve(context.Background(), false, load)
			resultErrors <- err
		}()
	}
	close(start)
	ready.Wait()
	select {
	case <-loadStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("discovery load did not start")
	}
	// Ensure every caller has time to join the blocked leader before exposing
	// the shared failure.
	time.Sleep(25 * time.Millisecond)
	close(releaseLoad)

	for range callers {
		if err := <-resultErrors; !errors.Is(err, sentinel) {
			t.Fatalf("coalesced discovery error = %v, want %v", err, sentinel)
		}
	}
	if got := loads.Load(); got != 1 {
		t.Fatalf("one failing caller burst invoked %d discovery loads, want 1", got)
	}

	if _, err := backend.discovery.resolve(context.Background(), false, load); !errors.Is(err, sentinel) {
		t.Fatalf("later discovery retry error = %v, want %v", err, sentinel)
	}
	if got := loads.Load(); got != 2 {
		t.Fatalf("failed discovery was cached: loads = %d, want 2", got)
	}
}

func TestDiscoveryCacheCoalescesConcurrentRefreshes(t *testing.T) {
	t.Parallel()
	refreshStarted := make(chan struct{})
	releaseRefresh := make(chan struct{})
	var discoveryCycles atomic.Int64
	handler := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api":
			cycle := discoveryCycles.Add(1)
			if cycle == 2 {
				close(refreshStarted)
				select {
				case <-releaseRefresh:
				case <-request.Context().Done():
					return
				}
			}
			writeDiscoveryJSON(t, writer, &metav1.APIVersions{Versions: []string{"v1"}})
		case "/apis":
			writeDiscoveryJSON(t, writer, &metav1.APIGroupList{})
		case "/api/v1":
			writeDiscoveryJSON(t, writer, &metav1.APIResourceList{
				GroupVersion: "v1",
				APIResources: []metav1.APIResource{{
					Name: "pods", Kind: "Pod", Namespaced: true, Verbs: metav1.Verbs{"list"},
				}},
			})
		default:
			http.NotFound(writer, request)
		}
	})

	first := discoveryTestSession(t, handler)
	sibling := &Session{backend: first.backend}
	if _, err := first.DiscoverResourcesCached(context.Background(), false); err != nil {
		t.Fatal(err)
	}

	const callers = 8
	start := make(chan struct{})
	var ready sync.WaitGroup
	ready.Add(callers)
	results := make(chan ResourceDiscovery, callers)
	resultErrors := make(chan error, callers)
	for index := range callers {
		session := first
		if index%2 != 0 {
			session = sibling
		}
		go func() {
			<-start
			ready.Done()
			result, err := session.DiscoverResourcesCached(context.Background(), true)
			results <- result
			resultErrors <- err
		}()
	}
	close(start)
	ready.Wait()
	select {
	case <-refreshStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("refresh discovery request did not start")
	}
	// Keep the leader blocked briefly after every caller is runnable so all
	// concurrent refresh requests can observe and join the same in-flight load.
	time.Sleep(25 * time.Millisecond)
	close(releaseRefresh)

	for range callers {
		if err := <-resultErrors; err != nil {
			t.Fatal(err)
		}
		result := <-results
		if len(result.Resources) != 1 || result.Resources[0].Resource != "pods" {
			t.Fatalf("discovery result = %#v", result)
		}
	}
	if cycles := discoveryCycles.Load(); cycles != 2 {
		t.Fatalf("concurrent refreshes caused %d total discovery cycles, want initial load plus one refresh", cycles)
	}
}

func TestCachedMetricsAPIAvailabilityTreatsPartialResultsConservatively(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		result    ResourceDiscovery
		available bool
		known     bool
	}{
		{name: "complete absence", result: ResourceDiscovery{}, known: true},
		{
			name:   "unrelated partial failure",
			result: ResourceDiscovery{PotentiallyIncomplete: true, Failures: []DiscoveryFailure{{Target: "broken.example.io/v1"}}},
			known:  true,
		},
		{
			name:   "group catalog failed",
			result: ResourceDiscovery{PotentiallyIncomplete: true, Failures: []DiscoveryFailure{{Target: "/apis"}}},
		},
		{
			name:   "metrics version failed",
			result: ResourceDiscovery{PotentiallyIncomplete: true, Failures: []DiscoveryFailure{{Target: "metrics.k8s.io/v1beta1"}}},
		},
		{
			name:      "metrics observed with unrelated failure",
			result:    ResourceDiscovery{MetricsAPIAvailable: true, PotentiallyIncomplete: true, Failures: []DiscoveryFailure{{Target: "broken.example.io/v1"}}},
			available: true,
			known:     true,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			backend := &sharedBackend{}
			if _, err := backend.discovery.resolve(
				context.Background(), false,
				func(context.Context) (ResourceDiscovery, error) { return test.result, nil },
			); err != nil {
				t.Fatal(err)
			}
			session := &Session{backend: backend}
			available, known := session.CachedMetricsAPIAvailability()
			if available != test.available || known != test.known {
				t.Fatalf("CachedMetricsAPIAvailability() = (%t, %t), want (%t, %t)",
					available, known, test.available, test.known,
				)
			}
		})
	}
}

func TestDiscoveryCacheHonorsCanceledContextOnHit(t *testing.T) {
	t.Parallel()
	var discoveryCycles atomic.Int64
	session := discoveryTestSession(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api":
			discoveryCycles.Add(1)
			writeDiscoveryJSON(t, writer, &metav1.APIVersions{Versions: []string{"v1"}})
		case "/apis":
			writeDiscoveryJSON(t, writer, &metav1.APIGroupList{})
		case "/api/v1":
			writeDiscoveryJSON(t, writer, &metav1.APIResourceList{
				GroupVersion: "v1",
				APIResources: []metav1.APIResource{{Name: "pods", Kind: "Pod", Verbs: metav1.Verbs{"list"}}},
			})
		default:
			http.NotFound(writer, request)
		}
	}))
	if _, err := session.DiscoverResourcesCached(context.Background(), false); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := session.DiscoverResourcesCached(ctx, false); !errors.Is(err, context.Canceled) {
		t.Fatalf("cached discovery error = %v, want context.Canceled", err)
	}
	if cycles := discoveryCycles.Load(); cycles != 1 {
		t.Fatalf("canceled cache hit caused %d discovery cycles, want 1", cycles)
	}
}

func TestDiscoveryCacheWaiterCancellationDoesNotAbortSharedLoad(t *testing.T) {
	t.Parallel()
	backend := &sharedBackend{}
	loadStarted := make(chan struct{})
	releaseLoad := make(chan struct{})
	var startOnce sync.Once
	var loads atomic.Int64
	load := func(ctx context.Context) (ResourceDiscovery, error) {
		loads.Add(1)
		startOnce.Do(func() { close(loadStarted) })
		select {
		case <-releaseLoad:
			return ResourceDiscovery{Revision: "shared"}, nil
		case <-ctx.Done():
			return ResourceDiscovery{}, ctx.Err()
		}
	}

	leaderDone := make(chan error, 1)
	go func() {
		_, err := backend.discovery.resolve(context.Background(), false, load)
		leaderDone <- err
	}()
	select {
	case <-loadStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("discovery leader did not start")
	}

	waiterContext, cancelWaiter := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancelWaiter()
	if _, err := backend.discovery.resolve(waiterContext, false, load); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("canceled waiter error = %v, want context deadline exceeded", err)
	}
	if got := loads.Load(); got != 1 {
		t.Fatalf("canceled waiter started %d discovery loads, want 1 shared load", got)
	}
	select {
	case err := <-leaderDone:
		t.Fatalf("waiter cancellation ended the leader early: %v", err)
	default:
	}

	close(releaseLoad)
	if err := <-leaderDone; err != nil {
		t.Fatal(err)
	}
	result, err := backend.discovery.resolve(context.Background(), false, func(context.Context) (ResourceDiscovery, error) {
		t.Fatal("completed shared load was not cached")
		return ResourceDiscovery{}, nil
	})
	if err != nil || result.Revision != "shared" {
		t.Fatalf("cached discovery = %#v, error = %v", result, err)
	}
}

func TestDiscoveryCacheLiveWaiterRetriesCanceledLeader(t *testing.T) {
	t.Parallel()
	backend := &sharedBackend{}
	leaderStarted := make(chan struct{})
	var loads atomic.Int64
	load := func(ctx context.Context) (ResourceDiscovery, error) {
		if loads.Add(1) == 1 {
			close(leaderStarted)
			<-ctx.Done()
			return ResourceDiscovery{}, ctx.Err()
		}
		return ResourceDiscovery{Revision: "replacement"}, nil
	}

	leaderContext, cancelLeader := context.WithCancel(context.Background())
	leaderDone := make(chan error, 1)
	go func() {
		_, err := backend.discovery.resolve(leaderContext, false, load)
		leaderDone <- err
	}()
	select {
	case <-leaderStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("discovery leader did not start")
	}

	type discoveryResult struct {
		value ResourceDiscovery
		err   error
	}
	waiterDone := make(chan discoveryResult, 1)
	go func() {
		result, err := backend.discovery.resolve(context.Background(), false, load)
		waiterDone <- discoveryResult{value: result, err: err}
	}()
	time.Sleep(25 * time.Millisecond)
	cancelLeader()
	if err := <-leaderDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("leader error = %v, want context canceled", err)
	}
	select {
	case result := <-waiterDone:
		if result.err != nil || result.value.Revision != "replacement" {
			t.Fatalf("replacement discovery = %#v, error = %v", result.value, result.err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("live waiter did not replace the canceled discovery load")
	}
	if got := loads.Load(); got != 2 {
		t.Fatalf("discovery loads after leader cancellation = %d, want 2", got)
	}
}

func TestDiscoveryCacheRedactsFailureMessages(t *testing.T) {
	t.Parallel()
	const secret = "bearer-token-must-not-be-cached"
	backend := &sharedBackend{}
	if _, err := backend.discovery.resolve(context.Background(), false, func(context.Context) (ResourceDiscovery, error) {
		return ResourceDiscovery{
			PotentiallyIncomplete: true,
			Failures: []DiscoveryFailure{
				{Target: "/apis", Err: errors.New(secret)},
				{Target: "metrics.k8s.io/v1beta1", Err: apierrors.NewUnauthorized(secret)},
			},
		}, nil
	}); err != nil {
		t.Fatal(err)
	}
	cached, err := backend.discovery.resolve(context.Background(), false, func(context.Context) (ResourceDiscovery, error) {
		t.Fatal("cached discovery invoked its loader")
		return ResourceDiscovery{}, nil
	})
	if err != nil || len(cached.Failures) != 2 {
		t.Fatalf("cached discovery = %#v, error=%v", cached, err)
	}
	if strings.Contains(cached.Failures[0].Err.Error(), secret) {
		t.Fatalf("cached discovery retained a raw failure message: %v", cached.Failures[0].Err)
	}
	var apiStatus apierrors.APIStatus
	if !errors.As(cached.Failures[1].Err, &apiStatus) {
		t.Fatalf("cached status failure lost Kubernetes structure: %T", cached.Failures[1].Err)
	}
	status := apiStatus.Status()
	if status.Code != http.StatusUnauthorized || status.Reason != metav1.StatusReasonUnauthorized ||
		status.Message != "" || strings.Contains(cached.Failures[1].Err.Error(), secret) {
		t.Fatalf("cached status failure was not safely preserved: %#v", status)
	}
}
