// Package execstream owns Kubernetes remote-command lifecycles. It is named
// execstream because "exec" is awkward at call sites and easy to confuse with
// the standard os/exec package.
package execstream

import (
	"context"
	"errors"
	"fmt"
	"io"

	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"
)

var (
	ErrInvalidRequest      = errors.New("invalid exec request")
	ErrSessionNotFound     = errors.New("cluster session was not found")
	ErrStaleGeneration     = errors.New("exec generation is stale")
	ErrSessionClosed       = errors.New("exec session is closed")
	ErrTooManySessions     = errors.New("too many active exec sessions")
	ErrInputClosed         = errors.New("exec stdin is closed")
	ErrInputBackpressure   = errors.New("exec stdin queue is full")
	ErrOutputBackpressure  = errors.New("exec output queue is full")
	ErrExecutorUnavailable = errors.New("Kubernetes remote-command transport is unavailable")
)

type Identity struct {
	SessionID string
	Group     string
	Version   string
	Resource  string
	Namespace string
	Name      string
	UID       string
}

type StartRequest struct {
	SessionID     string
	ExecSessionID string
	Generation    uint64
	Pod           Identity
	Container     string
	Command       []string
	TTY           bool
	Stdin         bool
	InitialSize   *TerminalSize
}

type TerminalSize struct {
	Columns uint32
	Rows    uint32
}

type StreamKind uint8

const (
	StreamStdout StreamKind = iota + 1
	StreamStderr
)

type Output struct {
	Kind StreamKind
	Data []byte
}

type State uint8

const (
	StateConnecting State = iota + 1
	StateRunning
	StateExited
	StateCancelled
	StateFailed
)

type Status struct {
	State        State
	ExitCode     *int32
	StatusReason string
	Err          error
}

type Delivery struct {
	Output *Output
	Status *Status
}

type RunOptions struct {
	Stdin   io.Reader
	Stdout  io.Writer
	Stderr  io.Writer
	TTY     bool
	Resizes remotecommand.TerminalSizeQueue
	Started func()
}

type Runner interface {
	Run(context.Context, StartRequest, RunOptions) error
}

type ResolvedSession struct {
	ContextName string
	Runner      Runner
	Release     func()
}

type Resolver interface {
	Resolve(sessionID string) (ResolvedSession, error)
}

type ResolverFunc func(string) (ResolvedSession, error)

func (f ResolverFunc) Resolve(sessionID string) (ResolvedSession, error) {
	return f(sessionID)
}

type ExecutorFactory interface {
	New(*rest.Config, string) (remotecommand.Executor, error)
}

type ExecutorFactoryFunc func(*rest.Config, string) (remotecommand.Executor, error)

func (f ExecutorFactoryFunc) New(config *rest.Config, requestURL string) (remotecommand.Executor, error) {
	return f(config, requestURL)
}

type UIDMismatchError struct {
	Namespace string
	Name      string
	Expected  string
	Actual    string
}

func (e *UIDMismatchError) Error() string {
	return fmt.Sprintf("Pod %s/%s was replaced (expected UID %s, found %s)", e.Namespace, e.Name, e.Expected, e.Actual)
}

func validateStart(request StartRequest, maxCommandArguments, maxCommandBytes int) error {
	if request.SessionID == "" || request.ExecSessionID == "" || request.Generation == 0 {
		return fmt.Errorf("%w: session ID, exec session ID, and generation are required", ErrInvalidRequest)
	}
	if len(request.ExecSessionID) > 256 {
		return fmt.Errorf("%w: exec session ID is too long", ErrInvalidRequest)
	}
	identity := request.Pod
	if identity.SessionID != request.SessionID || identity.Group != "" || identity.Version != "v1" ||
		identity.Resource != "pods" || identity.Namespace == "" || identity.Name == "" || identity.UID == "" {
		return fmt.Errorf("%w: a complete v1 Pod identity in this session is required", ErrInvalidRequest)
	}
	if request.Container == "" || len(request.Container) > 253 {
		return fmt.Errorf("%w: a bounded container name is required", ErrInvalidRequest)
	}
	if len(request.Command) == 0 || len(request.Command) > maxCommandArguments {
		return fmt.Errorf("%w: command must have between 1 and %d arguments", ErrInvalidRequest, maxCommandArguments)
	}
	totalBytes := 0
	for _, argument := range request.Command {
		if argument == "" {
			return fmt.Errorf("%w: command arguments must not be empty", ErrInvalidRequest)
		}
		totalBytes += len(argument)
	}
	if totalBytes > maxCommandBytes {
		return fmt.Errorf("%w: command is too large", ErrInvalidRequest)
	}
	if request.InitialSize != nil {
		if !request.TTY || request.InitialSize.Columns == 0 || request.InitialSize.Rows == 0 ||
			request.InitialSize.Columns > 65535 || request.InitialSize.Rows > 65535 {
			return fmt.Errorf("%w: initial terminal size requires TTY and dimensions from 1 to 65535", ErrInvalidRequest)
		}
	}
	return nil
}
