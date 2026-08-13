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
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
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
	DefaultViewReleaseDelay = 3 * time.Second
	DefaultViewBatchDelay   = 35 * time.Millisecond
	DefaultSnapshotChunk    = 500
	DefaultPendingRowLimit  = 4096
	DefaultWarmViewLimit    = 24
	DefaultWarmObjectLimit  = 250_000
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
	Source            ResourceSource
	Metrics           MetricSource
	Columns           ColumnProgramResolver
	ReleaseDelay      time.Duration
	BatchDelay        time.Duration
	SnapshotChunkSize int
	PendingRowLimit   int
	WarmViewLimit     int
	WarmObjectLimit   int
	PipelinePageSize  int64
	PipelineTimeout   time.Duration
}

// ColumnProgramResolver resolves programs once per opened view. Projection
// never compiles CEL once per Kubernetes object.
type ColumnProgramResolver interface {
	Resolve(
		group, version, resource string,
		requestedIDs []string,
		expectedVersion string,
	) (map[string]*viewcolumns.Program, string, error)
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
	closed    bool
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

type resourceRuntime struct {
	key          resourceKey
	store        *store.UIDStore
	client       watcher.ListerWatcher
	subscribers  map[*Subscription]struct{}
	ctx          context.Context
	cancel       context.CancelFunc
	running      bool
	runNumber    uint64
	releaseTimer *time.Timer
	lastStatus   watcher.Status
}

type viewKey struct {
	sessionID string
	viewID    string
}

func NewRuntime(config RuntimeConfig) (*Runtime, error) {
	if config.Source == nil {
		return nil, errors.New("resource source must not be nil")
	}
	if config.ReleaseDelay < 0 || config.BatchDelay < 0 || config.PipelinePageSize < 0 || config.PipelineTimeout < 0 {
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
	return &Runtime{
		source:            config.Source,
		metrics:           config.Metrics,
		columns:           config.Columns,
		releaseDelay:      releaseDelay,
		batchDelay:        batchDelay,
		snapshotChunkSize: chunkSize,
		pendingRowLimit:   pendingLimit,
		pageSize:          config.PipelinePageSize,
		watchTimeout:      config.PipelineTimeout,
		resources:         make(map[resourceKey]*resourceRuntime),
		views:             make(map[viewKey]*Subscription),
		warm:              watcher.NewWarmCache[resourceKey, *resourceRuntime](warmViews, warmObjects),
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
	}
	entry := r.resources[key]
	if entry == nil {
		if cached, ok := r.warm.Get(key); ok {
			entry = cached.Value
		}
	}
	if entry == nil {
		entry = &resourceRuntime{
			key:         key,
			store:       store.New(),
			client:      client,
			subscribers: make(map[*Subscription]struct{}),
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
	entry.subscribers[subscription] = struct{}{}
	r.views[streamKey] = subscription

	warmRows := projector.Project(entry.store.Snapshot())
	if len(warmRows) != 0 {
		subscription.replaceAllLocked(warmRows)
		subscription.setStatusLocked(statusForWarmEntry(entry))
	} else {
		subscription.setStatusLocked(&kmgrv1.ViewStatus{Freshness: kmgrv1.ViewFreshness_VIEW_FRESHNESS_LOADING})
		subscription.replaceAllLocked(nil)
	}
	if !entry.running {
		r.startResourceLocked(entry)
	}
	r.mu.Unlock()
	// Enqueue the base projection before metrics can publish. Starting this
	// goroutine after releasing the runtime lock also keeps a very fast metrics
	// response from contending with the base LIST/WATCH setup.
	subscription.attachMetrics(metricSubscription)
	return subscription, nil
}

func (r *Runtime) startResourceLocked(entry *resourceRuntime) {
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
		for subscription := range entry.subscribers {
			subscription.setError(structuredViewError("watch resource", err, true))
		}
		return
	}
	go func() {
		err := pipeline.Run(ctx)
		r.resourceStopped(entry, runNumber, err)
	}()
}

func (r *Runtime) receiveStatus(entry *resourceRuntime, runNumber uint64, status watcher.Status) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if entry.runNumber != runNumber || !entry.running {
		return
	}
	entry.lastStatus = status
	translated := statusFromPipeline(status)
	for subscription := range entry.subscribers {
		subscription.setStatus(translated)
	}
}

func (r *Runtime) receiveBatch(entry *resourceRuntime, runNumber uint64, batch watcher.Batch) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if entry.runNumber != runNumber || !entry.running {
		return
	}
	for subscription := range entry.subscribers {
		subscription.applyBatch(batch)
	}
}

func (r *Runtime) resourceStopped(entry *resourceRuntime, runNumber uint64, err error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if entry.runNumber != runNumber {
		return
	}
	entry.running = false
	entry.cancel = nil
	entry.ctx = nil
	if len(entry.subscribers) == 0 || errors.Is(err, context.Canceled) {
		return
	}
	for subscription := range entry.subscribers {
		subscription.setError(structuredViewError("watch resource", err, true))
	}
}

// Cancel is idempotent. A stale cancellation cannot close a newer generation.
func (r *Runtime) Cancel(sessionID, viewID string, generation uint64) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	subscription := r.views[viewKey{sessionID: sessionID, viewID: viewID}]
	if subscription == nil || subscription.generation != generation {
		return false
	}
	r.detachLocked(subscription)
	return true
}

