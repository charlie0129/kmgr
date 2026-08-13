package logs

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	coreclient "k8s.io/client-go/kubernetes/typed/core/v1"
)

var (
	ErrInvalidRequest       = errors.New("invalid log stream request")
	ErrSessionNotFound      = errors.New("cluster session was not found")
	ErrStaleGeneration      = errors.New("log stream generation is stale")
	ErrStreamClosed         = errors.New("log stream is closed")
	ErrTooManyStreams       = errors.New("too many active log streams")
	ErrLogClientUnavailable = errors.New("Kubernetes Pod log client is unavailable")
)

// Identity is the immutable Pod identity captured when the log window opens.
// Namespace/name locates the log subresource; UID prevents silently attaching
// to a same-name replacement Pod.
type Identity struct {
	SessionID string
	Group     string
	Version   string
	Resource  string
	Namespace string
	Name      string
	UID       string
}

type Source struct {
	Identity  Identity
	ID        string
	Label     string
	Container string
}

type Options struct {
	Follow       bool
	Previous     bool
	Timestamps   bool
	SinceTime    *time.Time
	SinceSeconds *int64
	TailLines    *int64
	ByteLimit    *int64
}

func (o Options) podLogOptions(container string) corev1.PodLogOptions {
	result := corev1.PodLogOptions{
		Container: container,
		Follow:    o.Follow, Previous: o.Previous, Timestamps: o.Timestamps,
	}
	if o.SinceTime != nil {
		value := metav1.NewTime(*o.SinceTime)
		result.SinceTime = &value
	}
	if o.SinceSeconds != nil {
		value := *o.SinceSeconds
		result.SinceSeconds = &value
	}
	if o.TailLines != nil {
		value := *o.TailLines
		result.TailLines = &value
	}
	if o.ByteLimit != nil {
		value := *o.ByteLimit
		result.LimitBytes = &value
	}
	return result
}

type StartRequest struct {
	SessionID  string
	StreamID   string
	Generation uint64
	Sources    []Source
	Options    Options
}

type Record struct {
	SourceID        string
	Data            []byte
	Timestamp       time.Time
	EndsWithNewline bool
}

type State uint8

const (
	StateConnecting State = iota + 1
	StateStreaming
	StateCompleted
	StateCancelled
	StateFailed
)

type Status struct {
	State          State
	SourceID       string
	Source         *Source
	DroppedRecords uint64
	DroppedBytes   uint64
	Err            error
}

type Delivery struct {
	Records    []Record
	TotalBytes uint64
	Status     *Status
}

// SourceOpener abstracts exactly the client-go Pod log operation needed by
// the stream manager, keeping lifecycle and backpressure tests deterministic.
type SourceOpener interface {
	Open(context.Context, Source, corev1.PodLogOptions) (io.ReadCloser, error)
}

type ResolvedSession struct {
	ContextName string
	Opener      SourceOpener
}

type Resolver interface {
	Resolve(sessionID string) (ResolvedSession, error)
}

type ResolverFunc func(string) (ResolvedSession, error)

func (f ResolverFunc) Resolve(sessionID string) (ResolvedSession, error) {
	return f(sessionID)
}

// ClientGoSource opens a Pod log subresource using the typed client-go API.
// Kubernetes does not offer a UID precondition for this subresource, so it
// verifies the current Pod UID immediately before opening the request.
type ClientGoSource struct {
	Core coreclient.CoreV1Interface
}

func (c ClientGoSource) Open(
	ctx context.Context,
	source Source,
	options corev1.PodLogOptions,
) (io.ReadCloser, error) {
	if c.Core == nil {
		return nil, ErrLogClientUnavailable
	}
	pods := c.Core.Pods(source.Identity.Namespace)
	pod, err := pods.Get(ctx, source.Identity.Name, metav1.GetOptions{})
	if err != nil {
		return nil, err
	}
	if string(pod.UID) != source.Identity.UID {
		return nil, &UIDMismatchError{
			Namespace: source.Identity.Namespace,
			Name:      source.Identity.Name,
			Expected:  source.Identity.UID,
			Actual:    string(pod.UID),
		}
	}
	return pods.GetLogs(source.Identity.Name, &options).Stream(ctx)
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

func (e *UIDMismatchError) Is(target error) bool {
	_, ok := target.(*UIDMismatchError)
	return ok
}

func validateStart(request StartRequest, maxSources int) error {
	if request.SessionID == "" || request.StreamID == "" || request.Generation == 0 {
		return fmt.Errorf("%w: session ID, stream ID, and generation are required", ErrInvalidRequest)
	}
	if len(request.StreamID) > 256 {
		return fmt.Errorf("%w: stream ID is too long", ErrInvalidRequest)
	}
	if len(request.Sources) == 0 || len(request.Sources) > maxSources {
		return fmt.Errorf("%w: source count must be between 1 and %d", ErrInvalidRequest, maxSources)
	}
	seen := make(map[string]struct{}, len(request.Sources))
	for _, source := range request.Sources {
		identity := source.Identity
		if source.ID == "" || len(source.ID) > 256 {
			return fmt.Errorf("%w: every source needs a bounded source ID", ErrInvalidRequest)
		}
		if _, exists := seen[source.ID]; exists {
			return fmt.Errorf("%w: duplicate source ID %q", ErrInvalidRequest, source.ID)
		}
		seen[source.ID] = struct{}{}
		if len(source.Label) > 512 || len(source.Container) > 253 {
			return fmt.Errorf("%w: source label or container is too long", ErrInvalidRequest)
		}
		if identity.SessionID != request.SessionID || identity.Group != "" || identity.Version != "v1" ||
			identity.Resource != "pods" || identity.Namespace == "" || identity.Name == "" || identity.UID == "" {
			return fmt.Errorf("%w: source %q must be a complete v1 Pod identity in this session", ErrInvalidRequest, source.ID)
		}
	}
	if request.Options.SinceTime != nil && request.Options.SinceSeconds != nil {
		return fmt.Errorf("%w: since time and since seconds are mutually exclusive", ErrInvalidRequest)
	}
	if request.Options.SinceSeconds != nil && *request.Options.SinceSeconds <= 0 {
		return fmt.Errorf("%w: since seconds must be positive", ErrInvalidRequest)
	}
	if request.Options.TailLines != nil && *request.Options.TailLines < -1 {
		return fmt.Errorf("%w: tail lines must be -1 or greater", ErrInvalidRequest)
	}
	if request.Options.ByteLimit != nil && *request.Options.ByteLimit <= 0 {
		return fmt.Errorf("%w: byte limit must be positive", ErrInvalidRequest)
	}
	return nil
}
