package logs

import (
	"bytes"
	"context"
	"errors"
	"io"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
)

type openerFunc func(context.Context, Source, corev1.PodLogOptions) (io.ReadCloser, error)

func (f openerFunc) Open(
	ctx context.Context,
	source Source,
	options corev1.PodLogOptions,
) (io.ReadCloser, error) {
	return f(ctx, source, options)
}

func testSource(id string) Source {
	return Source{
		Identity: Identity{
			SessionID: "session-1", Version: "v1", Resource: "pods",
			Namespace: "default", Name: "pod-" + id, UID: "uid-" + id,
		},
		ID: id, Label: "default/pod-" + id, Container: "main",
	}
}

func testManager(t *testing.T, opener SourceOpener, mutate func(*Config)) *Manager {
	t.Helper()
	config := Config{Resolver: ResolverFunc(func(sessionID string) (ResolvedSession, error) {
		if sessionID != "session-1" {
			return ResolvedSession{}, ErrSessionNotFound
		}
		return ResolvedSession{ContextName: "local", Opener: opener}, nil
	})}
	if mutate != nil {
		mutate(&config)
	}
	manager, err := NewManager(config)
	if err != nil {
		t.Fatalf("NewManager: %v", err)
	}
	t.Cleanup(manager.Close)
	return manager
}

