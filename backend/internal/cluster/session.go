package cluster

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"sync"

	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/discovery/cached/memory"
	"k8s.io/client-go/dynamic"
	coreclient "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/client-go/metadata"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/restmapper"
	"k8s.io/client-go/util/flowcontrol"
	metricsclient "k8s.io/metrics/pkg/client/clientset/versioned/typed/metrics/v1beta1"
)

const (
	DefaultClientQPS   = 40
	DefaultClientBurst = 80
)

type BackendClients struct {
	Dynamic   dynamic.Interface
	Discovery discovery.DiscoveryInterface
	Metadata  metadata.Interface
	Core      coreclient.CoreV1Interface
	Metrics   metricsclient.MetricsV1beta1Interface
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
	metadataClient, err := metadata.NewForConfigAndClient(config, httpClient)
	if err != nil {
		closeHTTPClient(httpClient)
		return BackendClients{}, fmt.Errorf("construct Kubernetes metadata client: %w", err)
	}
	coreClient, err := coreclient.NewForConfigAndClient(config, httpClient)
	if err != nil {
		closeHTTPClient(httpClient)
		return BackendClients{}, fmt.Errorf("construct Kubernetes core client: %w", err)
	}
	metricsClient, err := metricsclient.NewForConfigAndClient(config, httpClient)
	if err != nil {
		closeHTTPClient(httpClient)
		return BackendClients{}, fmt.Errorf("construct Kubernetes Metrics API client: %w", err)
	}
	mapper := restmapper.NewDeferredDiscoveryRESTMapper(memory.NewMemCacheClient(discoveryClient))
	return BackendClients{
		Dynamic:   dynamicClient,
		Discovery: discoveryClient,
		Metadata:  metadataClient,
		Core:      coreClient,
		Metrics:   metricsClient,
		Mapper:    mapper,
		Close:     func() { closeHTTPClient(httpClient) },
	}, nil
}

func configWithAPIActivity(config *rest.Config, activity *APIActivity) *rest.Config {
	config = rest.CopyConfig(config)
	previous := config.WrapTransport
	config.WrapTransport = func(base http.RoundTripper) http.RoundTripper {
		if previous != nil {
			base = previous(base)
		}
		return &activityRoundTripper{base: base, activity: activity}
	}
	return config
}

type activityRoundTripper struct {
	base     http.RoundTripper
	activity *APIActivity
}

func (t *activityRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	if request != nil && request.Body != nil {
		request = request.Clone(request.Context())
		request.Body = &activityReadCloser{ReadCloser: request.Body, activity: t.activity, sent: true}
		if request.GetBody != nil {
			getBody := request.GetBody
			request.GetBody = func() (io.ReadCloser, error) {
				body, err := getBody()
				if err != nil {
					return nil, err
				}
				return &activityReadCloser{ReadCloser: body, activity: t.activity, sent: true}, nil
			}
		}
	}
	response, err := t.base.RoundTrip(request)
	statusCode := 0
	if response != nil {
		statusCode = response.StatusCode
	}
	t.activity.ObserveRoundTrip(statusCode, err)
	if response != nil && response.Body != nil {
		response.Body = &activityReadCloser{ReadCloser: response.Body, activity: t.activity}
	}
	return response, err
}

type activityReadCloser struct {
	io.ReadCloser
	activity *APIActivity
	sent     bool
}

func (r *activityReadCloser) Read(buffer []byte) (int, error) {
	count, err := r.ReadCloser.Read(buffer)
	if count > 0 {
		if r.sent {
			r.activity.AddSent(uint64(count))
		} else {
			r.activity.AddReceived(uint64(count))
		}
	}
	return count, err
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
	mu                       sync.RWMutex
	factory                  ClientFactory
	qps                      float32
	burst                    int
	sessions                 map[string]*sessionEntry
	backends                 map[backendKey]*sharedBackend
	authorities              map[string]*sharedBackend
	authorityRetiredObserver func(string)
	warmCacheGlobal          WarmCacheUsage
	warmCacheAuthorityBudget WarmCacheUsage
	warmCacheAuthorities     map[string]WarmCacheUsage
	warmCacheGeneration      uint64
}

type sessionEntry struct {
	session           *Session
	workspaceLease    bool
	independentLeases int
}

type backendKey struct {
	catalog   *Catalog
	contextID string
}

