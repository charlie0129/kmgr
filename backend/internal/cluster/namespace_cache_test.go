package cluster

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestNamespaceNameCacheCoalescesColdMissesAndClonesResults(t *testing.T) {
	t.Parallel()
	var cache namespaceNameCache
	defer cache.close()

	const callers = 16
	start := make(chan struct{})
	loaderStarted := make(chan struct{})
	releaseLoader := make(chan struct{})
	var loaderOnce sync.Once
	var calls atomic.Int64
	loader := func(ctx context.Context) ([]string, error) {
		calls.Add(1)
		loaderOnce.Do(func() { close(loaderStarted) })
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-releaseLoader:
			return []string{"z", "a", "z"}, nil
		}
	}

	type result struct {
		names []string
		err   error
	}
	results := make(chan result, callers)
	var ready sync.WaitGroup
	ready.Add(callers)
	for range callers {
		go func() {
			ready.Done()
			<-start
			names, err := cache.load(context.Background(), loader)
			results <- result{names: names, err: err}
		}()
	}
	ready.Wait()
	close(start)
	select {
	case <-loaderStarted:
	case <-time.After(time.Second):
		t.Fatal("coalesced namespace loader did not start")
	}
	// Keep the first request in flight long enough for every simultaneously
	// released caller to join it. A duplicate loader is immediately observable.
	select {
	case <-time.After(25 * time.Millisecond):
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("concurrent cold namespace loads = %d, want 1", got)
	}
	close(releaseLoader)

	all := make([][]string, 0, callers)
	for range callers {
		select {
		case value := <-results:
			if value.err != nil {
				t.Fatal(value.err)
			}
			if !slices.Equal(value.names, []string{"a", "z"}) {
				t.Fatalf("names = %v, want [a z]", value.names)
			}
			all = append(all, value.names)
		case <-time.After(time.Second):
			t.Fatal("coalesced namespace caller did not finish")
		}
	}
	all[0][0] = "mutated"
	for index := 1; index < len(all); index++ {
		if all[index][0] != "a" {
			t.Fatalf("caller mutation reached result %d: %v", index, all[index])
		}
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("completed concurrent namespace loads = %d, want 1", got)
	}
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if !slices.Equal(cache.names, []string{"a", "z"}) {
		t.Fatalf("caller mutation reached cached names: %v", cache.names)
	}
}