func TestManagerMergesMultipleSourcesAndForwardsOptions(t *testing.T) {
	t.Parallel()
	var mu sync.Mutex
	captured := make(map[string]corev1.PodLogOptions)
	payloads := map[string][]byte{
		"alpha": []byte("a1\na2\n"),
		"beta":  {0xff, 0x00, '\n'},
	}
	opener := openerFunc(func(_ context.Context, source Source, options corev1.PodLogOptions) (io.ReadCloser, error) {
		mu.Lock()
		captured[source.ID] = options
		mu.Unlock()
		return io.NopCloser(bytes.NewReader(payloads[source.ID])), nil
	})
	manager := testManager(t, opener, nil)
	since := int64(60)
	tail := int64(25)
	limit := int64(4096)
	subscription, err := manager.Start(context.Background(), StartRequest{
		SessionID: "session-1", StreamID: "logs", Generation: 1,
		Sources: []Source{testSource("alpha"), testSource("beta")},
		Options: Options{
			Follow: true, Previous: true, Timestamps: true,
			SinceSeconds: &since, TailLines: &tail, ByteLimit: &limit,
		},
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer subscription.Close()

	records := collectUntilTerminal(t, subscription)
	bySource := make(map[string][]Record)
	for _, record := range records {
		bySource[record.SourceID] = append(bySource[record.SourceID], record)
	}
	if got := joinRecords(bySource["alpha"]); !bytes.Equal(got, []byte("a1a2")) {
		t.Fatalf("alpha payload = %q", got)
	}
	if len(bySource["alpha"]) != 2 || !bySource["alpha"][0].EndsWithNewline || !bySource["alpha"][1].EndsWithNewline {
		t.Fatalf("alpha record boundaries = %#v", bySource["alpha"])
	}
	if got := joinRecords(bySource["beta"]); !bytes.Equal(got, []byte{0xff, 0x00}) {
		t.Fatalf("beta payload = %v", got)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(captured) != 2 {
		t.Fatalf("opened sources = %d, want 2", len(captured))
	}
	for id, options := range captured {
		if options.Container != "main" || !options.Follow || !options.Previous || !options.Timestamps {
			t.Fatalf("options for %s = %#v", id, options)
		}
		if options.SinceSeconds == nil || *options.SinceSeconds != since ||
			options.TailLines == nil || *options.TailLines != tail ||
			options.LimitBytes == nil || *options.LimitBytes != limit {
			t.Fatalf("bounded options for %s = %#v", id, options)
		}
	}
}

func TestManagerCancellationClosesEverySource(t *testing.T) {
	t.Parallel()
	opened := make(chan *blockingReadCloser, 3)
	opener := openerFunc(func(_ context.Context, _ Source, _ corev1.PodLogOptions) (io.ReadCloser, error) {
		reader := newBlockingReadCloser()
		opened <- reader
		return reader, nil
	})
	manager := testManager(t, opener, nil)
	subscription, err := manager.Start(context.Background(), StartRequest{
		SessionID: "session-1", StreamID: "logs", Generation: 1,
		Sources: []Source{testSource("a"), testSource("b"), testSource("c")},
		Options: Options{Follow: true},
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer subscription.Close()
	readers := make([]*blockingReadCloser, 0, 3)
	for range 3 {
		select {
		case reader := <-opened:
			readers = append(readers, reader)
		case <-time.After(2 * time.Second):
			t.Fatal("not every source opened")
		}
	}
	if !manager.Cancel("session-1", "logs", 1) {
		t.Fatal("current generation cancellation was rejected")
	}
	for _, reader := range readers {
		select {
		case <-reader.closed:
		case <-time.After(2 * time.Second):
			t.Fatal("cancellation did not close a source reader")
		}
	}
	terminal := waitForTerminal(t, subscription)
	if terminal.State != StateCancelled {
		t.Fatalf("terminal state = %v, want cancelled", terminal.State)
	}
	subscription.Close()
	if manager.Active() != 0 {
		t.Fatalf("active subscriptions = %d after close", manager.Active())
	}
}

func TestSlowConsumerQueueIsBoundedByBytesAndRecords(t *testing.T) {
	t.Parallel()
	var payload bytes.Buffer
	for index := 0; index < 200; index++ {
		payload.WriteString("1234567\n")
	}
	opener := openerFunc(func(_ context.Context, _ Source, _ corev1.PodLogOptions) (io.ReadCloser, error) {
		return io.NopCloser(bytes.NewReader(payload.Bytes())), nil
	})
	manager := testManager(t, opener, func(config *Config) {
		config.QueueRecords = 4
		config.QueueBytes = 24
		config.MaxRecordBytes = 16
		config.BatchRecords = 2
		config.BatchBytes = 16
	})
	subscription, err := manager.Start(context.Background(), StartRequest{
		SessionID: "session-1", StreamID: "slow", Generation: 1,
		Sources: []Source{testSource("a")},
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer subscription.Close()
	waitFor(t, func() bool {
		subscription.operation.queue.mu.Lock()
		defer subscription.operation.queue.mu.Unlock()
		return subscription.operation.queue.terminal != nil
	}, "producer completion")
	stats := subscription.Stats()
	if stats.PeakQueuedRecords > 4 || stats.QueuedRecords > 4 {
		t.Fatalf("record bound exceeded: %#v", stats)
	}
	if stats.PeakQueuedBytes > 24 || stats.QueuedBytes > 24 {
		t.Fatalf("byte bound exceeded: %#v", stats)
	}
	if stats.DroppedRecords == 0 || stats.DroppedBytes == 0 {
		t.Fatalf("slow-consumer loss was not reported: %#v", stats)
	}

	terminal := waitForTerminal(t, subscription)
	if terminal.State != StateCompleted {
		t.Fatalf("terminal state = %v, want completed", terminal.State)
	}
	if terminal.DroppedRecords != stats.DroppedRecords || terminal.DroppedBytes != stats.DroppedBytes {
		t.Fatalf("terminal drops = %d/%d, stats = %d/%d",
			terminal.DroppedRecords, terminal.DroppedBytes, stats.DroppedRecords, stats.DroppedBytes)
	}
}

func TestStaleGenerationCannotStartOrCancelReplacement(t *testing.T) {
	t.Parallel()
	opened := make(chan struct {
		id     string
		reader *blockingReadCloser
	}, 2)
	opener := openerFunc(func(_ context.Context, source Source, _ corev1.PodLogOptions) (io.ReadCloser, error) {
		reader := newBlockingReadCloser()
		opened <- struct {
			id     string
			reader *blockingReadCloser
		}{id: source.ID, reader: reader}
		return reader, nil
	})
	manager := testManager(t, opener, nil)
	oldSubscription, err := manager.Start(context.Background(), StartRequest{
		SessionID: "session-1", StreamID: "same", Generation: 1,
		Sources: []Source{testSource("old")},
	})
	if err != nil {
		t.Fatalf("Start old: %v", err)
	}
	defer oldSubscription.Close()
	oldOpened := <-opened
	newSubscription, err := manager.Start(context.Background(), StartRequest{
		SessionID: "session-1", StreamID: "same", Generation: 2,
		Sources: []Source{testSource("new")},
	})
	if err != nil {
		t.Fatalf("Start replacement: %v", err)
	}
	defer newSubscription.Close()
	newOpened := <-opened
	if oldOpened.id != "old" || newOpened.id != "new" {
		t.Fatalf("open order = %q, %q", oldOpened.id, newOpened.id)
	}
	select {
	case <-oldOpened.reader.closed:
	case <-time.After(2 * time.Second):
		t.Fatal("replacement did not cancel the old generation")
	}

	var wait sync.WaitGroup
	for range 64 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			if manager.Cancel("session-1", "same", 1) {
				t.Error("stale cancellation was accepted")
			}
		}()
	}
	wait.Wait()
	select {
	case <-newOpened.reader.closed:
		t.Fatal("stale cancellation stopped the replacement")
	default:
	}
	if _, err := manager.Start(context.Background(), StartRequest{
		SessionID: "session-1", StreamID: "same", Generation: 1,
		Sources: []Source{testSource("stale")},
	}); !errors.Is(err, ErrStaleGeneration) {
		t.Fatalf("stale Start error = %v", err)
	}
	if !manager.Cancel("session-1", "same", 2) {
		t.Fatal("replacement cancellation was rejected")
	}
	select {
	case <-newOpened.reader.closed:
	case <-time.After(2 * time.Second):
		t.Fatal("replacement reader was not closed")
	}
	if status := waitForTerminal(t, oldSubscription); status.State != StateCancelled {
		t.Fatalf("old state = %v", status.State)
	}
	if status := waitForTerminal(t, newSubscription); status.State != StateCancelled {
		t.Fatalf("new state = %v", status.State)
	}
}

type blockingReadCloser struct {
	once   sync.Once
	closed chan struct{}
}

func newBlockingReadCloser() *blockingReadCloser {
	return &blockingReadCloser{closed: make(chan struct{})}
}

func (r *blockingReadCloser) Read(_ []byte) (int, error) {
	<-r.closed
	return 0, io.ErrClosedPipe
}

func (r *blockingReadCloser) Close() error {
	r.once.Do(func() { close(r.closed) })
	return nil
}

func collectUntilTerminal(t *testing.T, subscription *Subscription) []Record {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	var records []Record
	for {
		delivery, err := subscription.Next(ctx)
		if err != nil {
			t.Fatalf("Next: %v", err)
		}
		records = append(records, delivery.Records...)
		if delivery.Status != nil && delivery.Status.SourceID == "" && isTerminal(delivery.Status.State) {
			return records
		}
	}
}

func waitForTerminal(t *testing.T, subscription *Subscription) Status {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	for {
		delivery, err := subscription.Next(ctx)
		if err != nil {
			t.Fatalf("Next: %v", err)
		}
		if delivery.Status != nil && delivery.Status.SourceID == "" && isTerminal(delivery.Status.State) {
			return *delivery.Status
		}
	}
}

func joinRecords(records []Record) []byte {
	var result []byte
	for _, record := range records {
		result = append(result, record.Data...)
	}
	return result
}

func waitFor(t *testing.T, condition func() bool, description string) {
	t.Helper()
	deadline := time.NewTimer(3 * time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	for {
		if condition() {
			return
		}
		select {
		case <-deadline.C:
			t.Fatalf("timed out waiting for %s", description)
		case <-ticker.C:
		}
	}
}
