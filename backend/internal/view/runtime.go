package view

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/protobuf/proto"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	k8sruntime "k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/metrics"
	"github.com/charlie0129/kmgr/backend/internal/store"
	viewcolumns "github.com/charlie0129/kmgr/backend/internal/view/columns"
	"github.com/charlie0129/kmgr/backend/internal/watcher"
)

const (
	DefaultViewReleaseDelay          = 3 * time.Second
	DefaultViewBatchDelay            = 35 * time.Millisecond
	DefaultSnapshotChunk             = 500
	DefaultPendingRowLimit           = 4096
	DefaultWarmViewLimit             = 24
	DefaultWarmObjectLimit           = 250_000
	DefaultSearchSnapshotLimit       = 4
	DefaultSearchSnapshotObjectLimit = 250_000
	DefaultSearchSnapshotTTL         = 30 * time.Second
)

var (
	ErrViewClosed      = errors.New("resource view is closed")
	ErrSessionNotFound = errors.New("cluster session was not found")
	ErrStaleViewOpen   = errors.New("resource view generation is stale")
	ErrInvalidView     = errors.New("invalid resource view")
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

// ClusterResourceSource adapts the authoritative cluster session registry.
type ClusterResourceSource struct {
	Sessions *cluster.SessionRegistry
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
	// SessionRegistry shares one dynamic client between workspace sessions for
	// the same catalog/context. Include its pointer so a kubeconfig reload that
	// happens to retain the same stable context ID cannot cross-wire clients.
	authorityID := session.Context().ID + "/" + pointerIdentity(session.Dynamic())
	return authorityID, resourceClient, nil
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
	return session.Context().ID + "/" + pointerIdentity(session.Dynamic()), true
}

func pointerIdentity(value any) string {
	ref := reflect.ValueOf(value)
	switch ref.Kind() {
	case reflect.Chan, reflect.Func, reflect.Map, reflect.Pointer, reflect.Slice, reflect.UnsafePointer:
		if !ref.IsNil() {
			return fmt.Sprintf("%x", ref.Pointer())
		}
	}
	return fmt.Sprintf("%T", value)
}

type RuntimeConfig struct {
	Source                    ResourceSource
	Metrics                   MetricSource
	Columns                   ColumnProgramResolver
	ReleaseDelay              time.Duration
	BatchDelay                time.Duration
	SnapshotChunkSize         int
	PendingRowLimit           int
	WarmViewLimit             int
	WarmObjectLimit           int
	PipelinePageSize          int64
	PipelineTimeout           time.Duration
	SearchSnapshotLimit       int
	SearchSnapshotObjectLimit int
	SearchSnapshotTTL         time.Duration
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

	source            ResourceSource
	metrics           MetricSource
	columns           ColumnProgramResolver
	releaseDelay      time.Duration
	batchDelay        time.Duration
	snapshotChunkSize int
	pendingRowLimit   int
	pageSize          int64
	watchTimeout      time.Duration

	resources map[resourceKey]*resourceRuntime
	views     map[viewKey]*Subscription
	warm      *watcher.WarmCache[resourceKey, *resourceRuntime]

	searchSnapshots           map[searchSnapshotKey]*completedSearchSnapshot
	searchSnapshotLimit       int
	searchSnapshotObjects     int
	searchSnapshotObjectLimit int
	searchSnapshotTTL         time.Duration
	searchSnapshotSequence    uint64
	transientSearchLists      map[searchSnapshotKey]*transientSearchList

	nodeAccounting         map[nodeAccountingKey]*nodeAccountingWork
	nodeAccountingRevision uint64
	nodeAccountingComputer nodeAccountingComputer
	closed                 bool
}

// CachedChild identifies an object already retained by a visible or warm
// resource view. It deliberately exposes no store or watcher lifetime: callers
// get one bounded point-in-time slice and must treat it as incomplete coverage.
type CachedChild struct {
	Group    string
	Version  string
	Resource string
	Object   *unstructured.Unstructured
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
}

// searchSnapshotKey is deliberately stricter than resourceKey. A namespaced
// view whose client is cluster-scoped still has a logical namespace scope, so
// two multi-namespace views must not exchange snapshots merely because both
// clients LIST with namespace="".
type searchSnapshotKey struct {
	resource       resourceKey
	namespaceScope string
}

// completedSearchSnapshot is a short-lived, single-consumer handoff from a
// command-palette LIST to a subsequently opened resource view. Once consumed,
// the normal resourceRuntime owns the store and its LIST/WATCH lifetime.
type completedSearchSnapshot struct {
	store           *store.UIDStore
	objectCount     int
	completedAt     time.Time
	sequence        uint64
	expiresAt       time.Time
	expirationTimer *time.Timer
}

type resourceRuntime struct {
	key          resourceKey
	store        *store.UIDStore
	client       watcher.ListerWatcher
	subscribers  map[*Subscription]struct{}
	dependents   map[*Subscription]struct{}
	ctx          context.Context
	cancel       context.CancelFunc
	running      bool
	runNumber    uint64
	releaseTimer *time.Timer
	lastStatus   watcher.Status
	// accountingReady is set only after a complete LIST has reached runtime.
	// ResourceVersion can advance in the store just before that callback, so it
	// is not by itself a safe signal for a newly attached dependent.
	accountingReady bool
	accountingError error
	// transientSearchList is set while this entry is sharing a command-palette
	// LIST. The normal watcher pipeline must not start until that LIST either
	// commits its final resourceVersion or terminates and releases ownership.
	transientSearchList      *transientSearchList
	transientSearchUsesStore bool
}

type nodeAccountingKey struct {
	nodes *resourceRuntime
	pods  *resourceRuntime
}

type nodeAccountingResult struct {
	revision uint64
	snapshot NodeAccountingSnapshot
}

// nodeAccountingWork coalesces changes for one shared Node/Pod store pair.
// Every field is protected by Runtime.mu. The expensive store conversion and
// scheduler aggregation always happen in runNodeAccounting, outside that lock.
type nodeAccountingWork struct {
	key       nodeAccountingKey
	revision  uint64
	ready     bool
	err       error
	running   bool
	published *nodeAccountingResult
}

type nodeAccountingComputer func(
	nodeObjects, podObjects []*unstructured.Unstructured,
	accelerators metrics.AcceleratorConfig,
	ready bool,
	dependencyErr error,
) NodeAccountingSnapshot

type viewKey struct {
	sessionID string
	viewID    string
}

func NewRuntime(config RuntimeConfig) (*Runtime, error) {
	if config.Source == nil {
		return nil, errors.New("resource source must not be nil")
	}
	if config.ReleaseDelay < 0 || config.BatchDelay < 0 || config.PipelinePageSize < 0 || config.PipelineTimeout < 0 ||
		config.SearchSnapshotLimit < 0 || config.SearchSnapshotObjectLimit < 0 || config.SearchSnapshotTTL < 0 {
		return nil, errors.New("view runtime durations and page size must not be negative")
	}
	releaseDelay := config.ReleaseDelay
	if releaseDelay == 0 {
		releaseDelay = DefaultViewReleaseDelay
	}
	batchDelay := config.BatchDelay
	if batchDelay == 0 {
		batchDelay = DefaultViewBatchDelay
	}
	chunkSize := config.SnapshotChunkSize
	if chunkSize == 0 {
		chunkSize = DefaultSnapshotChunk
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
	if chunkSize <= 0 || pendingLimit <= 0 || warmViews <= 0 || warmObjects <= 0 {
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
	return &Runtime{
		source:                    config.Source,
		metrics:                   config.Metrics,
		columns:                   config.Columns,
		releaseDelay:              releaseDelay,
		batchDelay:                batchDelay,
		snapshotChunkSize:         chunkSize,
		pendingRowLimit:           pendingLimit,
		pageSize:                  config.PipelinePageSize,
		watchTimeout:              config.PipelineTimeout,
		resources:                 make(map[resourceKey]*resourceRuntime),
		views:                     make(map[viewKey]*Subscription),
		warm:                      watcher.NewWarmCache[resourceKey, *resourceRuntime](warmViews, warmObjects),
		searchSnapshots:           make(map[searchSnapshotKey]*completedSearchSnapshot),
		searchSnapshotLimit:       searchSnapshotLimit,
		searchSnapshotObjectLimit: searchSnapshotObjectLimit,
		searchSnapshotTTL:         searchSnapshotTTL,
		transientSearchLists:      make(map[searchSnapshotKey]*transientSearchList),
		nodeAccounting:            make(map[nodeAccountingKey]*nodeAccountingWork),
		nodeAccountingComputer:    computeNodeAccounting,
	}, nil
}

// Open installs warm rows synchronously before starting or resuming network
// continuity. A newer generation atomically replaces the prior stream with the
// same session/view ID.
func (r *Runtime) Open(request *kmgrv1.OpenViewRequest) (*Subscription, error) {
	if request == nil || request.GetContext() == nil || request.GetSpec() == nil {
		return nil, fmt.Errorf("%w: request, context, and spec are required", ErrInvalidView)
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
	serverNamespace, err := serverNamespace(request.GetSpec())
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidView, err)
	}
	authorityID, client, err := r.source.OpenResource(sessionID, gvr, serverNamespace)
	if err != nil {
		return nil, err
	}
	projector, err := projectorFromProto(sessionID, request.GetSpec(), r.columns)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidView, err)
	}
	key := resourceKey{
		authorityID: authorityID,
		group:       gvr.Group,
		version:     gvr.Version,
		resource:    gvr.Resource,
		namespace:   serverNamespace,
		labels:      request.GetSpec().GetLabelSelector(),
		fields:      request.GetSpec().GetFieldSelector(),
	}
	streamKey := viewKey{sessionID: sessionID, viewID: viewID}

	var replaced *Subscription
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return nil, ErrViewClosed
	}
	if previous := r.views[streamKey]; previous != nil && request.GetGeneration() < previous.generation {
		r.mu.Unlock()
		return nil, ErrStaleViewOpen
	}
	if previous := r.views[streamKey]; previous != nil {
		r.detachLocked(previous)
		replaced = previous
	}
	entry := r.resources[key]
	if entry == nil {
		if cached, ok := r.warm.Get(key); ok {
			entry = cached.Value
		}
	}
	var searchSnapshot *completedSearchSnapshot
	var transientList *transientSearchList
	if entry == nil {
		handoffKey := searchSnapshotKey{
			resource:       key,
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
			dependents:  make(map[*Subscription]struct{}),
		}
		if searchSnapshot != nil {
			entry.accountingReady = true
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
				entry.accountingReady = true
				entry.lastStatus.Phase = watcher.PhaseResuming
				entry.lastStatus.Stale = true
			}
		}
		r.resources[key] = entry
	}
	r.warm.Remove(key)
	if entry.releaseTimer != nil {
		entry.releaseTimer.Stop()
		entry.releaseTimer = nil
	}

	subscription := newSubscription(
		streamKey,
		request.GetGeneration(),
		projector,
		r.batchDelay,
		r.snapshotChunkSize,
		r.pendingRowLimit,
	)
	subscription.runtime = r
	subscription.resource = entry
	if needsNodeAccounting(projector) {
		projector = projector.WithNodeAccounting(NodeAccountingSnapshot{Active: true})
		subscription.projector = projector
	}
	var metricSubscription *metrics.Subscription
	if r.metrics != nil && needsMetricProvider(projector) {
		metricKind, _ := metricKindFor(projector.spec.Resource)
		provider, metricErr := r.metrics.OpenMetrics(
			sessionID, authorityID, metricKind,
			metricsNamespace(projector.spec.Resource, serverNamespace),
		)
		if metricErr != nil {
			// Optional metrics setup cannot fail the base resource view. The
			// projector already renders request/limit or allocatable accounting
			// with usage unavailable.
			projector = projector.WithMetrics(metrics.Snapshot{
				State: metrics.MeasurementUnavailable, Err: metricErr,
			})
			subscription.projector = projector
		} else {
			metricSubscription = provider.Subscribe()
		}
	}
	if metricSubscription == nil {
		projector = subscription.projector
	}
	warmRows := projector.Project(entry.store.Snapshot())
	if len(warmRows) != 0 {
		subscription.initializeRows(warmRows)
		subscription.setStatusLocked(statusForWarmEntry(entry))
	} else {
		subscription.setStatusLocked(&kmgrv1.ViewStatus{Freshness: kmgrv1.ViewFreshness_VIEW_FRESHNESS_LOADING})
		subscription.initializeRows(nil)
	}
	entry.subscribers[subscription] = struct{}{}
	r.views[streamKey] = subscription
	var startSubscribers []*Subscription
	var startError *kmgrv1.StructuredError
	if !entry.running && entry.transientSearchList == nil {
		startSubscribers, startError = r.startResourceLocked(entry)
	}
	r.mu.Unlock()
	if replaced != nil {
		replaced.close()
	}
	deliverSubscriptionError(startSubscribers, startError)
	// Enqueue the base projection before metrics can publish. Starting this
	// goroutine after releasing the runtime lock also keeps a very fast metrics
	// response from contending with the base LIST/WATCH setup.
	subscription.attachMetrics(metricSubscription)
	if needsNodeAccounting(projector) {
		go r.attachNodeAccounting(subscription, sessionID, authorityID)
	}
	return subscription, nil
}

