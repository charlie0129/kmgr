package cluster

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"

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
			backend.discovery.store(0, test.result, false)
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

func TestDiscoveryCacheRedactsFailureMessages(t *testing.T) {
	t.Parallel()
	const secret = "bearer-token-must-not-be-cached"
	backend := &sharedBackend{}
	backend.discovery.store(0, ResourceDiscovery{
		PotentiallyIncomplete: true,
		Failures: []DiscoveryFailure{
			{Target: "/apis", Err: errors.New(secret)},
			{Target: "metrics.k8s.io/v1beta1", Err: apierrors.NewUnauthorized(secret)},
		},
	}, false)
	cached, ok, _ := backend.discovery.begin(false)
	if !ok || len(cached.Failures) != 2 {
		t.Fatalf("cached discovery = %#v, present=%t", cached, ok)
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
