package metrics

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/rest"
	metricsapi "k8s.io/metrics/pkg/apis/metrics/v1beta1"
	metricsclient "k8s.io/metrics/pkg/client/clientset/versioned/typed/metrics/v1beta1"
)

func TestPodSampleCacheExactGETRefreshAndStableClones(t *testing.T) {
	t.Parallel()
	clock := newPodCacheClock(time.Unix(1_000, 0))
	var calls atomic.Int32
	var requestsMu sync.Mutex
	var requests []string
	client := &podCacheTestClient{get: func(
		_ context.Context, namespace, name string,
	) (*metricsapi.PodMetrics, error) {
		call := calls.Add(1)
		requestsMu.Lock()
		requests = append(requests, namespace+"/"+name)
		requestsMu.Unlock()
		return &metricsapi.PodMetrics{
			// An empty Metrics UID is permitted. The base UID remains the only
			// output key and cache identity.
			ObjectMeta: metav1.ObjectMeta{Namespace: namespace, Name: name},
			Timestamp:  metav1.NewTime(time.Unix(int64(call), 0)),
			Containers: []metricsapi.ContainerMetrics{
				{Name: "app", Usage: corev1.ResourceList{
					corev1.ResourceCPU:    resource.MustParse(fmt.Sprintf("%dm", 100*call)),
					corev1.ResourceMemory: resource.MustParse("64Mi"),
				}},
				{Name: "sidecar", Usage: corev1.ResourceList{
					corev1.ResourceCPU:    resource.MustParse("25m"),
					corev1.ResourceMemory: resource.MustParse("16Mi"),
				}},
			},
		}, nil
	}}
	cache := newTestPodSampleCache(t, PodSampleCacheConfig{
		Client: client, RefreshTTL: 10 * time.Second, NegativeTTL: time.Second,
		EntryLimit: 10, SampleLimit: 10, MaxConcurrentGETs: 2, Now: clock.Now,
	})
	reference := PodReference{Namespace: "team-a", Name: "api", UID: "uid-a"}

	first, err := cache.Resolve(context.Background(), []PodReference{reference, reference})
	if err != nil {
		t.Fatal(err)
	}
	firstSample := first.Samples["uid-a"]
	if calls.Load() != 1 || first.State != MeasurementCurrent || first.Err != nil ||
		len(first.Samples) != 1 || firstSample.Resources[string(corev1.ResourceCPU)] != 125_000_000 ||
		firstSample.Resources[string(corev1.ResourceMemory)] != 80*1024*1024 {
		t.Fatalf("first snapshot = %#v, calls = %d", first, calls.Load())
	}
	first.Samples["uid-a"].Resources[string(corev1.ResourceCPU)] = -1

	second, err := cache.Resolve(context.Background(), []PodReference{reference})
	if err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 || second.Samples["uid-a"].Resources[string(corev1.ResourceCPU)] != 125_000_000 {
		t.Fatalf("fresh cloned snapshot = %#v, calls = %d", second, calls.Load())
	}

	clock.Advance(10 * time.Second)
	third, err := cache.Resolve(context.Background(), []PodReference{reference})
	if err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 || third.Samples["uid-a"].Resources[string(corev1.ResourceCPU)] != 225_000_000 {
		t.Fatalf("refreshed snapshot = %#v, calls = %d", third, calls.Load())
	}
	requestsMu.Lock()
	defer requestsMu.Unlock()
	if got := strings.Join(requests, ","); got != "team-a/api,team-a/api" {
		t.Fatalf("GET requests = %q", got)
	}
}

