package view

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"slices"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/kubeerrors"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/protobuf/proto"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	k8sruntime "k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/metadata"
	clientwatchlist "k8s.io/client-go/util/watchlist"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/metrics"
	"github.com/charlie0129/kmgr/backend/internal/store"
	"github.com/charlie0129/kmgr/backend/internal/systemmemory"
	viewcolumns "github.com/charlie0129/kmgr/backend/internal/view/columns"
	viewfilter "github.com/charlie0129/kmgr/backend/internal/view/filter"
	"github.com/charlie0129/kmgr/backend/internal/watcher"
)

const (
	DefaultViewReleaseDelay                  = 3 * time.Second
	DefaultViewBatchDelay                    = 35 * time.Millisecond
	DefaultPendingRowLimit                   = 4096
	DefaultWarmViewLimit                     = 24
	DefaultWarmObjectLimit                   = 250_000
	DefaultWarmMemoryPercent                 = 20
	DefaultWarmViewLimitPerAuthority         = 8
	DefaultWarmObjectLimitPerAuthority       = 100_000
	DefaultSearchSnapshotLimit               = 4
	DefaultSearchSnapshotObjectLimit         = 250_000
	DefaultSearchSnapshotTTL                 = 30 * time.Second
	DefaultOpenGenerationHistory             = 1024
	DefaultWatchOpenTimeout                  = 15 * time.Second
	maxAutomaticWatchOpenRetries             = 3
	DefaultPipelinePageSize            int64 = 500
	MaximumPipelinePageSize            int64 = 10_000
	defaultOpenProjectionLimit               = 4
)

var (
	ErrViewClosed      = errors.New("resource view is closed")
	ErrSessionNotFound = errors.New("cluster session was not found")
	ErrStaleViewOpen   = errors.New("resource view generation is stale")
	ErrStaleFilter     = errors.New("resource view filter revision is stale")
	ErrInvalidView     = errors.New("invalid resource view")
	ErrDeliveryPending = errors.New("resource view delivery acknowledgement is pending")
)

// ResourceSource resolves a session plus server-side resource scope without
// making the view runtime depend on gRPC. AuthorityID must be equal for
// workspace sessions that share the same underlying Kubernetes clients.
type ResourceSource interface {
	OpenResource(sessionID string, resource schema.GroupVersionResource, namespace string) (
		authorityID string,
		client watcher.ListerWatcher,
		err error,
	)
}

// MetadataSearchResourceSource optionally provides identity-only clients for
// explicit resource search. Metadata search snapshots are deliberately kept
// separate from full-object view handoffs: a dynamic WATCH cannot hydrate
// fields omitted from PartialObjectMetadata for unchanged objects.
type MetadataSearchResourceSource interface {
	OpenMetadataSearchResource(sessionID string, resource schema.GroupVersionResource, namespace string) (
		authorityID string,
		client metadata.ResourceInterface,
		err error,
	)
}

// TableResourceSource optionally provides content-negotiated metav1.Table
// streams for resources without a curated native registry. Implementations
// include either metadata or full objects according to the projection plan.
// When Table negotiation is unavailable, metadata-only projections stay on
// PartialObjectMetadata while object-backed projections use the dynamic stream.
type TableResourceSource interface {
	OpenTableResource(
		sessionID string,
		resource schema.GroupVersionResource,
		namespace string,
		include metav1.IncludeObjectPolicy,
	) (
		authorityID string,
		client watcher.ListerWatcher,
		err error,
	)
}

// ClusterResourceSource adapts the authoritative cluster session registry.
type ClusterResourceSource struct {
	Sessions *cluster.SessionRegistry
}

// watchListDynamicResource opts a production dynamic client into streaming
// initial events while retaining the complete dynamic.ResourceInterface. The
// latter matters to adapters that use richer dynamic-client type assertions.
type watchListDynamicResource struct {
	dynamic.ResourceInterface
	session  *cluster.Session
	resource schema.GroupVersionResource
}

func (client watchListDynamicResource) SupportsWatchListSemantics() bool {
	return client.ResourceInterface != nil &&
		(client.session == nil || !client.session.WatchListUnavailable(client.resource)) &&
		!clientwatchlist.DoesClientNotSupportWatchListSemantics(client.ResourceInterface)
}

func (client watchListDynamicResource) DisableWatchListSemantics() {
	if client.session != nil {
		client.session.DisableWatchList(client.resource)
	}
}

func (s ClusterResourceSource) OpenResource(
	sessionID string,
	resource schema.GroupVersionResource,
	namespace string,
) (string, watcher.ListerWatcher, error) {
	if s.Sessions == nil {
		return "", nil, errors.New("cluster session registry is unavailable")
	}
	session, ok := s.Sessions.Get(sessionID)
	if !ok {
		return "", nil, ErrSessionNotFound
	}
	client := session.Dynamic().Resource(resource)
	var resourceClient dynamic.ResourceInterface
	if namespace == "" {
		resourceClient = client
	} else {
		resourceClient = client.Namespace(namespace)
	}
	resourceClient = watchListDynamicResource{
		ResourceInterface: resourceClient,
		session:           session,
		resource:          resource,
	}
	// SessionRegistry shares one dynamic client between workspace sessions for
	// the same catalog/context. Include its pointer so a kubeconfig reload that
	// happens to retain the same stable context ID cannot cross-wire clients.
	authorityID := clusterSessionAuthorityID(session)
	return authorityID, resourceClient, nil
}

func (s ClusterResourceSource) OpenMetadataSearchResource(
	sessionID string,
	resource schema.GroupVersionResource,
	namespace string,
) (string, metadata.ResourceInterface, error) {
	if s.Sessions == nil {
		return "", nil, errors.New("cluster session registry is unavailable")
	}
	session, ok := s.Sessions.Get(sessionID)
	if !ok {
		return "", nil, ErrSessionNotFound
	}
	metadataClient := session.Metadata()
	if metadataClient == nil {
		return "", nil, errors.New("cluster metadata client is unavailable")
	}
	client := metadataClient.Resource(resource)
	var resourceClient metadata.ResourceInterface = client
	if namespace != "" {
		resourceClient = client.Namespace(namespace)
	}
	return clusterSessionAuthorityID(session), resourceClient, nil
}

func clusterSessionAuthorityID(session *cluster.Session) string {
	if session == nil {
		return ""
	}
	return session.AuthorityID()
}

func (s ClusterResourceSource) OpenTableResource(
	sessionID string,
	resource schema.GroupVersionResource,
	namespace string,
	include metav1.IncludeObjectPolicy,
) (string, watcher.ListerWatcher, error) {
	authorityID, fallback, err := s.OpenResource(sessionID, resource, namespace)
	if err != nil {
		return "", nil, err
	}
	session, ok := s.Sessions.Get(sessionID)
	if !ok {
		return "", nil, ErrSessionNotFound
	}
	var metadataFallback metadata.ResourceInterface
	if include == metav1.IncludeMetadata {
		metadataClient := session.Metadata()
		if metadataClient == nil {
			return "", nil, errors.New("cluster metadata client is unavailable")
		}
		resourceClient := metadataClient.Resource(resource)
		if namespace == "" {
			metadataFallback = resourceClient
		} else {
			metadataFallback = resourceClient.Namespace(namespace)
		}
	}
	client, err := watcher.NewTableResourceClient(
		session.RESTConfig(), resource, namespace, fallback, metadataFallback, include,
	)
	if err != nil {
		if include == metav1.IncludeMetadata {
			// Never turn a metadata-only plan into an unbounded full-object stream.
			return "", nil, err
		}
		// A session without a reusable REST config remains fully usable through
		// the ordinary dynamic stream.
		return authorityID, fallback, nil
	}
	return authorityID, client, nil
}

// AuthorityID exposes the shared backend identity without leaking clients or
// credentials. It is stable for the lifetime of an open shared backend and is
// identical across independent workspace sessions using it.
func (s ClusterResourceSource) AuthorityID(sessionID string) (string, bool) {
	if s.Sessions == nil {
		return "", false
	}
	session, ok := s.Sessions.Get(sessionID)
	if !ok {
		return "", false
	}
	return clusterSessionAuthorityID(session), true
}

type RuntimeConfig struct {
	Source                      ResourceSource
	Metrics                     MetricSource
	Columns                     ColumnProgramResolver
	SelectionStoreConfig        SelectionStoreConfig
	ReleaseDelay                time.Duration
	BatchDelay                  time.Duration
	PendingRowLimit             int
	WarmViewLimit               int
	WarmObjectLimit             int
	WarmByteLimit               int64
	WarmViewLimitPerAuthority   int
	WarmObjectLimitPerAuthority int
	WarmByteLimitPerAuthority   int64
	WarmCacheObserver           func(WarmCacheTelemetry)
	WarmCacheAuthorityActive    func(string) bool
	PipelinePageSize            int64
	PipelineTimeout             time.Duration
	// WatchOpenTimeout bounds the time a resource may remain in the
	// pre-WATCH Resuming phase. It is separate from PipelineTimeout, which is
	// the server-side lifetime of an already established watch request.
	WatchOpenTimeout          time.Duration
	SearchSnapshotLimit       int
	SearchSnapshotObjectLimit int
	SearchSnapshotTTL         time.Duration
	OpenProjectionLimit       int
	ProjectionWorkerLimit     int
	OpenGenerationHistory     int
	openProjectionHook        func()
	openHandoffHook           func()
	pipelineRunHook           func(context.Context, func(context.Context) error) error
}

// ColumnProgramResolver resolves programs once per opened view. Projection
// never compiles CEL once per Kubernetes object.
type ColumnProgramResolver interface {
	Resolve(
		group, version, resource string,
		requestedIDs []string,
		expectedVersion string,
	) (viewcolumns.Resolution, string, error)
}

// AcceleratorConfigProvider is optionally implemented by the columns
// resolver. Runtime uses it only for exact-key scheduler discovery; column
// definitions still travel through the existing view protocol.
type AcceleratorConfigProvider interface {
	AcceleratorConfig() metrics.AcceleratorConfig
}

// Runtime shares compatible LIST/WATCH pipelines while giving every workspace
// an independent filter, sort, generation gate, and bounded output mailbox.
type Runtime struct {
	mu sync.Mutex

	source           ResourceSource
	metrics          MetricSource
	columns          ColumnProgramResolver
	selectionStore   *SelectionStore
	releaseDelay     time.Duration
	batchDelay       time.Duration
	pendingRowLimit  int
	pageSize         int64
	watchTimeout     time.Duration
	watchOpenTimeout time.Duration

	resources                      map[resourceKey]*resourceRuntime
	views                          map[viewKey]*Subscription
	warm                           *watcher.WarmCache[resourceKey, *resourceRuntime]
	warmByAuthority                map[string]*watcher.WarmCache[resourceKey, *resourceRuntime]
	warmViewLimit                  int
	warmObjectLimit                int
	warmByteLimit                  int64
	warmViewLimitPerAuthority      int
	warmObjectLimitPerAuthority    int
	warmByteLimitPerAuthority      int64
	warmBudgetEvictions            uint64
	warmBudgetEvictionsByAuthority map[string]uint64
	warmCacheObserver              func(WarmCacheTelemetry)
	warmCacheAuthorityActive       func(string) bool
	warmCacheTelemetryWake         chan struct{}
	warmCacheTelemetryStop         chan chan struct{}

	searchSnapshots           map[searchSnapshotKey]*completedSearchSnapshot
	searchSnapshotLimit       int
	searchSnapshotObjects     int
	searchSnapshotObjectLimit int
	searchSnapshotTTL         time.Duration
	searchSnapshotSequence    uint64
	transientSearchLists      map[searchSnapshotKey]*transientSearchList

	openProjectionGate chan struct{}
	projectionWorkers  *projectionWorkerPool
	openProjectionHook func()
	openHandoffHook    func()
	pipelineRunHook    func(context.Context, func(context.Context) error) error
	openings           map[viewKey]*openAttempt
	latestOpen         map[viewKey]uint64
	latestFilter       map[viewKey]uint64
	openHistory        []openGeneration
	openHistoryLimit   int
	closed             bool
}

// OptionalResourceCatalog is one cache-only scheduler-resource discovery
// result. Coverage is reported separately because namespace/selector-scoped
// Pod stores can prove presence but generally cannot prove cluster absence.
type OptionalResourceCatalog struct {
	Discovered            metrics.DiscoveredResources
	Accelerators          metrics.AcceleratorConfig
	NodesCacheAvailable   bool
	PodsCacheAvailable    bool
	NodesSnapshotComplete bool
	PodsSnapshotComplete  bool
	PotentiallyIncomplete bool
}

type resourceKey struct {
	authorityID string
	group       string
	version     string
	resource    string
	namespace   string
	labels      string
	fields      string
	tableObject metav1.IncludeObjectPolicy
}

// searchSnapshotKey is deliberately stricter than resourceKey. A namespaced
// view whose client is cluster-scoped still has a logical namespace scope, so
// two multi-namespace views must not exchange snapshots merely because both
// clients LIST with namespace="".
type searchSnapshotKey struct {
	resource       resourceKey
	namespaceScope string
	// metadataOnly prevents identity-only search pages from being consumed by
	// or joined to a full-object resource view. Dynamic fallback searches keep
	// the zero value and retain the legacy view-handoff optimization.
	metadataOnly bool
}

// completedSearchSnapshot is a short-lived, multi-search identity source.
// Full-object snapshots (metadataOnly=false) are also a single-consumer
// handoff to a subsequently opened resource view; metadata-only snapshots can
// never cross into that view lifecycle.
type completedSearchSnapshot struct {
	store           *store.UIDStore
	objectCount     int
	completedAt     time.Time
	sequence        uint64
	expiresAt       time.Time
	expirationTimer *time.Timer
}

type resourceRuntime struct {
	key resourceKey
	// store is the immutable initial pointer. Restarts publish later stores
	// through replacementStore so background projection/metrics readers can
	// load the current pointer without racing the lifecycle fence, while a
	// retired Pipeline keeps the exact store it was constructed with.
	store              *store.UIDStore
	replacementStore   atomic.Pointer[store.UIDStore]
	client             watcher.ListerWatcher
	subscribers        map[*Subscription]struct{}
	closing            map[*Subscription]struct{}
	ctx                context.Context
	cancel             context.CancelFunc
	state              resourceState
	runNumber          uint64
	watchOpenTimer     *time.Timer
	watchOpenRunNumber uint64
	watchOpenTimeouts  uint8
	releaseTimer       *time.Timer
	lastStatus         watcher.Status
	// revision advances after every store mutation callback while openers pins
	// the entry during an off-lock initial projection.
	revision uint64
	openers  int
	// snapshotComplete is set only after a complete LIST has reached runtime.
	// ResourceVersion can advance in the store just before that callback, so it
	// is not by itself a safe signal for absence-based reconciliation.
	snapshotComplete bool
	// transientSearchList is set while this entry is sharing a command-palette
	// LIST. The normal watcher pipeline must not start until that LIST either
	// commits its final resourceVersion or terminates and releases ownership.
	transientSearchList      *transientSearchList
	transientSearchUsesStore bool
	warmProjection           *warmProjection
	tableColumns             []metav1.TableColumnDefinition
	tableRows                map[string][]any
	restartRequested         bool
}

func (entry *resourceRuntime) currentStore() *store.UIDStore {
	if entry == nil {
		return nil
	}
	if replacement := entry.replacementStore.Load(); replacement != nil {
		return replacement
	}
	return entry.store
}

func (entry *resourceRuntime) replaceStore(replacement *store.UIDStore) {
	if entry == nil || replacement == nil {
		return
	}
	entry.replacementStore.Store(replacement)
}

type resourceState uint8

const (
	resourceIdle resourceState = iota
	resourceRunning
	resourceStopping
	resourceRestarting
)

type resourceRestartPlan struct {
	entry         *resourceRuntime
	fenceRun      uint64
	subscriptions []*Subscription
}

type openAttempt struct {
	key        viewKey
	generation uint64
	entry      *resourceRuntime
	cancel     context.CancelFunc
	released   bool
	wasWarm    bool
}

type openGeneration struct {
	key            viewKey
	generation     uint64
	filterRevision uint64
}

type viewKey struct {
	sessionID string
	viewID    string
}

