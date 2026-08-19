package watcher

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	rand "math/rand/v2"
	"reflect"
	"slices"
	"sync/atomic"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
	clientwatchlist "k8s.io/client-go/util/watchlist"
	"k8s.io/utils/ptr"

	"github.com/charlie0129/kmgr/backend/internal/store"
)

const (
	defaultPageSize     int64 = 500
	defaultWatchTimeout       = 5 * time.Minute
)

// ListerWatcher is the read-only portion of client-go's
// dynamic.ResourceInterface. A dynamic resource client satisfies it directly.
type ListerWatcher interface {
	List(context.Context, metav1.ListOptions) (*unstructured.UnstructuredList, error)
	Watch(context.Context, metav1.ListOptions) (watch.Interface, error)
}

// WatchListSemantics is an explicit capability opt-in. Arbitrary
// ListerWatcher implementations, especially test doubles and proxy adapters,
// are kept on the conventional LIST/WATCH path unless they advertise that
// streaming initial events preserve Kubernetes WatchList semantics.
type WatchListSemantics interface {
	SupportsWatchListSemantics() bool
}

// Phase describes whether the local store is being synchronized or is backed
// by a live watch. Callers can translate these phases directly into view
// freshness indicators.
type Phase string

const (
	PhaseListing      Phase = "listing"
	PhaseResuming     Phase = "resuming"
	PhaseWatching     Phase = "watching"
	PhaseReconnecting Phase = "reconnecting"
)

// Status is a point-in-time description of pipeline freshness. Error is set
// only on a reconnecting status and does not mean that cached rows were lost.
type Status struct {
	Phase            Phase
	Stale            bool
	ResourceVersion  string
	LastSynchronized time.Time
	RetryAttempt     int
	PagesListed      int
	ObjectsListed    int
	Error            error
}

// Batch describes changes already applied to Store. LIST pages and bounded
// WatchList initial-event chunks are delivered as one batch so downstream
// projection and IPC layers do not need a callback per object. A bookmark has
// no object changes and only advances freshness.
type Batch struct {
	Upserts          []*unstructured.Unstructured
	RemovedUIDs      []types.UID
	ResourceVersion  string
	FromList         bool
	ListPage         int
	ObjectsListed    int
	SnapshotComplete bool
	Bookmark         bool
	SynchronizedAt   time.Time
	Table            *TableData
}

// TableData is presentation metadata extracted from the same response as the
// full objects in this Batch. Cells are keyed by authoritative object UID.
type TableData struct {
	Columns  []metav1.TableColumnDefinition
	Cells    map[types.UID][]any
	Disabled bool
}

// RetryDelay returns the delay before a zero-based retry attempt. Tests can
// provide a deterministic function; production callers normally leave it nil
// to use jittered exponential backoff.
type RetryDelay func(attempt int) time.Duration

// PipelineConfig configures one compatible resource LIST/WATCH stream. The
// client must already be scoped to the desired GVR and namespace. Selectors in
// ListOptions are reused unchanged for WatchList, every LIST page, and every
// watch reconnect.
type PipelineConfig struct {
	Client                  ListerWatcher
	Store                   *store.UIDStore
	ListOptions             metav1.ListOptions
	PageSize                int64
	WatchTimeout            time.Duration
	ForceRelist             bool
	InitialLastSynchronized time.Time
	RetryDelay              RetryDelay
	OnStatus                func(Status)
	OnBatch                 func(Batch)
}

// Pipeline maintains a UIDStore without clearing it during reconnects or
// relists. A Pipeline may be run again after Run returns, but not concurrently.
type Pipeline struct {
	client            ListerWatcher
	store             *store.UIDStore
	listOptions       metav1.ListOptions
	pageSize          int64
	watchTimeout      time.Duration
	forceRelist       bool
	lastSynchronized  time.Time
	retryDelay        RetryDelay
	onStatus          func(Status)
	onBatch           func(Batch)
	tableColumns      []metav1.TableColumnDefinition
	watchListDisabled bool
	running           atomic.Bool
}

var ErrAlreadyRunning = errors.New("watcher: pipeline is already running")

