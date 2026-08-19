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
)

func TestProviderIsLazySharedAndCancelsAfterFinalConsumer(t *testing.T) {
	t.Parallel()
	fetcher := &blockingFetcher{started: make(chan struct{}, 1), stopped: make(chan struct{})}
	provider, err := NewProvider(fetcher, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if fetcher.calls.Load() != 0 {
		t.Fatal("metrics fetched without a consumer")
	}
	first := provider.Subscribe()
	second := provider.Subscribe()
	select {
	case <-fetcher.started:
	case <-time.After(time.Second):
		t.Fatal("metrics fetch did not start")
	}
	if fetcher.calls.Load() != 1 || provider.ConsumerCount() != 2 {
		t.Fatalf("calls=%d consumers=%d", fetcher.calls.Load(), provider.ConsumerCount())
	}
	first.Close()
	select {
	case <-fetcher.stopped:
		t.Fatal("shared fetch cancelled with a remaining consumer")
	default:
	}
	second.Close()
	select {
	case <-fetcher.stopped:
	case <-time.After(time.Second):
		t.Fatal("final consumer did not cancel metrics fetch")
	}
}

func TestProviderCoalescesSlowConsumersToNewestSnapshot(t *testing.T) {
	t.Parallel()
	fetcher := &sequenceFetcher{values: []map[string]Sample{
		{"pod": {Resources: map[string]int64{"cpu": 1}}},
		{"pod": {Resources: map[string]int64{"cpu": 2}}},
		{"pod": {Resources: map[string]int64{"cpu": 3}}},
	}}
	provider, err := NewProvider(fetcher, time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	subscription := provider.Subscribe()
	defer subscription.Close()
	eventuallyMetrics(t, time.Second, func() bool {
		provider.mu.Lock()
		defer provider.mu.Unlock()
		return provider.latest.Samples["pod"].Resources["cpu"] == 3
	})
	select {
	case snapshot := <-subscription.Updates():
		if got := snapshot.Samples["pod"].Resources["cpu"]; got != 3 {
			t.Fatalf("coalesced CPU = %d, want newest 3", got)
		}
	case <-time.After(time.Second):
		t.Fatal("no metrics update")
	}
}

func TestProviderDegradesFailureWithoutLeakingErrorPayload(t *testing.T) {
	t.Parallel()
	fetcher := &sequenceFetcher{err: errors.New("server response contained sensitive garbage")}
	provider, err := NewProvider(fetcher, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	subscription := provider.Subscribe()
	defer subscription.Close()
	select {
	case snapshot := <-subscription.Updates():
		if snapshot.State != MeasurementUnavailable || snapshot.Err == nil {
			t.Fatalf("snapshot = %#v", snapshot)
		}
		if snapshot.Err.Error() == fetcher.err.Error() {
			t.Fatal("provider retained raw remote error text")
		}
	case <-time.After(time.Second):
		t.Fatal("no failure snapshot")
	}
}

func TestProviderPreservesSafeMetricsErrorCategory(t *testing.T) {
	t.Parallel()
	provider, err := NewProvider(&sequenceFetcher{err: fmt.Errorf("%w: unsafe remote body", ErrMetricsAPIForbidden)}, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	subscription := provider.Subscribe()
	defer subscription.Close()
	select {
	case snapshot := <-subscription.Updates():
		if !errors.Is(snapshot.Err, ErrMetricsAPIForbidden) || strings.Contains(snapshot.Err.Error(), "unsafe remote body") {
			t.Fatalf("safe error category = %v", snapshot.Err)
		}
	case <-time.After(time.Second):
		t.Fatal("no metrics failure snapshot")
	}
}

func TestProviderRetainsLastGoodValuesAsStaleAfterRefreshFailure(t *testing.T) {
	t.Parallel()
	fetcher := &successThenFailureFetcher{}
	provider, err := NewProvider(fetcher, time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	subscription := provider.Subscribe()
	defer subscription.Close()
	select {
	case snapshot := <-subscription.Updates():
		if snapshot.State != MeasurementCurrent || snapshot.Samples["pod"].Resources["cpu"] != 42 {
			t.Fatalf("first snapshot = %#v", snapshot)
		}
	case <-time.After(time.Second):
		t.Fatal("no current metrics snapshot")
	}
	select {
	case snapshot := <-subscription.Updates():
		if snapshot.State != MeasurementStale || snapshot.Samples["pod"].Resources["cpu"] != 42 || snapshot.Err == nil {
			t.Fatalf("stale snapshot = %#v", snapshot)
		}
	case <-time.After(time.Second):
		t.Fatal("no stale metrics snapshot")
	}
}

func TestProviderCoalescesExplicitRefreshRequests(t *testing.T) {
	t.Parallel()
	provider, err := NewProvider(&sequenceFetcher{values: []map[string]Sample{
		{"pod": {Resources: map[string]int64{"cpu": 1}}},
		{"pod": {Resources: map[string]int64{"cpu": 2}}},
	}}, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	subscription := provider.Subscribe()
	defer subscription.Close()
	select {
	case snapshot := <-subscription.Updates():
		if snapshot.Samples["pod"].Resources["cpu"] != 1 {
			t.Fatalf("initial snapshot = %#v", snapshot)
		}
	case <-time.After(time.Second):
		t.Fatal("no initial metrics snapshot")
	}
	for range 32 {
		subscription.RequestRefresh()
	}
	select {
	case snapshot := <-subscription.Updates():
		if snapshot.Samples["pod"].Resources["cpu"] != 2 {
			t.Fatalf("refreshed snapshot = %#v", snapshot)
		}
	case <-time.After(time.Second):
		t.Fatal("explicit refresh did not wake provider")
	}
	time.Sleep(20 * time.Millisecond)
	if calls := provider.fetcher.(*sequenceFetcher).calls.Load(); calls < 2 || calls > 3 {
		// A request that races after the explicit fetch has started may schedule
		// one follow-up. The other 31 requests must still collapse rather than
		// causing one API call apiece.
		t.Fatalf("coalesced refresh fetches = %d, want 2 or 3 total", calls)
	}
}

func TestProviderLeasePinsUntilSubscriptionAndIdleReleaseDropsSnapshot(t *testing.T) {
	t.Parallel()
	fetcher := &sequenceFetcher{values: []map[string]Sample{
		{"pod": {Resources: map[string]int64{"cpu": 42}}},
	}}
	provider, err := NewProvider(fetcher, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	lease, err := provider.Acquire()
	if err != nil {
		t.Fatal(err)
	}
	if provider.ReleaseIdle() {
		t.Fatal("provider was released while an open lease pinned it")
	}
	subscription := lease.Subscribe()
	if subscription == nil {
		t.Fatal("lease did not convert to a subscription")
	}
	select {
	case snapshot := <-subscription.Updates():
		if snapshot.Samples["pod"].Resources["cpu"] != 42 {
			t.Fatalf("snapshot = %#v", snapshot)
		}
	case <-time.After(time.Second):
		t.Fatal("no metrics snapshot")
	}
	if provider.RetainedSampleCount() != 1 || provider.ReleaseIdle() {
		t.Fatal("active subscription was not pinned")
	}
	subscription.Close()
	if !provider.ReleaseIdle() {
		t.Fatal("idle provider was not released")
	}
	if provider.RetainedSampleCount() != 0 {
		t.Fatal("released provider retained its last sample")
	}
	if _, err := provider.Acquire(); err == nil {
		t.Fatal("released provider was reacquired")
	}
}

type blockingFetcher struct {
	started chan struct{}
	stopped chan struct{}
	once    sync.Once
	calls   atomic.Int64
}

func (f *blockingFetcher) Fetch(ctx context.Context) (map[string]Sample, error) {
	f.calls.Add(1)
	select {
	case f.started <- struct{}{}:
	default:
	}
	<-ctx.Done()
	f.once.Do(func() { close(f.stopped) })
	return nil, ctx.Err()
}

type sequenceFetcher struct {
	mu     sync.Mutex
	values []map[string]Sample
	err    error
	calls  atomic.Int64
}

type successThenFailureFetcher struct{ calls atomic.Int64 }

func (f *successThenFailureFetcher) Fetch(context.Context) (map[string]Sample, error) {
	if f.calls.Add(1) == 1 {
		return map[string]Sample{"pod": {Resources: map[string]int64{"cpu": 42}}}, nil
	}
	return nil, errors.New("temporary refresh failure with unsafe upstream details")
}

func (f *sequenceFetcher) Fetch(context.Context) (map[string]Sample, error) {
	index := int(f.calls.Add(1)) - 1
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return nil, f.err
	}
	return f.values[min(index, len(f.values)-1)], nil
}

func eventuallyMetrics(t *testing.T, timeout time.Duration, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("condition was not met")
}