func NewRuntime(config RuntimeConfig) (*Runtime, error) {
	if config.Source == nil {
		return nil, errors.New("resource source must not be nil")
	}
	selectionStore, err := NewSelectionStore(config.SelectionStoreConfig)
	if err != nil {
		return nil, fmt.Errorf("configure selection store: %w", err)
	}
	if config.ReleaseDelay < 0 || config.BatchDelay < 0 || config.PipelinePageSize < 0 || config.PipelineTimeout < 0 || config.WatchOpenTimeout < 0 ||
		config.SearchSnapshotLimit < 0 || config.SearchSnapshotObjectLimit < 0 || config.SearchSnapshotTTL < 0 ||
		config.OpenProjectionLimit < 0 || config.ProjectionWorkerLimit < 0 ||
		config.OpenGenerationHistory < 0 ||
		config.WarmByteLimit < 0 || config.WarmByteLimitPerAuthority < 0 {
		return nil, errors.New("view runtime durations and limits must not be negative")
	}
	if config.PipelinePageSize > MaximumPipelinePageSize {
		return nil, fmt.Errorf(
			"view runtime pipeline page size must not exceed %d",
			MaximumPipelinePageSize,
		)
	}
	releaseDelay := config.ReleaseDelay
	if releaseDelay == 0 {
		releaseDelay = DefaultViewReleaseDelay
	}
	batchDelay := config.BatchDelay
	if batchDelay == 0 {
		batchDelay = DefaultViewBatchDelay
	}
	watchOpenTimeout := config.WatchOpenTimeout
	if watchOpenTimeout == 0 {
		watchOpenTimeout = DefaultWatchOpenTimeout
	}
	pendingLimit := config.PendingRowLimit
	if pendingLimit == 0 {
		pendingLimit = DefaultPendingRowLimit
	}
	warmViews := config.WarmViewLimit
	if warmViews == 0 {
		warmViews = DefaultWarmViewLimit
	}
	warmObjects := config.WarmObjectLimit
	if warmObjects == 0 {
		warmObjects = DefaultWarmObjectLimit
	}
	warmBytes := config.WarmByteLimit
	warmViewsPerAuthority := config.WarmViewLimitPerAuthority
	if warmViewsPerAuthority == 0 {
		warmViewsPerAuthority = DefaultWarmViewLimitPerAuthority
	}
	warmObjectsPerAuthority := config.WarmObjectLimitPerAuthority
	if warmObjectsPerAuthority == 0 {
		warmObjectsPerAuthority = DefaultWarmObjectLimitPerAuthority
	}
	warmBytesPerAuthority := config.WarmByteLimitPerAuthority
	if warmBytes == 0 || warmBytesPerAuthority == 0 {
		physicalBytes, err := systemmemory.Bytes()
		if err != nil {
			return nil, fmt.Errorf("resolve default warm-cache memory budget: %w", err)
		}
		if warmBytes == 0 {
			warmBytes, err = systemmemory.PercentageLimit(
				physicalBytes, DefaultWarmMemoryPercent,
			)
			if err != nil {
				return nil, fmt.Errorf("resolve default global warm-cache memory budget: %w", err)
			}
		}
		if warmBytesPerAuthority == 0 {
			warmBytesPerAuthority, err = systemmemory.PercentageLimit(
				physicalBytes, DefaultWarmMemoryPercent,
			)
			if err != nil {
				return nil, fmt.Errorf("resolve default authority warm-cache memory budget: %w", err)
			}
		}
	}
	if pendingLimit <= 0 || warmViews <= 0 || warmObjects <= 0 ||
		warmBytes <= 0 || warmViewsPerAuthority <= 0 || warmObjectsPerAuthority <= 0 ||
		warmBytesPerAuthority <= 0 {
		return nil, errors.New("view runtime limits must be positive")
	}
	searchSnapshotLimit := config.SearchSnapshotLimit
	if searchSnapshotLimit == 0 {
		searchSnapshotLimit = DefaultSearchSnapshotLimit
	}
	searchSnapshotObjectLimit := config.SearchSnapshotObjectLimit
	if searchSnapshotObjectLimit == 0 {
		searchSnapshotObjectLimit = DefaultSearchSnapshotObjectLimit
	}
	searchSnapshotTTL := config.SearchSnapshotTTL
	if searchSnapshotTTL == 0 {
		searchSnapshotTTL = DefaultSearchSnapshotTTL
	}
	if searchSnapshotLimit <= 0 || searchSnapshotObjectLimit <= 0 {
		return nil, errors.New("search snapshot limits must be positive")
	}
	openProjectionLimit := config.OpenProjectionLimit
	if openProjectionLimit == 0 {
		openProjectionLimit = min(max(runtime.GOMAXPROCS(0), 1), defaultOpenProjectionLimit)
	}
	openHistoryLimit := config.OpenGenerationHistory
	if openHistoryLimit == 0 {
		openHistoryLimit = DefaultOpenGenerationHistory
	}
	if openProjectionLimit <= 0 || openHistoryLimit <= 0 {
		return nil, errors.New("open projection limits must be positive")
	}
	projectionWorkerLimit := config.ProjectionWorkerLimit
	if projectionWorkerLimit == 0 {
		projectionWorkerLimit = DefaultProjectionWorkerLimit()
	}
	if projectionWorkerLimit < 1 || projectionWorkerLimit > MaxProjectionWorkerLimit {
		return nil, fmt.Errorf(
			"projection worker limit must be between 1 and %d",
			MaxProjectionWorkerLimit,
		)
	}
	result := &Runtime{
		source:                         config.Source,
		metrics:                        config.Metrics,
		columns:                        config.Columns,
		selectionStore:                 selectionStore,
		releaseDelay:                   releaseDelay,
		batchDelay:                     batchDelay,
		pendingRowLimit:                pendingLimit,
		pageSize:                       config.PipelinePageSize,
		watchTimeout:                   config.PipelineTimeout,
		watchOpenTimeout:               watchOpenTimeout,
		resources:                      make(map[resourceKey]*resourceRuntime),
		views:                          make(map[viewKey]*Subscription),
		warm:                           watcher.NewWarmCache[resourceKey, *resourceRuntime](warmViews, warmObjects, warmBytes),
		warmByAuthority:                make(map[string]*watcher.WarmCache[resourceKey, *resourceRuntime]),
		warmViewLimit:                  warmViews,
		warmObjectLimit:                warmObjects,
		warmByteLimit:                  warmBytes,
		warmViewLimitPerAuthority:      warmViewsPerAuthority,
		warmObjectLimitPerAuthority:    warmObjectsPerAuthority,
		warmByteLimitPerAuthority:      warmBytesPerAuthority,
		warmBudgetEvictionsByAuthority: make(map[string]uint64),
		warmCacheObserver:              config.WarmCacheObserver,
		warmCacheAuthorityActive:       config.WarmCacheAuthorityActive,
		searchSnapshots:                make(map[searchSnapshotKey]*completedSearchSnapshot),
		searchSnapshotLimit:            searchSnapshotLimit,
		searchSnapshotObjectLimit:      searchSnapshotObjectLimit,
		searchSnapshotTTL:              searchSnapshotTTL,
		transientSearchLists:           make(map[searchSnapshotKey]*transientSearchList),
		openProjectionGate:             make(chan struct{}, openProjectionLimit),
		projectionWorkers:              newProjectionWorkerPool(projectionWorkerLimit),
		openProjectionHook:             config.openProjectionHook,
		openHandoffHook:                config.openHandoffHook,
		pipelineRunHook:                config.pipelineRunHook,
		openings:                       make(map[viewKey]*openAttempt),
		latestOpen:                     make(map[viewKey]uint64),
		latestFilter:                   make(map[viewKey]uint64),
		openHistoryLimit:               openHistoryLimit,
	}
	result.startWarmCacheTelemetry()
	return result, nil
}

// Open installs warm rows synchronously before starting or resuming network
// continuity. Expensive initial projection is cancellable and runs outside the
// runtime lifecycle mutex. A newer generation keeps the committed prior stream
// alive until its replacement is ready to publish atomically.
func (r *Runtime) Open(request *kmgrv1.OpenViewRequest) (*Subscription, error) {
	return r.OpenContext(context.Background(), request)
}

func (r *Runtime) OpenContext(ctx context.Context, request *kmgrv1.OpenViewRequest) (*Subscription, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if request == nil || request.GetContext() == nil || request.GetSpec() == nil {
		return nil, fmt.Errorf("%w: request, context, and spec are required", ErrInvalidView)
	}
	if strings.TrimSpace(request.GetContext().GetRequestId()) == "" {
		return nil, fmt.Errorf("%w: request ID is required", ErrInvalidView)
	}
	if deadlineUnixMs := request.GetContext().GetDeadlineUnixMs(); deadlineUnixMs != 0 {
		deadline := time.UnixMilli(deadlineUnixMs)
		if !deadline.After(time.Now()) {
			return nil, context.DeadlineExceeded
		}
		var cancelDeadline context.CancelFunc
		ctx, cancelDeadline = context.WithDeadline(ctx, deadline)
		defer cancelDeadline()
	}
	sessionID := request.GetContext().GetClusterSessionId()
	viewID := strings.TrimSpace(request.GetViewId())
	resource := request.GetSpec().GetResource()
	if sessionID == "" || viewID == "" || request.GetGeneration() == 0 || resource == nil {
		return nil, fmt.Errorf("%w: session, view ID, generation, and resource are required", ErrInvalidView)
	}
	gvr := schema.GroupVersionResource{
		Group: resource.GetGroup(), Version: resource.GetVersion(), Resource: resource.GetResource(),
	}
	namespacePlan, err := planNamespaceStream(request.GetSpec())
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidView, err)
	}
	query, err := planViewQuery(request.GetSpec())
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidView, err)
	}
	projector, err := projectorFromProto(
		sessionID, request.GetSpec(), r.columns, query.filter, r.projectionWorkers,
	)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidView, err)
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	var authorityID string
	var client watcher.ListerWatcher
	var requestedTableObject metav1.IncludeObjectPolicy
	_, tableAvailable := r.source.(TableResourceSource)
	useTable := tableAvailable &&
		!viewcolumns.HasCuratedNativeColumns(gvr.Group, gvr.Version, gvr.Resource)
	if useTable {
		requestedTableObject = tableObjectPolicy(projector)
	}
	authorityID, client, err = openNamespaceStream(
		r.source, sessionID, gvr, namespacePlan, useTable, requestedTableObject,
	)
	if err != nil {
		return nil, err
	}
	_, usesTableStream := client.(watcher.TableListerWatcher)
	if !usesTableStream {
		requestedTableObject = ""
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	key := resourceKey{
		authorityID: authorityID,
		group:       gvr.Group,
		version:     gvr.Version,
		resource:    gvr.Resource,
		namespace:   namespacePlan.cacheNamespace,
		labels:      query.labelSelector,
		fields:      query.fieldSelector,
		tableObject: requestedTableObject,
	}
	streamKey := viewKey{sessionID: sessionID, viewID: viewID}

	openCtx, cancelOpen := context.WithCancel(ctx)
	attempt := &openAttempt{key: streamKey, generation: request.GetGeneration(), cancel: cancelOpen}
	reserved := false
	defer func() {
		if !reserved {
			cancelOpen()
		}
	}()

	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return nil, ErrViewClosed
	}
	latest := r.latestOpen[streamKey]
	if current := r.views[streamKey]; current != nil {
		latest = max(latest, current.generation)
	}
	if opening := r.openings[streamKey]; opening != nil {
		latest = max(latest, opening.generation)
	}
	if request.GetGeneration() <= latest {
		r.mu.Unlock()
		return nil, fmt.Errorf("%w: generation %d is not newer than %d", ErrStaleViewOpen, request.GetGeneration(), latest)
	}
	filterRevision := request.GetSpec().GetFilterRevision()
	if latestFilter := r.latestFilter[streamKey]; filterRevision < latestFilter {
		r.mu.Unlock()
		return nil, fmt.Errorf(
			"%w: revision %d is older than %d",
			ErrStaleFilter, filterRevision, latestFilter,
		)
	}
	r.latestOpen[streamKey] = request.GetGeneration()
	r.latestFilter[streamKey] = filterRevision
	r.openHistory = append(r.openHistory, openGeneration{
		key: streamKey, generation: request.GetGeneration(), filterRevision: filterRevision,
	})
	if previousAttempt := r.openings[streamKey]; previousAttempt != nil {
		previousAttempt.cancel()
	}
	r.openings[streamKey] = attempt
	r.trimOpenHistoryLocked()
	r.mu.Unlock()
	reserved = true

	var entry *resourceRuntime
	var cachedProjection *warmProjection
	// Restart is committed only at the publication handoff below. Keeping the
	// preparation transactional means a cancelled/obsolete Open cannot retire
	// the currently usable stream for its sibling subscribers.
	restartPending := request.GetForceRelist()
	projectionAdmissionHeld := false
	for {
		r.mu.Lock()
		if r.closed || r.openings[streamKey] != attempt || openCtx.Err() != nil {
			r.mu.Unlock()
			r.abortOpen(attempt)
			if err := openCtx.Err(); err != nil {
				return nil, err
			}
			return nil, ErrViewClosed
		}
		entry = r.resources[key]
		fromWarm := false
		if entry != nil {
			if cached, ok := r.getWarmLocked(key); ok && cached.Value == entry {
				fromWarm = true
			}
		}
		if entry == nil {
			if cached, ok := r.getWarmLocked(key); ok {
				entry = cached.Value
				fromWarm = true
			}
		}
		cachedProjection = nil
		if entry != nil && len(entry.subscribers) == 0 &&
			entry.warmProjection != nil && entry.warmProjection.key == projector.cacheKey {
			cachedProjection = entry.warmProjection
		}
		// A stopped pipeline cannot be resumed safely by attaching a new
		// subscriber: its Run may still be blocked inside Watch and therefore
		// never reach resourceStopped. Defer the in-place lifecycle replacement
		// until publication so an aborted opener leaves the old stream intact.
		if entry != nil && entry.transientSearchList == nil &&
			(entry.state == resourceStopping || entry.restartRequested || restartPending) {
			restartPending = true
		}
		// A compatible immutable presentation needs no synchronous raw-store
		// projection. Every other path obtains bounded admission before it
		// consumes a search handoff, creates an entry, or removes a warm entry.
		if cachedProjection == nil && !restartPending && !projectionAdmissionHeld {
			r.mu.Unlock()
			if err := r.acquireOpenProjection(openCtx); err != nil {
				r.abortOpen(attempt)
				return nil, err
			}
			projectionAdmissionHeld = true
			continue
		}
		attempt.wasWarm = fromWarm
		break
	}
	if projectionAdmissionHeld {
		defer r.releaseOpenProjection()
	}

	var searchSnapshot *completedSearchSnapshot
	var transientList *transientSearchList
	if entry == nil && !usesTableStream && !restartPending {
		handoffResource := key
		if namespacePlan.exactFanIn {
			// Explicit resource search uses one all-namespaces scan plus the same
			// canonical logical-scope key. The exact namespace fan-in that owns the
			// subsequent live view may consume that full-object handoff; its local
			// projector removes any out-of-scope objects before publication, and
			// the first exact LIST reconciles the raw store.
			handoffResource.namespace = ""
		}
		handoffKey := searchSnapshotKey{
			resource:       handoffResource,
			namespaceScope: canonicalNamespaceScope(projector.spec.Resource, projector.spec.NamespaceScope),
		}
		transientList = r.transientSearchLists[handoffKey]
		if transientList != nil && (!transientList.joinable || transientList.store == nil) {
			transientList = nil
		}
		if transientList == nil {
			searchSnapshot = r.consumeSearchSnapshotLocked(handoffKey)
		}
	}
	if entry == nil {
		entryStore := store.New()
		if transientList != nil {
			entryStore = transientList.store
		} else if searchSnapshot != nil {
			entryStore = searchSnapshot.store
		}
		entry = &resourceRuntime{
			key:         key,
			store:       entryStore,
			client:      client,
			subscribers: make(map[*Subscription]struct{}),
		}
		if searchSnapshot != nil {
			// A global search LIST has one collection resourceVersion. An exact
			// namespace fan-in requires a vector checkpoint, so its handoff is a
			// stale first paint only and must perform the narrow initial LISTs.
			entry.snapshotComplete = !namespacePlan.exactFanIn
			entry.lastStatus = watcher.Status{
				Phase:            watcher.PhaseResuming,
				Stale:            true,
				ResourceVersion:  entryStore.ResourceVersion(),
				LastSynchronized: searchSnapshot.completedAt,
			}
		} else if transientList != nil {
			entry.transientSearchList = transientList
			entry.transientSearchUsesStore = true
			transientList.view = entry
			// Holding Runtime.mu while the coordinator mutates its store makes
			// initialization above an atomic replay. Future pages see this view
			// and are delivered through its bounded subscription mailbox.
			entry.lastStatus = watcher.Status{
				Phase: watcher.PhaseListing, ResourceVersion: entryStore.ResourceVersion(),
			}
			if transientList.terminal && entryStore.ResourceVersion() != "" {
				entry.snapshotComplete = true
				entry.lastStatus.Phase = watcher.PhaseResuming
				entry.lastStatus.Stale = true
			}
		}
		r.resources[key] = entry
		// A newly allocated entry already has an empty store and no retained
		// resourceVersion, so a force relist is implicit and needs no extra
		// lifecycle fence at publication.
		restartPending = false
	}
	attempt.entry = entry
	entry.openers++
	// A committed restart replaces this store at publication, so projecting its
	// full retired contents would perform an avoidable O(n) scan only to discard
	// the result. The client already retains its last usable rows while the fresh
	// generation stages; an aborted opener still leaves the old stream intact.
	skipRetiredProjection := restartPending
	usedWarmProjection := cachedProjection != nil && !skipRetiredProjection
	r.removeWarmLocked(key)
	if entry.releaseTimer != nil {
		entry.releaseTimer.Stop()
		entry.releaseTimer = nil
	}

	r.mu.Unlock()

	subscription := newSubscription(
		streamKey,
		request.GetGeneration(),
		projector,
		r.batchDelay,
		r.pendingRowLimit,
	)
	subscription.runtime = r
	subscription.resource = entry
	subscription.stageUntilReconciled = request.GetStageUntilReconciled()
	subscription.optionalResourceHints = newOptionalResourceStreamHints(
		entry.key, projector.spec.Accelerators,
	)
	metricPlan := planMetricView(projector, key.fields)
	if namespacePlan.exactFanIn && metricPlan.strategy == metricFetchSharedList &&
		!metricPlan.dependency.requiresCompleteCoverage() {
		if kind, supported := metricKindFor(projector.spec.Resource); supported && kind == metrics.PodMetrics {
			// A display-only exact namespace set needs only the bounded viewport.
			// Keep UID-pinned GETs here; LIST fan-in is reserved for global metric
			// sort/filter, where candidate-wide GETs would be the expensive shape.
			metricPlan.strategy = metricFetchPodObjects
		}
	}
	subscription.metricPlan = metricPlan
	if resolver, ok := r.metrics.(PodMetricResolver); ok {
		subscription.podMetricResolver = resolver
		subscription.metricSessionID = sessionID
		subscription.metricAuthorityID = authorityID
		subscription.metricRefreshInterval = metrics.DefaultPodSampleRefreshTTL
		if cadence, ok := r.metrics.(PodMetricRefreshCadence); ok {
			if interval := cadence.PodMetricRefreshInterval(); interval > 0 {
				subscription.metricRefreshInterval = interval
			}
		}
	}
	var (
		metricProviderScopes []string
		metricProviderLeases []*metrics.ProviderLease
	)
	if r.metrics != nil && metricPlan.strategy == metricFetchSharedList {
		metricKind, _ := metricKindFor(projector.spec.Resource)
		metricProviderScopes = []string{
			metricsNamespace(projector.spec.Resource, namespacePlan.metricNamespace),
		}
		if metricKind == metrics.PodMetrics && namespacePlan.exactFanIn {
			// Each child is an ordinary namespace-keyed shared provider. This retains
			// viewport-independent LIST efficiency for global metric sort/filter while
			// never broadening an exact 2-8 namespace object stream to all namespaces.
			metricProviderScopes = append([]string(nil), namespacePlan.apiNamespaces...)
		}
		var metricErr error
		for _, metricNamespace := range metricProviderScopes {
			var providerLease *metrics.ProviderLease
			providerLease, metricErr = r.metrics.OpenMetrics(
				sessionID, authorityID, metricKind, metricNamespace, key.labels,
			)
			if metricErr != nil {
				break
			}
			metricProviderLeases = append(metricProviderLeases, providerLease)
		}
		if metricErr != nil {
			closeMetricProviderLeases(metricProviderLeases)
			metricProviderLeases = nil
			// Optional metrics setup cannot fail the base resource view. The
			// projector already renders request/limit or allocatable accounting
			// with usage unavailable.
			projector = projector.WithMetrics(metrics.Snapshot{
				State: metrics.MeasurementUnavailable, Err: metricErr,
			})
			subscription.projector = projector
		}
		defer closeMetricProviderLeases(metricProviderLeases)
	} else if metricPlan.strategy == metricFetchPodObjects {
		// The exact point cache is driven later by revision-pinned viewport
		// interests, or by complete candidate coverage when metrics affect order
		// or membership. Start unavailable rather than ever broadening a
		// field-selected Pod query into an all-scope PodMetrics LIST.
		projector = projector.WithMetrics(metrics.Snapshot{
			State: metrics.MeasurementUnavailable,
		})
		subscription.projector = projector
	}
	if metricPlan.dependency.requiresCompleteCoverage() &&
		(len(metricProviderLeases) != 0 ||
			metricPlan.strategy == metricFetchPodObjects && subscription.podMetricResolver != nil) {
		subscription.metricsReconciling = true
	}
	if len(metricProviderLeases) == 0 {
		projector = subscription.projector
	}
	var warmRows []*kmgrv1.ResourceRow
	if usedWarmProjection {
		// Copy only the immutable slice header. Building the subscription's row
		// index happens outside Runtime.mu below.
		warmRows = cachedProjection.rows
	}
	if usedWarmProjection && len(metricProviderLeases) != 0 {
		// Metrics has an independent lifecycle from the raw resource store. The
		// close-time capture already trimmed this immutable snapshot to visible
		// UIDs, so seeding the catch-up projector remains O(1) on the warm Open
		// path. Fresh raw allocations/accounting are still recomputed normally.
		if warmMetrics := cachedProjection.metricSnapshot; warmMetrics != nil {
			subscription.projector = subscription.projector.WithMetrics(*warmMetrics)
		}
	}
	if err := openCtx.Err(); err != nil {
		r.abortOpen(attempt)
		return nil, err
	}
	r.mu.Lock()
	if r.closed || r.openings[streamKey] != attempt {
		r.mu.Unlock()
		r.abortOpen(attempt)
		if err := openCtx.Err(); err != nil {
			return nil, err
		}
		return nil, ErrStaleViewOpen
	}
	revision := entry.revision
	snapshotComplete := entry.snapshotComplete
	projectedStore := entry.currentStore()
	tableColumns := append([]metav1.TableColumnDefinition(nil), entry.tableColumns...)
	tableRows := make(map[string][]any, len(entry.tableRows))
	for uid, cells := range entry.tableRows {
		tableRows[uid] = append([]any(nil), cells...)
	}
	r.mu.Unlock()
	subscription.initializeServerTable(tableColumns, tableRows)

	var objects []*unstructured.Unstructured
	if !usedWarmProjection && !skipRetiredProjection {
		// UIDStore has its own lock. Taking this potentially large deterministic
		// snapshot outside Runtime.mu keeps all lifecycle operations responsive.
		objects, err = projectedStore.SnapshotContext(openCtx)
		if err != nil {
			r.abortOpen(attempt)
			return nil, err
		}

		if r.openProjectionHook != nil {
			r.openProjectionHook()
		}
		var projectErr error
		warmRows, projectErr = projector.ProjectContextWithAdditionalCells(
			openCtx, objects, subscription.serverCells,
		)
		if projectErr != nil {
			r.abortOpen(attempt)
			return nil, projectErr
		}
	}
	// Prepare all private subscription state before publication. No callback can
	// reach this subscription yet, so these helpers intentionally take no lock.
	// Do not traverse the full warm object cache for advisory keys here: the
	// automatic catalog query follows the usable snapshot and reads that cache,
	// while later LIST/WATCH upserts supply race-closing stream hints.
	subscription.initializeSealedRows(warmRows)
	if snapshotComplete && !usedWarmProjection && !skipRetiredProjection {
		subscription.seedInitialMetricEpochUnlocked(objects, subscription.serverCells)
	}
	var initialStatus *kmgrv1.ViewStatus
	r.mu.Lock()
	if r.closed || r.openings[streamKey] != attempt || openCtx.Err() != nil {
		r.mu.Unlock()
		r.abortOpen(attempt)
		if err := openCtx.Err(); err != nil {
			return nil, err
		}
		return nil, ErrViewClosed
	}
	if usedWarmProjection {
		initialStatus = statusForWarmEntry(entry)
		initialStatus.Freshness = kmgrv1.ViewFreshness_VIEW_FRESHNESS_STALE
		initialStatus.FromWarmCache = true
	} else if projectedStore.ResourceVersion() != "" || projectedStore.Len() != 0 || entry.state != resourceIdle || entry.transientSearchList != nil {
		initialStatus = statusForWarmEntry(entry)
	} else {
		initialStatus = &kmgrv1.ViewStatus{Freshness: kmgrv1.ViewFreshness_VIEW_FRESHNESS_LOADING}
	}
	previous := r.views[streamKey]
	captureReplacedProjection := previous != nil && previous.resource != entry &&
		r.canRetainWarmProjectionLocked(previous.resource)
	r.mu.Unlock()

	subscription.sealInitialUnlocked(
		initialStatus,
		warmRows,
		subscription.stageUntilReconciled && snapshotComplete && !subscription.metricsReconciling,
	)
	if r.openHandoffHook != nil {
		r.openHandoffHook()
	}

	// Freeze the committed generation before publication. Runtime lifecycle
	// paths never wait for Subscription.mu while holding Runtime.mu, so this is
	// the sole nested order: Subscription.mu then Runtime.mu. Work that resumes
	// afterward observes the retired subscription and cannot mutate or deliver
	// from it.
	if previous != nil {
		previous.mu.Lock()
	}
	var replacedProjection *warmProjection
	if captureReplacedProjection {
		replacedProjection = previous.captureWarmProjectionUnlocked()
	}
	// Revalidate after acquiring the handoff latch. A newer attempt or lifecycle
	// close may have won while the old subscription mutex was contended.
	r.mu.Lock()
	if r.closed || r.openings[streamKey] != attempt || openCtx.Err() != nil ||
		(r.views[streamKey] != nil && r.views[streamKey] != previous) {
		r.mu.Unlock()
		if previous != nil {
			previous.mu.Unlock()
		}
		r.abortOpen(attempt)
		if err := openCtx.Err(); err != nil {
			return nil, err
		}
		return nil, ErrStaleViewOpen
	}
	var restartPlan *resourceRestartPlan
	if entry.transientSearchList != nil && restartPending {
		// The command-palette LIST owns the shared store until its final page is
		// delivered. Preserve the explicit restart intent and fence that store
		// before the normal pipeline starts, rather than cancelling an unrelated
		// search or silently treating its snapshot as the requested fresh LIST.
		entry.restartRequested = true
		subscription.suppressInitialReconciliationUnlocked()
	} else if entry.transientSearchList == nil &&
		(restartPending || entry.restartRequested || entry.state == resourceStopping) {
		// Fence the previous run only after the replacement generation has
		// passed all off-lock projection and publication checks. The fresh
		// pipeline emits its own Listing/Resuming statuses to every subscriber.
		restartPlan = r.prepareResourceRestartLocked(entry, true)
	}
	storeChanged := entry.currentStore() != projectedStore
	if restartPlan != nil {
		subscription.prepareForResourceRestartUnlocked(restartPlan.fenceRun)
	} else if entry.state == resourceRestarting || storeChanged {
		// A concurrent shared restart may have swapped the raw store while this
		// opener projected outside Runtime.mu. This private subscription was not
		// necessarily captured by that restart plan, so align it with the same
		// run fence before publication.
		subscription.prepareForResourceRestartUnlocked(entry.runNumber)
	}
	// Runtime.mu linearizes publication with pipeline callbacks. Work applied
	// before this point advances revision and needs one authoritative catch-up;
	// work applied after publication sees the new subscriber directly.
	needsCatchup := usedWarmProjection || entry.revision != revision
	if needsCatchup && usesTableStream && entry.revision != revision {
		// The subscription was not yet published when the intervening callback
		// updated the entry's Table sidecar, so it did not receive that batch.
		// Refresh the sidecar while Runtime.mu excludes another callback; the
		// authoritative catch-up below then projects raw objects and server cells
		// from the same latest entry revision.
		subscription.replaceServerTableSnapshot(
			entry.tableColumns, entry.tableRows, true,
		)
	}
	// Completeness belongs to the same lifecycle revision as the off-lock
	// object snapshot. A final LIST may update the store before its callback can
	// advance entry.revision; using a later completeness bit with older objects
	// could otherwise misclassify a not-yet-seen page as deletion.
	if needsCatchup {
		// A callback that advanced the revision before publication is no longer
		// able to target this subscription. A compact warm projection may also
		// lag raw events already retained in the store. Its catch-up takes a fresh
		// store snapshot.
		subscription.discardInitialMetricEpochSeedUnlocked()
		subscription.snapshotComplete = entry.snapshotComplete
		if usedWarmProjection && entry.state == resourceRunning {
			subscription.warmCatchupRunNumber = entry.runNumber
		}
		subscription.markAuthoritativeResnapshotUnlocked()
	} else {
		subscription.snapshotComplete = snapshotComplete
	}
	replaced := r.views[streamKey]
	if replaced != nil {
		if replaced.resource != entry && replacedProjection != nil {
			if replaced.resource.closing == nil {
				replaced.resource.closing = make(map[*Subscription]struct{})
			}
			replaced.resource.closing[replaced] = struct{}{}
			if r.willDetachLastSubscriptionLocked(replaced) ||
				r.allAttachedSubscriptionsClosingLocked(replaced.resource) {
				r.retainWarmProjectionLocked(replaced.resource, replacedProjection)
			}
		}
		r.detachLocked(replaced)
	}
	// The active subscription now owns the presentation. Drop the cached copy
	// only at this publication point so an aborted Open leaves warm first paint
	// intact.
	entry.warmProjection = nil
	entry.subscribers[subscription] = struct{}{}
	r.views[streamKey] = subscription
	r.signalWarmCacheTelemetryLocked()
	var replacedMetrics metricSubscription
	if replaced != nil {
		replacedMetrics = replaced.retireLocked()
	}
	delete(r.openings, streamKey)
	r.releaseOpenAttemptLocked(attempt)
	r.trimOpenHistoryLocked()
	var startSubscribers []*Subscription
	var startError *kmgrv1.StructuredError
	if entry.state == resourceIdle && entry.transientSearchList == nil {
		startSubscribers, startError = r.startResourceLocked(entry)
	}
	r.mu.Unlock()
	if previous != nil {
		previous.mu.Unlock()
	}
	cancelOpen()
	if replacedMetrics != nil {
		replacedMetrics.Close()
	}
	if needsCatchup {
		subscription.scheduleAuthoritativeResnapshot()
	}
	deliverSubscriptionError(startSubscribers, startError)
	if restartPlan != nil {
		r.completeResourceRestart(restartPlan, true)
	}
	// Enqueue the base projection before metrics can publish. Starting this
	// goroutine after releasing the runtime lock also keeps a very fast metrics
	// response from contending with the base LIST/WATCH setup.
	if len(metricProviderLeases) != 0 {
		subscription.attachMetrics(subscribeMetricProviders(metricProviderScopes, metricProviderLeases))
	}
	// The pipeline may have crossed the initial LIST barrier while the open
	// handoff was being published. Read the subscription-owned completeness bit
	// under its mutex instead of consulting it concurrently with callbacks.
	subscription.mu.Lock()
	requestCompleteMetrics := subscription.snapshotComplete &&
		subscription.metricPlan.dependency.requiresCompleteCoverage()
	subscription.mu.Unlock()
	if requestCompleteMetrics {
		subscription.requestCompleteMetricCoverage()
	}
	return subscription, nil
}