func (r *Runtime) detachLocked(subscription *Subscription) {
	if subscription == nil || subscription.closed {
		return
	}
	delete(r.views, subscription.key)
	entry := subscription.resource
	delete(entry.subscribers, subscription)
	subscription.closeLocked()
	if len(entry.subscribers) != 0 || entry.releaseTimer != nil {
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
	if r.closed || r.resources[key] != entry || len(entry.subscribers) != 0 || entry.runNumber != runNumber {
		return
	}
	entry.releaseTimer = nil
	if entry.cancel != nil {
		entry.cancel()
	}
	entry.running = false
	evicted := r.warm.Put(key, watcher.WarmEntry[*resourceRuntime]{
		Value:            entry,
		ObjectCount:      entry.store.Len(),
		ResourceVersion:  entry.store.ResourceVersion(),
		LastSynchronized: entry.lastStatus.LastSynchronized,
		Complete:         entry.store.ResourceVersion() != "",
	})
	for _, evictedKey := range evicted {
		if evictedEntry := r.resources[evictedKey]; evictedEntry != nil && len(evictedEntry.subscribers) == 0 && !evictedEntry.running {
			delete(r.resources, evictedKey)
		}
	}
}

func (r *Runtime) closeSubscription(subscription *Subscription) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if current := r.views[subscription.key]; current == subscription {
		r.detachLocked(subscription)
	}
}

func (r *Runtime) Close() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return
	}
	r.closed = true
	for _, subscription := range r.views {
		subscription.closeLocked()
	}
	clear(r.views)
	for key, entry := range r.resources {
		if entry.releaseTimer != nil {
			entry.releaseTimer.Stop()
		}
		if entry.cancel != nil {
			entry.cancel()
		}
		delete(r.resources, key)
	}
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

// Subscription is a bounded, coalescing mailbox. Slow clients retain at most
// PendingRowLimit delta rows before falling back to one newest snapshot.
type Subscription struct {
	runtime      *Runtime
	resource     *resourceRuntime
	key          viewKey
	metrics      *metrics.Subscription
	metricCancel context.CancelFunc

	mu              sync.Mutex
	generation      uint64
	sequence        uint64
	projector       *Projector
	rows            map[string]*kmgrv1.ResourceRow
	order           []string
	pendingUpserts  map[string]*kmgrv1.ResourceRow
	pendingRemoved  map[string]struct{}
	pendingStatuses []*kmgrv1.ViewStatus
	pendingError    *kmgrv1.StructuredError
	orderDirty      bool
	resnapshot      bool
	notify          chan struct{}
	done            chan struct{}
	timer           *time.Timer
	batchDelay      time.Duration
	chunkSize       int
	pendingLimit    int
	closed          bool
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
	s.metrics = subscription
	ctx, cancel := context.WithCancel(context.Background())
	s.metricCancel = cancel
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
	projected := s.projector.Project(s.resource.store.Snapshot())
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

func (s *Subscription) replaceAllLocked(rows []*kmgrv1.ResourceRow) {
	s.mu.Lock()
	defer s.mu.Unlock()
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
		row, visible := s.projector.ProjectOne(object)
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

func (s *Subscription) closeLocked() {
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
	var programs map[string]*viewcolumns.Program
	if resolver != nil {
		var err error
		programs, _, err = resolver.Resolve(
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
		CELPrograms:      programs,
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
