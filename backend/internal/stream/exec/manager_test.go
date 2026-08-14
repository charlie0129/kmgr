package execstream

import (
	"bytes"
	"context"
	"errors"
	"io"
	"sync"
	"testing"
	"time"

	"k8s.io/client-go/tools/remotecommand"
	utilexec "k8s.io/client-go/util/exec"
)

type runnerFunc func(context.Context, StartRequest, RunOptions) error

func (f runnerFunc) Run(ctx context.Context, request StartRequest, options RunOptions) error {
	return f(ctx, request, options)
}

func testStart(generation uint64) StartRequest {
	return StartRequest{
		SessionID: "cluster-session", ExecSessionID: "terminal", Generation: generation,
		Pod: Identity{
			SessionID: "cluster-session", Version: "v1", Resource: "pods",
			Namespace: "default", Name: "api-0", UID: "pod-uid",
		},
		Container: "main", Command: []string{"/bin/sh"}, TTY: true, Stdin: true,
		InitialSize: &TerminalSize{Columns: 80, Rows: 24},
	}
}

func testManager(t *testing.T, runner Runner, mutate func(*Config)) *Manager {
	t.Helper()
	config := Config{Resolver: ResolverFunc(func(sessionID string) (ResolvedSession, error) {
		if sessionID != "cluster-session" {
			return ResolvedSession{}, ErrSessionNotFound
		}
		return ResolvedSession{ContextName: "local", Runner: runner}, nil
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

func TestManagerCarriesStdinAndDistinctOutputs(t *testing.T) {
	t.Parallel()
	var capturedRequest StartRequest
	runner := runnerFunc(func(_ context.Context, request StartRequest, options RunOptions) error {
		capturedRequest = request
		if options.Started != nil {
			options.Started()
		}
		stdin, err := io.ReadAll(options.Stdin)
		if err != nil || !bytes.Equal(stdin, []byte{0xff, 0x00, 'x'}) {
			t.Errorf("stdin = %v, %v", stdin, err)
		}
		if _, err := options.Stdout.Write([]byte("out")); err != nil {
			return err
		}
		if options.Stderr == nil {
			t.Error("non-TTY stderr writer is nil")
		} else if _, err := options.Stderr.Write([]byte("err")); err != nil {
			return err
		}
		return nil
	})
	manager := testManager(t, runner, nil)
	request := testStart(1)
	request.TTY = false
	request.InitialSize = nil
	session, err := manager.Start(context.Background(), request)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer session.Close()
	if err := session.SendStdin([]byte{0xff, 0x00, 'x'}); err != nil {
		t.Fatalf("SendStdin: %v", err)
	}
	if err := session.Resize(TerminalSize{Columns: 120, Rows: 40}); !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("non-TTY resize error = %v", err)
	}
	session.CloseStdin()

	deliveries := collectTerminal(t, session)
	var stdout, stderr []byte
	var states []State
	for _, delivery := range deliveries {
		if delivery.Output != nil {
			if delivery.Output.Kind == StreamStderr {
				stderr = append(stderr, delivery.Output.Data...)
			} else {
				stdout = append(stdout, delivery.Output.Data...)
			}
		}
		if delivery.Status != nil {
			states = append(states, delivery.Status.State)
		}
	}
	if string(stdout) != "out" || string(stderr) != "err" {
		t.Fatalf("output = stdout %q stderr %q", stdout, stderr)
	}
	if !containsState(states, StateConnecting) || !containsState(states, StateRunning) || !containsState(states, StateExited) {
		t.Fatalf("states = %v", states)
	}
	if capturedRequest.Container != "main" || capturedRequest.Command[0] != "/bin/sh" {
		t.Fatalf("request = %#v", capturedRequest)
	}
}

func TestTTYNeverReceivesSeparateStderr(t *testing.T) {
	t.Parallel()
	initialSizeRead := make(chan struct{})
	runner := runnerFunc(func(_ context.Context, _ StartRequest, options RunOptions) error {
		if options.Stderr != nil {
			t.Fatal("TTY mode exposed a separate stderr stream")
		}
		if options.Started != nil {
			options.Started()
		}
		firstSize := options.Resizes.Next()
		close(initialSizeRead)
		secondSize := options.Resizes.Next()
		if firstSize == nil || firstSize.Width != 80 || firstSize.Height != 24 ||
			secondSize == nil || secondSize.Width != 120 || secondSize.Height != 40 {
			t.Errorf("terminal sizes = %#v, %#v", firstSize, secondSize)
		}
		_, err := options.Stdout.Write([]byte("terminal"))
		return err
	})
	manager := testManager(t, runner, nil)
	session, err := manager.Start(context.Background(), testStart(1))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer session.Close()
	select {
	case <-initialSizeRead:
	case <-time.After(2 * time.Second):
		t.Fatal("runner did not receive initial terminal size")
	}
	if err := session.Resize(TerminalSize{Columns: 120, Rows: 40}); err != nil {
		t.Fatalf("Resize: %v", err)
	}
	deliveries := collectTerminal(t, session)
	for _, delivery := range deliveries {
		if delivery.Output != nil && delivery.Output.Kind == StreamStderr {
			t.Fatal("TTY emitted stderr")
		}
	}
}

func TestOutputBackpressureIsBoundedAndTerminatesSession(t *testing.T) {
	t.Parallel()
	release := make(chan struct{})
	runner := runnerFunc(func(_ context.Context, _ StartRequest, options RunOptions) error {
		if options.Started != nil {
			options.Started()
		}
		<-release
		_, err := options.Stdout.Write([]byte("0123456789abcdef"))
		return err
	})
	manager := testManager(t, runner, func(config *Config) {
		config.OutputItems = 2
		config.OutputBytes = 8
		config.OutputChunkBytes = 4
	})
	session, err := manager.Start(context.Background(), testStart(1))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer session.Close()
	close(release)
	waitFor(t, func() bool {
		session.operation.output.mu.Lock()
		defer session.operation.output.mu.Unlock()
		return session.operation.output.terminal != nil
	}, "output failure")
	stats := session.Stats()
	if stats.PeakItems > 2 || stats.PeakBytes > 8 {
		t.Fatalf("output queue exceeded bounds: %#v", stats)
	}
	deliveries := collectTerminal(t, session)
	terminal := deliveries[len(deliveries)-1].Status
	if terminal == nil || terminal.State != StateFailed || terminal.StatusReason != "OutputBackpressure" ||
		!errors.Is(terminal.Err, ErrOutputBackpressure) {
		t.Fatalf("terminal status = %#v", terminal)
	}
}

func TestCancellationAndStaleGenerationIsolation(t *testing.T) {
	t.Parallel()
	type running struct {
		generation uint64
		done       chan struct{}
	}
	started := make(chan running, 2)
	runner := runnerFunc(func(ctx context.Context, request StartRequest, options RunOptions) error {
		if options.Started != nil {
			options.Started()
		}
		done := make(chan struct{})
		started <- running{generation: request.Generation, done: done}
		<-ctx.Done()
		close(done)
		return ctx.Err()
	})
	manager := testManager(t, runner, nil)
	oldSession, err := manager.Start(context.Background(), testStart(1))
	if err != nil {
		t.Fatalf("Start old: %v", err)
	}
	defer oldSession.Close()
	oldRun := <-started
	newSession, err := manager.Start(context.Background(), testStart(2))
	if err != nil {
		t.Fatalf("Start replacement: %v", err)
	}
	defer newSession.Close()
	newRun := <-started
	if oldRun.generation != 1 || newRun.generation != 2 {
		t.Fatalf("generations = %d, %d", oldRun.generation, newRun.generation)
	}
	select {
	case <-oldRun.done:
	case <-time.After(2 * time.Second):
		t.Fatal("replacement did not cancel old generation")
	}

	var wait sync.WaitGroup
	for range 64 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			if manager.Cancel("cluster-session", "terminal", 1) {
				t.Error("stale cancellation was accepted")
			}
		}()
	}
	wait.Wait()
	select {
	case <-newRun.done:
		t.Fatal("stale cancel stopped replacement")
	default:
	}
	if _, err := manager.Start(context.Background(), testStart(2)); !errors.Is(err, ErrStaleGeneration) {
		t.Fatalf("stale start error = %v", err)
	}
	if !manager.Cancel("cluster-session", "terminal", 2) {
		t.Fatal("current cancellation was rejected")
	}
	select {
	case <-newRun.done:
	case <-time.After(2 * time.Second):
		t.Fatal("current cancel did not stop runner")
	}
	if terminal := lastTerminal(t, oldSession); terminal.State != StateCancelled {
		t.Fatalf("old terminal = %#v", terminal)
	}
	if terminal := lastTerminal(t, newSession); terminal.State != StateCancelled {
		t.Fatalf("new terminal = %#v", terminal)
	}
}

func TestManagerReleasesResolvedSessionOnFailureAndTermination(t *testing.T) {
	t.Parallel()
	var mu sync.Mutex
	acquired := 0
	released := 0
	runner := runnerFunc(func(ctx context.Context, _ StartRequest, options RunOptions) error {
		if options.Started != nil {
			options.Started()
		}
		<-ctx.Done()
		return ctx.Err()
	})
	resolver := ResolverFunc(func(string) (ResolvedSession, error) {
		mu.Lock()
		acquired++
		mu.Unlock()
		return ResolvedSession{ContextName: "local", Runner: runner, Release: func() {
			mu.Lock()
			released++
			mu.Unlock()
		}}, nil
	})
	manager, err := NewManager(Config{Resolver: resolver, MaxSessions: 1})
	if err != nil {
		t.Fatal(err)
	}
	first, err := manager.Start(context.Background(), testStart(1))
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	if _, err := manager.Start(context.Background(), testStart(1)); !errors.Is(err, ErrStaleGeneration) {
		t.Fatalf("stale Start error = %v", err)
	}
	full := testStart(1)
	full.ExecSessionID = "another"
	if _, err := manager.Start(context.Background(), full); !errors.Is(err, ErrTooManySessions) {
		t.Fatalf("capacity Start error = %v", err)
	}
	mu.Lock()
	if acquired != 1 || released != 0 {
		t.Fatalf("before termination acquired/released = %d/%d, want 1/0", acquired, released)
	}
	mu.Unlock()
	manager.Close()
	if terminal := lastTerminal(t, first); terminal.State != StateCancelled {
		t.Fatalf("terminal = %#v", terminal)
	}
	waitFor(t, func() bool {
		mu.Lock()
		defer mu.Unlock()
		return released == 1
	}, "active session lease release")
	first.Close()
	mu.Lock()
	defer mu.Unlock()
	if released != 1 {
		t.Fatalf("session close released lease again: %d", released)
	}
}

func TestManagerRetainsAuthorityForReconnectAfterWorkspaceClose(t *testing.T) {
	t.Parallel()
	var mu sync.Mutex
	workspaceOpen := true
	resolveCalls := 0
	releases := 0
	runner := runnerFunc(func(_ context.Context, _ StartRequest, options RunOptions) error {
		if options.Started != nil {
			options.Started()
		}
		return nil
	})
	resolver := ResolverFunc(func(string) (ResolvedSession, error) {
		mu.Lock()
		defer mu.Unlock()
		resolveCalls++
		if !workspaceOpen {
			return ResolvedSession{}, ErrSessionNotFound
		}
		return ResolvedSession{
			ContextName: "local",
			Runner:      runner,
			Release: func() {
				mu.Lock()
				releases++
				mu.Unlock()
			},
		}, nil
	})
	manager, err := NewManager(Config{Resolver: resolver, MaxSessions: 1})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(manager.Close)

	first, err := manager.Start(context.Background(), testStart(1))
	if err != nil {
		t.Fatal(err)
	}
	if terminal := lastTerminal(t, first); terminal.State != StateExited {
		t.Fatalf("first terminal = %#v", terminal)
	}
	mu.Lock()
	workspaceOpen = false
	mu.Unlock()

	second, err := manager.Start(context.Background(), testStart(2))
	if err != nil {
		t.Fatalf("replacement after workspace close: %v", err)
	}
	if terminal := lastTerminal(t, second); terminal.State != StateExited {
		t.Fatalf("second terminal = %#v", terminal)
	}
	mu.Lock()
	if resolveCalls != 1 || releases != 0 {
		t.Fatalf("before close resolve/release calls = %d/%d, want 1/0", resolveCalls, releases)
	}
	mu.Unlock()

	first.Close()
	mu.Lock()
	if releases != 0 {
		t.Fatalf("first close released authority still used by replacement: %d", releases)
	}
	mu.Unlock()
	second.Close()
	waitFor(t, func() bool {
		mu.Lock()
		defer mu.Unlock()
		return releases == 1
	}, "shared retained exec authority release")
}

func TestExitCodeIsPreserved(t *testing.T) {
	t.Parallel()
	runner := runnerFunc(func(_ context.Context, _ StartRequest, options RunOptions) error {
		if options.Started != nil {
			options.Started()
		}
		return utilexec.CodeExitError{Err: errors.New("command exited"), Code: 37}
	})
	manager := testManager(t, runner, nil)
	session, err := manager.Start(context.Background(), testStart(1))
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer session.Close()
	terminal := lastTerminal(t, session)
	if terminal.State != StateExited || terminal.ExitCode == nil || *terminal.ExitCode != 37 || terminal.Err != nil {
		t.Fatalf("terminal = %#v", terminal)
	}
}

func TestInputPipeBackpressureAndClose(t *testing.T) {
	t.Parallel()
	pipe := newInputPipe(2, 5)
	if err := pipe.Send([]byte("abc")); err != nil {
		t.Fatalf("Send first: %v", err)
	}
	if err := pipe.Send([]byte("de")); err != nil {
		t.Fatalf("Send second: %v", err)
	}
	if err := pipe.Send([]byte("f")); !errors.Is(err, ErrInputBackpressure) {
		t.Fatalf("overflow error = %v", err)
	}
	pipe.Close()
	data, err := io.ReadAll(pipe)
	if err != nil || string(data) != "abcde" {
		t.Fatalf("ReadAll = %q, %v", data, err)
	}
	if err := pipe.Send([]byte("x")); !errors.Is(err, ErrInputClosed) {
		t.Fatalf("send after close = %v", err)
	}
}

func TestResizeQueueCoalescesLatestDimensions(t *testing.T) {
	t.Parallel()
	queue := newResizeQueue(nil)
	if err := queue.Send(TerminalSize{Columns: 80, Rows: 24}); err != nil {
		t.Fatalf("Send first: %v", err)
	}
	if err := queue.Send(TerminalSize{Columns: 132, Rows: 50}); err != nil {
		t.Fatalf("Send second: %v", err)
	}
	if got := queue.Next(); got == nil || got.Width != 132 || got.Height != 50 {
		t.Fatalf("coalesced size = %#v", got)
	}
	queue.Close()
	if got := queue.Next(); got != nil {
		t.Fatalf("size after close = %#v", got)
	}
}

func collectTerminal(t *testing.T, session *Session) []Delivery {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	var deliveries []Delivery
	for {
		delivery, err := session.Next(ctx)
		if err != nil {
			t.Fatalf("Next: %v", err)
		}
		deliveries = append(deliveries, delivery)
		if delivery.Status != nil && isTerminal(delivery.Status.State) {
			return deliveries
		}
	}
}

func lastTerminal(t *testing.T, session *Session) Status {
	t.Helper()
	deliveries := collectTerminal(t, session)
	return *deliveries[len(deliveries)-1].Status
}

func containsState(states []State, target State) bool {
	for _, state := range states {
		if state == target {
			return true
		}
	}
	return false
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

var _ remotecommand.TerminalSizeQueue = (*resizeQueue)(nil)
