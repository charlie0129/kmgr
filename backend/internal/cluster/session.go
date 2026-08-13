package cluster

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"sync"

	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/discovery/cached/memory"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/restmapper"
)

const (
	DefaultClientQPS   = 40
	DefaultClientBurst = 80
)

type BackendClients struct {
	Dynamic   dynamic.Interface
	Discovery discovery.DiscoveryInterface
	Mapper    meta.ResettableRESTMapper
	Close     func()
}

type ClientFactory interface {
	New(*rest.Config) (BackendClients, error)
}

type DefaultClientFactory struct{}

func (DefaultClientFactory) New(config *rest.Config) (BackendClients, error) {
	httpClient, err := rest.HTTPClientFor(config)
	if err != nil {
		return BackendClients{}, fmt.Errorf("construct Kubernetes HTTP client: %w", err)
	}
	dynamicClient, err := dynamic.NewForConfigAndClient(config, httpClient)
	if err != nil {
		closeHTTPClient(httpClient)
		return BackendClients{}, fmt.Errorf("construct Kubernetes dynamic client: %w", err)
	}
	discoveryClient, err := discovery.NewDiscoveryClientForConfigAndClient(config, httpClient)
	if err != nil {
		closeHTTPClient(httpClient)
		return BackendClients{}, fmt.Errorf("construct Kubernetes discovery client: %w", err)
	}
	mapper := restmapper.NewDeferredDiscoveryRESTMapper(memory.NewMemCacheClient(discoveryClient))
	return BackendClients{
		Dynamic:   dynamicClient,
		Discovery: discoveryClient,
		Mapper:    mapper,
		Close:     func() { closeHTTPClient(httpClient) },
	}, nil
}

func closeHTTPClient(client *http.Client) {
	if client == nil {
		return
	}
	if closer, ok := client.Transport.(interface{ CloseIdleConnections() }); ok {
		closer.CloseIdleConnections()
	}
}

type SessionRegistry struct {
	mu       sync.RWMutex
	factory  ClientFactory
	qps      float32
	burst    int
	sessions map[string]*Session
	backends map[backendKey]*sharedBackend
}

type backendKey struct {
	catalog   *Catalog
	contextID string
}

type sharedBackend struct {
	clients BackendClients
	refs    int
}

// Session is the immutable cluster identity exposed to one workspace window.
// More than one Session may share its underlying Kubernetes clients and
// watcher authority while retaining distinct IDs and independent UI state.
type Session struct {
	id      string
	context ContextInfo
	key     backendKey
	backend *sharedBackend
}

func NewSessionRegistry(factory ClientFactory) *SessionRegistry {
	if factory == nil {
		factory = DefaultClientFactory{}
	}
	return &SessionRegistry{
		factory:  factory,
		qps:      DefaultClientQPS,
		burst:    DefaultClientBurst,
		sessions: make(map[string]*Session),
		backends: make(map[backendKey]*sharedBackend),
	}
}

func (r *SessionRegistry) SetRateLimit(qps float32, burst int) error {
	if qps <= 0 || burst <= 0 {
		return errors.New("Kubernetes rate limits must be positive")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.sessions) != 0 {
		return errors.New("cannot change Kubernetes rate limits while sessions are open")
	}
	r.qps = qps
	r.burst = burst
	return nil
}

func (r *SessionRegistry) Open(catalog *Catalog, contextReference string) (*Session, error) {
	if catalog == nil {
		return nil, errors.New("kubeconfig catalog must not be nil")
	}
	contextInfo, ok := catalog.Context(contextReference)
	if !ok {
		return nil, &ContextNotFoundError{Reference: contextReference}
	}
	config, err := catalog.RESTConfig(contextReference)
	if err != nil {
		return nil, err
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	config = rest.CopyConfig(config)
	config.QPS = r.qps
	config.Burst = r.burst
	config.UserAgent = "kmgr-engine"

	key := backendKey{catalog: catalog, contextID: contextInfo.ID}
	backend := r.backends[key]
	if backend == nil {
		clients, err := r.factory.New(config)
		if err != nil {
			return nil, fmt.Errorf("open context %q: %w", contextInfo.Name, err)
		}
		backend = &sharedBackend{clients: clients}
		r.backends[key] = backend
	}

	sessionID, err := newSessionID()
	if err != nil {
		if backend.refs == 0 {
			if backend.clients.Close != nil {
				backend.clients.Close()
			}
			delete(r.backends, key)
		}
		return nil, err
	}
	for r.sessions[sessionID] != nil {
		sessionID, err = newSessionID()
		if err != nil {
			return nil, err
		}
	}
	backend.refs++
	session := &Session{id: sessionID, context: contextInfo, key: key, backend: backend}
	r.sessions[sessionID] = session
	return session, nil
}

func (r *SessionRegistry) Get(sessionID string) (*Session, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	session, ok := r.sessions[sessionID]
	return session, ok
}

func (r *SessionRegistry) Close(sessionID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	session := r.sessions[sessionID]
	if session == nil {
		return false
	}
	delete(r.sessions, sessionID)
	backend := session.backend
	backend.refs--
	if backend.refs == 0 {
		if backend.clients.Mapper != nil {
			backend.clients.Mapper.Reset()
		}
		if backend.clients.Close != nil {
			backend.clients.Close()
		}
		delete(r.backends, session.key)
	}
	return true
}

func (r *SessionRegistry) CloseAll() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for key, backend := range r.backends {
		if backend.clients.Mapper != nil {
			backend.clients.Mapper.Reset()
		}
		if backend.clients.Close != nil {
			backend.clients.Close()
		}
		delete(r.backends, key)
	}
	clear(r.sessions)
}

func (s *Session) ID() string                              { return s.id }
func (s *Session) Context() ContextInfo                    { return s.context }
func (s *Session) Dynamic() dynamic.Interface              { return s.backend.clients.Dynamic }
func (s *Session) Discovery() discovery.DiscoveryInterface { return s.backend.clients.Discovery }
func (s *Session) Mapper() meta.RESTMapper                 { return s.backend.clients.Mapper }

func newSessionID() (string, error) {
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", fmt.Errorf("generate cluster session ID: %w", err)
	}
	return "session_" + hex.EncodeToString(random[:]), nil
}