func (r *Runtime) acquireOpenProjection(ctx context.Context) error {
	select {
	case r.openProjectionGate <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (r *Runtime) releaseOpenProjection() {
	<-r.openProjectionGate
}

func (r *Runtime) abortOpen(attempt *openAttempt) {
	if attempt == nil {
		return
	}
	r.mu.Lock()
	if r.openings[attempt.key] == attempt {
		delete(r.openings, attempt.key)
	}
	entry := attempt.entry
	if r.releaseOpenAttemptLocked(attempt) {
		r.cleanupUnusedEntryLocked(entry)
		if r.resources[entry.key] == entry {
			restoredWarm := attempt.wasWarm && r.finalizeWarmLocked(entry)
			if !restoredWarm && r.resources[entry.key] == entry {
				r.scheduleReleaseLocked(entry)
			}
		}
	}
	r.trimOpenHistoryLocked()
	r.mu.Unlock()
	attempt.cancel()
}

func (r *Runtime) releaseOpenAttemptLocked(attempt *openAttempt) bool {
	if attempt == nil || attempt.released || attempt.entry == nil {
		return false
	}
	attempt.released = true
	attempt.entry.openers--
	if attempt.entry.openers < 0 {
		panic("view: negative resource opener count")
	}
	return true
}

func (r *Runtime) trimOpenHistoryLocked() {
	for len(r.openHistory) > r.openHistoryLimit {
		removed := false
		for index, generation := range r.openHistory {
			if opening := r.openings[generation.key]; opening != nil && opening.generation == generation.generation {
				continue
			}
			if current := r.views[generation.key]; current != nil && current.generation == generation.generation {
				continue
			}
			// While a logical view is attached or opening, retain its newest
			// observed generation as the anti-replay floor even when that newer
			// attempt aborted. Otherwise a small global history can evict the
			// failed fence in favor of an older committed stream and incorrectly
			// admit the failed generation (or an intermediate one) again.
			if r.latestOpen[generation.key] == generation.generation &&
				(r.views[generation.key] != nil || r.openings[generation.key] != nil) {
				continue
			}
			r.openHistory = append(r.openHistory[:index], r.openHistory[index+1:]...)
			if r.latestOpen[generation.key] == generation.generation {
				delete(r.latestOpen, generation.key)
				delete(r.latestFilter, generation.key)
				for _, retained := range r.openHistory {
					if retained.key == generation.key && retained.generation > r.latestOpen[generation.key] {
						r.latestOpen[generation.key] = retained.generation
						r.latestFilter[generation.key] = retained.filterRevision
					}
				}
			}
			removed = true
			break
		}
		if !removed {
			return
		}
	}
}

func (r *Runtime) startResourceLocked(entry *resourceRuntime) ([]*Subscription, *kmgrv1.StructuredError) {
	if entry.transientSearchList != nil || entry.state != resourceIdle {
		return nil, nil
	}
	entry.runNumber++
	runNumber := entry.runNumber
	ctx, cancel := context.WithCancel(context.Background())
	entry.ctx = ctx
	entry.cancel = cancel
	entry.state = resourceRunning
	pipeline, err := watcher.NewPipeline(watcher.PipelineConfig{
		Client:                  entry.client,
		Store:                   entry.currentStore(),
		PageSize:                r.pageSize,
		WatchTimeout:            r.watchTimeout,
		ForceRelist:             !entry.snapshotComplete,
		InitialLastSynchronized: entry.lastStatus.LastSynchronized,
		ListOptions: metav1.ListOptions{
			LabelSelector: entry.key.labels,
			FieldSelector: entry.key.fields,
		},
		OnWatchOpenComplete: func() { r.watchOpened(entry, runNumber) },
		OnWatchOpen:         func() { r.watchOpening(entry, runNumber) },
		OnStatus:            func(status watcher.Status) { r.receiveStatus(entry, runNumber, status) },
		OnBatch:             func(batch watcher.Batch) { r.receiveBatch(entry, runNumber, batch) },
	})
	if err != nil {
		entry.state = resourceIdle
		entry.cancel()
		entry.cancel = nil
		entry.ctx = nil
		subscriptions := make([]*Subscription, 0, len(entry.subscribers))
		for subscription := range entry.subscribers {
			subscriptions = append(subscriptions, subscription)
		}
		return subscriptions, structuredViewError("watch resource", err, true)
	}
	go func() {
		run := pipeline.Run
		var err error
		if r.pipelineRunHook != nil {
			err = r.pipelineRunHook(ctx, run)
		} else {
			err = run(ctx)
		}
		r.resourceStopped(entry, runNumber, err)
	}()
	return nil, nil
}

// watchOpening is invoked by watcher.Pipeline immediately before it enters a
// client Watch call. Dynamic clients normally return quickly, but a broken
// transport/proxy can block there while ignoring context cancellation. Keep a
// bounded timer at the runtime lifecycle layer so a replacement run can be
// fenced and started without waiting for that goroutine to unwind.
func (r *Runtime) watchOpening(entry *resourceRuntime, runNumber uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || r.resources[entry.key] != entry || entry.runNumber != runNumber ||
		entry.state != resourceRunning {
		return
	}
	r.armWatchOpenTimerLocked(entry, runNumber)
}

// watchOpened ends the pre-open watchdog window as soon as the client Watch
// method returns. WatchList may still take time to deliver its initial events,
// so waiting for a later Watching status would misclassify a healthy but large
// stream as a blocked Watch call.
func (r *Runtime) watchOpened(entry *resourceRuntime, runNumber uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || r.resources[entry.key] != entry || entry.runNumber != runNumber ||
		entry.state != resourceRunning {
		return
	}
	r.stopWatchOpenTimerLocked(entry)
}

func (r *Runtime) armWatchOpenTimerLocked(entry *resourceRuntime, runNumber uint64) {
	if entry == nil || r.watchOpenTimeout <= 0 {
		return
	}
	if entry.watchOpenTimer != nil && entry.watchOpenRunNumber == runNumber {
		return
	}
	if entry.watchOpenTimer != nil {
		entry.watchOpenTimer.Stop()
	}
	entry.watchOpenRunNumber = runNumber
	entry.watchOpenTimer = time.AfterFunc(r.watchOpenTimeout, func() {
		r.watchOpenTimedOut(entry, runNumber)
	})
}

func (r *Runtime) stopWatchOpenTimerLocked(entry *resourceRuntime) {
	if entry == nil {
		return
	}
	if entry.watchOpenTimer != nil {
		entry.watchOpenTimer.Stop()
		entry.watchOpenTimer = nil
	}
	entry.watchOpenRunNumber = 0
}

func (r *Runtime) watchOpenTimedOut(entry *resourceRuntime, runNumber uint64) {
	var (
		plan          *resourceRestartPlan
		failure       *kmgrv1.StructuredError
		failureStatus *kmgrv1.ViewStatus
	)
	r.mu.Lock()
	if r.closed || r.resources[entry.key] != entry || entry.runNumber != runNumber ||
		entry.state != resourceRunning || entry.watchOpenRunNumber != runNumber {
		r.mu.Unlock()
		return
	}
	r.stopWatchOpenTimerLocked(entry)
	entry.watchOpenTimeouts++
	plan = r.prepareResourceRestartLocked(
		entry,
		false,
	)
	if plan == nil {
		r.mu.Unlock()
		return
	}
	if entry.watchOpenTimeouts > maxAutomaticWatchOpenRetries {
		// Keep the failure bounded. A cancellation-resistant client can leave
		// each retired goroutine blocked forever; after a small number of
		// attempts, stop spawning replacements and require the user action.
		entry.lastStatus = watcher.Status{
			Phase:            watcher.PhaseReconnecting,
			Stale:            len(plan.subscriptions) != 0,
			LastSynchronized: entry.lastStatus.LastSynchronized,
			Error: fmt.Errorf(
				"watch open exceeded %s after %d attempts",
				r.watchOpenTimeout, entry.watchOpenTimeouts,
			),
		}
		failure = structuredViewError("watch resource", entry.lastStatus.Error, true)
		failure.Reason = "WatchOpenTimeout"
		failure.Message = "The Kubernetes resource stream did not open in time. Use Restart Resource Stream to try again."
		failureStatus = statusFromPipeline(entry.lastStatus)
	}
	r.mu.Unlock()
	subscriptions, committed := r.completeResourceRestart(plan, failure == nil)
	if committed && failure != nil {
		deliverSubscriptionStatus(subscriptions, failureStatus)
		deliverSubscriptionError(subscriptions, failure)
	}
}

// prepareResourceRestartLocked retires the current raw run without waiting
// for its client Watch call to return. Runtime.mu must be held. The old run
// keeps its own store pointer and is fenced as soon as runNumber advances;
// the replacement therefore cannot be contaminated by a late event from a
// cancellation-resistant client. A user/open lifecycle restart resets the
// bounded automatic-timeout counter; watchdog retries pass false so repeated
// failures remain bounded and eventually require an explicit restart.
func (r *Runtime) prepareResourceRestartLocked(
	entry *resourceRuntime,
	resetWatchOpenFailures bool,
) *resourceRestartPlan {
	if entry == nil {
		return nil
	}
	if entry.transientSearchList != nil {
		entry.restartRequested = true
		return nil
	}
	if entry.watchOpenTimer != nil {
		entry.watchOpenTimer.Stop()
		entry.watchOpenTimer = nil
	}
	entry.watchOpenRunNumber = 0
	if resetWatchOpenFailures {
		entry.watchOpenTimeouts = 0
	}
	if entry.releaseTimer != nil {
		entry.releaseTimer.Stop()
		entry.releaseTimer = nil
	}
	if entry.cancel != nil {
		entry.cancel()
	}
	// Advance the fence before publishing the replacement state. Even if the
	// opener is cancelled before startResourceLocked runs, callbacks from the
	// retired pipeline are ignored.
	entry.runNumber++
	fenceRun := entry.runNumber
	previousStore := entry.currentStore()
	hadData := previousStore != nil &&
		(previousStore.Len() != 0 || previousStore.ResourceVersion() != "")
	lastSynchronized := entry.lastStatus.LastSynchronized
	entry.ctx = nil
	entry.cancel = nil
	entry.replaceStore(store.New())
	entry.snapshotComplete = false
	entry.revision++
	entry.tableColumns = nil
	entry.tableRows = nil
	entry.warmProjection = nil
	entry.restartRequested = false
	entry.lastStatus = watcher.Status{
		Phase:            watcher.PhaseListing,
		Stale:            hadData,
		LastSynchronized: lastSynchronized,
	}
	// Do not start the replacement until every captured subscriber has crossed
	// the same fence. This leaves no window where a batch from the new run can
	// overtake presentation reset, and avoids Runtime/Subscription lock
	// inversion because the reset happens after Runtime.mu is released.
	entry.state = resourceRestarting

	subscriptions := make([]*Subscription, 0, len(entry.subscribers))
	for subscription := range entry.subscribers {
		subscriptions = append(subscriptions, subscription)
	}
	return &resourceRestartPlan{
		entry: entry, fenceRun: fenceRun, subscriptions: subscriptions,
	}
}

// completeResourceRestart moves every already-published presentation across
// the raw-run fence before the replacement pipeline can start. Subscribers
// published while the plan is in resourceRestarting state perform the same
// private reset in OpenContext, so they need not be present in plan.
func (r *Runtime) completeResourceRestart(
	plan *resourceRestartPlan,
	start bool,
) ([]*Subscription, bool) {
	if plan == nil || plan.entry == nil {
		return nil, false
	}
	for _, subscription := range plan.subscriptions {
		subscription.prepareForResourceRestart(plan.fenceRun)
	}

	var (
		startSubscribers []*Subscription
		startError       *kmgrv1.StructuredError
	)
	r.mu.Lock()
	entry := plan.entry
	if r.closed || r.resources[entry.key] != entry ||
		entry.runNumber != plan.fenceRun || entry.state != resourceRestarting {
		r.mu.Unlock()
		return nil, false
	}
	entry.state = resourceIdle
	subscriptions := make([]*Subscription, 0, len(entry.subscribers))
	for subscription := range entry.subscribers {
		subscriptions = append(subscriptions, subscription)
	}
	if start && len(subscriptions) != 0 {
		startSubscribers, startError = r.startResourceLocked(entry)
	} else if len(subscriptions) == 0 {
		// No consumer remains. The reset still fences the blocked run, but does
		// not create another unobserved network stream.
		r.scheduleReleaseLocked(entry)
	}
	r.mu.Unlock()
	deliverSubscriptionError(startSubscribers, startError)
	return subscriptions, true
}

func deliverSubscriptionError(subscriptions []*Subscription, value *kmgrv1.StructuredError) {
	if value == nil {
		return
	}
	for _, subscription := range subscriptions {
		subscription.setError(value)
	}
}

func deliverSubscriptionStatus(subscriptions []*Subscription, value *kmgrv1.ViewStatus) {
	if value == nil {
		return
	}
	for _, subscription := range subscriptions {
		subscription.setStatus(value)
	}
}

func (r *Runtime) receiveStatus(entry *resourceRuntime, runNumber uint64, status watcher.Status) {
	r.mu.Lock()
	if entry.runNumber != runNumber || entry.state != resourceRunning {
		r.mu.Unlock()
		return
	}
	switch status.Phase {
	case watcher.PhaseResuming:
		// OnWatchOpen normally arms this first. Keeping the status path as a
		// fallback also protects custom Pipeline hooks that emit Resuming
		// without invoking the lifecycle callback.
		r.armWatchOpenTimerLocked(entry, runNumber)
	case watcher.PhaseListing, watcher.PhaseWatching, watcher.PhaseReconnecting:
		r.stopWatchOpenTimerLocked(entry)
	}
	if status.Phase == watcher.PhaseWatching {
		entry.watchOpenTimeouts = 0
	}
	if status.LastSynchronized.Before(entry.lastStatus.LastSynchronized) {
		status.LastSynchronized = entry.lastStatus.LastSynchronized
	}
	if status.Phase == watcher.PhaseListing {
		// Once a LIST starts, progressive pages make the store a mixture of the
		// prior snapshot and the replacement snapshot until the final page. Keep
		// that state explicitly incomplete even if the run is cancelled midway.
		entry.snapshotComplete = false
	}
	entry.lastStatus = status
	translated := statusFromPipeline(status)
	subscriptions := make([]*Subscription, 0, len(entry.subscribers))
	for subscription := range entry.subscribers {
		subscriptions = append(subscriptions, subscription)
	}
	r.mu.Unlock()
	for _, subscription := range subscriptions {
		subscription.setResourceStatus(runNumber, translated)
	}
}

func (r *Runtime) receiveBatch(entry *resourceRuntime, runNumber uint64, batch watcher.Batch) {
	r.mu.Lock()
	if r.closed || r.resources[entry.key] != entry || entry.runNumber != runNumber ||
		(entry.state != resourceRunning && entry.state != resourceStopping) {
		r.mu.Unlock()
		return
	}
	subscriptions := r.prepareEntryBatchLocked(entry, batch)
	r.mu.Unlock()

	for _, subscription := range subscriptions {
		subscription.applyResourceBatch(runNumber, batch)
	}
}

// prepareEntryBatchLocked mirrors the lifecycle work needed for both ordinary
// pipeline batches and command-palette LIST pages. Runtime.mu must be held.
func (r *Runtime) prepareEntryBatchLocked(
	entry *resourceRuntime,
	batch watcher.Batch,
) []*Subscription {
	entry.revision++
	applyResourceTableBatch(entry, batch)
	// UIDStore retained weights change before this lifecycle callback. Publish
	// a coalesced hint even when no view is attached so progressive LIST pages
	// and background WATCH updates are reflected in cache telemetry.
	r.signalWarmCacheTelemetryLocked()
	if batch.SynchronizedAt.After(entry.lastStatus.LastSynchronized) {
		entry.lastStatus.LastSynchronized = batch.SynchronizedAt
	}
	if batch.ResourceVersion != "" && (batch.SnapshotComplete || !batch.FromList) {
		entry.lastStatus.ResourceVersion = batch.ResourceVersion
	}
	if batch.FromList {
		entry.lastStatus.PagesListed = batch.ListPage
		entry.lastStatus.ObjectsListed = batch.ObjectsListed
	}
	// Capture consumers while the lifecycle graph is stable, then project the
	// batch after releasing the runtime-wide mutex. Subscription.applyBatch has
	// its own closed/generation gate, so a concurrent detach is safe.
	subscriptions := make([]*Subscription, 0, len(entry.subscribers))
	for subscription := range entry.subscribers {
		subscriptions = append(subscriptions, subscription)
	}
	if batch.SnapshotComplete {
		entry.snapshotComplete = true
	}
	return subscriptions
}

func applyResourceTableBatch(entry *resourceRuntime, batch watcher.Batch) {
	if entry == nil {
		return
	}
	for _, uid := range batch.RemovedUIDs {
		delete(entry.tableRows, string(uid))
	}
	if batch.Table == nil {
		return
	}
	if batch.Table.Disabled {
		entry.tableColumns = nil
		entry.tableRows = nil
		return
	}
	if len(batch.Table.Columns) != 0 {
		entry.tableColumns = append([]metav1.TableColumnDefinition(nil), batch.Table.Columns...)
	}
	if len(batch.Table.Cells) == 0 {
		return
	}
	if entry.tableRows == nil {
		entry.tableRows = make(map[string][]any, len(batch.Table.Cells))
	}
	for uid, cells := range batch.Table.Cells {
		entry.tableRows[string(uid)] = append([]any(nil), cells...)
	}
}

func (r *Runtime) resourceStopped(entry *resourceRuntime, runNumber uint64, err error) {
	r.mu.Lock()
	if r.closed || r.resources[entry.key] != entry || entry.runNumber != runNumber {
		r.mu.Unlock()
		return
	}
	wasStopping := entry.state == resourceStopping
	r.stopWatchOpenTimerLocked(entry)
	entry.state = resourceIdle
	entry.cancel = nil
	entry.ctx = nil
	if len(entry.subscribers) == 0 {
		if wasStopping {
			r.finalizeWarmLocked(entry)
		} else {
			r.scheduleReleaseLocked(entry)
		}
		r.mu.Unlock()
		return
	}
	if errors.Is(err, context.Canceled) {
		var startSubscribers []*Subscription
		var startError *kmgrv1.StructuredError
		if !r.closed && entry.transientSearchList == nil {
			startSubscribers, startError = r.startResourceLocked(entry)
		}
		r.mu.Unlock()
		deliverSubscriptionError(startSubscribers, startError)
		return
	}
	subscriptions := make([]*Subscription, 0, len(entry.subscribers))
	for subscription := range entry.subscribers {
		subscriptions = append(subscriptions, subscription)
	}
	r.mu.Unlock()
	failure := structuredViewError("watch resource", err, true)
	for _, subscription := range subscriptions {
		subscription.setResourceError(runNumber, failure)
	}
}

func (r *Runtime) Cancel(sessionID, viewID string, generation uint64) bool {
	r.mu.Lock()
	key := viewKey{sessionID: sessionID, viewID: viewID}
	if attempt := r.openings[key]; attempt != nil && attempt.generation == generation {
		attempt.cancel()
		r.mu.Unlock()
		return true
	}
	subscription := r.views[key]
	if subscription == nil || subscription.generation != generation {
		r.mu.Unlock()
		return false
	}
	registeredClose, captureProjection := r.prepareSubscriptionCloseLocked(subscription)
	if !registeredClose {
		r.mu.Unlock()
		return true
	}
	r.mu.Unlock()

	// Match replacement publication's sole nested lock order. A delivery that
	// finishes before this latch is persisted; work after retirement cannot
	// mutate the logical view contract.
	subscription.mu.Lock()
	var projection *warmProjection
	if captureProjection {
		projection = subscription.captureWarmProjectionUnlocked()
	}
	r.mu.Lock()
	if r.views[key] != subscription || subscription.generation != generation {
		r.cancelSubscriptionCloseLocked(subscription)
		r.mu.Unlock()
		subscription.mu.Unlock()
		return false
	}
	if projection != nil && (r.willDetachLastSubscriptionLocked(subscription) ||
		r.allAttachedSubscriptionsClosingLocked(subscription.resource)) {
		r.retainWarmProjectionLocked(subscription.resource, projection)
	}
	r.detachLocked(subscription)
	metricSubscription := subscription.retireLocked()
	r.trimOpenHistoryLocked()
	r.mu.Unlock()
	subscription.mu.Unlock()
	if metricSubscription != nil {
		metricSubscription.Close()
	}
	return true
}

func (r *Runtime) detachLocked(subscription *Subscription) {
	if subscription == nil || r.views[subscription.key] != subscription {
		return
	}
	delete(r.views, subscription.key)
	entry := subscription.resource
	delete(entry.subscribers, subscription)
	delete(entry.closing, subscription)
	if len(entry.closing) == 0 {
		entry.closing = nil
	}
	r.cleanupUnusedEntryLocked(entry)
	r.scheduleReleaseLocked(entry)
	r.signalWarmCacheTelemetryLocked()
}

// willDetachLastSubscriptionLocked reports whether removing subscription
// would leave its raw resource with no subscriber or dependent. An in-flight
// opener does not suppress provisional capture: successful same-resource
// publication drops that candidate, while an aborted opener leaves it usable.
// Runtime.mu must be held.
func (r *Runtime) willDetachLastSubscriptionLocked(subscription *Subscription) bool {
	if subscription == nil || r.views[subscription.key] != subscription || subscription.resource == nil {
		return false
	}
	entry := subscription.resource
	if len(entry.subscribers) != 1 {
		return false
	}
	_, attached := entry.subscribers[subscription]
	return attached
}

// prepareSubscriptionCloseLocked marks one closing stream before it releases
// Runtime.mu. If every attached stream is now closing, exactly that caller
// freezes a provisional candidate; it may be retained before the other closes
// finish so concurrent final detaches cannot all miss capture.
func (r *Runtime) prepareSubscriptionCloseLocked(subscription *Subscription) (bool, bool) {
	if subscription == nil || r.views[subscription.key] != subscription || subscription.resource == nil {
		return false, false
	}
	entry := subscription.resource
	if entry.closing == nil {
		entry.closing = make(map[*Subscription]struct{})
	}
	if _, duplicate := entry.closing[subscription]; duplicate {
		return false, false
	}
	entry.closing[subscription] = struct{}{}
	return true, r.allAttachedSubscriptionsClosingLocked(entry) &&
		r.canRetainWarmProjectionLocked(entry)
}

func (r *Runtime) allAttachedSubscriptionsClosingLocked(entry *resourceRuntime) bool {
	if entry == nil || len(entry.subscribers) == 0 || len(entry.closing) < len(entry.subscribers) {
		return false
	}
	for subscription := range entry.subscribers {
		if _, closing := entry.closing[subscription]; !closing {
			return false
		}
	}
	return true
}

func (r *Runtime) cancelSubscriptionCloseLocked(subscription *Subscription) {
	if subscription != nil && subscription.resource != nil {
		entry := subscription.resource
		delete(entry.closing, subscription)
		if len(entry.closing) == 0 {
			entry.closing = nil
		}
	}
}

// canRetainWarmProjectionLocked rejects compact-row work up front when the
// authoritative raw store already fills an individual warm-cache ceiling.
// UIDStore maintains both values incrementally, so this remains O(1) while
// Runtime.mu is held. Aggregate LRU pressure is still handled at admission.
func (r *Runtime) canRetainWarmProjectionLocked(entry *resourceRuntime) bool {
	store := entry.currentStore()
	if store == nil || store.Len() > r.warmObjectLimit ||
		store.Len() > r.warmObjectLimitPerAuthority {
		return false
	}
	rawBytes := store.RetainedBytes()
	return rawBytes < r.warmByteLimit && rawBytes < r.warmByteLimitPerAuthority
}

func (r *Runtime) retainWarmProjectionLocked(entry *resourceRuntime, projection *warmProjection) {
	if entry == nil || projection == nil || projection.retainedBytes < 0 {
		return
	}
	retainedBytes := saturatingProjectionBytes(
		entry.currentStore().RetainedBytes(), projection.retainedBytes,
	)
	if retainedBytes > r.warmByteLimit || retainedBytes > r.warmByteLimitPerAuthority {
		entry.warmProjection = nil
		return
	}
	entry.warmProjection = projection
}

func (r *Runtime) cleanupUnusedEntryLocked(entry *resourceRuntime) {
	if entry == nil || entry.openers != 0 || len(entry.subscribers) != 0 {
		return
	}
	if transient := entry.transientSearchList; transient != nil && transient.view == entry &&
		len(entry.subscribers) == 0 {
		// A valid terminal LIST is still delivering its final projection. Keep
		// the entry and coordinator association until that delivery gate opens;
		// a same-key Open can then reuse the complete store instead of starting a
		// duplicate LIST, and the reusable search offer remains truthful.
		if transient.terminal && entry.currentStore().ResourceVersion() != "" {
			r.scheduleReleaseLocked(entry)
		} else {
			transient.view = nil
			entry.transientSearchList = nil
			entry.transientSearchUsesStore = false
			// An incomplete shared LIST must never enter the normal warm cache or
			// be found by a later Open as an ordinary resource entry. The transient
			// coordinator retains the store and a later compatible view may rejoin it.
			if r.resources[entry.key] == entry {
				delete(r.resources, entry.key)
			}
			if entry.releaseTimer != nil {
				entry.releaseTimer.Stop()
				entry.releaseTimer = nil
			}
			if !transient.storeBounded {
				// The shared store was allowed to exceed the snapshot budget only
				// because this view needed progressive rows. Once it leaves, stop
				// retaining further pages and make later views run their own LIST.
				transient.store = nil
				transient.joinable = false
			}
			if len(transient.searches) == 0 {
				r.cancelTransientSearchListLocked(transient)
			}
		}
	}
}
func (r *Runtime) scheduleReleaseLocked(entry *resourceRuntime) {
	if entry == nil || entry.transientSearchList != nil ||
		entry.state == resourceStopping || entry.state == resourceRestarting ||
		entry.openers != 0 ||
		len(entry.subscribers) != 0 || entry.releaseTimer != nil {
		return
	}
	key := entry.key
	runNumber := entry.runNumber
	entry.releaseTimer = time.AfterFunc(r.releaseDelay, func() {
		r.releaseResource(key, entry, runNumber)
	})
}

func (r *Runtime) releaseResource(key resourceKey, entry *resourceRuntime, runNumber uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || r.resources[key] != entry || entry.openers != 0 ||
		len(entry.subscribers) != 0 || entry.runNumber != runNumber {
		return
	}
	entry.releaseTimer = nil
	switch entry.state {
	case resourceRunning:
		if entry.cancel == nil {
			return
		}
		r.stopWatchOpenTimerLocked(entry)
		entry.cancel()
		entry.state = resourceStopping
	case resourceStopping:
		return
	case resourceIdle:
		r.finalizeWarmLocked(entry)
	}
}

// getWarmLocked touches both the process-wide and per-authority LRUs. Warm
// entries are admitted to both budgets as one logical cache; repairing a
// one-sided entry defensively avoids bypassing either limit after test fixture
// injection or future recovery code.
func (r *Runtime) getWarmLocked(
	key resourceKey,
) (watcher.WarmEntry[*resourceRuntime], bool) {
	global, inGlobal := r.warm.Get(key)
	authorityCache := r.warmByAuthority[key.authorityID]
	var authority watcher.WarmEntry[*resourceRuntime]
	inAuthority := false
	if authorityCache != nil {
		authority, inAuthority = authorityCache.Get(key)
	}
	if inGlobal && inAuthority {
		return global, true
	}
	if inGlobal {
		r.warm.Remove(key)
	}
	if inAuthority {
		authorityCache.Remove(key)
	}
	r.removeEmptyAuthorityWarmLocked(key.authorityID)
	if inGlobal || inAuthority {
		r.signalWarmCacheTelemetryLocked()
	}
	return authority, false
}

// putWarmLocked admits an inactive resource only when it fits both the
// per-authority and process-wide budgets. Eviction from either LRU is mirrored
// into the other so a busy cluster cannot retain ghost entries or consume the
// budget reserved for other open authorities.
func (r *Runtime) putWarmLocked(
	key resourceKey,
	entry watcher.WarmEntry[*resourceRuntime],
) ([]resourceKey, bool) {
	if !r.warmCacheAuthorityIsActiveLocked(key.authorityID) {
		return nil, false
	}
	if entry.ObjectCount > r.warmObjectLimit || entry.ObjectCount > r.warmObjectLimitPerAuthority ||
		entry.ByteCount > r.warmByteLimit || entry.ByteCount > r.warmByteLimitPerAuthority {
		return nil, false
	}
	authorityCache := r.warmByAuthority[key.authorityID]
	if authorityCache == nil {
		authorityCache = watcher.NewWarmCache[resourceKey, *resourceRuntime](
			r.warmViewLimitPerAuthority, r.warmObjectLimitPerAuthority, r.warmByteLimitPerAuthority,
		)
		r.warmByAuthority[key.authorityID] = authorityCache
	}
	authorityEvicted, admitted := authorityCache.Put(key, entry)
	if !admitted {
		r.removeEmptyAuthorityWarmLocked(key.authorityID)
		return nil, false
	}
	evicted := make([]resourceKey, 0, len(authorityEvicted)+1)
	seen := make(map[resourceKey]struct{}, cap(evicted))
	appendEvicted := func(evictedKey resourceKey) {
		if _, exists := seen[evictedKey]; exists {
			return
		}
		seen[evictedKey] = struct{}{}
		evicted = append(evicted, evictedKey)
	}
	for _, evictedKey := range authorityEvicted {
		r.warm.Remove(evictedKey)
		appendEvicted(evictedKey)
	}
	globalEvicted, admitted := r.warm.Put(key, entry)
	if !admitted {
		authorityCache.Remove(key)
		r.removeEmptyAuthorityWarmLocked(key.authorityID)
		r.recordWarmBudgetEvictionsLocked(evicted)
		if len(evicted) != 0 {
			r.signalWarmCacheTelemetryLocked()
		}
		return evicted, false
	}
	for _, evictedKey := range globalEvicted {
		if cache := r.warmByAuthority[evictedKey.authorityID]; cache != nil {
			cache.Remove(evictedKey)
			r.removeEmptyAuthorityWarmLocked(evictedKey.authorityID)
		}
		appendEvicted(evictedKey)
	}
	r.removeEmptyAuthorityWarmLocked(key.authorityID)
	r.recordWarmBudgetEvictionsLocked(evicted)
	r.signalWarmCacheTelemetryLocked()
	return evicted, true
}

func (r *Runtime) warmCacheAuthorityIsActiveLocked(authorityID string) bool {
	return r.warmCacheAuthorityActive == nil || r.warmCacheAuthorityActive(authorityID)
}

func (r *Runtime) removeWarmLocked(key resourceKey) bool {
	removed := r.warm.Remove(key)
	if cache := r.warmByAuthority[key.authorityID]; cache != nil {
		removed = cache.Remove(key) || removed
		r.removeEmptyAuthorityWarmLocked(key.authorityID)
	}
	if removed {
		r.signalWarmCacheTelemetryLocked()
	}
	return removed
}

func (r *Runtime) removeEmptyAuthorityWarmLocked(authorityID string) {
	if cache := r.warmByAuthority[authorityID]; cache != nil && cache.Len() == 0 {
		delete(r.warmByAuthority, authorityID)
	}
}

// finalizeWarmLocked publishes only quiescent stores. A running pipeline may
// still finish a selected event after cancellation, so warm-cache object/RV
// accounting is not stable until Run acknowledges exit.
func (r *Runtime) finalizeWarmLocked(entry *resourceRuntime) bool {
	if entry == nil || r.closed || r.resources[entry.key] != entry || entry.state != resourceIdle ||
		entry.openers != 0 || len(entry.subscribers) != 0 || entry.transientSearchList != nil {
		return false
	}
	key := entry.key
	currentStore := entry.currentStore()
	rawBytes := currentStore.RetainedBytes()
	retainedBytes := rawBytes
	if entry.warmProjection != nil {
		retainedBytes = saturatingProjectionBytes(retainedBytes, entry.warmProjection.retainedBytes)
		// Compact rows are an optimization layered over the authoritative raw
		// store. If their combined graph is individually too large, retain the
		// raw cache alone instead of rejecting the previously useful store.
		if retainedBytes > r.warmByteLimit || retainedBytes > r.warmByteLimitPerAuthority {
			entry.warmProjection = nil
			retainedBytes = rawBytes
		}
	}
	evicted, admitted := r.putWarmLocked(key, watcher.WarmEntry[*resourceRuntime]{
		Value:            entry,
		ObjectCount:      currentStore.Len(),
		ByteCount:        retainedBytes,
		ResourceVersion:  currentStore.ResourceVersion(),
		LastSynchronized: entry.lastStatus.LastSynchronized,
		Complete:         entry.snapshotComplete && currentStore.ResourceVersion() != "",
	})
	if !admitted && r.resources[key] == entry {
		entry.warmProjection = nil
		delete(r.resources, key)
	}
	for _, evictedKey := range evicted {
		if evictedEntry := r.resources[evictedKey]; evictedEntry != nil &&
			evictedEntry.openers == 0 && len(evictedEntry.subscribers) == 0 &&
			evictedEntry.state == resourceIdle {
			evictedEntry.warmProjection = nil
			delete(r.resources, evictedKey)
		}
	}
	return admitted
}

func (r *Runtime) closeSubscription(subscription *Subscription) {
	r.mu.Lock()
	if current := r.views[subscription.key]; current != subscription {
		r.mu.Unlock()
		return
	}
	registeredClose, captureProjection := r.prepareSubscriptionCloseLocked(subscription)
	if !registeredClose {
		r.mu.Unlock()
		return
	}
	r.mu.Unlock()

	subscription.mu.Lock()
	var projection *warmProjection
	if captureProjection {
		projection = subscription.captureWarmProjectionUnlocked()
	}
	r.mu.Lock()
	if current := r.views[subscription.key]; current != subscription {
		r.cancelSubscriptionCloseLocked(subscription)
		r.mu.Unlock()
		subscription.mu.Unlock()
		return
	}
	if projection != nil && (r.willDetachLastSubscriptionLocked(subscription) ||
		r.allAttachedSubscriptionsClosingLocked(subscription.resource)) {
		r.retainWarmProjectionLocked(subscription.resource, projection)
	}
	r.detachLocked(subscription)
	metricSubscription := subscription.retireLocked()
	r.trimOpenHistoryLocked()
	r.mu.Unlock()
	subscription.mu.Unlock()
	if metricSubscription != nil {
		metricSubscription.Close()
	}
}

func (r *Runtime) Close() {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return
	}
	r.closed = true
	attempts := make([]*openAttempt, 0, len(r.openings))
	for _, attempt := range r.openings {
		attempts = append(attempts, attempt)
	}
	clear(r.openings)
	clear(r.latestOpen)
	clear(r.latestFilter)
	r.openHistory = nil
	subscriptions := make([]*Subscription, 0, len(r.views))
	for _, subscription := range r.views {
		subscriptions = append(subscriptions, subscription)
	}
	clear(r.views)
	for key, entry := range r.resources {
		r.stopWatchOpenTimerLocked(entry)
		if entry.releaseTimer != nil {
			entry.releaseTimer.Stop()
		}
		if entry.cancel != nil {
			entry.cancel()
		}
		entry.state = resourceIdle
		r.removeWarmLocked(key)
		delete(r.resources, key)
	}
	// Defensive reset also releases any one-sided fixture or recovery entry
	// that was not reachable through resources. Shutdown is not an eviction.
	r.warm = watcher.NewWarmCache[resourceKey, *resourceRuntime](
		r.warmViewLimit, r.warmObjectLimit, r.warmByteLimit,
	)
	clear(r.warmByAuthority)
	r.signalWarmCacheTelemetryLocked()
	for key, snapshot := range r.searchSnapshots {
		r.removeSearchSnapshotLocked(key, snapshot)
	}
	for _, transient := range r.transientSearchLists {
		r.closeTransientSearchListLocked(transient, ErrViewClosed)
	}
	r.mu.Unlock()
	r.stopWarmCacheTelemetry()
	for _, attempt := range attempts {
		attempt.cancel()
	}
	for _, subscription := range subscriptions {
		subscription.close()
	}
	if releaser, ok := r.metrics.(interface{ ReleaseIdleProviders() int }); ok {
		releaser.ReleaseIdleProviders()
	}
}

func (r *Runtime) consumeSearchSnapshotLocked(key searchSnapshotKey) *completedSearchSnapshot {
	snapshot := r.searchSnapshots[key]
	if snapshot == nil {
		return nil
	}
	if !time.Now().Before(snapshot.expiresAt) {
		r.removeSearchSnapshotLocked(key, snapshot)
		return nil
	}
	r.removeSearchSnapshotLocked(key, snapshot)
	return snapshot
}

// completedSearchSnapshot returns a live bounded snapshot without removing it
// from the query-reuse cache or consuming an eligible full-object view
// handoff. The UIDStore owns its synchronization, and callers keep the returned
// snapshot reachable while scanning even if expiration or a view concurrently
// removes it from Runtime's cache.
func (r *Runtime) completedSearchSnapshot(key searchSnapshotKey) *completedSearchSnapshot {
	r.mu.Lock()
	defer r.mu.Unlock()
	snapshot := r.searchSnapshots[key]
	if snapshot == nil {
		return nil
	}
	if !time.Now().Before(snapshot.expiresAt) {
		r.removeSearchSnapshotLocked(key, snapshot)
		return nil
	}
	return snapshot
}

func (r *Runtime) expireSearchSnapshot(key searchSnapshotKey, snapshot *completedSearchSnapshot) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.removeSearchSnapshotLocked(key, snapshot)
}