func (r *Runtime) attachNodeAccounting(subscription *Subscription, sessionID, authorityID string) {
	podGVR := schema.GroupVersionResource{Version: "v1", Resource: "pods"}
	resolvedAuthority, client, err := r.source.OpenResource(sessionID, podGVR, "")
	if err != nil {
		r.applyNodeAccountingError(subscription, err)
		return
	}
	if resolvedAuthority != authorityID {
		r.applyNodeAccountingError(subscription, errors.New("Pod accounting resolved a different cluster authority"))
		return
	}
	key := resourceKey{authorityID: authorityID, version: "v1", resource: "pods"}
	r.mu.Lock()
	if r.closed || r.views[subscription.key] != subscription {
		r.mu.Unlock()
		return
	}
	entry := r.resources[key]
	if entry == nil {
		if cached, ok := r.warm.Get(key); ok {
			entry = cached.Value
		}
	}
	if entry == nil {
		entry = &resourceRuntime{
			key: key, store: store.New(), client: client,
			subscribers: make(map[*Subscription]struct{}),
			dependents:  make(map[*Subscription]struct{}),
		}
		r.resources[key] = entry
	}
	if entry.dependents == nil {
		entry.dependents = make(map[*Subscription]struct{})
	}
	if !entry.accountingReady && entry.store.ResourceVersion() != "" {
		// A warm pipeline resumes directly from its retained resourceVersion and
		// has no new LIST-complete callback. Its retained Pod snapshot is already
		// a valid (stale-until-watch-connects) accounting basis.
		entry.accountingReady = true
	}
	r.warm.Remove(key)
	if entry.releaseTimer != nil {
		entry.releaseTimer.Stop()
		entry.releaseTimer = nil
	}
	entry.dependents[subscription] = struct{}{}
	subscription.nodePods = entry
	var startSubscribers []*Subscription
	var startError *kmgrv1.StructuredError
	if !entry.running {
		startSubscribers, startError = r.startResourceLocked(entry)
	}
	var current *nodeAccountingResult
	if entry.accountingReady || entry.accountingError != nil {
		current = r.currentOrScheduleNodeAccountingLocked(
			subscription.resource, entry, entry.accountingError,
		)
	}
	r.mu.Unlock()
	deliverSubscriptionError(startSubscribers, startError)
	if current != nil {
		subscription.applyNodeAccounting(current)
	}
}

