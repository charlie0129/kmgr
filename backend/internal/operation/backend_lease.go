package operation

import (
	"errors"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/object"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
)

// AcquiredMutationBackend keeps the Kubernetes authority used by one accepted
// mutation alive independently of its originating workspace. Release must be
// safe to call once after the operation reaches a terminal state.
type AcquiredMutationBackend struct {
	Backend     MutationBackend
	ContextName string
	Release     func()
}

// MutationBackendAcquirer atomically converts a live workspace session into
// independently leased mutation authority. Implementations must reject new
// acquisitions after the workspace lease has closed.
type MutationBackendAcquirer interface {
	AcquireMutationBackend(sessionID string) (AcquiredMutationBackend, error)
}

type staticMutationBackendAcquirer struct {
	backend MutationBackend
}

type mutationContextNameProvider interface {
	ContextName(sessionID string) (string, bool)
}

func (a staticMutationBackendAcquirer) AcquireMutationBackend(sessionID string) (AcquiredMutationBackend, error) {
	contextName := ""
	if provider, ok := a.backend.(mutationContextNameProvider); ok {
		contextName, _ = provider.ContextName(sessionID)
	}
	return AcquiredMutationBackend{
		Backend: a.backend, ContextName: contextName, Release: func() {},
	}, nil
}

// ClusterMutationBackendAcquirer is the production acquirer backed by the
// cluster session registry. The returned object reader resolves directly
// against the leased immutable session, so CloseWorkspace can hide the
// session from new work without invalidating an already accepted mutation.
type ClusterMutationBackendAcquirer struct {
	Sessions *cluster.SessionRegistry
}

func (a ClusterMutationBackendAcquirer) AcquireMutationBackend(
	sessionID string,
) (AcquiredMutationBackend, error) {
	if a.Sessions == nil {
		return AcquiredMutationBackend{}, object.ErrSessionNotFound
	}
	session, lease, ok := a.Sessions.Acquire(sessionID)
	if !ok {
		return AcquiredMutationBackend{}, object.ErrSessionNotFound
	}
	release := lease.Release
	if session.Dynamic() == nil {
		release()
		return AcquiredMutationBackend{}, errors.New("Kubernetes mutation client is unavailable")
	}
	reader, err := object.NewReader(leasedSessionResourceResolver{session: session})
	if err != nil {
		release()
		return AcquiredMutationBackend{}, err
	}
	return AcquiredMutationBackend{
		Backend: reader, ContextName: session.Context().Name, Release: release,
	}, nil
}

type leasedSessionResourceResolver struct {
	session *cluster.Session
}

func (r leasedSessionResourceResolver) Resource(
	sessionID string,
	gvr schema.GroupVersionResource,
	namespace string,
) (dynamic.ResourceInterface, error) {
	if r.session == nil || r.session.ID() != sessionID || r.session.Dynamic() == nil {
		return nil, object.ErrSessionNotFound
	}
	resource := r.session.Dynamic().Resource(gvr)
	if namespace == "" {
		return resource, nil
	}
	return resource.Namespace(namespace), nil
}

func (r leasedSessionResourceResolver) ContextName(sessionID string) (string, bool) {
	if r.session == nil || r.session.ID() != sessionID || r.session.Context().Name == "" {
		return "", false
	}
	return r.session.Context().Name, true
}
