package metrics

import (
	"context"
	"errors"
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
	eventuallyMetrics(t, time.Second, func() bool { return fetcher.calls.Load() >= 3 })
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
