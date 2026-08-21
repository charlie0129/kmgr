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
	ErrInvalidRequest              = errors.New("invalid exec request")
	ErrSessionNotFound             = errors.New("cluster session was not found")
	ErrStaleGeneration             = errors.New("exec generation is stale")
	ErrSessionClosed               = errors.New("exec session is closed")
	ErrTooManySessions             = errors.New("too many active exec sessions")
	ErrInputClosed                 = errors.New("exec stdin is closed")
	ErrInputBackpressure           = errors.New("exec stdin queue is full")
	ErrExecutorUnavailable         = errors.New("Kubernetes remote-command transport is unavailable")
	ErrWindowsNodeShellUnsupported = errors.New("Windows node shell is not supported")
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

type PodTarget struct {
	Pod       Identity
	Container string
}

type NodeShellTarget struct {
	Node      Identity
	Namespace string
	Image     string
}

type StartRequest struct {
	SessionID     string
	ExecSessionID string
	Generation    uint64
	Pod           *PodTarget
	NodeShell     *NodeShellTarget
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
	State              State
	ExitCode           *int32
	StatusReason       string
	Err                error
	DroppedOutputItems uint64
	DroppedOutputBytes uint64
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

type ExecutorFactory interface {
	New(*rest.Config, string, func()) (remotecommand.Executor, error)
}

type UIDMismatchError struct {
	Namespace string
	Name      string
	Expected  string
	Actual    string
}

type NodeUIDMismatchError struct {
	Name     string
	Expected string
	Actual   string
}

func (e *NodeUIDMismatchError) Error() string {
	return fmt.Sprintf("Node %s was replaced (expected UID %s, found %s)", e.Name, e.Expected, e.Actual)
}

type NodeShellPodStartError struct {
	Reason string
}

func (e *NodeShellPodStartError) Error() string {
	return fmt.Sprintf("node shell helper Pod could not start (%s)", e.Reason)
}

type NodeShellPodReplacedError struct {
	Name string
}

func (e *NodeShellPodReplacedError) Error() string {
	return fmt.Sprintf("node shell helper Pod %s was replaced", e.Name)
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
	if (request.Pod == nil) == (request.NodeShell == nil) {
		return fmt.Errorf("%w: exactly one Pod exec or Node shell target is required", ErrInvalidRequest)
	}
	if request.Pod != nil {
		identity := request.Pod.Pod
		if identity.SessionID != request.SessionID || identity.Group != "" || identity.Version != "v1" ||
			identity.Resource != "pods" || identity.Namespace == "" || identity.Name == "" || identity.UID == "" {
			return fmt.Errorf("%w: a complete v1 Pod identity in this session is required", ErrInvalidRequest)
		}
		if request.Pod.Container == "" || len(request.Pod.Container) > 253 {
			return fmt.Errorf("%w: a bounded container name is required", ErrInvalidRequest)
		}
	} else {
		identity := request.NodeShell.Node
		if identity.SessionID != request.SessionID || identity.Group != "" || identity.Version != "v1" ||
			identity.Resource != "nodes" || identity.Namespace != "" || identity.Name == "" || identity.UID == "" {
			return fmt.Errorf("%w: a complete v1 Node identity in this session is required", ErrInvalidRequest)
		}
		if !validNamespace(request.NodeShell.Namespace) {
			return fmt.Errorf("%w: a valid helper Pod namespace is required", ErrInvalidRequest)
		}
		if !validImageReference(request.NodeShell.Image) {
			return fmt.Errorf("%w: a bounded helper image reference is required", ErrInvalidRequest)
		}
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

func (r StartRequest) targetIdentity() Identity {
	if r.Pod != nil {
		return r.Pod.Pod
	}
	if r.NodeShell != nil {
		return r.NodeShell.Node
	}
	return Identity{}
}

func validNamespace(value string) bool {
	if len(value) == 0 || len(value) > 63 || value[0] == '-' || value[len(value)-1] == '-' {
		return false
	}
	for _, character := range value {
		if (character >= 'a' && character <= 'z') ||
			(character >= '0' && character <= '9') || character == '-' {
			continue
		}
		return false
	}
	return true
}

func validImageReference(value string) bool {
	if len(value) == 0 || len(value) > 1_024 {
		return false
	}
	for _, character := range value {
		if character <= ' ' || character == 0x7f {
			return false
		}
	}
	return true
}