func NewPipeline(config PipelineConfig) (*Pipeline, error) {
	if config.Client == nil {
		return nil, errors.New("watcher: nil LIST/WATCH client")
	}
	if config.Store == nil {
		return nil, errors.New("watcher: nil UID store")
	}
	if config.PageSize < 0 {
		return nil, errors.New("watcher: negative page size")
	}
	if config.WatchTimeout < 0 {
		return nil, errors.New("watcher: negative watch timeout")
	}

	pageSize := config.PageSize
	if pageSize == 0 {
		pageSize = config.ListOptions.Limit
	}
	if pageSize == 0 {
		pageSize = defaultPageSize
	}
	watchTimeout := config.WatchTimeout
	if watchTimeout == 0 {
		watchTimeout = defaultWatchTimeout
	}
	retryDelay := config.RetryDelay
	if retryDelay == nil {
		retryDelay = jitteredExponentialDelay
	}

	return &Pipeline{
		client:           config.Client,
		store:            config.Store,
		listOptions:      config.ListOptions,
		pageSize:         pageSize,
		watchTimeout:     watchTimeout,
		forceRelist:      config.ForceRelist,
		lastSynchronized: config.InitialLastSynchronized,
		retryDelay:       retryDelay,
		onStatus:         config.OnStatus,
		onBatch:          config.OnBatch,
	}, nil
}

// Run synchronizes until ctx is cancelled. Transient API and transport errors
// are surfaced through OnStatus and retried. Run returns ctx.Err on cancellation.
func (p *Pipeline) Run(ctx context.Context) error {
	if !p.running.CompareAndSwap(false, true) {
		return ErrAlreadyRunning
	}
	defer p.running.Store(false)

	resourceVersion := p.store.ResourceVersion()
	needsSnapshot := p.forceRelist || resourceVersion == ""
	firstWatch := !needsSnapshot
	retryAttempt := 0
	var listedPages, listedObjects int
	lastSynchronized := p.lastSynchronized
	defer func() { p.lastSynchronized = lastSynchronized }()

	for {
		if err := ctx.Err(); err != nil {
			return err
		}

		var (
			result          watchResult
			haveWatchResult bool
		)
		if needsSnapshot {
			// Progressive relist pages mutate the retained store before the final
			// reconciliation commits a new consistent snapshot. Invalidate the old
			// continuation point first so cancellation or a page error can never
			// make that mixed store look safe to resume by WATCH.
			p.store.SetResourceVersion("")
			p.emitStatus(Status{
				Phase:            PhaseListing,
				Stale:            p.store.Len() != 0,
				ResourceVersion:  p.store.ResourceVersion(),
				LastSynchronized: lastSynchronized,
				RetryAttempt:     retryAttempt,
			})
			if p.watchListEligible() {
				watchList := p.watchList(ctx)
				if ctxErr := ctx.Err(); ctxErr != nil {
					return ctxErr
				}
				if watchList.fallback {
					// A server or client that cannot complete one strict WatchList
					// snapshot is kept on the proven paginated LIST path for this
					// Pipeline's remaining lifetime, including later 410 recovery.
					p.watchListDisabled = true
				} else if watchList.synchronized {
					resourceVersion = watchList.list.resourceVersion
					listedPages = watchList.list.pages
					listedObjects = watchList.list.objects
					lastSynchronized = watchList.list.synchronizedAt
					needsSnapshot = false
					firstWatch = false
					retryAttempt = 0
					result = watchList.watch
					haveWatchResult = true
				} else {
					if isTerminalAPIError(watchList.watch.err) {
						return fmt.Errorf("stream initial resource state: %w", watchList.watch.err)
					}
					p.emitStatus(Status{
						Phase:            PhaseReconnecting,
						Stale:            p.store.Len() != 0,
						ResourceVersion:  p.store.ResourceVersion(),
						LastSynchronized: lastSynchronized,
						RetryAttempt:     retryAttempt,
						Error: fmt.Errorf(
							"stream initial resource state: %w", watchList.watch.err,
						),
					})
					if err := waitForRetry(ctx, p.retryDelay(retryAttempt)); err != nil {
						return err
					}
					retryAttempt++
					continue
				}
			}

			if !haveWatchResult {
				list, err := p.list(ctx)
				if err != nil {
					if ctxErr := ctx.Err(); ctxErr != nil {
						return ctxErr
					}
					if isTerminalAPIError(err) {
						return fmt.Errorf("list resource: %w", err)
					}
					p.emitStatus(Status{
						Phase:            PhaseReconnecting,
						Stale:            p.store.Len() != 0,
						ResourceVersion:  p.store.ResourceVersion(),
						LastSynchronized: lastSynchronized,
						RetryAttempt:     retryAttempt,
						Error:            fmt.Errorf("list resource: %w", err),
					})
					if err := waitForRetry(ctx, p.retryDelay(retryAttempt)); err != nil {
						return err
					}
					retryAttempt++
					continue
				}

				resourceVersion = list.resourceVersion
				listedPages = list.pages
				listedObjects = list.objects
				lastSynchronized = list.synchronizedAt
				needsSnapshot = false
				firstWatch = false
				retryAttempt = 0
			}
		} else if firstWatch {
			p.emitStatus(Status{
				Phase:            PhaseResuming,
				Stale:            true,
				ResourceVersion:  resourceVersion,
				LastSynchronized: lastSynchronized,
			})
			firstWatch = false
		}

		if !haveWatchResult {
			result = p.watch(ctx, resourceVersion, Status{
				Phase:            PhaseWatching,
				Stale:            false,
				ResourceVersion:  resourceVersion,
				LastSynchronized: lastSynchronized,
				PagesListed:      listedPages,
				ObjectsListed:    listedObjects,
			})
		}
		if result.lastSynchronized.After(lastSynchronized) {
			lastSynchronized = result.lastSynchronized
		}
		if ctxErr := ctx.Err(); ctxErr != nil {
			return ctxErr
		}
		resourceVersion = p.store.ResourceVersion()
		if result.expired {
			needsSnapshot = true
			retryAttempt = 0
			continue
		}
		if isTerminalAPIError(result.err) {
			return fmt.Errorf("watch resource: %w", result.err)
		}
		if result.progressed {
			retryAttempt = 0
		}
		p.emitStatus(Status{
			Phase:            PhaseReconnecting,
			Stale:            true,
			ResourceVersion:  resourceVersion,
			LastSynchronized: lastSynchronized,
			RetryAttempt:     retryAttempt,
			PagesListed:      listedPages,
			ObjectsListed:    listedObjects,
			Error:            fmt.Errorf("watch resource: %w", result.err),
		})
		if err := waitForRetry(ctx, p.retryDelay(retryAttempt)); err != nil {
			return err
		}
		retryAttempt++
	}
}