// currentOrScheduleNodeAccountingLocked lets a late dependent consume the
// exact revision already shared by its peers. Attaching a view is not itself a
// store change and therefore must not repeat cluster-wide aggregation.
func (r *Runtime) currentOrScheduleNodeAccountingLocked(
	nodes, pods *resourceRuntime,
	dependencyErr error,
) *nodeAccountingResult {
	key := nodeAccountingKey{nodes: nodes, pods: pods}
	if work := r.nodeAccounting[key]; work != nil {
		if work.published != nil && work.published.revision == work.revision &&
			work.published.snapshot.Ready && sameError(work.published.snapshot.Err, dependencyErr) {
			return work.published
		}
		if work.running {
			return nil
		}
	}
	r.scheduleNodeAccountingLocked(nodes, pods, pods.accountingReady, dependencyErr)
	return nil
}

func sameError(left, right error) bool {
	if left == nil || right == nil {
		return left == nil && right == nil
	}
	return left.Error() == right.Error()
}

func (r *Runtime) applyNodeAccountingError(subscription *Subscription, err error) {
	r.mu.Lock()
	if r.closed || subscription == nil || r.views[subscription.key] != subscription {
		r.mu.Unlock()
		return
	}
	r.nodeAccountingRevision++
	result := &nodeAccountingResult{
		revision: r.nodeAccountingRevision,
		snapshot: NodeAccountingSnapshot{Active: true, Err: err},
	}
	r.mu.Unlock()
	subscription.applyNodeAccounting(result)
}

func (r *Runtime) startResourceLocked(entry *resourceRuntime) ([]*Subscription, *kmgrv1.StructuredError) {
	if entry.transientSearchList != nil {
		return nil, nil
	}
	entry.runNumber++
	runNumber := entry.runNumber
	ctx, cancel := context.WithCancel(context.Background())
	entry.ctx = ctx
	entry.cancel = cancel
	entry.running = true
	pipeline, err := watcher.NewPipeline(watcher.PipelineConfig{
		Client:       entry.client,
		Store:        entry.store,
		PageSize:     r.pageSize,
		WatchTimeout: r.watchTimeout,
		ListOptions: metav1.ListOptions{
			LabelSelector: entry.key.labels,
			FieldSelector: entry.key.fields,
		},
		OnStatus: func(status watcher.Status) { r.receiveStatus(entry, runNumber, status) },
		OnBatch:  func(batch watcher.Batch) { r.receiveBatch(entry, runNumber, batch) },
	})
	if err != nil {
		entry.running = false
		entry.cancel()
		entry.cancel = nil
		entry.ctx = nil
		subscriptions := make([]*Subscription, 0, len(entry.subscribers))
		for subscription := range entry.subscribers {
			subscriptions = append(subscriptions, subscription)
		}
		if len(entry.dependents) != 0 {
			entry.accountingReady = false
			entry.accountingError = fmt.Errorf("watch Pods: %w", err)
			r.scheduleNodeAccountingLocked(nil, entry, false, entry.accountingError)
		}
		return subscriptions, structuredViewError("watch resource", err, true)
	}
	go func() {
		err := pipeline.Run(ctx)
		r.resourceStopped(entry, runNumber, err)
	}()
	return nil, nil
}