func (r *Runtime) removeSearchSnapshotLocked(key searchSnapshotKey, expected *completedSearchSnapshot) {
	current := r.searchSnapshots[key]
	if current == nil || (expected != nil && current != expected) {
		return
	}
	delete(r.searchSnapshots, key)
	if current.expirationTimer != nil {
		current.expirationTimer.Stop()
		current.expirationTimer = nil
	}
	r.searchSnapshotObjects -= current.objectCount
	if r.searchSnapshotObjects < 0 {
		// Defensive only: every mutation is serialized under Runtime.mu.
		r.searchSnapshotObjects = 0
	}
	r.signalWarmCacheTelemetryLocked()
}

func (r *Runtime) oldestSearchSnapshotLocked() (searchSnapshotKey, *completedSearchSnapshot) {
	var oldestKey searchSnapshotKey
	var oldest *completedSearchSnapshot
	for key, snapshot := range r.searchSnapshots {
		if oldest == nil || snapshot.sequence < oldest.sequence {
			oldestKey, oldest = key, snapshot
		}
	}
	return oldestKey, oldest
}

// ActiveResourceCount is exposed for lifecycle tests and redacted diagnostics.
func (r *Runtime) ActiveResourceCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	count := 0
	for _, entry := range r.resources {
		if entry.state == resourceRunning {
			count++
		}
	}
	return count
}

