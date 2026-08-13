package watcher

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

func TestLeasesShareWatcherAcrossWindows(t *testing.T) {
	t.Parallel()
	started := make(chan struct{}, 2)
	stopped := make(chan struct{}, 2)
	var starts atomic.Int32
	manager := NewLeaseManager(20*time.Millisecond, func(ctx context.Context, key string) {
		starts.Add(1)
		started <- struct{}{}
		<-ctx.Done()
		stopped <- struct{}{}
	})
	t.Cleanup(manager.Close)

	first := manager.Acquire("pods")
	second := manager.Acquire("pods")
	receive(t, started, "watch start")
	if got := manager.References("pods"); got != 2 {
		t.Fatalf("references = %d, want 2", got)
	}
	first.Close()
	assertNoReceive(t, stopped, 30*time.Millisecond, "watch stopped while another window consumed it")
	second.Close()
	receive(t, stopped, "watch cancellation after final consumer")
	if got := starts.Load(); got != 1 {
		t.Fatalf("starts = %d, want 1", got)
	}
}

func TestAcquireDuringDebouncePreventsChurn(t *testing.T) {
	t.Parallel()
	started := make(chan struct{}, 2)
	stopped := make(chan struct{}, 2)
	manager := NewLeaseManager(40*time.Millisecond, func(ctx context.Context, key string) {
		started <- struct{}{}
		<-ctx.Done()
		stopped <- struct{}{}
	})
	t.Cleanup(manager.Close)

	first := manager.Acquire("nodes")
	receive(t, started, "watch start")
	first.Close()
	time.Sleep(5 * time.Millisecond)
	second := manager.Acquire("nodes")
	assertNoReceive(t, stopped, 60*time.Millisecond, "watch churned during debounce")
	assertNoReceive(t, started, 5*time.Millisecond, "second watcher started during debounce")
	second.Close()
	receive(t, stopped, "final cancellation")
}

func TestLeaseCloseIsIdempotent(t *testing.T) {
	t.Parallel()
	started := make(chan struct{}, 1)
	manager := NewLeaseManager(0, func(ctx context.Context, key string) {
		started <- struct{}{}
		<-ctx.Done()
	})
	t.Cleanup(manager.Close)
	lease := manager.Acquire("events")
	receive(t, started, "watch start")
	lease.Close()
	lease.Close()
	eventually(t, func() bool { return manager.ActiveCount() == 0 }, "manager to remove closed watcher")
}

func receive(t *testing.T, channel <-chan struct{}, description string) {
	t.Helper()
	select {
	case <-channel:
	case <-time.After(time.Second):
		t.Fatalf("timed out waiting for %s", description)
	}
}

func assertNoReceive(t *testing.T, channel <-chan struct{}, duration time.Duration, description string) {
	t.Helper()
	select {
	case <-channel:
		t.Fatal(description)
	case <-time.After(duration):
	}
}

func eventually(t *testing.T, condition func() bool, description string) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", description)
		}
		time.Sleep(time.Millisecond)
	}
}