func TestNamespaceNamesAreSharedByBackendAndRefreshStaleSnapshot(t *testing.T) {
	t.Parallel()
	clock := newNamespaceNameCacheTestClock()
	var calls atomic.Int64
	refreshStarted := make(chan struct{})
	releaseRefresh := make(chan struct{})
	session := namespaceTestSession(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch calls.Add(1) {
		case 1:
			writeNamespaceList(t, writer, "", "old", "alpha")
		case 2:
			close(refreshStarted)
			select {
			case <-request.Context().Done():
				return
			case <-releaseRefresh:
				writeNamespaceList(t, writer, "", "new", "beta")
			}
		default:
			writeNamespaceList(t, writer, "", "new", "beta")
		}
	}))
	t.Cleanup(session.backend.namespaceNames.close)
	session.backend.namespaceNames.now = clock.Now
	session.backend.namespaceNames.freshnessInterval = time.Minute
	sibling := &Session{backend: session.backend}

	initial, err := session.ListNamespacesCached(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(initial, []string{"alpha", "old"}) {
		t.Fatalf("initial names = %v", initial)
	}
	clock.Advance(time.Minute)

	stale, err := sibling.ListNamespacesCached(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(stale, []string{"alpha", "old"}) {
		t.Fatalf("stale names = %v", stale)
	}
	select {
	case <-refreshStarted:
	case <-time.After(time.Second):
		t.Fatal("stale cache hit did not start a refresh")
	}
	session.backend.namespaceNames.mu.Lock()
	flight := session.backend.namespaceNames.flight
	session.backend.namespaceNames.mu.Unlock()
	if flight == nil {
		t.Fatal("namespace refresh was not retained as an in-flight request")
	}
	close(releaseRefresh)
	select {
	case <-flight.done:
	case <-time.After(time.Second):
		t.Fatal("namespace refresh did not finish")
	}

	initial[0] = "mutated-initial"
	stale[0] = "mutated-stale"
	session.backend.namespaceNames.mu.Lock()
	cached := slices.Clone(session.backend.namespaceNames.names)
	session.backend.namespaceNames.mu.Unlock()
	if !slices.Equal(cached, []string{"beta", "new"}) {
		t.Fatalf("refreshed cached names = %v, want [beta new]", cached)
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("shared backend namespace LISTs = %d, want 2", got)
	}
}

func TestNamespaceNameCacheFreshHitsDoNotReloadAndExpiryCoalescesRefresh(t *testing.T) {
	t.Parallel()
	clock := newNamespaceNameCacheTestClock()
	cache := namespaceNameCache{
		now:               clock.Now,
		freshnessInterval: time.Minute,
	}
	defer cache.close()

	refreshStarted := make(chan struct{})
	releaseRefresh := make(chan struct{})
	var calls atomic.Int64
	loader := func(ctx context.Context) ([]string, error) {
		switch calls.Add(1) {
		case 1:
			return []string{"stable"}, nil
		case 2:
			close(refreshStarted)
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-releaseRefresh:
				return []string{"refreshed"}, nil
			}
		default:
			return nil, errors.New("unexpected namespace refresh")
		}
	}

	if _, err := cache.load(context.Background(), loader); err != nil {
		t.Fatal(err)
	}
	for range 10 {
		names, err := cache.load(context.Background(), loader)
		if err != nil || !slices.Equal(names, []string{"stable"}) {
			t.Fatalf("fresh cache hit = %v, %v", names, err)
		}
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("fresh cache loader calls = %d, want 1", got)
	}
	cache.mu.Lock()
	freshFlight := cache.flight
	cache.mu.Unlock()
	if freshFlight != nil {
		t.Fatal("fresh cache hit started a refresh")
	}

	// The interval is a freshness duration, so equality is expired.
	clock.Advance(time.Minute)
	names, err := cache.load(context.Background(), loader)
	if err != nil || !slices.Equal(names, []string{"stable"}) {
		t.Fatalf("expired cache hit = %v, %v", names, err)
	}
	select {
	case <-refreshStarted:
	case <-time.After(time.Second):
		t.Fatal("expired cache hit did not start a refresh")
	}
	cache.mu.Lock()
	refresh := cache.flight
	cache.mu.Unlock()
	if refresh == nil {
		t.Fatal("expired cache refresh was not retained in flight")
	}
	for range 10 {
		names, err := cache.load(context.Background(), loader)
		if err != nil || !slices.Equal(names, []string{"stable"}) {
			t.Fatalf("coalesced stale cache hit = %v, %v", names, err)
		}
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("expired cache loader calls = %d, want 2", got)
	}
	close(releaseRefresh)
	select {
	case <-refresh.done:
	case <-time.After(time.Second):
		t.Fatal("namespace refresh did not finish")
	}
	cache.mu.Lock()
	cached := slices.Clone(cache.names)
	cache.mu.Unlock()
	if !slices.Equal(cached, []string{"refreshed"}) {
		t.Fatalf("refreshed cache names = %v", cached)
	}
}

func TestNamespaceNameCacheNeverCachesFailures(t *testing.T) {
	t.Parallel()
	var cache namespaceNameCache
	defer cache.close()
	wantErr := errors.New("namespace list unavailable")
	var calls atomic.Int64
	loader := func(context.Context) ([]string, error) {
		if calls.Add(1) == 1 {
			return nil, wantErr
		}
		return []string{"recovered"}, nil
	}

	if _, err := cache.load(context.Background(), loader); !errors.Is(err, wantErr) {
		t.Fatalf("first load error = %v, want %v", err, wantErr)
	}
	names, err := cache.load(context.Background(), loader)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(names, []string{"recovered"}) || calls.Load() != 2 {
		t.Fatalf("recovered names/calls = %v/%d", names, calls.Load())
	}
}