// DiscoverOptionalResources inspects only core/v1 Node and Pod stores that are
// already active or warm for the requested session authority. It deliberately
// does not call OpenResource, create a Metrics API provider, or change any
// watcher lifetime. Results may therefore be partial while the base view is
// loading or when retained Pod stores are namespace/selector scoped.
func (r *Runtime) DiscoverOptionalResources(ctx context.Context, sessionID string) (OptionalResourceCatalog, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return OptionalResourceCatalog{}, err
	}
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return OptionalResourceCatalog{}, fmt.Errorf("%w: cluster session is required", ErrInvalidView)
	}
	authoritySource, ok := r.source.(interface {
		AuthorityID(string) (string, bool)
	})
	if !ok {
		return OptionalResourceCatalog{}, ErrSessionNotFound
	}
	authorityID, ok := authoritySource.AuthorityID(sessionID)
	if !ok {
		return OptionalResourceCatalog{}, ErrSessionNotFound
	}

	type cachedStore struct {
		key      resourceKey
		store    *store.UIDStore
		complete bool
	}
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return OptionalResourceCatalog{}, ErrViewClosed
	}
	entries := make([]cachedStore, 0, len(r.resources))
	for key, entry := range r.resources {
		currentStore := entry.currentStore()
		if key.authorityID != authorityID || key.group != "" || key.version != "v1" ||
			(key.resource != "nodes" && key.resource != "pods") || currentStore == nil {
			continue
		}
		entries = append(entries, cachedStore{
			key: key, store: currentStore, complete: entry.snapshotComplete,
		})
	}
	acceleratorProvider, _ := r.columns.(AcceleratorConfigProvider)
	r.mu.Unlock()

	accelerators := metrics.AcceleratorConfig{}
	if acceleratorProvider != nil {
		accelerators = acceleratorProvider.AcceleratorConfig()
	}
	nodesByUID := make(map[types.UID]*corev1.Node)
	podsByUID := make(map[types.UID]*corev1.Pod)
	result := OptionalResourceCatalog{Accelerators: accelerators}
	nodesClusterWideComplete, podsClusterWideComplete := false, false
	conversionIncomplete := false
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return OptionalResourceCatalog{}, err
		}
		switch entry.key.resource {
		case "nodes":
			result.NodesCacheAvailable = true
			if entry.complete && entry.key.namespace == "" && entry.key.labels == "" && entry.key.fields == "" {
				nodesClusterWideComplete = true
			}
			for _, object := range entry.store.Snapshot() {
				var node corev1.Node
				if object != nil && k8sruntime.DefaultUnstructuredConverter.FromUnstructured(object.Object, &node) == nil {
					nodesByUID[node.UID] = &node
				} else {
					conversionIncomplete = true
				}
			}
		case "pods":
			result.PodsCacheAvailable = true
			if entry.complete && entry.key.namespace == "" && entry.key.labels == "" && entry.key.fields == "" {
				podsClusterWideComplete = true
			}
			for _, object := range entry.store.Snapshot() {
				var pod corev1.Pod
				if object != nil && k8sruntime.DefaultUnstructuredConverter.FromUnstructured(object.Object, &pod) == nil {
					podsByUID[pod.UID] = &pod
				} else {
					conversionIncomplete = true
				}
			}
		}
	}
	nodes := make([]*corev1.Node, 0, len(nodesByUID))
	for _, node := range nodesByUID {
		nodes = append(nodes, node)
	}
	pods := make([]*corev1.Pod, 0, len(podsByUID))
	for _, pod := range podsByUID {
		pods = append(pods, pod)
	}
	result.Discovered = metrics.DiscoverResources(nodes, pods, accelerators)
	result.NodesSnapshotComplete = nodesClusterWideComplete
	result.PodsSnapshotComplete = podsClusterWideComplete
	// Nodes alone are an authoritative cluster-wide source for capacity-based
	// optional resources. Pods supplement keys that are requested despite not
	// appearing on a Node. Until the Node store is complete, absence is never
	// conclusive; scoped Pod caches likewise keep coverage explicitly partial.
	result.PotentiallyIncomplete = conversionIncomplete || !nodesClusterWideComplete || !podsClusterWideComplete
	return result, nil
}

// Subscription owns one complete filtered/sorted backend presentation and a
// bounded, coalescing control-event mailbox. Rows never travel through
// StreamView; clients fetch only revision-pinned viewport ranges.
type Subscription struct {
	runtime      *Runtime
	resource     *resourceRuntime
	key          viewKey
	metricPlan   metricViewPlan
	metrics      metricSubscription
	metricCancel context.CancelFunc

	podMetricResolver     PodMetricResolver
	metricSessionID       string
	metricAuthorityID     string
	metricInterestID      uint64
	metricInterestStop    context.CancelFunc
	metricRefreshInterval time.Duration
	metricCoverageID      uint64
	metricCoverageCommit  uint64
	metricCoverageRunning bool
	metricCoverageDirty   bool
	metricCoverageTimer   *time.Timer
	metricCoverageTimerID uint64
	metricRefreshAfter    time.Time
	metricRefreshPending  bool
	metricsReconciling    bool
	// A staged view with metric-dependent membership or ordering reconciles
	// against one immutable base-object epoch. WATCH churn may still publish a
	// provisional projection while that epoch resolves; only the exact pinned
	// pass owns the first ViewReconciled barrier.
	initialMetricEpoch *initialMetricEpoch
	lastStatus         *kmgrv1.ViewStatus

	mu                          sync.Mutex
	generation                  uint64
	sequence                    uint64
	projector                   *Projector
	projectionCacheKey          projectionCacheKey
	rows                        map[string]*kmgrv1.ResourceRow
	order                       []string
	presentationRowBytes        map[string]int64
	presentationRowBytesTotal   int64
	presentationUIDBytesTotal   int64
	presentationRetainedObjects atomic.Uint64
	presentationRetainedBytes   atomic.Uint64
	presentationRevision        uint64
	indexRevision               uint64
	pendingInvalidation         bool
	pendingStatuses             []*kmgrv1.ViewStatus
	pendingError                *kmgrv1.StructuredError
	pendingSchema               *kmgrv1.ViewSchema
	sealedInitial               []*kmgrv1.ViewEvent
	stageUntilReconciled        bool
	pendingReconciliation       bool
	reconciliationDelivered     bool
	serverSchema                *kmgrv1.ViewSchema
	serverColumns               []projectedTableColumn
	serverCells                 map[string][]*kmgrv1.Cell
	selectionSnapshot           *SelectionSnapshot
	selectionSnapshotBuildHook  func()
	optionalResourceHints       optionalResourceStreamHints
	inFlightDelivery            *subscriptionDelivery
	pendingObjects              map[string]*unstructured.Unstructured
	projectionTimer             *time.Timer
	projectionScheduled         bool
	projectionRunning           bool
	projectionResnapshot        bool
	projectionRevision          uint64
	projectionScheduleID        uint64
	projectionPasses            uint64
	projectedObjects            uint64
	projectionContext           context.Context
	cancelProjection            context.CancelFunc
	// snapshotComplete records whether this generation crossed an authoritative
	// initial LIST/WatchList barrier. It gates staged reconciliation and warm
	// catch-up status; it is not client row-delivery state.
	snapshotComplete bool
	// minimumResourceRun rejects a batch that was captured from a retired raw
	// pipeline before its runtime callback released Runtime.mu. Zero is the
	// initial transient/LIST generation; a restart advances this floor before
	// the replacement pipeline is allowed to start.
	minimumResourceRun uint64
	// warmCatchupRunNumber identifies an already-running pipeline whose compact
	// cached rows were sealed as a stale first paint. Once the mandatory full
	// reprojection commits, the subscription republishes that run's current
	// status so a debounce reopen does not remain visibly stale forever. A stop
	// or restart changes the run number and leaves freshness to the new run's
	// ordinary status callbacks.
	warmCatchupRunNumber uint64
	// scheduleProjection is replaced by tests to make coalescing flushes
	// deterministic. Production uses one batchDelay timer.
	scheduleProjection func(func()) *time.Timer
	notify             chan struct{}
	done               chan struct{}
	timer              *time.Timer
	batchDelay         time.Duration
	pendingLimit       int
	closed             bool
}