type sharedBackend struct {
	authorityID string
	clients     BackendClients
	config      *rest.Config
	// refs counts live session entries, not individual workspace or stream
	// leases. A session entry remains live after its workspace closes only
	// while an independent operation still owns it.
	refs      int
	activity  *APIActivity
	discovery discoveryResultCache
	// namespaceNames stores only a sorted string snapshot and belongs to this
	// shared Kubernetes authority rather than any workspace session.
	namespaceNames namespaceNameCache
}

// WarmCacheTelemetry is one redacted process-memory cache snapshot from the
// view runtime. Authorities are addressed only by their process-local opaque
// IDs; those IDs never cross the connection protocol.
type WarmCacheTelemetry struct {
	Global          WarmCacheUsage
	AuthorityBudget WarmCacheUsage
	Authorities     map[string]WarmCacheUsage
}

// SessionLease keeps one session and its shared Kubernetes backend alive for
// an independent operation. Release is idempotent so cleanup paths may safely
// converge without closing a backend more than once.
type SessionLease struct {
	registry *SessionRegistry
	entry    *sessionEntry
	once     sync.Once
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
		factory:              factory,
		qps:                  DefaultClientQPS,
		burst:                DefaultClientBurst,
		sessions:             make(map[string]*sessionEntry),
		backends:             make(map[backendKey]*sharedBackend),
		authorities:          make(map[string]*sharedBackend),
		warmCacheAuthorities: make(map[string]WarmCacheUsage),
	}
}

// SetAuthorityRetiredObserver installs the process-local lifecycle callback
// used by cache owners to discard state tied to closed backend clients. The
// callback is always invoked after SessionRegistry releases its mutex.
func (r *SessionRegistry) SetAuthorityRetiredObserver(observer func(string)) {
	if r == nil {
		return
	}
	r.mu.Lock()
	r.authorityRetiredObserver = observer
	r.mu.Unlock()
}

// AuthorityActive reports whether an opaque authority still owns live shared
// Kubernetes clients. It is an O(1), process-local cache-lifecycle check.
func (r *SessionRegistry) AuthorityActive(authorityID string) bool {
	if r == nil || authorityID == "" {
		return false
	}
	r.mu.RLock()
	_, ok := r.authorities[authorityID]
	r.mu.RUnlock()
	return ok
}

func (r *SessionRegistry) notifyAuthoritiesRetired(authorityIDs ...string) {
	if r == nil || len(authorityIDs) == 0 {
		return
	}
	r.mu.RLock()
	observer := r.authorityRetiredObserver
	r.mu.RUnlock()
	if observer == nil {
		return
	}
	for _, authorityID := range authorityIDs {
		if authorityID != "" {
			observer(authorityID)
		}
	}
}

// SetWarmCacheTelemetry publishes one coherent snapshot to every live shared
// backend. Activity callbacks happen after registry ownership is released, so
// a connection-stream consumer can never deadlock session or view-cache locks.
func (r *SessionRegistry) SetWarmCacheTelemetry(snapshot WarmCacheTelemetry) {
	if r == nil {
		return
	}
	authorities := make(map[string]WarmCacheUsage, len(snapshot.Authorities))
	for authorityID, usage := range snapshot.Authorities {
		if authorityID != "" {
			authorities[authorityID] = usage
		}
	}
	type update struct {
		activity  *APIActivity
		authority WarmCacheUsage
	}
	r.mu.Lock()
	r.warmCacheGeneration++
	generation := r.warmCacheGeneration
	r.warmCacheGlobal = snapshot.Global
	r.warmCacheAuthorityBudget = snapshot.AuthorityBudget
	r.warmCacheAuthorities = authorities
	updates := make([]update, 0, len(r.backends))
	for _, backend := range r.backends {
		if backend == nil || backend.activity == nil {
			continue
		}
		usage := r.warmCacheUsageForAuthorityLocked(backend.authorityID)
		updates = append(updates, update{activity: backend.activity, authority: usage})
	}
	global := r.warmCacheGlobal
	r.mu.Unlock()

	for _, update := range updates {
		update.activity.setWarmCacheUsage(generation, update.authority, global)
	}
}

func (r *SessionRegistry) warmCacheUsageForAuthorityLocked(authorityID string) WarmCacheUsage {
	if usage, ok := r.warmCacheAuthorities[authorityID]; ok {
		return usage
	}
	budget := r.warmCacheAuthorityBudget
	budget.RetainedViews = 0
	budget.RetainedObjects = 0
	budget.RetainedBytes = 0
	budget.BudgetEvictions = 0
	return budget
}