type listResult struct {
	resourceVersion string
	pages           int
	objects         int
	synchronizedAt  time.Time
}

type watchListResult struct {
	synchronized bool
	fallback     bool
	list         listResult
	watch        watchResult
}

func (p *Pipeline) watchListEligible() bool {
	if p.watchListDisabled {
		return false
	}
	// Active Table representations cannot carry WatchList's streaming
	// initial-event contract. A disabled Table client is an ordinary fallback
	// stream and may preserve that fallback's WatchList capability.
	if table, ok := p.client.(TableListerWatcher); ok && table.TableEnabled() {
		return false
	}
	capability, supported := p.client.(WatchListSemantics)
	if !supported || !capability.SupportsWatchListSemantics() {
		return false
	}
	return !clientwatchlist.DoesClientNotSupportWatchListSemantics(p.client)
}

// watchList streams a consistent initial snapshot and then keeps consuming the
// same request as the live watch. Until the annotated end bookmark arrives,
// the store's resourceVersion remains empty and stale objects are retained.
func (p *Pipeline) watchList(ctx context.Context) watchListResult {
	options := p.listOptions
	options.Watch = true
	options.AllowWatchBookmarks = true
	options.ResourceVersion = ""
	options.ResourceVersionMatch = metav1.ResourceVersionMatchNotOlderThan
	options.Continue = ""
	options.Limit = 0
	options.SendInitialEvents = ptr.To(true)
	timeoutSeconds := int64(math.Ceil(p.watchTimeout.Seconds()))
	if timeoutSeconds < 1 {
		timeoutSeconds = 1
	}
	options.TimeoutSeconds = &timeoutSeconds

	stream, err := p.client.Watch(ctx, options)
	if err != nil {
		return watchListResult{
			fallback: isWatchListFallbackError(err),
			watch: watchResult{
				err:     err,
				expired: isExpired(err),
			},
		}
	}
	if stream == nil {
		return watchListResult{
			fallback: true,
			watch:    watchResult{err: errors.New("server returned a nil WatchList stream")},
		}
	}
	defer stream.Stop()

	result := watchListResult{}
	present := make(map[types.UID]struct{})
	var pending []*unstructured.Unstructured
	pages := 0
	objects := 0

	for {
		select {
		case <-ctx.Done():
			result.watch.err = ctx.Err()
			return result
		case event, ok := <-stream.ResultChan():
			if ctxErr := ctx.Err(); ctxErr != nil {
				result.watch.err = ctxErr
				return result
			}
			if !ok {
				result.watch.err = io.EOF
				result.fallback = !result.synchronized
				return result
			}
			if event.Type == watch.Error {
				eventErr := apierrors.FromObject(event.Object)
				result.watch.err = eventErr
				result.watch.expired = isExpired(eventErr)
				if !result.synchronized {
					var status apierrors.APIStatus
					result.fallback = !errors.As(eventErr, &status) ||
						isWatchListFallbackError(eventErr)
				}
				return result
			}

			if result.synchronized {
				if err := p.applyWatchEvent(event, &result.watch); err != nil {
					result.watch.err = err
				}
				if result.watch.err != nil {
					return result
				}
				continue
			}

			switch event.Type {
			case watch.Added:
				object, objectErr := initialWatchListObject(event.Object)
				if objectErr != nil {
					result.watch.err = objectErr
					result.fallback = true
					return result
				}
				uid := object.GetUID()
				if _, duplicate := present[uid]; duplicate {
					result.watch.err = fmt.Errorf("WatchList initial events repeated UID %q", uid)
					result.fallback = true
					return result
				}
				if int64(len(pending)) == p.pageSize {
					pages++
					removed := p.applyWatchListUpserts(pending)
					p.publishWatchListBatch(
						pending, removed, "", pages, objects, false, time.Time{},
					)
					pending = nil
				}
				present[uid] = struct{}{}
				pending = append(pending, object)
				objects++

			case watch.Bookmark:
				bookmark, bookmarkErr := initialWatchListBookmark(event.Object)
				if bookmarkErr != nil {
					result.watch.err = bookmarkErr
					result.fallback = true
					return result
				}
				annotation, annotated := bookmark.GetAnnotations()[metav1.InitialEventsAnnotationKey]
				if annotated && annotation != "true" {
					result.watch.err = fmt.Errorf(
						"WatchList end bookmark annotation %q has value %q, want true",
						metav1.InitialEventsAnnotationKey, annotation,
					)
					result.fallback = true
					return result
				}
				if !annotated {
					continue
				}

				resourceVersion := bookmark.GetResourceVersion()
				synchronizedAt := time.Now()
				pages++
				removed := p.applyWatchListUpserts(pending)
				removed = append(
					removed,
					p.store.ReconcileSnapshot(present, resourceVersion)...,
				)
				p.publishWatchListBatch(
					pending, removed, resourceVersion, pages, objects, true, synchronizedAt,
				)
				pending = nil
				result.synchronized = true
				result.list = listResult{
					resourceVersion: resourceVersion,
					pages:           pages,
					objects:         objects,
					synchronizedAt:  synchronizedAt,
				}
				result.watch.progressed = true
				result.watch.lastSynchronized = synchronizedAt
				p.emitStatus(Status{
					Phase:            PhaseWatching,
					Stale:            false,
					ResourceVersion:  resourceVersion,
					LastSynchronized: synchronizedAt,
					PagesListed:      pages,
					ObjectsListed:    objects,
				})

			default:
				result.watch.err = fmt.Errorf(
					"WatchList initial stream contains unsupported %q event", event.Type,
				)
				result.fallback = true
				return result
			}
		}
	}
}