type subscriptionDelivery struct {
	generation   uint64
	lastSequence uint64
}

func newSubscription(
	key viewKey,
	generation uint64,
	projector *Projector,
	batchDelay time.Duration,
	pendingLimit int,
) *Subscription {
	projectionContext, cancelProjection := context.WithCancel(context.Background())
	subscription := &Subscription{
		key:                  key,
		generation:           generation,
		projector:            projector,
		projectionCacheKey:   projector.cacheKey,
		rows:                 make(map[string]*kmgrv1.ResourceRow),
		presentationRowBytes: make(map[string]int64),
		presentationRevision: 1,
		indexRevision:        1,
		pendingObjects:       make(map[string]*unstructured.Unstructured),
		notify:               make(chan struct{}, 1),
		done:                 make(chan struct{}),
		batchDelay:           batchDelay,
		pendingLimit:         pendingLimit,
		projectionContext:    projectionContext,
		cancelProjection:     cancelProjection,
	}
	subscription.scheduleProjection = func(flush func()) *time.Timer {
		return time.AfterFunc(batchDelay, flush)
	}
	return subscription
}

// Next waits for one coalesced delivery and returns ordered control events.
// One batch must be acknowledged before another Next call so concurrent stream
// consumers cannot reorder cursors.
func (s *Subscription) Next(ctx context.Context) ([]*kmgrv1.ViewEvent, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-s.done:
		return nil, ErrViewClosed
	case <-s.notify:
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, ErrViewClosed
	}
	if s.inFlightDelivery != nil {
		return nil, ErrDeliveryPending
	}
	events := s.drainLocked()
	if len(events) != 0 {
		s.inFlightDelivery = deliveryContract(events)
	}
	return events, nil
}

// AcknowledgeDelivery releases the in-flight cursor batch only after every
// event returned by one Next call was sent successfully.
func (s *Subscription) AcknowledgeDelivery(events []*kmgrv1.ViewEvent) error {
	if len(events) == 0 {
		return nil
	}
	contract := deliveryContract(events)
	s.mu.Lock()
	defer s.mu.Unlock()
	pending := s.inFlightDelivery
	if pending == nil || pending.generation != contract.generation ||
		pending.lastSequence != contract.lastSequence {
		return ErrDeliveryPending
	}
	s.inFlightDelivery = nil
	return nil
}

func deliveryContract(events []*kmgrv1.ViewEvent) *subscriptionDelivery {
	contract := &subscriptionDelivery{}
	for _, event := range events {
		if event == nil {
			continue
		}
		if cursor := event.GetCursor(); cursor != nil {
			contract.generation = cursor.GetGeneration()
			contract.lastSequence = cursor.GetSequence()
		}
	}
	return contract
}

func (s *Subscription) Close() {
	if s.runtime != nil {
		s.runtime.closeSubscription(s)
	}
}

func (s *Subscription) attachMetrics(subscription metricSubscription) {
	if subscription == nil {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		cancel()
		subscription.Close()
		return
	}
	s.metrics = subscription
	s.metricCancel = cancel
	requestRefresh := s.metricRefreshPending
	s.metricRefreshPending = false
	s.mu.Unlock()
	if requestRefresh {
		subscription.RequestRefresh()
	}
	go s.receiveMetrics(ctx, subscription)
}

func (s *Subscription) receiveMetrics(ctx context.Context, subscription metricSubscription) {
	for {
		select {
		case <-ctx.Done():
			return
		case snapshot, ok := <-subscription.Updates():
			if !ok {
				return
			}
			s.applyMetrics(snapshot)
		}
	}
}

func (s *Subscription) applyMetrics(snapshot metrics.Snapshot) {
	s.mu.Lock()
	if s.closed || s.resource == nil {
		s.mu.Unlock()
		return
	}
	s.projector = s.projector.WithMetrics(snapshot)
	s.projectionRevision++
	s.projectionResnapshot = true
	if s.metricPlan.dependency.requiresCompleteCoverage() && s.snapshotComplete {
		epoch := s.activeInitialMetricEpochLocked()
		switch {
		case epoch != nil:
			if epoch.objectsReady &&
				(s.metricRefreshAfter.IsZero() || !snapshot.UpdatedAt.Before(s.metricRefreshAfter)) {
				s.metricCoverageCommit = epoch.coverageID
				s.metricRefreshAfter = time.Time{}
			}
		case s.shouldStartInitialMetricEpochLocked():
			// Open will pin the base epoch immediately after attaching the
			// provider. A cached pre-epoch sample can update the projector, but it
			// cannot satisfy the first staged reconciliation barrier.
		default:
			if !s.metricsReconciling {
				s.metricCoverageID++
				s.setMetricsReconcilingLocked(true)
			}
			if s.metricRefreshAfter.IsZero() || !snapshot.UpdatedAt.Before(s.metricRefreshAfter) {
				s.metricCoverageCommit = s.metricCoverageID
				s.metricRefreshAfter = time.Time{}
			}
		}
	}
	s.scheduleProjectionLocked()
	s.mu.Unlock()
}

// initializeSealedRows prepares the private state for an Open handoff. The
// initial rows are considered client-retainable immediately because the sealed
// delivery cannot be replaced once the subscription is published. Unlike the
// legacy initializeRows helper, it leaves the ordinary mailbox empty so a
// catch-up is delivered only when authoritative state actually raced Open.
func (s *Subscription) initializeSealedRows(rows []*kmgrv1.ResourceRow) {
	clear(s.rows)
	clear(s.presentationRowBytes)
	s.presentationRowBytesTotal = 0
	s.presentationUIDBytesTotal = 0
	s.order = s.order[:0]
	s.pendingStatuses = nil
	s.pendingError = nil
	s.pendingSchema = nil
	clear(s.pendingObjects)
	s.pendingInvalidation = false
	if s.presentationRevision == 0 {
		s.presentationRevision = 1
	}
	if s.indexRevision == 0 {
		s.indexRevision = 1
	}
	for _, row := range rows {
		uid := row.GetIdentity().GetUid()
		if uid == "" {
			continue
		}
		s.rows[uid] = row
		s.presentationRowBytes[uid] = projectedRowRetainedBytes(row)
		s.presentationRowBytesTotal = saturatingProjectionBytes(
			s.presentationRowBytesTotal,
			s.presentationRowBytes[uid],
		)
		s.presentationUIDBytesTotal = saturatingProjectionBytes(
			s.presentationUIDBytesTotal,
			int64(len(uid)),
		)
		s.order = append(s.order, uid)
	}
	s.publishPresentationRetentionLocked()
}

// initializeServerTable is called while a new subscription is still private.
// It snapshots the resource runtime's sidecar at the same lifecycle revision
// as the initial object projection.
func (s *Subscription) initializeServerTable(
	columns []metav1.TableColumnDefinition,
	rows map[string][]any,
) {
	s.replaceServerTableSnapshot(columns, rows, false)
}

// replaceServerTableSnapshot installs one resource-runtime sidecar snapshot.
// announce is used when publication detects an intervening callback after the
// sealed initial payload was built; clients then receive the latest schema
// immediately after that immutable first payload.
func (s *Subscription) replaceServerTableSnapshot(
	columns []metav1.TableColumnDefinition,
	rows map[string][]any,
	announce bool,
) {
	previous := s.serverSchema
	schema, projected := projectTableSchema(columns)
	s.serverSchema = schema
	s.serverColumns = projected
	if announce {
		switch {
		case schema != nil && (previous == nil || schema.GetRevision() != previous.GetRevision()):
			s.pendingSchema = proto.Clone(schema).(*kmgrv1.ViewSchema)
		case schema == nil && previous != nil:
			s.pendingSchema = &kmgrv1.ViewSchema{Revision: "raw", ServerTable: false}
		}
	}
	if len(rows) == 0 || len(projected) == 0 {
		s.serverCells = nil
		return
	}
	s.serverCells = make(map[string][]*kmgrv1.Cell, len(rows))
	now := s.projector.beginBatch().spec.Now
	for uid, values := range rows {
		s.serverCells[uid] = projectTableCells(projected, values, now)
	}
}

func (s *Subscription) applyServerTableBatchLocked(batch watcher.Batch) {
	for _, uid := range batch.RemovedUIDs {
		delete(s.serverCells, string(uid))
	}
	if batch.Table == nil {
		return
	}
	if batch.Table.Disabled {
		hadTable := s.serverSchema != nil
		s.serverSchema = nil
		s.serverColumns = nil
		s.serverCells = nil
		if hadTable {
			s.pendingSchema = &kmgrv1.ViewSchema{Revision: "raw", ServerTable: false}
		}
		return
	}
	if len(batch.Table.Columns) != 0 {
		schema, projected := projectTableSchema(batch.Table.Columns)
		if schema != nil && (s.serverSchema == nil || schema.GetRevision() != s.serverSchema.GetRevision()) {
			s.serverSchema = schema
			s.serverColumns = projected
			s.serverCells = nil
			s.pendingSchema = proto.Clone(schema).(*kmgrv1.ViewSchema)
		}
	}
	if len(batch.Table.Cells) == 0 || len(s.serverColumns) == 0 {
		return
	}
	if s.serverCells == nil {
		s.serverCells = make(map[string][]*kmgrv1.Cell, len(batch.Table.Cells))
	}
	now := s.projector.beginBatch().spec.Now
	for uid, values := range batch.Table.Cells {
		s.serverCells[string(uid)] = projectTableCells(s.serverColumns, values, now)
	}
}

func (s *Subscription) sealInitialUnlocked(
	status *kmgrv1.ViewStatus,
	rows []*kmgrv1.ResourceRow,
	reconciled bool,
) {
	s.sealedInitial = nil
	if status != nil {
		copy := proto.Clone(status).(*kmgrv1.ViewStatus)
		copy.RowsVisible = uint64(len(rows))
		copy.MetricsReconciling = s.metricsReconciling
		s.lastStatus = proto.Clone(copy).(*kmgrv1.ViewStatus)
		s.sealedInitial = append(s.sealedInitial, &kmgrv1.ViewEvent{
			Payload: &kmgrv1.ViewEvent_Status{Status: copy},
		})
	}
	if s.serverSchema != nil {
		s.sealedInitial = append(s.sealedInitial, &kmgrv1.ViewEvent{
			Payload: &kmgrv1.ViewEvent_Schema{
				Schema: proto.Clone(s.serverSchema).(*kmgrv1.ViewSchema),
			},
		})
	}
	observedOptionalResources := s.optionalResourceHints.takePendingLocked()
	s.sealedInitial = append(s.sealedInitial, &kmgrv1.ViewEvent{
		Payload: &kmgrv1.ViewEvent_Invalidation{Invalidation: &kmgrv1.ViewInvalidation{
			PresentationRevision:                  s.presentationRevision,
			IndexRevision:                         s.indexRevision,
			RowsVisible:                           uint64(len(s.order)),
			MaxRangeLength:                        DefaultViewRangeLength,
			ObservedOptionalResourceKeys:          observedOptionalResources.keys,
			ObservedOptionalResourceKeysTruncated: observedOptionalResources.truncated,
		}},
	})
	if reconciled {
		s.sealedInitial = append(s.sealedInitial, &kmgrv1.ViewEvent{
			Payload: &kmgrv1.ViewEvent_Reconciled{Reconciled: &kmgrv1.ViewReconciled{
				RowsVisible:          uint64(len(s.order)),
				PresentationRevision: s.presentationRevision,
				IndexRevision:        s.indexRevision,
			}},
		})
		s.reconciliationDelivered = true
	}
	s.signalLocked(true)
}

// suppressInitialReconciliationUnlocked removes a sealed marker that was
// prepared from the old raw store when publication subsequently decides to
// restart that store. A fresh LIST must own the first reconciliation barrier;
// otherwise a warm client can promote stale rows before the replacement
// snapshot has arrived and then never receive another marker.
func (s *Subscription) suppressInitialReconciliationUnlocked() {
	if !s.reconciliationDelivered && !s.stageUntilReconciled {
		return
	}
	filtered := s.sealedInitial[:0]
	for _, event := range s.sealedInitial {
		if event == nil || event.GetReconciled() == nil {
			filtered = append(filtered, event)
		}
	}
	s.sealedInitial = filtered
	s.reconciliationDelivered = false
	s.pendingReconciliation = false
}

func (s *Subscription) prepareForResourceRestart(fenceRun uint64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.prepareForResourceRestartUnlocked(fenceRun)
}

// prepareForResourceRestartUnlocked invalidates presentation state derived
// from the retired UIDStore. It is used without the mutex only while a new
// subscription is still private; published subscriptions enter through the
// locking wrapper above. Clearing projected rows is necessary because the
// replacement store intentionally starts empty, so its final LIST cannot
// produce tombstones for objects that existed only in the retired store.
func (s *Subscription) prepareForResourceRestartUnlocked(fenceRun uint64) {
	minimumRun := fenceRun + 1
	if minimumRun == 0 {
		minimumRun = fenceRun
	}
	if s.closed || minimumRun <= s.minimumResourceRun {
		return
	}
	s.minimumResourceRun = minimumRun
	s.cancelProjectionScheduleLocked()
	s.projectionRevision++
	clear(s.pendingObjects)
	s.projectionResnapshot = false
	s.snapshotComplete = false
	s.warmCatchupRunNumber = 0
	s.serverCells = nil
	s.pendingStatuses = nil
	s.pendingError = nil
	s.metricCoverageID++
	s.metricCoverageCommit = 0
	s.metricCoverageDirty = false
	s.initialMetricEpoch = nil
	s.stopCompletePodMetricCoverageTimerLocked()

	clear(s.rows)
	s.order = s.order[:0]
	clear(s.presentationRowBytes)
	s.presentationRowBytesTotal = 0
	s.presentationUIDBytesTotal = 0
	s.publishPresentationRetentionLocked()
	s.advancePresentationLocked(true)
	s.pendingReconciliation = false
	s.reconciliationDelivered = false

	// A just-published Open may still own a sealed first delivery constructed
	// from the retired store. Keep its status/schema ordering but rewrite the
	// range contract to the empty replacement presentation and remove the stale
	// reconciliation marker.
	hadSealedInitial := len(s.sealedInitial) != 0
	filtered := s.sealedInitial[:0]
	for _, event := range s.sealedInitial {
		if event == nil || event.GetReconciled() != nil {
			continue
		}
		if status := event.GetStatus(); status != nil {
			status.RowsVisible = 0
		}
		if invalidation := event.GetInvalidation(); invalidation != nil {
			invalidation.PresentationRevision = s.presentationRevision
			invalidation.IndexRevision = s.indexRevision
			invalidation.RowsVisible = 0
			invalidation.MaxRangeLength = DefaultViewRangeLength
		}
		filtered = append(filtered, event)
	}
	s.sealedInitial = filtered
	if s.lastStatus != nil {
		s.lastStatus.RowsVisible = 0
	}
	if hadSealedInitial {
		// The rewritten sealed invalidation already carries this revision.
		s.pendingInvalidation = false
	}
	s.signalLocked(true)
}

// markReconciledLocked queues a generation-local commit barrier behind all
// row payloads already present in the mailbox. The marker is emitted exactly
// once because a retained client needs only the first complete replacement;
// later WATCH updates apply directly to the promoted table.
func (s *Subscription) markReconciledLocked() {
	if !s.stageUntilReconciled || s.metricsReconciling ||
		s.reconciliationDelivered || s.pendingReconciliation {
		return
	}
	s.pendingReconciliation = true
}

func (s *Subscription) markAuthoritativeResnapshotUnlocked() {
	s.projectionRevision++
	s.projectionResnapshot = true
}

func (s *Subscription) scheduleAuthoritativeResnapshot() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || !s.projectionResnapshot {
		return
	}
	s.scheduleProjectionLocked()
}

func (s *Subscription) applyBatch(batch watcher.Batch) {
	s.applyBatchForRun(0, false, batch)
}

func (s *Subscription) applyResourceBatch(runNumber uint64, batch watcher.Batch) {
	s.applyBatchForRun(runNumber, true, batch)
}