func (r *SessionRegistry) SetRateLimit(qps float32, burst int) error {
	if qps <= 0 || math.IsNaN(float64(qps)) || math.IsInf(float64(qps), 0) {
		return errors.New("Kubernetes QPS must be finite and positive")
	}
	if burst <= 0 {
		return errors.New("Kubernetes burst must be positive")
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

	var retiredAuthorities []string
	r.mu.Lock()
	defer func() {
		r.mu.Unlock()
		r.notifyAuthoritiesRetired(retiredAuthorities...)
	}()
	config = rest.CopyConfig(config)
	config.QPS = r.qps
	config.Burst = r.burst
	config.UserAgent = "kmgr-engine"

	key := backendKey{catalog: catalog, contextID: contextInfo.ID}
	backend := r.backends[key]
	if backend == nil {
		var authorityID string
		for {
			authorityID, err = newAuthorityID()
			if err != nil {
				return nil, err
			}
			if r.authorities[authorityID] == nil {
				break
			}
		}
		// Every client constructed for this authority must receive this exact
		// limiter. Supplying only QPS/Burst would make each REST client allocate
		// an independent token bucket and multiply the effective API-server cap.
		config.RateLimiter = flowcontrol.NewTokenBucketRateLimiter(config.QPS, config.Burst)
		activity := &APIActivity{}
		config = configWithAPIActivity(config, activity)
		clients, err := r.factory.New(config)
		if err != nil {
			return nil, fmt.Errorf("open context %q: %w", contextInfo.Name, err)
		}
		backend = &sharedBackend{
			authorityID: authorityID,
			clients:     clients,
			config:      rest.CopyConfig(config),
			activity:    activity,
		}
		activity.setWarmCacheUsage(
			r.warmCacheGeneration,
			r.warmCacheUsageForAuthorityLocked(authorityID),
			r.warmCacheGlobal,
		)
		r.backends[key] = backend
		r.authorities[authorityID] = backend
	}

	sessionID, err := newSessionID()
	if err != nil {
		if backend.refs == 0 {
			retiredAuthorities = append(retiredAuthorities, r.closeBackendLocked(key, backend))
		}
		return nil, err
	}
	for r.sessions[sessionID] != nil {
		sessionID, err = newSessionID()
		if err != nil {
			if backend.refs == 0 {
				retiredAuthorities = append(retiredAuthorities, r.closeBackendLocked(key, backend))
			}
			return nil, err
		}
	}
	backend.refs++
	session := &Session{id: sessionID, context: contextInfo, key: key, backend: backend}
	r.sessions[sessionID] = &sessionEntry{session: session, workspaceLease: true}
	return session, nil
}

func (r *SessionRegistry) Get(sessionID string) (*Session, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	entry, ok := r.sessions[sessionID]
	if !ok || !entry.workspaceLease {
		return nil, false
	}
	return entry.session, true
}

// Acquire obtains a lease for an independent operation. It is atomic with
// workspace close: either the lease is retained and the session remains
// usable, or the session has already disappeared and Acquire returns false.
func (r *SessionRegistry) Acquire(sessionID string) (*Session, *SessionLease, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	entry := r.sessions[sessionID]
	if entry == nil || !entry.workspaceLease {
		return nil, nil, false
	}
	entry.independentLeases++
	return entry.session, &SessionLease{registry: r, entry: entry}, true
}

// CloseWorkspace releases the lease created by Open while preserving the
// session for any independent operations that already acquired their own
// leases. Once the final independent lease ends, the session and (when no
// other session shares it) its Kubernetes backend are closed automatically.
func (r *SessionRegistry) CloseWorkspace(sessionID string) bool {
	r.mu.Lock()
	entry := r.sessions[sessionID]
	if entry == nil || !entry.workspaceLease {
		r.mu.Unlock()
		return false
	}
	entry.workspaceLease = false
	retiredAuthority := ""
	if entry.independentLeases == 0 {
		retiredAuthority = r.removeSessionLocked(sessionID, entry)
	}
	r.mu.Unlock()
	r.notifyAuthoritiesRetired(retiredAuthority)
	return true
}

// Close force-closes a session regardless of outstanding independent leases.
// It is used for explicit non-preserving close, failed Open rollback, and
// other callers that require immediate invalidation.
func (r *SessionRegistry) Close(sessionID string) bool {
	r.mu.Lock()
	entry := r.sessions[sessionID]
	if entry == nil {
		r.mu.Unlock()
		return false
	}
	retiredAuthority := r.removeSessionLocked(sessionID, entry)
	r.mu.Unlock()
	r.notifyAuthoritiesRetired(retiredAuthority)
	return true
}

func (r *SessionRegistry) removeSessionLocked(sessionID string, entry *sessionEntry) string {
	if entry == nil || r.sessions[sessionID] != entry {
		return ""
	}
	delete(r.sessions, sessionID)
	backend := entry.session.backend
	backend.refs--
	if backend.refs == 0 {
		return r.closeBackendLocked(entry.session.key, backend)
	}
	return ""
}

func (r *SessionRegistry) closeBackendLocked(key backendKey, backend *sharedBackend) string {
	if backend == nil {
		return ""
	}
	backend.namespaceNames.close()
	if backend.clients.Mapper != nil {
		backend.clients.Mapper.Reset()
	}
	if backend.clients.Close != nil {
		backend.clients.Close()
	}
	delete(r.backends, key)
	if r.authorities[backend.authorityID] == backend {
		delete(r.authorities, backend.authorityID)
	}
	return backend.authorityID
}

func (r *SessionRegistry) CloseAll() {
	r.mu.Lock()
	clear(r.sessions)
	retiredAuthorities := make([]string, 0, len(r.backends))
	for key, backend := range r.backends {
		retiredAuthorities = append(retiredAuthorities, r.closeBackendLocked(key, backend))
	}
	r.mu.Unlock()
	r.notifyAuthoritiesRetired(retiredAuthorities...)
}

func (l *SessionLease) Release() {
	if l == nil || l.registry == nil || l.entry == nil {
		return
	}
	l.once.Do(func() {
		r := l.registry
		r.mu.Lock()
		entry := l.entry
		if r.sessions[entry.session.id] != entry || entry.independentLeases == 0 {
			r.mu.Unlock()
			return
		}
		entry.independentLeases--
		retiredAuthority := ""
		if !entry.workspaceLease && entry.independentLeases == 0 {
			retiredAuthority = r.removeSessionLocked(entry.session.id, entry)
		}
		r.mu.Unlock()
		r.notifyAuthoritiesRetired(retiredAuthority)
	})
}

func (s *Session) ID() string                              { return s.id }
func (s *Session) Context() ContextInfo                    { return s.context }
func (s *Session) Dynamic() dynamic.Interface              { return s.backend.clients.Dynamic }
func (s *Session) Discovery() discovery.DiscoveryInterface { return s.backend.clients.Discovery }
func (s *Session) Metadata() metadata.Interface            { return s.backend.clients.Metadata }
func (s *Session) Core() coreclient.CoreV1Interface        { return s.backend.clients.Core }
func (s *Session) Metrics() metricsclient.MetricsV1beta1Interface {
	return s.backend.clients.Metrics
}
func (s *Session) Mapper() meta.RESTMapper { return s.backend.clients.Mapper }
func (s *Session) APIActivity() *APIActivity {
	if s == nil || s.backend == nil {
		return nil
	}
	return s.backend.activity
}

// AuthorityID is an opaque process-local identity shared by sessions that use
// the exact same backend clients. It contains no kubeconfig or server data.
func (s *Session) AuthorityID() string {
	if s == nil || s.backend == nil {
		return ""
	}
	return s.backend.authorityID
}

// RESTConfig returns an independent copy for Table and subresource transports
// such as exec and port-forward. The copy deliberately retains the shared
// authority-wide RateLimiter identity. Callers must never log it because it
// may contain authentication material.
func (s *Session) RESTConfig() *rest.Config {
	if s == nil || s.backend == nil || s.backend.config == nil {
		return nil
	}
	return rest.CopyConfig(s.backend.config)
}

func newSessionID() (string, error) {
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", fmt.Errorf("generate cluster session ID: %w", err)
	}
	return "session_" + hex.EncodeToString(random[:]), nil
}

func newAuthorityID() (string, error) {
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", fmt.Errorf("generate Kubernetes authority ID: %w", err)
	}
	return "authority_" + hex.EncodeToString(random[:]), nil
}