func TestPodSampleCacheKeysRecreatedPodByBaseUID(t *testing.T) {
	t.Parallel()
	var calls atomic.Int32
	client := &podCacheTestClient{get: func(
		context.Context, string, string,
	) (*metricsapi.PodMetrics, error) {
		call := calls.Add(1)
		return podMetric("", int64(call)), nil
	}}
	cache := newTestPodSampleCache(t, PodSampleCacheConfig{
		Client: client, RefreshTTL: time.Hour, NegativeTTL: time.Minute,
		EntryLimit: 10, SampleLimit: 10, MaxConcurrentGETs: 1,
	})
	oldPod := PodReference{Namespace: "team", Name: "api", UID: "old-uid"}
	newPod := PodReference{Namespace: "team", Name: "api", UID: "new-uid"}
	first, err := cache.Resolve(context.Background(), []PodReference{oldPod})
	if err != nil {
		t.Fatal(err)
	}
	second, err := cache.Resolve(context.Background(), []PodReference{newPod})
	if err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 || first.Samples["old-uid"].Resources["cpu"] != 1 ||
		second.Samples["new-uid"].Resources["cpu"] != 2 {
		t.Fatalf("old = %#v, new = %#v, calls = %d", first, second, calls.Load())
	}
}

func TestPodSampleCacheNegativeTTL(t *testing.T) {
	t.Parallel()
	clock := newPodCacheClock(time.Unix(2_000, 0))
	var calls atomic.Int32
	client := &podCacheTestClient{get: func(
		context.Context, string, string,
	) (*metricsapi.PodMetrics, error) {
		if calls.Add(1) == 1 {
			return nil, apierrors.NewNotFound(
				schema.GroupResource{Group: "metrics.k8s.io", Resource: "pods"}, "api",
			)
		}
		return podMetric("uid-a", 42), nil
	}}
	cache := newTestPodSampleCache(t, PodSampleCacheConfig{
		Client: client, RefreshTTL: 10 * time.Second, NegativeTTL: 2 * time.Second,
		EntryLimit: 10, SampleLimit: 10, MaxConcurrentGETs: 1, Now: clock.Now,
	})
	reference := PodReference{Namespace: "team", Name: "api", UID: "uid-a"}

	for range 2 {
		snapshot, err := cache.Resolve(context.Background(), []PodReference{reference})
		if err != nil || snapshot.State != MeasurementCurrent || snapshot.Err != nil || len(snapshot.Samples) != 0 {
			t.Fatalf("negative snapshot = %#v, error = %v", snapshot, err)
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("fresh negative cache calls = %d, want 1", calls.Load())
	}
	clock.Advance(2 * time.Second)
	snapshot, err := cache.Resolve(context.Background(), []PodReference{reference})
	if err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 || snapshot.State != MeasurementCurrent || snapshot.Samples["uid-a"].Resources["cpu"] != 42 {
		t.Fatalf("retried snapshot = %#v, calls = %d", snapshot, calls.Load())
	}
}

func TestPodSampleCacheCoalescesConcurrentGETs(t *testing.T) {
	t.Parallel()
	started := make(chan struct{}, 1)
	release := make(chan struct{})
	var calls atomic.Int32
	client := &podCacheTestClient{get: func(
		context.Context, string, string,
	) (*metricsapi.PodMetrics, error) {
		calls.Add(1)
		started <- struct{}{}
		<-release
		return podMetric("uid-a", 7), nil
	}}
	cache := newTestPodSampleCache(t, PodSampleCacheConfig{
		Client: client, RefreshTTL: time.Hour, NegativeTTL: time.Minute,
		EntryLimit: 10, SampleLimit: 10, MaxConcurrentGETs: 4,
	})
	reference := PodReference{Namespace: "team", Name: "api", UID: "uid-a"}
	const waiters = 40
	gate := make(chan struct{})
	results := make(chan Snapshot, waiters)
	errorsCh := make(chan error, waiters)
	var ready sync.WaitGroup
	ready.Add(waiters)
	for range waiters {
		go func() {
			ready.Done()
			<-gate
			snapshot, err := cache.Resolve(context.Background(), []PodReference{reference})
			results <- snapshot
			errorsCh <- err
		}()
	}
	ready.Wait()
	close(gate)
	receivePodCacheSignal(t, started, "coalesced GET")
	close(release)
	for range waiters {
		if err := <-errorsCh; err != nil {
			t.Fatal(err)
		}
		snapshot := <-results
		if snapshot.Samples["uid-a"].Resources["cpu"] != 7 {
			t.Fatalf("snapshot = %#v", snapshot)
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("GET calls = %d, want 1", calls.Load())
	}
}

func TestPodSampleCacheCanceledWaiterDoesNotCancelSharedGET(t *testing.T) {
	t.Parallel()
	started := make(chan struct{}, 1)
	release := make(chan struct{})
	var calls atomic.Int32
	client := &podCacheTestClient{get: func(
		ctx context.Context, _, _ string,
	) (*metricsapi.PodMetrics, error) {
		calls.Add(1)
		started <- struct{}{}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-release:
			return podMetric("uid-a", 9), nil
		}
	}}
	cache := newTestPodSampleCache(t, PodSampleCacheConfig{
		Client: client, RefreshTTL: time.Hour, NegativeTTL: time.Minute,
		EntryLimit: 10, SampleLimit: 10, MaxConcurrentGETs: 1,
	})
	reference := PodReference{Namespace: "team", Name: "api", UID: "uid-a"}
	leaderContext, cancelLeader := context.WithCancel(context.Background())
	leaderDone := make(chan error, 1)
	go func() {
		_, err := cache.Resolve(leaderContext, []PodReference{reference})
		leaderDone <- err
	}()
	receivePodCacheSignal(t, started, "leader GET")

	followerDone := make(chan struct {
		snapshot Snapshot
		err      error
	}, 1)
	go func() {
		snapshot, err := cache.Resolve(context.Background(), []PodReference{reference})
		followerDone <- struct {
			snapshot Snapshot
			err      error
		}{snapshot: snapshot, err: err}
	}()
	cancelLeader()
	select {
	case err := <-leaderDone:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("leader error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("canceled waiter remained blocked")
	}
	select {
	case result := <-followerDone:
		t.Fatalf("shared GET ended before release: %#v", result)
	default:
	}
	close(release)
	select {
	case result := <-followerDone:
		if result.err != nil || result.snapshot.Samples["uid-a"].Resources["cpu"] != 9 {
			t.Fatalf("follower result = %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("follower did not receive shared result")
	}
	if calls.Load() != 1 {
		t.Fatalf("GET calls = %d, want 1", calls.Load())
	}
}

func TestPodSampleCacheBoundsGETConcurrency(t *testing.T) {
	t.Parallel()
	const (
		limit = 3
		count = 12
	)
	started := make(chan string, count)
	release := make(chan struct{})
	var calls atomic.Int32
	var active atomic.Int32
	var peak atomic.Int32
	client := &podCacheTestClient{get: func(
		_ context.Context, _, name string,
	) (*metricsapi.PodMetrics, error) {
		calls.Add(1)
		current := active.Add(1)
		for {
			previous := peak.Load()
			if current <= previous || peak.CompareAndSwap(previous, current) {
				break
			}
		}
		started <- name
		<-release
		active.Add(-1)
		return podMetric(types.UID("uid-"+name), 1), nil
	}}
	cache := newTestPodSampleCache(t, PodSampleCacheConfig{
		Client: client, RefreshTTL: time.Hour, NegativeTTL: time.Minute,
		EntryLimit: count, SampleLimit: count, MaxConcurrentGETs: limit,
	})
	references := make([]PodReference, 0, count)
	for index := range count {
		name := fmt.Sprintf("pod-%02d", index)
		references = append(references, PodReference{
			Namespace: "team", Name: name, UID: types.UID("uid-" + name),
		})
	}
	done := make(chan struct {
		snapshot Snapshot
		err      error
	}, 1)
	go func() {
		snapshot, err := cache.Resolve(context.Background(), references)
		done <- struct {
			snapshot Snapshot
			err      error
		}{snapshot: snapshot, err: err}
	}()
	for range limit {
		receivePodCacheSignal(t, started, "bounded GET")
	}
	select {
	case name := <-started:
		t.Fatalf("GET %q exceeded concurrency limit before release", name)
	case <-time.After(50 * time.Millisecond):
	}
	close(release)
	select {
	case result := <-done:
		if result.err != nil || len(result.snapshot.Samples) != count {
			t.Fatalf("result = %#v", result)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("bounded GET batch did not finish")
	}
	if calls.Load() != count || peak.Load() > limit {
		t.Fatalf("calls = %d, peak = %d, limit = %d", calls.Load(), peak.Load(), limit)
	}
}

func TestPodSampleCacheRetainsStaleSampleAfterTransientFailure(t *testing.T) {
	t.Parallel()
	clock := newPodCacheClock(time.Unix(3_000, 0))
	var calls atomic.Int32
	client := &podCacheTestClient{get: func(
		context.Context, string, string,
	) (*metricsapi.PodMetrics, error) {
		switch calls.Add(1) {
		case 1:
			return podMetric("uid-a", 42), nil
		case 2:
			return nil, apierrors.NewServiceUnavailable("sensitive upstream payload")
		default:
			return podMetric("uid-a", 84), nil
		}
	}}
	cache := newTestPodSampleCache(t, PodSampleCacheConfig{
		Client: client, RefreshTTL: 10 * time.Second, NegativeTTL: 2 * time.Second,
		EntryLimit: 10, SampleLimit: 10, MaxConcurrentGETs: 1, Now: clock.Now,
	})
	reference := PodReference{Namespace: "team", Name: "api", UID: "uid-a"}
	first, err := cache.Resolve(context.Background(), []PodReference{reference})
	if err != nil || first.Samples["uid-a"].Resources["cpu"] != 42 {
		t.Fatalf("first = %#v, error = %v", first, err)
	}
	clock.Advance(10 * time.Second)
	stale, err := cache.Resolve(context.Background(), []PodReference{reference})
	if err != nil {
		t.Fatal(err)
	}
	if stale.State != MeasurementStale || stale.Samples["uid-a"].Resources["cpu"] != 42 ||
		!errors.Is(stale.Err, ErrMetricsAPIUnavailable) ||
		strings.Contains(stale.Err.Error(), "sensitive") {
		t.Fatalf("stale = %#v", stale)
	}
	stale.Samples["uid-a"].Resources["cpu"] = -1
	cachedStale, err := cache.Resolve(context.Background(), []PodReference{reference})
	if err != nil || cachedStale.Samples["uid-a"].Resources["cpu"] != 42 || calls.Load() != 2 {
		t.Fatalf("cached stale = %#v, error = %v, calls = %d", cachedStale, err, calls.Load())
	}
	clock.Advance(2 * time.Second)
	current, err := cache.Resolve(context.Background(), []PodReference{reference})
	if err != nil || current.State != MeasurementCurrent || current.Err != nil ||
		current.Samples["uid-a"].Resources["cpu"] != 84 || calls.Load() != 3 {
		t.Fatalf("current = %#v, error = %v, calls = %d", current, err, calls.Load())
	}
}

func TestPodSampleCacheDoesNotUseStaleSampleForTerminalResults(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		refresh   func() (*metricsapi.PodMetrics, error)
		wantState MeasurementState
		wantErr   error
	}{
		{
			name: "UID mismatch",
			refresh: func() (*metricsapi.PodMetrics, error) {
				return podMetric("different-uid", 99), nil
			},
			wantState: MeasurementUnavailable,
			wantErr:   ErrPodMetricsUIDMismatch,
		},
		{
			name: "forbidden",
			refresh: func() (*metricsapi.PodMetrics, error) {
				return nil, apierrors.NewForbidden(
					schema.GroupResource{Group: "metrics.k8s.io", Resource: "pods"},
					"api", errors.New("sensitive authorization body"),
				)
			},
			wantState: MeasurementUnavailable,
			wantErr:   ErrMetricsAPIForbidden,
		},
		{
			name: "not found",
			refresh: func() (*metricsapi.PodMetrics, error) {
				return nil, apierrors.NewNotFound(
					schema.GroupResource{Group: "metrics.k8s.io", Resource: "pods"}, "api",
				)
			},
			wantState: MeasurementCurrent,
		},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			clock := newPodCacheClock(time.Unix(4_000, 0))
			var calls atomic.Int32
			client := &podCacheTestClient{get: func(
				context.Context, string, string,
			) (*metricsapi.PodMetrics, error) {
				if calls.Add(1) == 1 {
					return podMetric("uid-a", 42), nil
				}
				return test.refresh()
			}}
			cache := newTestPodSampleCache(t, PodSampleCacheConfig{
				Client: client, RefreshTTL: 10 * time.Second, NegativeTTL: 2 * time.Second,
				EntryLimit: 10, SampleLimit: 10, MaxConcurrentGETs: 1, Now: clock.Now,
			})
			reference := PodReference{Namespace: "team", Name: "api", UID: "uid-a"}
			if _, err := cache.Resolve(context.Background(), []PodReference{reference}); err != nil {
				t.Fatal(err)
			}
			clock.Advance(10 * time.Second)
			snapshot, err := cache.Resolve(context.Background(), []PodReference{reference})
			if err != nil {
				t.Fatal(err)
			}
			if snapshot.State != test.wantState || len(snapshot.Samples) != 0 ||
				!errors.Is(snapshot.Err, test.wantErr) ||
				(snapshot.Err != nil && strings.Contains(snapshot.Err.Error(), "sensitive")) {
				t.Fatalf("terminal snapshot = %#v", snapshot)
			}
			if _, err := cache.Resolve(context.Background(), []PodReference{reference}); err != nil {
				t.Fatal(err)
			}
			if calls.Load() != 2 {
				t.Fatalf("short terminal cache calls = %d, want 2", calls.Load())
			}
		})
	}
}

func TestPodSampleCacheLRUBoundsEntriesAndSamples(t *testing.T) {
	t.Parallel()
	t.Run("negative entries count toward entry limit and hits touch recency", func(t *testing.T) {
		var calls atomic.Int32
		client := &podCacheTestClient{get: func(
			context.Context, string, string,
		) (*metricsapi.PodMetrics, error) {
			calls.Add(1)
			return nil, apierrors.NewNotFound(
				schema.GroupResource{Group: "metrics.k8s.io", Resource: "pods"}, "missing",
			)
		}}
		cache := newTestPodSampleCache(t, PodSampleCacheConfig{
			Client: client, RefreshTTL: time.Hour, NegativeTTL: time.Minute,
			EntryLimit: 2, SampleLimit: 2, MaxConcurrentGETs: 1,
		})
		a, b, c := podReference("a"), podReference("b"), podReference("c")
		resolvePodCache(t, cache, a)
		resolvePodCache(t, cache, b)
		resolvePodCache(t, cache, a) // Touch a, making b the least recently used.
		resolvePodCache(t, cache, c)
		resolvePodCache(t, cache, a)
		resolvePodCache(t, cache, b)
		if calls.Load() != 4 {
			t.Fatalf("GET calls = %d, want 4", calls.Load())
		}
		cache.mu.Lock()
		defer cache.mu.Unlock()
		if len(cache.entries) != 2 || cache.sampleCount != 0 {
			t.Fatalf("entries = %d, samples = %d", len(cache.entries), cache.sampleCount)
		}
	})

	t.Run("sample limit evicts positives but retains separate negatives", func(t *testing.T) {
		client := &podCacheTestClient{get: func(
			_ context.Context, _, name string,
		) (*metricsapi.PodMetrics, error) {
			if name == "negative" {
				return nil, apierrors.NewNotFound(
					schema.GroupResource{Group: "metrics.k8s.io", Resource: "pods"}, name,
				)
			}
			return podMetric(types.UID("uid-"+name), 1), nil
		}}
		cache := newTestPodSampleCache(t, PodSampleCacheConfig{
			Client: client, RefreshTTL: time.Hour, NegativeTTL: time.Minute,
			EntryLimit: 3, SampleLimit: 1, MaxConcurrentGETs: 1,
		})
		resolvePodCache(t, cache, podReference("first"))
		resolvePodCache(t, cache, podReference("second"))
		negative := PodReference{Namespace: "team", Name: "negative", UID: "uid-negative"}
		resolvePodCache(t, cache, negative)

		cache.mu.Lock()
		defer cache.mu.Unlock()
		if len(cache.entries) != 2 || cache.sampleCount != 1 ||
			cache.entries[podSampleKey{namespace: "team", name: "first", uid: "uid-first"}] != nil ||
			cache.entries[podSampleKey{namespace: "team", name: "second", uid: "uid-second"}] == nil ||
			cache.entries[podSampleKey{namespace: "team", name: "negative", uid: "uid-negative"}] == nil {
			t.Fatalf("entries = %#v, sample count = %d", cache.entries, cache.sampleCount)
		}
	})
}

func TestPodSampleCacheCloseCancelsGETAndWaiters(t *testing.T) {
	t.Parallel()
	started := make(chan struct{}, 1)
	canceled := make(chan struct{}, 1)
	client := &podCacheTestClient{get: func(
		ctx context.Context, _, _ string,
	) (*metricsapi.PodMetrics, error) {
		started <- struct{}{}
		<-ctx.Done()
		canceled <- struct{}{}
		return nil, ctx.Err()
	}}
	cache, err := NewPodSampleCache(PodSampleCacheConfig{
		Client: client, RefreshTTL: time.Hour, NegativeTTL: time.Minute,
		EntryLimit: 10, SampleLimit: 10, MaxConcurrentGETs: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, resolveErr := cache.Resolve(context.Background(), []PodReference{podReference("api")})
		done <- resolveErr
	}()
	receivePodCacheSignal(t, started, "blocking GET")
	cache.Close()
	receivePodCacheSignal(t, canceled, "GET cancellation")
	select {
	case resolveErr := <-done:
		if !errors.Is(resolveErr, ErrPodSampleCacheClosed) {
			t.Fatalf("Resolve error = %v", resolveErr)
		}
	case <-time.After(time.Second):
		t.Fatal("Resolve waiter was not released by Close")
	}
	if _, err := cache.Resolve(context.Background(), []PodReference{podReference("api")}); !errors.Is(err, ErrPodSampleCacheClosed) {
		t.Fatalf("Resolve after Close error = %v", err)
	}
	cache.Close()
}

func TestPodSampleCacheValidatesConfigurationAndReferences(t *testing.T) {
	t.Parallel()
	client := &podCacheTestClient{get: func(
		context.Context, string, string,
	) (*metricsapi.PodMetrics, error) {
		return podMetric("uid", 1), nil
	}}
	for _, test := range []struct {
		name   string
		config PodSampleCacheConfig
	}{
		{name: "nil client", config: PodSampleCacheConfig{}},
		{name: "negative refresh TTL", config: PodSampleCacheConfig{Client: client, RefreshTTL: -1}},
		{
			name: "negative TTL not shorter",
			config: PodSampleCacheConfig{
				Client: client, RefreshTTL: time.Second, NegativeTTL: time.Second,
			},
		},
		{name: "negative entry limit", config: PodSampleCacheConfig{Client: client, EntryLimit: -1}},
		{name: "negative sample limit", config: PodSampleCacheConfig{Client: client, SampleLimit: -1}},
		{name: "negative concurrency", config: PodSampleCacheConfig{Client: client, MaxConcurrentGETs: -1}},
	} {
		if cache, err := NewPodSampleCache(test.config); err == nil {
			cache.Close()
			t.Fatalf("%s: expected error", test.name)
		}
	}

	cache := newTestPodSampleCache(t, PodSampleCacheConfig{
		Client: client, RefreshTTL: time.Hour, NegativeTTL: time.Minute,
		EntryLimit: 10, SampleLimit: 10, MaxConcurrentGETs: 1,
	})
	for _, references := range [][]PodReference{
		{{Namespace: "", Name: "api", UID: "uid"}},
		{{Namespace: "team", Name: "", UID: "uid"}},
		{{Namespace: "team", Name: "api", UID: ""}},
		{
			{Namespace: "team", Name: "api", UID: "same-uid"},
			{Namespace: "other", Name: "api", UID: "same-uid"},
		},
	} {
		if _, err := cache.Resolve(context.Background(), references); !errors.Is(err, ErrInvalidPodReference) {
			t.Fatalf("references %#v error = %v", references, err)
		}
	}
	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := cache.Resolve(canceled, []PodReference{podReference("api")}); !errors.Is(err, context.Canceled) {
		t.Fatalf("pre-canceled Resolve error = %v", err)
	}
}

type podCacheTestClient struct {
	get func(context.Context, string, string) (*metricsapi.PodMetrics, error)
}

func (*podCacheTestClient) RESTClient() rest.Interface { return nil }

func (*podCacheTestClient) NodeMetricses() metricsclient.NodeMetricsInterface { return nil }

func (c *podCacheTestClient) PodMetricses(namespace string) metricsclient.PodMetricsInterface {
	return &podCacheTestPods{client: c, namespace: namespace}
}

type podCacheTestPods struct {
	client    *podCacheTestClient
	namespace string
}

func (c *podCacheTestPods) Get(
	ctx context.Context,
	name string,
	_ metav1.GetOptions,
) (*metricsapi.PodMetrics, error) {
	return c.client.get(ctx, c.namespace, name)
}

func (*podCacheTestPods) List(
	context.Context,
	metav1.ListOptions,
) (*metricsapi.PodMetricsList, error) {
	return nil, errors.New("unexpected PodMetrics LIST")
}

func (*podCacheTestPods) Watch(context.Context, metav1.ListOptions) (watch.Interface, error) {
	return nil, errors.New("unexpected PodMetrics WATCH")
}

type podCacheClock struct {
	mu  sync.Mutex
	now time.Time
}

func newPodCacheClock(now time.Time) *podCacheClock { return &podCacheClock{now: now} }

func (c *podCacheClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *podCacheClock) Advance(duration time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(duration)
	c.mu.Unlock()
}

func newTestPodSampleCache(t *testing.T, config PodSampleCacheConfig) *PodSampleCache {
	t.Helper()
	cache, err := NewPodSampleCache(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(cache.Close)
	return cache
}

func podMetric(uid types.UID, cpu int64) *metricsapi.PodMetrics {
	return &metricsapi.PodMetrics{
		ObjectMeta: metav1.ObjectMeta{UID: uid},
		Timestamp:  metav1.NewTime(time.Unix(cpu, 0)),
		Containers: []metricsapi.ContainerMetrics{{
			Name: "app", Usage: corev1.ResourceList{
				corev1.ResourceCPU: *resource.NewScaledQuantity(cpu, resource.Nano),
			},
		}},
	}
}

func podReference(name string) PodReference {
	return PodReference{Namespace: "team", Name: name, UID: types.UID("uid-" + name)}
}

func resolvePodCache(t *testing.T, cache *PodSampleCache, reference PodReference) Snapshot {
	t.Helper()
	snapshot, err := cache.Resolve(context.Background(), []PodReference{reference})
	if err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func receivePodCacheSignal[T any](t *testing.T, values <-chan T, description string) T {
	t.Helper()
	select {
	case value := <-values:
		return value
	case <-time.After(time.Second):
		t.Fatalf("timed out waiting for %s", description)
		var zero T
		return zero
	}
}