func (s *Subscription) applyBatchForRun(
	runNumber uint64,
	enforceRunFence bool,
	batch watcher.Batch,
) {
	if !batch.FromList && !batch.SnapshotComplete {
		s.enqueueWatchBatch(runNumber, enforceRunFence, batch)
		return
	}
	observedOptionalResourceKeys := s.optionalResourceHints.extract(batch.Upserts)
	s.flushProjection()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || enforceRunFence && runNumber < s.minimumResourceRun {
		return
	}
	s.applyServerTableBatchLocked(batch)
	s.optionalResourceHints.observeLocked(observedOptionalResourceKeys)
	epoch := s.activeInitialMetricEpochLocked()
	if epoch == nil && s.shouldStartInitialMetricEpochLocked() {
		// Open may have seeded an epoch with coverageID == 0 and a WATCH/LIST
		// callback can arrive before the post-publication metric request starts.
		// Promote that seed now so the callback is recorded as newer state instead
		// of allowing the pinned pass to resurrect a deleted or replaced object.
		s.startInitialMetricEpochLocked(true)
		epoch = s.activeInitialMetricEpochLocked()
	}
	if epoch != nil {
		// A batch that races the pinned metric epoch is newer state. Keep the
		// exact metric barrier pinned, but let the ordinary projection publish a
		// provisional view from the latest raw store. A relist/tombstone needs one
		// post-barrier resnapshot because pendingObjects has no tombstone form.
		epoch.dirty = true
		if batch.FromList {
			epoch.needsResnapshot = true
		}
	}
	// LIST pages and snapshot-complete batches are projection barriers. An
	// older WATCH projection may still be running when flushProjection returns;
	// advancing the revision before touching rows prevents that work from
	// committing over the newer authoritative LIST state.
	s.projectionRevision++
	// Any WATCH objects claimed before this authoritative LIST page are older
	// than the barrier. Dropping them prevents a later WATCH from causing those
	// stranded objects to be projected over the LIST state.
	clear(s.pendingObjects)
	// Do not erase a full pass that was already queued before this LIST callback:
	// the callback itself is still projected incrementally, but the queued pass
	// must run afterward so a racing WATCH/LIST or metric update cannot strand
	// rows that were not present in this page. An exact pinned metric pass is
	// additionally mandatory when its coverage is ready.
	s.projectionResnapshot = s.projectionResnapshot ||
		(epoch != nil && epoch.objectsReady &&
			s.metricCoverageCommit == epoch.coverageID)
	batchProjector := s.projector.beginBatch()
	presentationChanged := false
	var previousOrder []string
	orderCandidate := false
	markOrderCandidate := func() {
		orderCandidate = true
		if previousOrder == nil {
			previousOrder = append([]string(nil), s.order...)
		}
	}
	for _, uid := range batch.RemovedUIDs {
		key := string(uid)
		if s.rows[key] == nil {
			continue
		}
		markOrderCandidate()
		delete(s.rows, key)
		s.updatePresentationRowRetentionLocked(key, nil)
		presentationChanged = true
	}
	for _, object := range batch.Upserts {
		if object == nil || object.GetUID() == "" {
			continue
		}
		uid := string(object.GetUID())
		previous := s.rows[uid]
		row, visible := batchProjector.projectOneWithCells(object, s.serverCells[uid])
		if !visible {
			if previous != nil {
				markOrderCandidate()
				delete(s.rows, uid)
				s.updatePresentationRowRetentionLocked(uid, nil)
				presentationChanged = true
			}
			continue
		}
		if previous == nil || s.projector.compareRows(previous, row) != 0 {
			markOrderCandidate()
		}
		s.rows[uid] = row
		s.updatePresentationRowRetentionLocked(uid, row)
		if previous == nil || !proto.Equal(previous, row) {
			presentationChanged = true
		}
	}
	if len(batch.RemovedUIDs) != 0 || len(batch.Upserts) != 0 {
		s.publishPresentationRetentionLocked()
	}
	indexChanged := false
	if orderCandidate {
		s.rebuildOrderLocked()
		indexChanged = !slices.Equal(previousOrder, s.order)
	}
	if presentationChanged || indexChanged {
		s.advancePresentationLocked(indexChanged)
	}
	if batch.SnapshotComplete {
		s.snapshotComplete = true
		s.setStatusLocked(&kmgrv1.ViewStatus{
			Freshness:              kmgrv1.ViewFreshness_VIEW_FRESHNESS_WATCHING,
			ObjectsExamined:        uint64(batch.ObjectsListed),
			RowsVisible:            uint64(len(s.rows)),
			LastSynchronizedUnixMs: batch.SynchronizedAt.UnixMilli(),
		})
		s.requireCompleteMetricCoverageLocked(true)
		s.markReconciledLocked()
	}
	s.signalLocked(batch.FromList)
}

// enqueueWatchBatch keeps WATCH ingestion to bounded map work. Upserts are
// projected newest-per-UID after one short coalescing window; removals are
// applied and signaled immediately so deleted rows never linger behind CEL or
// a full-table sort.
func (s *Subscription) enqueueWatchBatch(
	runNumber uint64,
	enforceRunFence bool,
	batch watcher.Batch,
) {
	observedOptionalResourceKeys := s.optionalResourceHints.extract(batch.Upserts)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || enforceRunFence && runNumber < s.minimumResourceRun {
		return
	}
	tableDisabled := batch.Table != nil && batch.Table.Disabled && s.serverSchema != nil
	s.applyServerTableBatchLocked(batch)
	s.optionalResourceHints.observeLocked(observedOptionalResourceKeys)
	epoch := s.activeInitialMetricEpochLocked()
	if epoch == nil && s.shouldStartInitialMetricEpochLocked() {
		// See the LIST path above: a seeded, not-yet-started epoch still owns the
		// first exact metric barrier, and this WATCH batch must make it dirty.
		s.startInitialMetricEpochLocked(true)
		epoch = s.activeInitialMetricEpochLocked()
	}
	if epoch != nil {
		// Keep the first complete metric request pinned, but do not hold WATCH
		// updates behind it. The ordinary bounded pendingObjects path below
		// publishes a provisional base projection immediately. Deletions and
		// table fallback still require one post-barrier resnapshot because
		// pendingObjects deliberately has no tombstone representation.
		epoch.dirty = true
		if tableDisabled || len(batch.RemovedUIDs) != 0 {
			epoch.needsResnapshot = true
		}
		if epoch.objectsReady && s.metricCoverageCommit == epoch.coverageID {
			// A complete metric result is waiting for its pinned full pass. Keep
			// that pass scheduled even when this WATCH batch only needs the bounded
			// incremental path below.
			s.projectionResnapshot = true
		}
	}
	if tableDisabled {
		// The raw fallback has no server cells. Rebuild every retained row so a
		// persisted server column cannot keep displaying a stale pre-fallback
		// value until that particular object happens to change again.
		s.projectionRevision++
		s.projectionResnapshot = true
	}
	presentationChanged := false
	for _, uid := range batch.RemovedUIDs {
		key := string(uid)
		if key == "" {
			continue
		}
		delete(s.pendingObjects, key)
		// A claimed object is absent from pendingObjects and may not have a
		// committed row yet. Every valid tombstone must therefore invalidate
		// in-flight work, not only tombstones for currently visible rows.
		s.projectionRevision++
		if s.projectionRunning && s.resource != nil {
			s.projectionResnapshot = true
		}
		if previous := s.rows[key]; previous != nil {
			s.order, _ = removeOrderedRow(
				s.order, s.rows, key, previous, s.projector.compareRows,
			)
			delete(s.rows, key)
			s.updatePresentationRowRetentionLocked(key, nil)
			presentationChanged = true
		}
	}
	if presentationChanged {
		s.publishPresentationRetentionLocked()
	}
	for _, object := range batch.Upserts {
		if object == nil || object.GetUID() == "" {
			continue
		}
		key := string(object.GetUID())
		if epoch := s.activeInitialMetricEpochLocked(); epoch != nil {
			s.noteInitialMetricEpochUpsertLocked(epoch, object)
		}
		s.pendingObjects[key] = object
	}
	if len(s.pendingObjects) > s.pendingLimit {
		clear(s.pendingObjects)
		s.projectionResnapshot = true
	}
	if s.snapshotComplete && (len(batch.Upserts) != 0 || len(batch.RemovedUIDs) != 0) {
		s.requireCompleteMetricCoverageLocked(false)
	}
	if presentationChanged {
		s.advancePresentationLocked(true)
		s.signalLocked(true)
	}
	if s.pendingSchema != nil {
		s.signalLocked(true)
	}
	if len(s.pendingObjects) != 0 || s.projectionResnapshot {
		s.scheduleProjectionLocked()
	}
}

func (s *Subscription) scheduleProjectionLocked() {
	if s.closed || s.projectionScheduled || s.projectionRunning {
		return
	}
	s.projectionScheduled = true
	s.projectionScheduleID++
	scheduleID := s.projectionScheduleID
	// Production scheduling is non-blocking. Tests replace this hook with one
	// that captures (but does not synchronously invoke) the callback.
	s.projectionTimer = s.scheduleProjection(func() {
		s.flushScheduledProjection(scheduleID)
	})
}

func (s *Subscription) cancelProjectionScheduleLocked() {
	if s.projectionTimer != nil {
		s.projectionTimer.Stop()
		s.projectionTimer = nil
	}
	if s.projectionScheduled {
		s.projectionScheduled = false
		s.projectionScheduleID++
	}
}

func (s *Subscription) flushScheduledProjection(scheduleID uint64) {
	s.mu.Lock()
	if s.closed || !s.projectionScheduled || s.projectionScheduleID != scheduleID {
		s.mu.Unlock()
		return
	}
	s.projectionScheduled = false
	s.projectionTimer = nil
	if s.projectionRunning || (len(s.pendingObjects) == 0 &&
		!s.projectionResnapshot && !s.initialMetricEpochReadyLocked()) {
		s.mu.Unlock()
		return
	}
	s.projectionRunning = true
	s.mu.Unlock()
	s.runProjection()
}

// flushProjection synchronously starts any queued projection. It exists both
// as a LIST barrier and as deterministic test control; production WATCH
// delivery normally enters through flushScheduledProjection.
func (s *Subscription) flushProjection() {
	s.mu.Lock()
	s.cancelProjectionScheduleLocked()
	if s.closed || s.projectionRunning ||
		(len(s.pendingObjects) == 0 && !s.projectionResnapshot &&
			!s.initialMetricEpochReadyLocked()) {
		s.mu.Unlock()
		return
	}
	s.projectionRunning = true
	s.mu.Unlock()
	s.runProjection()
}

// runProjection snapshots coalesced state under Subscription.mu, performs CEL
// projection and sorting without either the lifecycle or subscription mutex,
// then commits only against the same row/projector revision. A removal, LIST
// barrier, or enrichment revision that races the work causes a retry from the
// authoritative object store.
func (s *Subscription) runProjection() {
	for {
		s.mu.Lock()
		if s.closed {
			s.projectionRunning = false
			s.mu.Unlock()
			return
		}
		epoch := s.activeInitialMetricEpochLocked()
		pinnedMetricEpochReady := s.initialMetricEpochReadyLocked()
		if len(s.pendingObjects) == 0 && !s.projectionResnapshot && !pinnedMetricEpochReady {
			s.projectionRunning = false
			s.mu.Unlock()
			return
		}
		revision := s.projectionRevision
		projector := s.projector
		// Once the pinned metric snapshot is available, its exact projection is
		// mandatory even if a concurrent WATCH pass consumed the ordinary
		// resnapshot flag. This is the only pass allowed to close the initial
		// staged barrier.
		full := s.projectionResnapshot || pinnedMetricEpochReady
		s.projectionResnapshot = false
		pinnedMetricEpoch := full && pinnedMetricEpochReady
		var objects []*unstructured.Unstructured
		if pinnedMetricEpoch {
			objects = epoch.objects
		} else {
			objects = make([]*unstructured.Unstructured, 0, len(s.pendingObjects))
			for _, object := range s.pendingObjects {
				objects = append(objects, object)
			}
			clear(s.pendingObjects)
		}
		var serverCells map[string][]*kmgrv1.Cell
		if pinnedMetricEpoch {
			serverCells = epoch.serverCells
		} else {
			serverCells = cloneServerCells(s.serverCells)
		}
		var baseRows map[string]*kmgrv1.ResourceRow
		if full && s.resource == nil {
			baseRows = make(map[string]*kmgrv1.ResourceRow, len(s.rows))
			for uid, row := range s.rows {
				baseRows[uid] = row
			}
		}
		resource := s.resource
		var resourceStore *store.UIDStore
		if resource != nil {
			resourceStore = resource.currentStore()
		}
		projectionContext := s.projectionContext
		if projectionContext == nil {
			projectionContext = context.Background()
		}
		s.mu.Unlock()

		fullAdmissionHeld := false
		var projectionErr error
		if full && resource != nil {
			if s.runtime != nil {
				if err := s.runtime.acquireOpenProjection(projectionContext); err != nil {
					s.mu.Lock()
					s.projectionRunning = false
					s.mu.Unlock()
					return
				}
				fullAdmissionHeld = true
			}
			if !pinnedMetricEpoch {
				objects, projectionErr = resourceStore.SnapshotContext(projectionContext)
			}
		}
		var projectedRows map[string]*kmgrv1.ResourceRow
		if !full {
			projectedRows = make(map[string]*kmgrv1.ResourceRow, len(objects))
		}
		projectedObjects := uint64(0)
		var ordered []*kmgrv1.ResourceRow
		if full && resource != nil {
			for index, object := range objects {
				if index&255 == 0 {
					if projectionErr = projectionContext.Err(); projectionErr != nil {
						break
					}
				}
				if object == nil || object.GetUID() == "" {
					continue
				}
				projectedObjects++
			}
			if projectionErr == nil {
				ordered, projectionErr = projector.ProjectContextWithAdditionalCells(
					projectionContext, objects, serverCells,
				)
			}
			if projectionErr == nil {
				baseRows = make(map[string]*kmgrv1.ResourceRow, len(ordered))
				for _, row := range ordered {
					baseRows[row.GetIdentity().GetUid()] = row
				}
			}
		} else {
			batchProjector := projector.beginBatch()
			for _, object := range objects {
				if projectionErr != nil {
					break
				}
				if object == nil || object.GetUID() == "" {
					continue
				}
				projectedObjects++
				uid := string(object.GetUID())
				var row *kmgrv1.ResourceRow
				var visible bool
				projectionErr = batchProjector.workerPool.run(projectionContext, func() error {
					var err error
					row, visible, err = batchProjector.projectOneAdmittedWithCells(
						projectionContext, object, serverCells[uid],
					)
					return err
				})
				if projectionErr != nil {
					break
				}
				if full {
					if visible {
						baseRows[uid] = row
					} else {
						delete(baseRows, uid)
					}
				} else if visible {
					projectedRows[uid] = row
				} else {
					// A present nil value means this UID was projected and is now
					// filter-hidden. It is distinct from an object not in this batch.
					projectedRows[uid] = nil
				}
			}
			if full {
				ordered = make([]*kmgrv1.ResourceRow, 0, len(baseRows))
				for _, row := range baseRows {
					ordered = append(ordered, row)
				}
				if projectionErr == nil {
					projectionErr = sortRowsContext(projectionContext, ordered, projector.compareRows)
				}
			}
		}
		if fullAdmissionHeld {
			s.runtime.releaseOpenProjection()
		}
		if projectionErr != nil {
			s.mu.Lock()
			s.projectionRunning = false
			s.mu.Unlock()
			return
		}

		s.mu.Lock()
		s.projectionPasses++
		s.projectedObjects += projectedObjects
		if s.closed {
			s.projectionRunning = false
			s.mu.Unlock()
			return
		}
		if s.projectionRevision != revision {
			// The pinned epoch is deliberately an immutable barrier. Accepting
			// that pass despite newer WATCH revisions prevents continuous churn
			// from starving ViewReconciled; coalesced upserts and any required
			// resnapshot are applied by the next loop. A replaced/retired epoch
			// is still rejected so an old generation can never overwrite a new
			// resource store.
			pinnedEpochStillActive := pinnedMetricEpoch &&
				s.initialMetricEpoch == epoch &&
				s.metricCoverageCommit == epoch.coverageID
			if !pinnedEpochStillActive {
				if s.projectionResnapshot || len(s.pendingObjects) != 0 {
					s.mu.Unlock()
					continue
				}
				s.projectionRunning = false
				s.mu.Unlock()
				return
			}
			// A newer metric snapshot changes the projector itself. Preserve a
			// full pass after the pinned commit; ordinary WATCH-only changes stay
			// bounded in pendingObjects and use the incremental loop.
			if s.projector != projector {
				s.projectionResnapshot = true
			}
		}
		if full {
			previousRows := s.rows
			previousOrder := s.order
			nextOrder := make([]string, 0, len(ordered))
			for _, row := range ordered {
				nextOrder = append(nextOrder, row.GetIdentity().GetUid())
			}
			presentationChanged := !resourceRowsEqual(previousRows, baseRows)
			indexChanged := !slices.Equal(previousOrder, nextOrder)
			s.rows = baseRows
			s.order = nextOrder
			s.replacePresentationRetentionLocked(baseRows)
			if presentationChanged || indexChanged {
				s.advancePresentationLocked(indexChanged)
			}
			s.publishWarmCatchupStatusLocked()
			s.completeMetricCoverageLocked()
		} else {
			var previousOrder []string
			orderCandidate := false
			for _, object := range objects {
				if object == nil || object.GetUID() == "" {
					continue
				}
				uid := string(object.GetUID())
				previous, row := s.rows[uid], projectedRows[uid]
				if (previous == nil) != (row == nil) ||
					(previous != nil && row != nil && projector.compareRows(previous, row) != 0) {
					orderCandidate = true
					previousOrder = append([]string(nil), s.order...)
					break
				}
			}
			presentationChanged := false
			for _, object := range objects {
				if object == nil || object.GetUID() == "" {
					continue
				}
				uid := string(object.GetUID())
				previous := s.rows[uid]
				row := projectedRows[uid]
				if row == nil {
					// Filter invisibility is represented by the complete order, not
					// RemovedUids: clients retain hidden-row selection and only a
					// confirmed Kubernetes deletion may remove the identity.
					if previous != nil {
						s.order, _ = removeOrderedRow(
							s.order, s.rows, uid, previous, projector.compareRows,
						)
						delete(s.rows, uid)
						s.updatePresentationRowRetentionLocked(uid, nil)
						presentationChanged = true
					}
					continue
				}
				rowMoved := previous == nil || projector.compareRows(previous, row) != 0
				if rowMoved && previous != nil {
					s.order, _ = removeOrderedRow(
						s.order, s.rows, uid, previous, projector.compareRows,
					)
				}
				s.rows[uid] = row
				s.updatePresentationRowRetentionLocked(uid, row)
				if rowMoved {
					s.order = insertOrderedRow(s.order, s.rows, uid, row, projector.compareRows)
				}
				if previous == nil || !proto.Equal(previous, row) {
					presentationChanged = true
				}
			}
			s.publishPresentationRetentionLocked()
			indexChanged := orderCandidate && !slices.Equal(previousOrder, s.order)
			if presentationChanged || indexChanged {
				s.advancePresentationLocked(indexChanged)
			}
		}
		// Rows and their complete order changed as one atomic projection
		// commit. Advance the revision so a concurrent LIST projection that
		// started from older rows cannot later replace this state.
		s.projectionRevision++
		if s.hasPendingDeliveryLocked() {
			s.signalLocked(false)
		}
		if len(s.pendingObjects) == 0 && !s.projectionResnapshot {
			s.projectionRunning = false
			s.mu.Unlock()
			return
		}
		s.mu.Unlock()
	}
}

