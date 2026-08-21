package credentialexec

import (
	"io"
	"os"
	"os/exec"
	"sync"
	"time"
)

const processTerminationGrace = 500 * time.Millisecond

type supervisedCommand struct {
	command     string
	arguments   []string
	environment []string
	stdin       io.Reader
	timeout     time.Duration
	outputLimit int
	parentPID   int
	interrupt   <-chan os.Signal
}

type supervisedResult struct {
	stdout         []byte
	err            error
	startError     bool
	timedOut       bool
	parentExited   bool
	interrupted    bool
	outputTooLarge bool
}

func runSupervised(spec supervisedCommand) supervisedResult {
	command := exec.Command(spec.command, spec.arguments...)
	command.Env = spec.environment
	command.Stdin = spec.stdin
	command.Stderr = io.Discard
	output := &boundedOutput{limit: spec.outputLimit}
	command.Stdout = output
	// If a misbehaving descendant keeps the inherited stdout descriptor open
	// after the plugin process exits, bound the time Wait spends draining it.
	command.WaitDelay = processTerminationGrace
	configureProcessGroup(command)
	if err := command.Start(); err != nil {
		return supervisedResult{err: err, startError: true}
	}

	waited := make(chan error, 1)
	go func() { waited <- command.Wait() }()

	timer := time.NewTimer(spec.timeout)
	defer timer.Stop()
	var parentTicker *time.Ticker
	var parentTicks <-chan time.Time
	if spec.parentPID > 0 {
		parentTicker = time.NewTicker(250 * time.Millisecond)
		parentTicks = parentTicker.C
		defer parentTicker.Stop()
	}

	for {
		select {
		case err := <-waited:
			// The plugin's main process may deliberately or accidentally leave
			// background descendants behind. Once its result is complete, no
			// process from this credential invocation is allowed to outlive it.
			_ = killProcessGroup(command.Process.Pid)
			captured, exceeded := output.snapshot()
			return supervisedResult{
				stdout: captured, err: err, outputTooLarge: exceeded,
			}
		case <-timer.C:
			err := stopProcessGroup(command.Process.Pid, waited)
			captured, exceeded := output.snapshot()
			return supervisedResult{
				stdout: captured, err: err, timedOut: true,
				outputTooLarge: exceeded,
			}
		case <-parentTicks:
			if os.Getppid() == spec.parentPID {
				continue
			}
			err := stopProcessGroup(command.Process.Pid, waited)
			captured, exceeded := output.snapshot()
			return supervisedResult{
				stdout: captured, err: err, parentExited: true,
				outputTooLarge: exceeded,
			}
		case <-spec.interrupt:
			err := stopProcessGroup(command.Process.Pid, waited)
			captured, exceeded := output.snapshot()
			return supervisedResult{
				stdout: captured, err: err, interrupted: true,
				outputTooLarge: exceeded,
			}
		}
	}
}

func stopProcessGroup(processID int, waited <-chan error) error {
	_ = terminateProcessGroup(processID)
	timer := time.NewTimer(processTerminationGrace)
	defer timer.Stop()
	select {
	case err := <-waited:
		// The main process may exit while leaving descendants behind. SIGKILL
		// the original group even after Wait returns so those descendants do
		// not outlive the bounded credential operation.
		_ = killProcessGroup(processID)
		return err
	case <-timer.C:
		_ = killProcessGroup(processID)
		return <-waited
	}
}

type boundedOutput struct {
	mu       sync.Mutex
	data     []byte
	limit    int
	exceeded bool
}

func (w *boundedOutput) Write(data []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	limit := w.limit
	if limit < 0 {
		limit = 0
	}
	remaining := limit - len(w.data)
	if remaining > len(data) {
		remaining = len(data)
	}
	if remaining > 0 {
		w.data = append(w.data, data[:remaining]...)
	}
	if remaining < len(data) {
		w.exceeded = true
	}
	// Always report the full write so os/exec continues draining a noisy child
	// without retaining additional bytes.
	return len(data), nil
}

func (w *boundedOutput) snapshot() ([]byte, bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]byte(nil), w.data...), w.exceeded
}