func deliverSubscriptionError(subscriptions []*Subscription, value *kmgrv1.StructuredError) {
	if value == nil {
		return
	}
	for _, subscription := range subscriptions {
		subscription.setError(value)
	}
}

func (r *Runtime) receiveStatus(entry *resourceRuntime, runNumber uint64, status watcher.Status) {
	r.mu.Lock()
	if entry.runNumber != runNumber || !entry.running {
		r.mu.Unlock()
		return
	}
	entry.lastStatus = status
	translated := statusFromPipeline(status)
	subscriptions := make([]*Subscription, 0, len(entry.subscribers))
	for subscription := range entry.subscribers {
		subscriptions = append(subscriptions, subscription)
	}
	r.mu.Unlock()
	for _, subscription := range subscriptions {
		subscription.setStatus(translated)
	}
}

func (r *Runtime) receiveBatch(entry *resourceRuntime, runNumber uint64, batch watcher.Batch) {
	r.mu.Lock()
	if entry.runNumber != runNumber || !entry.running {
		r.mu.Unlock()
		return
	}
	subscriptions := r.prepareEntryBatchLocked(entry, batch)
	r.mu.Unlock()

	for _, subscription := range subscriptions {
		subscription.applyBatch(batch)
	}
}

// prepareEntryBatchLocked mirrors the lifecycle work needed for both ordinary
// pipeline batches and command-palette LIST pages. Runtime.mu must be held.
func (r *Runtime) prepareEntryBatchLocked(
	entry *resourceRuntime,
	batch watcher.Batch,
) []*Subscription {
	// Capture consumers while the lifecycle graph is stable, then project the
	// batch after releasing the runtime-wide mutex. Subscription.applyBatch has
	// its own closed/generation gate, so a concurrent detach is safe.
	subscriptions := make([]*Subscription, 0, len(entry.subscribers))
	for subscription := range entry.subscribers {
		subscriptions = append(subscriptions, subscription)
	}
	if batch.SnapshotComplete {
		entry.accountingReady = true
	}
	entry.accountingError = nil
	if len(entry.dependents) != 0 && (batch.SnapshotComplete || (!batch.FromList && !batch.Bookmark)) {
		r.scheduleNodeAccountingLocked(nil, entry, entry.accountingReady, nil)
	}
	if isNodeResourceKey(entry.key) && (batch.SnapshotComplete || (!batch.FromList && !batch.Bookmark)) {
		seenPods := make(map[*resourceRuntime]struct{})
		for subscription := range entry.subscribers {
			pods := subscription.nodePods
			if pods == nil || !pods.accountingReady {
				continue
			}
			if _, seen := seenPods[pods]; seen {
				continue
			}
			seenPods[pods] = struct{}{}
			r.scheduleNodeAccountingLocked(entry, pods, true, nil)
		}
	}
	return subscriptions
}

func (r *Runtime) resourceStopped(entry *resourceRuntime, runNumber uint64, err error) {
	r.mu.Lock()
	if entry.runNumber != runNumber {
		r.mu.Unlock()
		return
	}
	entry.running = false
	entry.cancel = nil
	entry.ctx = nil
	if len(entry.subscribers)+len(entry.dependents) == 0 || errors.Is(err, context.Canceled) {
		r.mu.Unlock()
		return
	}
	subscriptions := make([]*Subscription, 0, len(entry.subscribers))
	for subscription := range entry.subscribers {
		subscriptions = append(subscriptions, subscription)
	}
	if len(entry.dependents) != 0 {
		// Preserve a previously complete cached revision while surfacing that
		// it is stale. A failure before the first complete Pod snapshot instead
		// becomes unavailable and leaves Calculating immediately.
		entry.accountingError = err
		r.scheduleNodeAccountingLocked(nil, entry, entry.accountingReady, entry.accountingError)
	}
	r.mu.Unlock()
	deliverSubscriptionError(subscriptions, structuredViewError("watch resource", err, true))
}

func isNodeResourceKey(key resourceKey) bool {
	return key.group == "" && key.version == "v1" && key.resource == "nodes"
}

// scheduleNodeAccountingLocked marks one shared Node/Pod accounting pair
// dirty and ensures at most one worker is running for it. Either entry may be
// nil when the caller only knows the other side; all currently attached pairs
// are then selected. Repeated changes coalesce behind the newest revision.
func (r *Runtime) scheduleNodeAccountingLocked(
	nodes *resourceRuntime,
	pods *resourceRuntime,
	ready bool,
	dependencyErr error,
) {
	if r.closed || pods == nil {
		return
	}
	selected := make(map[*resourceRuntime]struct{})
	for subscription := range pods.dependents {
		if subscription == nil || subscription.resource == nil {
			continue
		}
		if nodes == nil || subscription.resource == nodes {
			selected[subscription.resource] = struct{}{}
		}
	}
	for nodeEntry := range selected {
		key := nodeAccountingKey{nodes: nodeEntry, pods: pods}
		work := r.nodeAccounting[key]
		if work == nil {
			work = &nodeAccountingWork{key: key}
			r.nodeAccounting[key] = work
		}
		r.nodeAccountingRevision++
		work.revision = r.nodeAccountingRevision
		work.ready = ready
		work.err = dependencyErr
		if work.running {
			continue
		}
		work.running = true
		go r.runNodeAccounting(work)
	}
}