func initialWatchListObject(value any) (*unstructured.Unstructured, error) {
	object, ok := value.(*unstructured.Unstructured)
	if !ok || object == nil {
		return nil, fmt.Errorf(
			"WatchList initial event object has type %T, want *unstructured.Unstructured", value,
		)
	}
	if object.GetUID() == "" {
		return nil, errors.New("WatchList initial event object has no UID")
	}
	if object.GetResourceVersion() == "" {
		return nil, errors.New("WatchList initial event object has no resourceVersion")
	}
	return object, nil
}

func initialWatchListBookmark(value any) (*unstructured.Unstructured, error) {
	bookmark, ok := value.(*unstructured.Unstructured)
	if !ok || bookmark == nil {
		return nil, fmt.Errorf(
			"WatchList bookmark object has type %T, want *unstructured.Unstructured", value,
		)
	}
	if bookmark.GetResourceVersion() == "" {
		return nil, errors.New("WatchList bookmark has no resourceVersion")
	}
	return bookmark, nil
}

func (p *Pipeline) applyWatchListUpserts(
	objects []*unstructured.Unstructured,
) []types.UID {
	var removed []types.UID
	for _, object := range objects {
		change := p.store.Upsert(object)
		if change.ReplacedUID != "" {
			removed = append(removed, change.ReplacedUID)
		}
	}
	return removed
}

