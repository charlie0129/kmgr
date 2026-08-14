// Package portforward owns app-wide Kubernetes port-forward lifecycles.
package portforward

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"

	"k8s.io/apimachinery/pkg/types"
)

var (
	ErrInvalidRequest        = errors.New("invalid port-forward request")
	ErrSessionNotFound       = errors.New("cluster session was not found")
	ErrPortForwardNotFound   = errors.New("port-forward was not found")
	ErrDuplicatePortForward  = errors.New("port-forward ID already exists")
	ErrTooManyPortForwards   = errors.New("too many active port-forwards")
	ErrNonLoopbackUnapproved = errors.New("non-loopback bind requires explicit approval")
	ErrPodRecreated          = errors.New("selected Pod was recreated")
	ErrServiceRecreated      = errors.New("selected Service was recreated")
	ErrNoEligiblePod         = errors.New("Service has no eligible backing Pod")
	ErrManagerClosed         = errors.New("port-forward manager is closed")
)

const (
	MaxPortForwardIDBytes    = 256
	MaxPortForwardLabelBytes = 512
	maxSessionIDBytes        = 256
	maxAPIGroupBytes         = 253
	maxAPIVersionBytes       = 63
	maxResourceBytes         = 253
	maxNamespaceBytes        = 253
	maxNameBytes             = 253
	maxUIDBytes              = 256
)

type Identity struct {
	SessionID string
	Group     string
	Version   string
	Resource  string
	Namespace string
	Name      string
	UID       types.UID
}

func (i Identity) Validate() error {
	if strings.TrimSpace(i.SessionID) == "" || strings.TrimSpace(i.Version) == "" ||
		strings.TrimSpace(i.Resource) == "" || strings.TrimSpace(i.Namespace) == "" ||
		strings.TrimSpace(i.Name) == "" || i.UID == "" {
		return fmt.Errorf("%w: a complete resource identity is required", ErrInvalidRequest)
	}
	fields := []struct {
		name  string
		value string
		limit int
	}{
		{"cluster session ID", i.SessionID, maxSessionIDBytes},
		{"API group", i.Group, maxAPIGroupBytes},
		{"API version", i.Version, maxAPIVersionBytes},
		{"resource", i.Resource, maxResourceBytes},
		{"namespace", i.Namespace, maxNamespaceBytes},
		{"name", i.Name, maxNameBytes},
		{"UID", string(i.UID), maxUIDBytes},
	}
	for _, field := range fields {
		if len(field.value) > field.limit {
			return fmt.Errorf("%w: %s exceeds %d bytes", ErrInvalidRequest, field.name, field.limit)
		}
	}
	return nil
}

func (i Identity) IsPod() bool {
	return i.Group == "" && i.Version == "v1" && i.Resource == "pods"
}

func (i Identity) IsService() bool {
	return i.Group == "" && i.Version == "v1" && i.Resource == "services"
}

type StartRequest struct {
	ID               string
	Target           Identity
	RemotePort       uint16
	LocalPort        uint16
	BindAddress      string
	Label            string
	AllowNonLoopback bool
}

func (r *StartRequest) normalize() error {
	if err := validatePortForwardID(r.ID); err != nil {
		return err
	}
	if r.RemotePort == 0 {
		return fmt.Errorf("%w: remote port is required", ErrInvalidRequest)
	}
	if len(r.Label) > MaxPortForwardLabelBytes {
		return fmt.Errorf("%w: label exceeds %d bytes", ErrInvalidRequest, MaxPortForwardLabelBytes)
	}
	if err := r.Target.Validate(); err != nil {
		return err
	}
	if !r.Target.IsPod() && !r.Target.IsService() {
		return fmt.Errorf("%w: target must be a Pod or Service", ErrInvalidRequest)
	}
	if r.BindAddress == "" {
		r.BindAddress = "127.0.0.1"
	}
	ip := net.ParseIP(r.BindAddress)
	if ip == nil {
		return fmt.Errorf("%w: bind address must be an IP address", ErrInvalidRequest)
	}
	if !ip.IsLoopback() && !r.AllowNonLoopback {
		return ErrNonLoopbackUnapproved
	}
	return nil
}

func validatePortForwardID(id string) error {
	if strings.TrimSpace(id) == "" {
		return fmt.Errorf("%w: port-forward ID is required", ErrInvalidRequest)
	}
	if len(id) > MaxPortForwardIDBytes {
		return fmt.Errorf("%w: port-forward ID exceeds %d bytes", ErrInvalidRequest, MaxPortForwardIDBytes)
	}
	return nil
}

type State uint8

const (
	StateStarting State = iota + 1
	StateListening
	StateReconnecting
	StateFailed
	StateStopped
)

type Snapshot struct {
	ID              string
	ContextName     string
	Target          Identity
	ResolvedPod     *Identity
	RemotePort      uint16
	LocalPort       uint16
	BindAddress     string
	Label           string
	NonLoopbackBind bool
	State           State
	StartedAt       time.Time
	UpdatedAt       time.Time
	LastError       error
}

type Session struct {
	ContextName string
	Resolver    TargetResolver
	Forwarder   Forwarder
	Release     func()
}

type SessionResolver interface {
	ResolveSession(sessionID string) (Session, error)
}

// TargetResolver performs fresh, authoritative resolution for every attempt.
type TargetResolver interface {
	Resolve(context.Context, Identity, uint16) (ResolvedTarget, error)
}

type ResolvedTarget struct {
	Pod        Identity
	RemotePort uint16
}

type ForwardRequest struct {
	Pod         Identity
	RemotePort  uint16
	LocalPort   uint16
	BindAddress string
}

type RunningForward interface {
	LocalPort() uint16
	Wait() error
	Close() error
}

// Forwarder must not return until the listener has been bound. A local port of
// zero is allocated by that bind itself, never by a check-then-bind probe.
type Forwarder interface {
	Start(context.Context, ForwardRequest) (RunningForward, error)
}

type Backoff interface {
	Wait(context.Context, int) error
}

type BackoffFunc func(context.Context, int) error

func (f BackoffFunc) Wait(ctx context.Context, attempt int) error { return f(ctx, attempt) }