func (r *Runtime) runNodeAccounting(work *nodeAccountingWork) {
	for {
		r.mu.Lock()
		if r.closed || r.nodeAccounting[work.key] != work {
			r.mu.Unlock()
			return
		}
		revision, ready, dependencyErr := work.revision, work.ready, work.err
		nodeStore, podStore := work.key.nodes.store, work.key.pods.store
		computer := r.nodeAccountingComputer
		acceleratorProvider, _ := r.columns.(AcceleratorConfigProvider)
		r.mu.Unlock()

		// Store snapshots, typed conversion, aggregation, and projection are
		// deliberately outside Runtime.mu. UIDStore supplies its own locking.
		accelerators := metrics.AcceleratorConfig{}
		if acceleratorProvider != nil {
			accelerators = acceleratorProvider.AcceleratorConfig()
		}
		snapshot := computer(
			nodeStore.Snapshot(), podStore.Snapshot(), accelerators, ready, dependencyErr,
		)

		r.mu.Lock()
		if r.closed || r.nodeAccounting[work.key] != work {
			r.mu.Unlock()
			return
		}
		if work.revision != revision {
			r.mu.Unlock()
			continue
		}
		result := &nodeAccountingResult{revision: revision, snapshot: snapshot}
		work.published = result
		subscriptions := r.nodeAccountingSubscribersLocked(work.key)
		r.mu.Unlock()

		for _, subscription := range subscriptions {
			subscription.applyNodeAccounting(result)
		}

		r.mu.Lock()
		if r.closed || r.nodeAccounting[work.key] != work {
			r.mu.Unlock()
			return
		}
		if work.revision != revision {
			r.mu.Unlock()
			continue
		}
		work.running = false
		r.mu.Unlock()
		return
	}
}

func (r *Runtime) nodeAccountingSubscribersLocked(key nodeAccountingKey) []*Subscription {
	result := make([]*Subscription, 0, len(key.pods.dependents))
	for subscription := range key.pods.dependents {
		if subscription == nil || subscription.resource != key.nodes ||
			subscription.nodePods != key.pods || r.views[subscription.key] != subscription {
			continue
		}
		result = append(result, subscription)
	}
	return result
}

func computeNodeAccounting(
	nodeObjects, podObjects []*unstructured.Unstructured,
	accelerators metrics.AcceleratorConfig,
	ready bool,
	dependencyErr error,
) NodeAccountingSnapshot {
	nodes := make([]*corev1.Node, 0, len(nodeObjects))
	for _, object := range nodeObjects {
		var node corev1.Node
		if err := k8sruntime.DefaultUnstructuredConverter.FromUnstructured(object.Object, &node); err == nil {
			nodes = append(nodes, &node)
		}
	}
	pods := make([]*corev1.Pod, 0, len(podObjects))
	for _, object := range podObjects {
		var pod corev1.Pod
		if err := k8sruntime.DefaultUnstructuredConverter.FromUnstructured(object.Object, &pod); err == nil {
			pods = append(pods, &pod)
		}
	}
	return NodeAccountingSnapshot{
		Active: true, Ready: ready, Err: dependencyErr,
		Nodes:      metrics.AggregateNodes(nodes, pods, nil),
		Discovered: metrics.DiscoverResources(nodes, pods, accelerators),
	}
}

// Cancel is idempotent. A stale cancellation cannot close a newer generation.
func (r *Runtime) Cancel(sessionID, viewID string, generation uint64) bool {
	r.mu.Lock()
	subscription := r.views[viewKey{sessionID: sessionID, viewID: viewID}]
	if subscription == nil || subscription.generation != generation {
		r.mu.Unlock()
		return false
	}
	r.detachLocked(subscription)
	r.mu.Unlock()
	subscription.close()
	return true
}