func (p *Pipeline) publishWatchListBatch(
	upserts []*unstructured.Unstructured,
	removed []types.UID,
	resourceVersion string,
	page, objects int,
	complete bool,
	synchronizedAt time.Time,
) {
	p.emitBatch(Batch{
		Upserts:          upserts,
		RemovedUIDs:      sortedUniqueUIDs(removed),
		ResourceVersion:  resourceVersion,
		FromList:         true,
		ListPage:         page,
		ObjectsListed:    objects,
		SnapshotComplete: complete,
		SynchronizedAt:   synchronizedAt,
	})
}

func isWatchListFallbackError(err error) bool {
	return apierrors.IsBadRequest(err) || apierrors.IsInvalid(err) ||
		apierrors.IsNotAcceptable(err) || apierrors.IsUnsupportedMediaType(err) ||
		apierrors.IsMethodNotSupported(err) || isExpired(err)
}

func (p *Pipeline) list(ctx context.Context) (listResult, error) {
	options := p.listOptions
	options.Watch = false
	options.AllowWatchBookmarks = false
	options.ResourceVersion = ""
	options.ResourceVersionMatch = ""
	options.Continue = ""
	options.Limit = p.pageSize
	options.SendInitialEvents = nil
	options.TimeoutSeconds = nil

	present := make(map[types.UID]struct{})
	seenContinueTokens := make(map[string]struct{})
	var snapshotResourceVersion string
	pages := 0
	objects := 0

	for {
		var (
			pageObjects         []*unstructured.Unstructured
			pageResourceVersion string
			continueToken       string
			tableData           *TableData
		)
		if tableClient, ok := p.client.(TableListerWatcher); ok {
			page, err := tableClient.ListTable(ctx, options)
			if err != nil {
				return listResult{}, err
			}
			if page == nil {
				return listResult{}, errors.New("server returned a nil list")
			}
			pageObjects = page.Objects
			pageResourceVersion = page.ResourceVersion
			continueToken = page.Continue
			if page.ServerTable {
				if len(p.tableColumns) != 0 && !reflect.DeepEqual(p.tableColumns, page.Columns) {
					return listResult{}, errors.New("Table column definitions changed between list pages")
				}
				p.tableColumns = append([]metav1.TableColumnDefinition(nil), page.Columns...)
				tableData = &TableData{Columns: p.tableColumns, Cells: page.Cells}
			} else {
				p.tableColumns = nil
				tableData = &TableData{Disabled: true}
			}
		} else {
			page, err := p.client.List(ctx, options)
			if err != nil {
				return listResult{}, err
			}
			if page == nil {
				return listResult{}, errors.New("server returned a nil list")
			}
			pageResourceVersion = page.GetResourceVersion()
			continueToken = page.GetContinue()
			pageObjects = make([]*unstructured.Unstructured, 0, len(page.Items))
			for index := range page.Items {
				pageObjects = append(pageObjects, &page.Items[index])
			}
		}
		if pageResourceVersion == "" {
			return listResult{}, errors.New("list page has no resourceVersion")
		}
		if snapshotResourceVersion == "" {
			snapshotResourceVersion = pageResourceVersion
		} else if pageResourceVersion != snapshotResourceVersion {
			return listResult{}, fmt.Errorf(
				"paginated list resourceVersion changed from %q to %q",
				snapshotResourceVersion,
				pageResourceVersion,
			)
		}

		// Validate the complete page before publishing any part of it.
		for i, object := range pageObjects {
			if object == nil || object.GetUID() == "" {
				return listResult{}, fmt.Errorf("list page item %d has no UID", i)
			}
		}

		pages++
		objects += len(pageObjects)
		upserts := make([]*unstructured.Unstructured, 0, len(pageObjects))
		removed := make([]types.UID, 0)
		for _, object := range pageObjects {
			present[object.GetUID()] = struct{}{}
			change := p.store.Upsert(object)
			if change.ReplacedUID != "" {
				removed = append(removed, change.ReplacedUID)
			}
			upserts = append(upserts, object)
		}

		complete := continueToken == ""
		var synchronizedAt time.Time
		if complete {
			removed = append(removed, p.store.ReconcileSnapshot(present, snapshotResourceVersion)...)
			removed = sortedUniqueUIDs(removed)
			synchronizedAt = time.Now()
		}
		p.emitBatch(Batch{
			Upserts:          upserts,
			RemovedUIDs:      removed,
			ResourceVersion:  snapshotResourceVersion,
			FromList:         true,
			ListPage:         pages,
			ObjectsListed:    objects,
			SnapshotComplete: complete,
			SynchronizedAt:   synchronizedAt,
			Table:            tableData,
		})
		if complete {
			return listResult{
				resourceVersion: snapshotResourceVersion,
				pages:           pages,
				objects:         objects,
				synchronizedAt:  synchronizedAt,
			}, nil
		}
		if _, duplicate := seenContinueTokens[continueToken]; duplicate {
			return listResult{}, fmt.Errorf("server repeated continue token %q", continueToken)
		}
		seenContinueTokens[continueToken] = struct{}{}
		options.Continue = continueToken
	}
}