// publishWarmCatchupStatusLocked completes the visible stale-to-current
// transition for a compatible reopen that reused a still-running pipeline.
// Subscription.mu is held by the caller. Lifecycle code never waits for that
// mutex while holding Runtime.mu, so taking the runtime lock here follows the
// established handoff order used by replacement publication.
func (s *Subscription) publishWarmCatchupStatusLocked() {
	runNumber := s.warmCatchupRunNumber
	if runNumber == 0 {
		return
	}
	s.warmCatchupRunNumber = 0
	if s.runtime == nil || s.resource == nil {
		return
	}
	runtime := s.runtime
	resource := s.resource
	var status *kmgrv1.ViewStatus
	runtime.mu.Lock()
	if !runtime.closed && runtime.views[s.key] == s && resource.state == resourceRunning &&
		resource.runNumber == runNumber {
		status = statusFromPipeline(resource.lastStatus)
	}
	runtime.mu.Unlock()
	if status != nil {
		s.setStatusLocked(status)
	}
}

// removeOrderedRow removes one affected row from an already sorted UID slice.
// compareRows includes UID as its final tie-breaker, so binary search finds a
// unique position without comparing or sorting the rest of the table. The
// linear fallback is defensive against a corrupted intermediate order and is
// not used during ordinary projection.
func removeOrderedRow(
	order []string,
	rows map[string]*kmgrv1.ResourceRow,
	uid string,
	row *kmgrv1.ResourceRow,
	compare func(*kmgrv1.ResourceRow, *kmgrv1.ResourceRow) int,
) ([]string, bool) {
	index := sort.Search(len(order), func(index int) bool {
		return compare(rows[order[index]], row) >= 0
	})
	if index >= len(order) || order[index] != uid {
		index = slices.Index(order, uid)
		if index < 0 {
			return order, false
		}
	}
	copy(order[index:], order[index+1:])
	clear(order[len(order)-1:])
	return order[:len(order)-1], true
}

// insertOrderedRow applies one affected ordering change with logarithmic row
// comparisons. Moving slice storage is cheaper than reconstructing a row map
// and full-sorting every retained row for each coalesced WATCH batch.
func insertOrderedRow(
	order []string,
	rows map[string]*kmgrv1.ResourceRow,
	uid string,
	row *kmgrv1.ResourceRow,
	compare func(*kmgrv1.ResourceRow, *kmgrv1.ResourceRow) int,
) []string {
	index := sort.Search(len(order), func(index int) bool {
		return compare(rows[order[index]], row) >= 0
	})
	order = append(order, "")
	copy(order[index+1:], order[index:])
	order[index] = uid
	return order
}

func resourceRowsEqual(left, right map[string]*kmgrv1.ResourceRow) bool {
	if len(left) != len(right) {
		return false
	}
	for uid, leftRow := range left {
		if !proto.Equal(leftRow, right[uid]) {
			return false
		}
	}
	return true
}

func (s *Subscription) replacePresentationRetentionLocked(
	rows map[string]*kmgrv1.ResourceRow,
) {
	weights := make(map[string]int64, len(rows))
	var total int64
	var uidBytes int64
	for uid, row := range rows {
		weight := projectedRowRetainedBytes(row)
		weights[uid] = weight
		total = saturatingProjectionBytes(total, weight)
		uidBytes = saturatingProjectionBytes(uidBytes, int64(len(uid)))
	}
	s.presentationRowBytes = weights
	s.presentationRowBytesTotal = total
	s.presentationUIDBytesTotal = uidBytes
	s.publishPresentationRetentionLocked()
}

func (s *Subscription) updatePresentationRowRetentionLocked(
	uid string,
	row *kmgrv1.ResourceRow,
) {
	if uid == "" {
		return
	}
	previous, existed := s.presentationRowBytes[uid]
	if previous <= s.presentationRowBytesTotal {
		s.presentationRowBytesTotal -= previous
	} else {
		s.presentationRowBytesTotal = 0
	}
	if row == nil {
		delete(s.presentationRowBytes, uid)
		if existed {
			s.presentationUIDBytesTotal = max(
				0,
				s.presentationUIDBytesTotal-int64(len(uid)),
			)
		}
	} else {
		weight := projectedRowRetainedBytes(row)
		s.presentationRowBytes[uid] = weight
		s.presentationRowBytesTotal = saturatingProjectionBytes(
			s.presentationRowBytesTotal,
			weight,
		)
		if !existed {
			s.presentationUIDBytesTotal = saturatingProjectionBytes(
				s.presentationUIDBytesTotal,
				int64(len(uid)),
			)
		}
	}
}

func (s *Subscription) publishPresentationRetentionLocked() {
	objects := uint64(len(s.rows))
	bytes := retainedUint64(s.presentationRowBytesTotal)
	// Account for the map/slice containers and UID strings even when the
	// projected rows themselves are tiny. Capacity is intentionally included:
	// deleting rows does not necessarily return these allocations to the heap.
	containerBytes := saturatingProjectionBytes(
		int64(256),
		saturatingProjectionProduct(int64(cap(s.order)), 24),
	)
	containerBytes = saturatingProjectionBytes(
		containerBytes,
		saturatingProjectionProduct(int64(len(s.rows)), 48),
	)
	containerBytes = saturatingProjectionBytes(containerBytes, s.presentationUIDBytesTotal)
	bytes = uint64(saturatingProjectionBytes(int64(bytes), containerBytes))
	s.presentationRetainedObjects.Store(objects)
	s.presentationRetainedBytes.Store(bytes)
	if s.runtime != nil {
		// This is a coalescing hint only. Avoid the Runtime mutex from the
		// Subscription lock; telemetry reads the atomic totals later.
		s.runtime.signalWarmCacheTelemetry()
	}
}

func (s *Subscription) advancePresentationLocked(indexChanged bool) {
	if s.presentationRevision == 0 {
		s.presentationRevision = 1
	} else {
		s.presentationRevision++
	}
	if s.indexRevision == 0 {
		s.indexRevision = 1
	} else if indexChanged {
		s.indexRevision++
	}
	if indexChanged {
		// Tokens retain their own immutable snapshot through fixed expiry. The
		// live subscription owns only the lazily built current pointer.
		s.selectionSnapshot = nil
	}
	if indexChanged && s.metricInterestStop != nil {
		s.metricInterestID++
		s.metricInterestStop()
		s.metricInterestStop = nil
	}
	s.pendingInvalidation = true
}

func (s *Subscription) rebuildOrderLocked() {
	rows := make([]*kmgrv1.ResourceRow, 0, len(s.rows))
	for _, row := range s.rows {
		rows = append(rows, row)
	}
	slices.SortStableFunc(rows, s.projector.compareRows)
	s.order = s.order[:0]
	for _, row := range rows {
		s.order = append(s.order, row.GetIdentity().GetUid())
	}
}

func (s *Subscription) setStatus(status *kmgrv1.ViewStatus) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.setStatusLocked(status)
}

func (s *Subscription) setResourceStatus(
	runNumber uint64,
	status *kmgrv1.ViewStatus,
) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if runNumber < s.minimumResourceRun {
		return
	}
	s.setStatusLocked(status)
}

func (s *Subscription) setStatusLocked(status *kmgrv1.ViewStatus) {
	if s.closed {
		return
	}
	copy := proto.Clone(status).(*kmgrv1.ViewStatus)
	copy.RowsVisible = uint64(len(s.rows))
	copy.MetricsReconciling = s.metricsReconciling
	s.lastStatus = proto.Clone(copy).(*kmgrv1.ViewStatus)
	if len(s.pendingStatuses) < 8 {
		s.pendingStatuses = append(s.pendingStatuses, copy)
	} else {
		// Preserve the first unobserved transition (notably Cached) and
		// coalesce reconnect churn to the newest state.
		s.pendingStatuses[len(s.pendingStatuses)-1] = copy
	}
	s.signalLocked(true)
}

func (s *Subscription) setError(value *kmgrv1.StructuredError) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	s.pendingError = value
	s.signalLocked(true)
}

func (s *Subscription) setResourceError(
	runNumber uint64,
	value *kmgrv1.StructuredError,
) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || runNumber < s.minimumResourceRun {
		return
	}
	s.pendingError = value
	s.signalLocked(true)
}

func (s *Subscription) signalLocked(immediate bool) {
	if s.closed {
		return
	}
	if immediate || s.batchDelay == 0 {
		if s.timer != nil {
			s.timer.Stop()
			s.timer = nil
		}
		select {
		case s.notify <- struct{}{}:
		default:
		}
		return
	}
	if s.timer != nil {
		return
	}
	s.timer = time.AfterFunc(s.batchDelay, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		s.timer = nil
		if !s.closed {
			select {
			case s.notify <- struct{}{}:
			default:
			}
		}
	})
}

func (s *Subscription) drainLocked() []*kmgrv1.ViewEvent {
	if len(s.sealedInitial) != 0 {
		events := s.sealedInitial
		s.sealedInitial = nil
		for _, event := range events {
			event.Cursor = s.cursorLocked()
		}
		if s.hasPendingDeliveryLocked() {
			s.signalLocked(true)
		}
		return events
	}
	events := make([]*kmgrv1.ViewEvent, 0, 4)
	if s.pendingSchema != nil {
		events = append(events, s.schemaEventLocked(s.pendingSchema))
		s.pendingSchema = nil
	}
	for _, status := range s.pendingStatuses {
		events = append(events, s.statusEventLocked(status))
	}
	s.pendingStatuses = nil
	if s.pendingInvalidation || s.optionalResourceHints.hasPendingLocked() {
		observedOptionalResources := s.optionalResourceHints.takePendingLocked()
		events = append(events, s.invalidationEventLocked(&kmgrv1.ViewInvalidation{
			PresentationRevision:                  s.presentationRevision,
			IndexRevision:                         s.indexRevision,
			RowsVisible:                           uint64(len(s.order)),
			MaxRangeLength:                        DefaultViewRangeLength,
			ObservedOptionalResourceKeys:          observedOptionalResources.keys,
			ObservedOptionalResourceKeysTruncated: observedOptionalResources.truncated,
		}))
		s.pendingInvalidation = false
	}
	if s.pendingError != nil {
		events = append(events, s.errorEventLocked(s.pendingError))
		s.pendingError = nil
	}
	if s.pendingReconciliation {
		events = append(events, s.reconciliationEventLocked())
		s.pendingReconciliation = false
		s.reconciliationDelivered = true
	}
	return events
}

func (s *Subscription) hasPendingDeliveryLocked() bool {
	return s.pendingSchema != nil || len(s.pendingStatuses) != 0 || s.pendingInvalidation ||
		s.pendingError != nil || s.pendingReconciliation || s.optionalResourceHints.hasPendingLocked()
}

func (s *Subscription) cursorLocked() *kmgrv1.StreamCursor {
	s.sequence++
	return &kmgrv1.StreamCursor{StreamId: s.key.viewID, Generation: s.generation, Sequence: s.sequence}
}

func (s *Subscription) statusEventLocked(status *kmgrv1.ViewStatus) *kmgrv1.ViewEvent {
	return &kmgrv1.ViewEvent{Cursor: s.cursorLocked(), Payload: &kmgrv1.ViewEvent_Status{Status: status}}
}

func (s *Subscription) schemaEventLocked(schema *kmgrv1.ViewSchema) *kmgrv1.ViewEvent {
	return &kmgrv1.ViewEvent{Cursor: s.cursorLocked(), Payload: &kmgrv1.ViewEvent_Schema{Schema: schema}}
}

func (s *Subscription) invalidationEventLocked(invalidation *kmgrv1.ViewInvalidation) *kmgrv1.ViewEvent {
	return &kmgrv1.ViewEvent{Cursor: s.cursorLocked(), Payload: &kmgrv1.ViewEvent_Invalidation{Invalidation: invalidation}}
}

func (s *Subscription) errorEventLocked(value *kmgrv1.StructuredError) *kmgrv1.ViewEvent {
	return &kmgrv1.ViewEvent{Cursor: s.cursorLocked(), Payload: &kmgrv1.ViewEvent_Error{Error: value}}
}

func (s *Subscription) reconciliationEventLocked() *kmgrv1.ViewEvent {
	return &kmgrv1.ViewEvent{
		Cursor: s.cursorLocked(),
		Payload: &kmgrv1.ViewEvent_Reconciled{Reconciled: &kmgrv1.ViewReconciled{
			RowsVisible:          uint64(len(s.order)),
			PresentationRevision: s.presentationRevision,
			IndexRevision:        s.indexRevision,
		}},
	}
}

func (s *Subscription) close() {
	s.mu.Lock()
	metricSubscription := s.retireLocked()
	s.mu.Unlock()
	if metricSubscription != nil {
		metricSubscription.Close()
	}
}

// retireLocked makes a generation permanently inert while the caller holds
// Subscription.mu. It returns the metrics subscription so provider teardown,
// which takes an unrelated mutex, can happen after all lifecycle locks are
// released.
func (s *Subscription) retireLocked() metricSubscription {
	if s.closed {
		return nil
	}
	s.inFlightDelivery = nil
	s.closed = true
	s.selectionSnapshot = nil
	if s.cancelProjection != nil {
		s.cancelProjection()
		s.cancelProjection = nil
	}
	if s.metricCancel != nil {
		s.metricCancel()
		s.metricCancel = nil
	}
	if s.metricInterestStop != nil {
		s.metricInterestStop()
		s.metricInterestStop = nil
	}
	s.stopCompletePodMetricCoverageTimerLocked()
	s.initialMetricEpoch = nil
	metricSubscription := s.metrics
	s.metrics = nil
	if s.timer != nil {
		s.timer.Stop()
		s.timer = nil
	}
	s.cancelProjectionScheduleLocked()
	clear(s.pendingObjects)
	close(s.done)
	return metricSubscription
}

func projectorFromProto(
	sessionID string,
	spec *kmgrv1.ViewSpec,
	resolver ColumnProgramResolver,
	compiledFilter *viewfilter.Filter,
	workerPool *projectionWorkerPool,
) (*Projector, error) {
	resource := spec.GetResource()
	namespaceScope := NamespaceScope{}
	if scope := spec.GetNamespaceScope(); scope != nil {
		namespaceScope.All = scope.GetAllNamespaces()
		namespaceScope.Namespaces = append([]string(nil), scope.GetNamespaces()...)
	}
	sortDescriptors := make([]SortDescriptor, 0, len(spec.GetSort()))
	for _, descriptor := range spec.GetSort() {
		if descriptor.GetDirection() == kmgrv1.SortDirection_SORT_DIRECTION_UNSPECIFIED {
			continue
		}
		sortDescriptors = append(sortDescriptors, SortDescriptor{
			ColumnID:   descriptor.GetColumnId(),
			Descending: descriptor.GetDirection() == kmgrv1.SortDirection_SORT_DIRECTION_DESCENDING,
			NullsFirst: descriptor.GetNullsFirst(),
		})
	}
	var resolved viewcolumns.Resolution
	var resolvedVersion string
	if resolver != nil {
		var err error
		resolved, resolvedVersion, err = resolver.Resolve(
			resource.GetGroup(), resource.GetVersion(), resource.GetResource(),
			spec.GetColumnIds(), spec.GetColumnConfigurationVersion(),
		)
		if err != nil {
			return nil, err
		}
	}
	accelerators := metrics.AcceleratorConfig{}
	if provider, ok := resolver.(AcceleratorConfigProvider); ok {
		accelerators = provider.AcceleratorConfig()
	}
	return NewProjector(ProjectionSpec{
		ClusterSessionID: sessionID,
		Resource: ResourceType{
			Group: resource.GetGroup(), Version: resource.GetVersion(), Resource: resource.GetResource(),
			Kind: resource.GetKind(), Namespaced: resource.GetNamespaced(),
		},
		NamespaceScope:                     namespaceScope,
		ColumnIDs:                          append([]string(nil), spec.GetColumnIds()...),
		FilterExpression:                   spec.GetFilterExpression(),
		Sort:                               sortDescriptors,
		ColumnConfigurationVersion:         spec.GetColumnConfigurationVersion(),
		ResolvedColumnConfigurationVersion: resolvedVersion,
		CELPrograms:                        resolved.Programs,
		ColumnExtractors:                   resolved.Extractors,
		Accelerators:                       accelerators,
		compiledFilter:                     compiledFilter,
		workerPool:                         workerPool,
	})
}

func statusForWarmEntry(entry *resourceRuntime) *kmgrv1.ViewStatus {
	status := statusFromPipeline(entry.lastStatus)
	currentStore := entry.currentStore()
	if entry.state != resourceRunning && (currentStore.ResourceVersion() != "" || currentStore.Len() != 0) {
		status.Freshness = kmgrv1.ViewFreshness_VIEW_FRESHNESS_STALE
		status.FromWarmCache = true
	}
	if status.ResourceVersionHint == "" {
		status.ResourceVersionHint = currentStore.ResourceVersion()
	}
	return status
}

func statusFromPipeline(status watcher.Status) *kmgrv1.ViewStatus {
	freshness := kmgrv1.ViewFreshness_VIEW_FRESHNESS_LOADING
	switch status.Phase {
	case watcher.PhaseListing:
		if status.Stale {
			freshness = kmgrv1.ViewFreshness_VIEW_FRESHNESS_RELISTING
		}
	case watcher.PhaseResuming:
		freshness = kmgrv1.ViewFreshness_VIEW_FRESHNESS_RESUMING
	case watcher.PhaseWatching:
		freshness = kmgrv1.ViewFreshness_VIEW_FRESHNESS_WATCHING
	case watcher.PhaseReconnecting:
		freshness = kmgrv1.ViewFreshness_VIEW_FRESHNESS_RECONNECTING
	}
	lastSynchronizedUnixMs := int64(0)
	if !status.LastSynchronized.IsZero() {
		lastSynchronizedUnixMs = status.LastSynchronized.UnixMilli()
	}
	return &kmgrv1.ViewStatus{
		Freshness:              freshness,
		ObjectsExamined:        uint64(max(0, status.ObjectsListed)),
		LastSynchronizedUnixMs: lastSynchronizedUnixMs,
		FromWarmCache:          status.Stale,
		ResourceVersionHint:    status.ResourceVersion,
	}
}

func structuredViewError(operation string, err error, retryable bool) *kmgrv1.StructuredError {
	if err == nil {
		err = errors.New("unknown error")
	}
	result := &kmgrv1.StructuredError{
		Category:  kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE,
		Reason:    "ViewStreamFailed",
		Message:   "The Kubernetes resource stream failed.",
		Retryable: retryable,
		Operation: operation,
	}
	kubeerrors.Enrich(result, err)
	return result
}

// Compile-time check that dynamic clients remain compatible with the narrow
// pipeline contract as client-go evolves.
var _ watcher.ListerWatcher = dynamic.ResourceInterface(nil)
var _ watcher.ListerWatcher = watchListDynamicResource{}
var _ watcher.WatchListSemantics = watchListDynamicResource{}
var _ watcher.WatchListSemanticsDisabler = watchListDynamicResource{}
var _ dynamic.ResourceInterface = watchListDynamicResource{}
var _ MetadataSearchResourceSource = ClusterResourceSource{}
var _ = types.UID("")