func (r *Runtime) detachLocked(subscription *Subscription) {
	if subscription == nil || r.views[subscription.key] != subscription {
		return
	}
	delete(r.views, subscription.key)
	entry := subscription.resource
	delete(entry.subscribers, subscription)
	if transient := entry.transientSearchList; transient != nil && transient.view == entry &&
		len(entry.subscribers)+len(entry.dependents) == 0 {
		// A valid terminal LIST is still delivering its final projection. Keep
		// the entry and coordinator association until that delivery gate opens;
		// a same-key Open can then reuse the complete store instead of starting a
		// duplicate LIST, and the reusable search offer remains truthful.
		if transient.terminal && entry.store.ResourceVersion() != "" {
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
	if dependency := subscription.nodePods; dependency != nil {
		delete(dependency.dependents, subscription)
		subscription.nodePods = nil
		r.removeUnusedNodeAccountingLocked(entry, dependency)
		r.scheduleReleaseLocked(dependency)
	}
	r.scheduleReleaseLocked(entry)
}

func (r *Runtime) removeUnusedNodeAccountingLocked(nodes, pods *resourceRuntime) {
	if nodes == nil || pods == nil {
		return
	}
	for subscription := range pods.dependents {
		if subscription != nil && subscription.resource == nodes && subscription.nodePods == pods {
			return
		}
	}
	delete(r.nodeAccounting, nodeAccountingKey{nodes: nodes, pods: pods})
}

func (r *Runtime) scheduleReleaseLocked(entry *resourceRuntime) {
	if entry == nil || entry.transientSearchList != nil ||
		len(entry.subscribers)+len(entry.dependents) != 0 || entry.releaseTimer != nil {
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
	if r.closed || r.resources[key] != entry || len(entry.subscribers)+len(entry.dependents) != 0 || entry.runNumber != runNumber {
		return
	}
	entry.releaseTimer = nil
	if entry.cancel != nil {
		entry.cancel()
	}
	entry.running = false
	evicted, admitted := r.warm.Put(key, watcher.WarmEntry[*resourceRuntime]{
		Value:            entry,
		ObjectCount:      entry.store.Len(),
		ResourceVersion:  entry.store.ResourceVersion(),
		LastSynchronized: entry.lastStatus.LastSynchronized,
		Complete:         entry.store.ResourceVersion() != "",
	})
	if !admitted && r.resources[key] == entry &&
		len(entry.subscribers)+len(entry.dependents) == 0 && !entry.running {
		delete(r.resources, key)
	}
	for _, evictedKey := range evicted {
		if evictedEntry := r.resources[evictedKey]; evictedEntry != nil && len(evictedEntry.subscribers)+len(evictedEntry.dependents) == 0 && !evictedEntry.running {
			delete(r.resources, evictedKey)
		}
	}
}

func (r *Runtime) closeSubscription(subscription *Subscription) {
	r.mu.Lock()
	detached := false
	if current := r.views[subscription.key]; current == subscription {
		r.detachLocked(subscription)
		detached = true
	}
	r.mu.Unlock()
	if detached {
		subscription.close()
	}
}

func (r *Runtime) Close() {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return
	}
	r.closed = true
	subscriptions := make([]*Subscription, 0, len(r.views))
	for _, subscription := range r.views {
		subscriptions = append(subscriptions, subscription)
	}
	clear(r.views)
	for key, entry := range r.resources {
		if entry.releaseTimer != nil {
			entry.releaseTimer.Stop()
		}
		if entry.cancel != nil {
			entry.cancel()
		}
		entry.running = false
		delete(r.resources, key)
	}
	for key, snapshot := range r.searchSnapshots {
		r.removeSearchSnapshotLocked(key, snapshot)
	}
	for _, transient := range r.transientSearchLists {
		r.closeTransientSearchListLocked(transient, ErrViewClosed)
	}
	clear(r.nodeAccounting)
	r.mu.Unlock()
	for _, subscription := range subscriptions {
		subscription.close()
	}
}

// installSearchSnapshot retains one completed, validated LIST for a short
// handoff window. Entry and aggregate object budgets evict the oldest
// snapshots first. It returns the installed identity so a failed final emit
// can revoke exactly that snapshot without deleting a newer replacement.
func (r *Runtime) installSearchSnapshot(
	key searchSnapshotKey,
	snapshotStore *store.UIDStore,
) (*completedSearchSnapshot, bool) {
	if snapshotStore == nil || snapshotStore.ResourceVersion() == "" {
		return nil, false
	}
	objectCount := snapshotStore.Len()
	if objectCount > r.searchSnapshotObjectLimit {
		return nil, false
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now()
	if !r.installCompletedSearchSnapshotLocked(key, snapshotStore, now) {
		return nil, false
	}
	snapshot := r.searchSnapshots[key]
	return snapshot, true
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

func (r *Runtime) revokeSearchSnapshot(key searchSnapshotKey, snapshot *completedSearchSnapshot) {
	if snapshot == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.removeSearchSnapshotLocked(key, snapshot)
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
		if entry.running {
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
		if key.authorityID != authorityID || key.group != "" || key.version != "v1" ||
			(key.resource != "nodes" && key.resource != "pods") || entry == nil || entry.store == nil {
			continue
		}
		entries = append(entries, cachedStore{
			key: key, store: entry.store, complete: entry.accountingReady || entry.store.ResourceVersion() != "",
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

// CachedChildren returns only children visible in existing view caches for the
// selected session authority. It never opens a resource, starts a watcher, or
// performs network I/O. Different selectors/scopes can retain overlapping
// objects, so results are de-duplicated by full GVR plus UID.
func (r *Runtime) CachedChildren(sessionID, ownerUID string) []CachedChild {
	if strings.TrimSpace(sessionID) == "" || strings.TrimSpace(ownerUID) == "" {
		return nil
	}
	authoritySource, ok := r.source.(interface {
		AuthorityID(string) (string, bool)
	})
	if !ok {
		return nil
	}
	authorityID, ok := authoritySource.AuthorityID(sessionID)
	if !ok {
		return nil
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	seen := make(map[string]struct{})
	result := make([]CachedChild, 0)
	for key, entry := range r.resources {
		if key.authorityID != authorityID || entry == nil || entry.store == nil {
			continue
		}
		for _, object := range entry.store.Children(types.UID(ownerUID)) {
			if object == nil || object.GetUID() == "" {
				continue
			}
			unique := strings.Join([]string{
				key.group, key.version, key.resource, string(object.GetUID()),
			}, "\x00")
			if _, exists := seen[unique]; exists {
				continue
			}
			seen[unique] = struct{}{}
			result = append(result, CachedChild{
				Group: key.group, Version: key.version, Resource: key.resource, Object: object,
			})
		}
	}
	sort.Slice(result, func(i, j int) bool {
		left, right := result[i], result[j]
		return strings.Join([]string{
			left.Group, left.Version, left.Resource, left.Object.GetNamespace(),
			left.Object.GetName(), string(left.Object.GetUID()),
		}, "\x00") < strings.Join([]string{
			right.Group, right.Version, right.Resource, right.Object.GetNamespace(),
			right.Object.GetName(), string(right.Object.GetUID()),
		}, "\x00")
	})
	return result
}

// Subscription is a bounded, coalescing mailbox. Slow clients retain at most
// PendingRowLimit delta rows before falling back to one newest snapshot.
type Subscription struct {
	runtime      *Runtime
	resource     *resourceRuntime
	nodePods     *resourceRuntime
	key          viewKey
	metrics      *metrics.Subscription
	metricCancel context.CancelFunc

	mu                     sync.Mutex
	generation             uint64
	sequence               uint64
	projector              *Projector
	nodeAccountingRevision uint64
	rows                   map[string]*kmgrv1.ResourceRow
	order                  []string
	pendingUpserts         map[string]*kmgrv1.ResourceRow
	pendingRemoved         map[string]struct{}
	pendingStatuses        []*kmgrv1.ViewStatus
	pendingError           *kmgrv1.StructuredError
	orderDirty             bool
	resnapshot             bool
	notify                 chan struct{}
	done                   chan struct{}
	timer                  *time.Timer
	batchDelay             time.Duration
	chunkSize              int
	pendingLimit           int
	closed                 bool
}

func newSubscription(
	key viewKey,
	generation uint64,
	projector *Projector,
	batchDelay time.Duration,
	chunkSize int,
	pendingLimit int,
) *Subscription {
	return &Subscription{
		key:            key,
		generation:     generation,
		projector:      projector,
		rows:           make(map[string]*kmgrv1.ResourceRow),
		pendingUpserts: make(map[string]*kmgrv1.ResourceRow),
		pendingRemoved: make(map[string]struct{}),
		notify:         make(chan struct{}, 1),
		done:           make(chan struct{}),
		batchDelay:     batchDelay,
		chunkSize:      chunkSize,
		pendingLimit:   pendingLimit,
	}
}

func (s *Subscription) Generation() uint64 { return s.generation }
func (s *Subscription) ViewID() string     { return s.key.viewID }

// Next waits for one coalesced delivery and returns one or more ordered stream
// events. Snapshot chunks are bounded even when the retained view is huge.
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
	return s.drainLocked(), nil
}

func (s *Subscription) Close() {
	if s.runtime != nil {
		s.runtime.closeSubscription(s)
	}
}

func (s *Subscription) attachMetrics(subscription *metrics.Subscription) {
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
	s.mu.Unlock()
	go s.receiveMetrics(ctx, subscription)
}

func (s *Subscription) receiveMetrics(ctx context.Context, subscription *metrics.Subscription) {
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
	defer s.mu.Unlock()
	if s.closed || s.resource == nil {
		return
	}
	s.projector = s.projector.WithMetrics(snapshot)
	s.replaceProjectionLocked(s.projector.Project(s.resource.store.Snapshot()))
}

func (s *Subscription) applyNodeAccounting(result *nodeAccountingResult) {
	if result == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.resource == nil || result.revision <= s.nodeAccountingRevision {
		return
	}
	s.nodeAccountingRevision = result.revision
	s.projector = s.projector.WithNodeAccounting(result.snapshot)
	s.replaceProjectionLocked(s.projector.Project(s.resource.store.Snapshot()))
}

func (s *Subscription) replaceProjectionLocked(projected []*kmgrv1.ResourceRow) {
	clear(s.rows)
	s.order = s.order[:0]
	clear(s.pendingRemoved)
	clear(s.pendingUpserts)
	for _, row := range projected {
		uid := row.GetIdentity().GetUid()
		if uid == "" {
			continue
		}
		s.rows[uid] = row
		s.order = append(s.order, uid)
		s.pendingUpserts[uid] = row
	}
	s.orderDirty = true
	if len(s.pendingUpserts) > s.pendingLimit {
		s.resnapshot = true
		clear(s.pendingUpserts)
	}
	s.signalLocked(false)
}

// initializeRows is called only before the subscription is published in the
// runtime lifecycle graph. Keeping initialization lock-free avoids acquiring
// Subscription.mu while Runtime.mu protects that publication.
func (s *Subscription) initializeRows(rows []*kmgrv1.ResourceRow) {
	clear(s.rows)
	s.order = s.order[:0]
	for _, row := range rows {
		uid := row.GetIdentity().GetUid()
		if uid == "" {
			continue
		}
		s.rows[uid] = row
		s.order = append(s.order, uid)
	}
	clear(s.pendingUpserts)
	clear(s.pendingRemoved)
	s.resnapshot = true
	s.orderDirty = false
	s.signalLocked(true)
}

func (s *Subscription) applyBatch(batch watcher.Batch) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	batchProjector := s.projector.beginBatch()
	for _, uid := range batch.RemovedUIDs {
		key := string(uid)
		delete(s.rows, key)
		delete(s.pendingUpserts, key)
		s.pendingRemoved[key] = struct{}{}
		s.orderDirty = true
	}
	for _, object := range batch.Upserts {
		uid := string(object.GetUID())
		previous := s.rows[uid]
		row, visible := batchProjector.projectOne(object)
		if !visible {
			if previous != nil {
				delete(s.rows, uid)
				delete(s.pendingUpserts, uid)
				s.orderDirty = true
			}
			continue
		}
		delete(s.pendingRemoved, uid)
		s.rows[uid] = row
		s.pendingUpserts[uid] = row
		if previous == nil || s.projector.compareRows(previous, row) != 0 {
			s.orderDirty = true
		}
	}
	if s.orderDirty {
		s.rebuildOrderLocked()
	}
	if len(s.pendingUpserts)+len(s.pendingRemoved) > s.pendingLimit {
		s.resnapshot = true
		clear(s.pendingUpserts)
		clear(s.pendingRemoved)
	}
	if batch.SnapshotComplete {
		s.pendingStatuses = append(s.pendingStatuses, &kmgrv1.ViewStatus{
			Freshness:              kmgrv1.ViewFreshness_VIEW_FRESHNESS_WATCHING,
			ObjectsExamined:        uint64(batch.ObjectsListed),
			RowsVisible:            uint64(len(s.rows)),
			LastSynchronizedUnixMs: batch.SynchronizedAt.UnixMilli(),
		})
	}
	s.signalLocked(batch.FromList)
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

func (s *Subscription) setStatusLocked(status *kmgrv1.ViewStatus) {
	if s.closed {
		return
	}
	copy := proto.Clone(status).(*kmgrv1.ViewStatus)
	copy.RowsVisible = uint64(len(s.rows))
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
	events := make([]*kmgrv1.ViewEvent, 0, 4)
	for _, status := range s.pendingStatuses {
		events = append(events, s.statusEventLocked(status))
	}
	s.pendingStatuses = nil
	if s.resnapshot {
		if len(s.order) == 0 {
			events = append(events, s.snapshotEventLocked(&kmgrv1.SnapshotChunk{
				FirstChunk: true, LastChunk: true,
			}))
		} else {
			for start, index := 0, uint64(0); start < len(s.order); start, index = start+s.chunkSize, index+1 {
				end := min(start+s.chunkSize, len(s.order))
				rows := make([]*kmgrv1.ResourceRow, 0, end-start)
				for _, uid := range s.order[start:end] {
					rows = append(rows, s.rows[uid])
				}
				events = append(events, s.snapshotEventLocked(&kmgrv1.SnapshotChunk{
					Rows: rows, FirstChunk: start == 0, LastChunk: end == len(s.order),
					ChunkIndex: index, EstimatedTotalRows: uint64(len(s.order)),
				}))
			}
		}
		s.resnapshot = false
		s.orderDirty = false
		clear(s.pendingUpserts)
		clear(s.pendingRemoved)
	} else if len(s.pendingUpserts) != 0 || len(s.pendingRemoved) != 0 || s.orderDirty {
		upserts := make([]*kmgrv1.ResourceRow, 0, len(s.pendingUpserts))
		for _, uid := range s.order {
			if row := s.pendingUpserts[uid]; row != nil {
				upserts = append(upserts, row)
			}
		}
		removed := make([]string, 0, len(s.pendingRemoved))
		for uid := range s.pendingRemoved {
			removed = append(removed, uid)
		}
		sort.Strings(removed)
		delta := &kmgrv1.RowDelta{Upserts: upserts, RemovedUids: removed}
		if s.orderDirty {
			delta.OrderedUids = append([]string(nil), s.order...)
			delta.OrderIsComplete = true
		}
		events = append(events, s.deltaEventLocked(delta))
		clear(s.pendingUpserts)
		clear(s.pendingRemoved)
		s.orderDirty = false
	}
	if s.pendingError != nil {
		events = append(events, s.errorEventLocked(s.pendingError))
		s.pendingError = nil
	}
	return events
}

func (s *Subscription) cursorLocked() *kmgrv1.StreamCursor {
	s.sequence++
	return &kmgrv1.StreamCursor{StreamId: s.key.viewID, Generation: s.generation, Sequence: s.sequence}
}

func (s *Subscription) statusEventLocked(status *kmgrv1.ViewStatus) *kmgrv1.ViewEvent {
	return &kmgrv1.ViewEvent{Cursor: s.cursorLocked(), Payload: &kmgrv1.ViewEvent_Status{Status: status}}
}

func (s *Subscription) snapshotEventLocked(snapshot *kmgrv1.SnapshotChunk) *kmgrv1.ViewEvent {
	return &kmgrv1.ViewEvent{Cursor: s.cursorLocked(), Payload: &kmgrv1.ViewEvent_Snapshot{Snapshot: snapshot}}
}

func (s *Subscription) deltaEventLocked(delta *kmgrv1.RowDelta) *kmgrv1.ViewEvent {
	return &kmgrv1.ViewEvent{Cursor: s.cursorLocked(), Payload: &kmgrv1.ViewEvent_Delta{Delta: delta}}
}

func (s *Subscription) errorEventLocked(value *kmgrv1.StructuredError) *kmgrv1.ViewEvent {
	return &kmgrv1.ViewEvent{Cursor: s.cursorLocked(), Payload: &kmgrv1.ViewEvent_Error{Error: value}}
}

func (s *Subscription) close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	s.closed = true
	s.closeMetricsLocked()
	if s.timer != nil {
		s.timer.Stop()
		s.timer = nil
	}
	close(s.done)
}

func (s *Subscription) closeMetricsLocked() {
	if s.metricCancel != nil {
		s.metricCancel()
		s.metricCancel = nil
	}
	if s.metrics != nil {
		s.metrics.Close()
		s.metrics = nil
	}
}

func projectorFromProto(
	sessionID string,
	spec *kmgrv1.ViewSpec,
	resolver ColumnProgramResolver,
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
	if resolver != nil {
		var err error
		resolved, _, err = resolver.Resolve(
			resource.GetGroup(), resource.GetVersion(), resource.GetResource(),
			spec.GetColumnIds(), spec.GetColumnConfigurationVersion(),
		)
		if err != nil {
			return nil, err
		}
	}
	return NewProjector(ProjectionSpec{
		ClusterSessionID: sessionID,
		Resource: ResourceType{
			Group: resource.GetGroup(), Version: resource.GetVersion(), Resource: resource.GetResource(),
			Kind: resource.GetKind(), Namespaced: resource.GetNamespaced(),
		},
		NamespaceScope:   namespaceScope,
		ColumnIDs:        append([]string(nil), spec.GetColumnIds()...),
		FilterExpression: spec.GetFilterExpression(),
		Sort:             sortDescriptors,
		CELPrograms:      resolved.Programs,
		ColumnExtractors: resolved.Extractors,
	})
}

func serverNamespace(spec *kmgrv1.ViewSpec) (string, error) {
	if !spec.GetResource().GetNamespaced() {
		return "", nil
	}
	scope := spec.GetNamespaceScope()
	if scope == nil || (!scope.GetAllNamespaces() && len(scope.GetNamespaces()) == 0) {
		return "default", nil
	}
	if scope.GetAllNamespaces() || len(scope.GetNamespaces()) > 1 {
		return "", nil
	}
	if scope.GetNamespaces()[0] == "" {
		return "", errors.New("namespace must not be empty")
	}
	return scope.GetNamespaces()[0], nil
}

func statusForWarmEntry(entry *resourceRuntime) *kmgrv1.ViewStatus {
	freshness := kmgrv1.ViewFreshness_VIEW_FRESHNESS_STALE
	if entry.running {
		freshness = kmgrv1.ViewFreshness_VIEW_FRESHNESS_WATCHING
	}
	return &kmgrv1.ViewStatus{
		Freshness:              freshness,
		LastSynchronizedUnixMs: entry.lastStatus.LastSynchronized.UnixMilli(),
		FromWarmCache:          !entry.running,
		ResourceVersionHint:    entry.store.ResourceVersion(),
	}
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
	return &kmgrv1.ViewStatus{
		Freshness:              freshness,
		ObjectsExamined:        uint64(max(0, status.ObjectsListed)),
		LastSynchronizedUnixMs: status.LastSynchronized.UnixMilli(),
		FromWarmCache:          status.Stale,
		ResourceVersionHint:    status.ResourceVersion,
	}
}

func structuredViewError(operation string, err error, retryable bool) *kmgrv1.StructuredError {
	if err == nil {
		err = errors.New("unknown error")
	}
	return &kmgrv1.StructuredError{
		Category:  kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE,
		Reason:    "ViewStreamFailed",
		Message:   err.Error(),
		Retryable: retryable,
		Operation: operation,
	}
}

// Compile-time check that dynamic clients remain compatible with the narrow
// pipeline contract as client-go evolves.
var _ watcher.ListerWatcher = dynamic.ResourceInterface(nil)
var _ = types.UID("")