type watchResult struct {
	err              error
	expired          bool
	progressed       bool
	lastSynchronized time.Time
}

func (p *Pipeline) watch(ctx context.Context, resourceVersion string, watching Status) watchResult {
	options := p.listOptions
	options.Watch = true
	options.AllowWatchBookmarks = true
	options.ResourceVersion = resourceVersion
	options.ResourceVersionMatch = ""
	options.Continue = ""
	options.Limit = 0
	options.SendInitialEvents = nil
	timeoutSeconds := int64(math.Ceil(p.watchTimeout.Seconds()))
	if timeoutSeconds < 1 {
		timeoutSeconds = 1
	}
	options.TimeoutSeconds = &timeoutSeconds

	var stream watch.Interface
	var err error
	if tableClient, ok := p.client.(TableListerWatcher); ok {
		stream, err = tableClient.WatchTable(ctx, options)
	} else {
		stream, err = p.client.Watch(ctx, options)
	}
	if err != nil {
		return watchResult{err: err, expired: isExpired(err)}
	}
	if stream == nil {
		return watchResult{err: errors.New("server returned a nil watch")}
	}
	defer stream.Stop()
	p.emitStatus(watching)

	result := watchResult{}
	for {
		select {
		case <-ctx.Done():
			return watchResult{err: ctx.Err(), lastSynchronized: result.lastSynchronized}
		case event, ok := <-stream.ResultChan():
			if !ok {
				result.err = io.EOF
				return result
			}
			if event.Type == watch.Error {
				err := apierrors.FromObject(event.Object)
				result.err = err
				result.expired = isExpired(err)
				return result
			}
			if err := p.applyWatchEvent(event, &result); err != nil {
				result.err = err
				result.expired = errors.Is(err, errTableSchemaChanged)
				return result
			}
		}
	}
}