func TestNamespaceNameCacheKeepsStaleSnapshotAfterRefreshFailure(t *testing.T) {
	t.Parallel()
	clock := newNamespaceNameCacheTestClock()
	cache := namespaceNameCache{
		now:               clock.Now,
		freshnessInterval: time.Minute,
	}
	defer cache.close()
	refreshStarted := make(chan struct{})
	releaseRefresh := make(chan struct{})
	recoveryStarted := make(chan struct{})
	releaseRecovery := make(chan struct{})
	var calls atomic.Int64
	loader := func(ctx context.Context) ([]string, error) {
		switch calls.Add(1) {
		case 1:
			return []string{"stable"}, nil
		case 2:
			close(refreshStarted)
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-releaseRefresh:
				return nil, errors.New("refresh failed")
			}
		default:
			close(recoveryStarted)
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-releaseRecovery:
				return []string{"new"}, nil
			}
		}
	}
	if _, err := cache.load(context.Background(), loader); err != nil {
		t.Fatal(err)
	}
	clock.Advance(time.Minute)
	stale, err := cache.load(context.Background(), loader)
	if err != nil || !slices.Equal(stale, []string{"stable"}) {
		t.Fatalf("stale cache hit = %v, %v", stale, err)
	}
	select {
	case <-refreshStarted:
	case <-time.After(time.Second):
		t.Fatal("refresh did not start")
	}
	cache.mu.Lock()
	flight := cache.flight
	cache.mu.Unlock()
	close(releaseRefresh)
	select {
	case <-flight.done:
	case <-time.After(time.Second):
		t.Fatal("failed refresh did not finish")
	}
	cache.mu.Lock()
	cached := slices.Clone(cache.names)
	cache.mu.Unlock()
	if !slices.Equal(cached, []string{"stable"}) {
		t.Fatalf("refresh failure replaced stale names: %v", cached)
	}

	// A failure is not memoized: the next read returns stale again and starts a
	// new refresh, which may recover the cache.
	if _, err := cache.load(context.Background(), loader); err != nil {
		t.Fatal(err)
	}
	select {
	case <-recoveryStarted:
	case <-time.After(time.Second):
		t.Fatal("recovery refresh did not start")
	}
	cache.mu.Lock()
	recovery := cache.flight
	cache.mu.Unlock()
	if recovery == nil {
		t.Fatal("recovery refresh was not retained in flight")
	}
	close(releaseRecovery)
	select {
	case <-recovery.done:
	case <-time.After(time.Second):
		t.Fatal("recovery refresh did not finish")
	}
	cache.mu.Lock()
	cached = slices.Clone(cache.names)
	cache.mu.Unlock()
	if !slices.Equal(cached, []string{"new"}) || calls.Load() != 3 {
		t.Fatalf("recovered cache/calls = %v/%d", cached, calls.Load())
	}
}

type namespaceNameCacheTestClock struct {
	mu  sync.Mutex
	now time.Time
}

func newNamespaceNameCacheTestClock() *namespaceNameCacheTestClock {
	return &namespaceNameCacheTestClock{now: time.Unix(1_000, 0)}
}

func (c *namespaceNameCacheTestClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *namespaceNameCacheTestClock) Advance(duration time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(duration)
}

func TestNamespaceNameCacheCloseCancelsRefreshAndRejectsNewLoads(t *testing.T) {
	t.Parallel()
	var cache namespaceNameCache
	loaderStarted := make(chan struct{})
	loader := func(ctx context.Context) ([]string, error) {
		close(loaderStarted)
		<-ctx.Done()
		return nil, ctx.Err()
	}
	result := make(chan error, 1)
	go func() {
		_, err := cache.load(context.Background(), loader)
		result <- err
	}()
	select {
	case <-loaderStarted:
	case <-time.After(time.Second):
		t.Fatal("namespace refresh did not start")
	}
	cache.close()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("closed refresh error = %v, want context.Canceled", err)
		}
	case <-time.After(time.Second):
		t.Fatal("closing namespace cache did not cancel refresh")
	}
	if _, err := cache.load(context.Background(), loader); !errors.Is(err, errNamespaceNameCacheClosed) {
		t.Fatalf("post-close load error = %v, want cache closed", err)
	}
}