func (p *Pipeline) applyWatchEvent(event watch.Event, result *watchResult) error {
	checkpoint := ""
	if wrapped, ok := event.Object.(*checkpointedWatchObject); ok {
		if wrapped == nil || wrapped.Object == nil || wrapped.Checkpoint == "" {
			return fmt.Errorf("%s event has an invalid composite checkpoint", event.Type)
		}
		event.Object = wrapped.Object
		checkpoint = wrapped.Checkpoint
	}
	if table, ok := event.Object.(*metav1.Table); ok {
		return p.applyTableWatchEvent(event.Type, table, checkpoint, result)
	}
	accessor, err := meta.Accessor(event.Object)
	if err != nil {
		return fmt.Errorf("read %s event metadata: %w", event.Type, err)
	}
	resourceVersion := accessor.GetResourceVersion()
	if resourceVersion == "" {
		return fmt.Errorf("%s event has no resourceVersion", event.Type)
	}
	storeResourceVersion := resourceVersion
	if checkpoint != "" {
		storeResourceVersion = checkpoint
	}

	synchronizedAt := time.Now()
	switch event.Type {
	case watch.Added, watch.Modified:
		object, ok := event.Object.(*unstructured.Unstructured)
		if !ok {
			return fmt.Errorf("%s event object has type %T, want *unstructured.Unstructured", event.Type, event.Object)
		}
		if object.GetUID() == "" {
			return fmt.Errorf("%s event object has no UID", event.Type)
		}
		change := p.store.Upsert(object)
		p.store.SetResourceVersion(storeResourceVersion)
		var removed []types.UID
		if change.ReplacedUID != "" {
			removed = []types.UID{change.ReplacedUID}
		}
		p.emitBatch(Batch{
			Upserts:         []*unstructured.Unstructured{object},
			RemovedUIDs:     removed,
			ResourceVersion: storeResourceVersion,
			SynchronizedAt:  synchronizedAt,
		})
	case watch.Deleted:
		uid := accessor.GetUID()
		if uid == "" {
			return errors.New("DELETED event object has no UID")
		}
		p.store.Delete(uid)
		p.store.SetResourceVersion(storeResourceVersion)
		p.emitBatch(Batch{
			RemovedUIDs:     []types.UID{uid},
			ResourceVersion: storeResourceVersion,
			SynchronizedAt:  synchronizedAt,
		})
	case watch.Bookmark:
		p.store.SetResourceVersion(storeResourceVersion)
		p.emitBatch(Batch{
			ResourceVersion: storeResourceVersion,
			Bookmark:        true,
			SynchronizedAt:  synchronizedAt,
		})
	default:
		return fmt.Errorf("unsupported watch event type %q", event.Type)
	}
	result.progressed = true
	result.lastSynchronized = synchronizedAt
	return nil
}

var errTableSchemaChanged = errors.New("Table column definitions changed")

func (p *Pipeline) applyTableWatchEvent(
	eventType watch.EventType,
	table *metav1.Table,
	checkpoint string,
	result *watchResult,
) error {
	if table == nil {
		return p.disableMalformedTable("watch event contains a nil Table")
	}
	if len(table.ColumnDefinitions) != 0 {
		if len(p.tableColumns) != 0 && !reflect.DeepEqual(p.tableColumns, table.ColumnDefinitions) {
			return errTableSchemaChanged
		}
		p.tableColumns = append([]metav1.TableColumnDefinition(nil), table.ColumnDefinitions...)
	}
	resourceVersion := table.GetResourceVersion()
	storeResourceVersion := resourceVersion
	if checkpoint != "" {
		storeResourceVersion = checkpoint
	}
	if eventType == watch.Bookmark {
		if resourceVersion == "" {
			return p.disableMalformedTable("Table BOOKMARK has no resourceVersion")
		}
		synchronizedAt := time.Now()
		p.store.SetResourceVersion(storeResourceVersion)
		p.emitBatch(Batch{
			ResourceVersion: storeResourceVersion, Bookmark: true, SynchronizedAt: synchronizedAt,
		})
		result.progressed = true
		result.lastSynchronized = synchronizedAt
		return nil
	}
	if eventType != watch.Added && eventType != watch.Modified && eventType != watch.Deleted {
		return p.disableMalformedTable(fmt.Sprintf("unsupported Table watch event type %q", eventType))
	}
	if len(table.Rows) != 1 {
		return p.disableMalformedTable(fmt.Sprintf("Table %s event has %d rows; want 1", eventType, len(table.Rows)))
	}
	row := &table.Rows[0]
	if len(row.Cells) != len(p.tableColumns) {
		return p.disableMalformedTable(fmt.Sprintf(
			"Table %s event has %d cells for %d columns",
			eventType, len(row.Cells), len(p.tableColumns),
		))
	}
	object, err := decodeTableObject(row)
	if err != nil {
		return p.disableMalformedTable(fmt.Sprintf("decode Table %s object: %v", eventType, err))
	}
	if object.GetUID() == "" {
		return p.disableMalformedTable(fmt.Sprintf("Table %s object has no UID", eventType))
	}
	if resourceVersion == "" {
		resourceVersion = object.GetResourceVersion()
	}
	if resourceVersion == "" {
		return p.disableMalformedTable(fmt.Sprintf("Table %s event has no resourceVersion", eventType))
	}
	storeResourceVersion = resourceVersion
	if checkpoint != "" {
		storeResourceVersion = checkpoint
	}
	synchronizedAt := time.Now()
	batch := Batch{
		ResourceVersion: storeResourceVersion, SynchronizedAt: synchronizedAt,
		Table: &TableData{
			Columns: append([]metav1.TableColumnDefinition(nil), p.tableColumns...),
			Cells:   map[types.UID][]any{object.GetUID(): append([]any(nil), row.Cells...)},
		},
	}
	switch eventType {
	case watch.Added, watch.Modified:
		change := p.store.Upsert(object)
		batch.Upserts = []*unstructured.Unstructured{object}
		if change.ReplacedUID != "" {
			batch.RemovedUIDs = []types.UID{change.ReplacedUID}
		}
	case watch.Deleted:
		p.store.Delete(object.GetUID())
		batch.RemovedUIDs = []types.UID{object.GetUID()}
	}
	p.store.SetResourceVersion(storeResourceVersion)
	p.emitBatch(batch)
	result.progressed = true
	result.lastSynchronized = synchronizedAt
	return nil
}

func (p *Pipeline) disableMalformedTable(message string) error {
	if tableClient, ok := p.client.(TableListerWatcher); ok {
		tableClient.DisableTable()
	}
	p.tableColumns = nil
	p.emitBatch(Batch{
		ResourceVersion: p.store.ResourceVersion(), Table: &TableData{Disabled: true},
	})
	return errors.New(message)
}

func (p *Pipeline) emitStatus(status Status) {
	if p.onStatus != nil {
		p.onStatus(status)
	}
}

func (p *Pipeline) emitBatch(batch Batch) {
	if p.onBatch != nil {
		p.onBatch(batch)
	}
}

func isExpired(err error) bool {
	return apierrors.IsGone(err) || apierrors.IsResourceExpired(err)
}

func isTerminalAPIError(err error) bool {
	return apierrors.IsBadRequest(err) || apierrors.IsInvalid(err) ||
		apierrors.IsForbidden(err) || apierrors.IsUnauthorized(err)
}

func sortedUniqueUIDs(values []types.UID) []types.UID {
	if len(values) < 2 {
		return values
	}
	slices.Sort(values)
	return slices.Compact(values)
}

func waitForRetry(ctx context.Context, delay time.Duration) error {
	if delay < 0 {
		delay = 0
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func jitteredExponentialDelay(attempt int) time.Duration {
	if attempt < 0 {
		attempt = 0
	}
	const (
		minimum = 100 * time.Millisecond
		maximum = 30 * time.Second
	)
	exponent := min(attempt, 20)
	delay := minimum * time.Duration(uint64(1)<<exponent)
	if delay > maximum {
		delay = maximum
	}
	// Keep jitter bounded so a retry never collapses to an immediate loop.
	return time.Duration(float64(delay) * (0.8 + rand.Float64()*0.4))
}
