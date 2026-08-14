package watcher

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	rand "math/rand/v2"
	"slices"
	"sync/atomic"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"

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

// Batch describes changes already applied to Store. List pages are delivered
// as one batch so downstream projection and IPC layers do not need a callback
// per object. A bookmark has no object changes and only advances freshness.
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
}

// RetryDelay returns the delay before a zero-based retry attempt. Tests can
// provide a deterministic function; production callers normally leave it nil
// to use jittered exponential backoff.
type RetryDelay func(attempt int) time.Duration

// PipelineConfig configures one compatible resource LIST/WATCH stream. The
// client must already be scoped to the desired GVR and namespace. Selectors in
// ListOptions are reused unchanged for every list page and watch reconnect.
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
	client           ListerWatcher
	store            *store.UIDStore
	listOptions      metav1.ListOptions
	pageSize         int64
	watchTimeout     time.Duration
	forceRelist      bool
	lastSynchronized time.Time
	retryDelay       RetryDelay
	onStatus         func(Status)
	onBatch          func(Batch)
	running          atomic.Bool
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
	needsList := p.forceRelist || resourceVersion == ""
	firstWatch := !needsList
	retryAttempt := 0
	var listedPages, listedObjects int
	lastSynchronized := p.lastSynchronized
	defer func() { p.lastSynchronized = lastSynchronized }()

	for {
		if err := ctx.Err(); err != nil {
			return err
		}

		if needsList {
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
			result, err := p.list(ctx)
			if err != nil {
				if ctxErr := ctx.Err(); ctxErr != nil {
					return ctxErr
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

			resourceVersion = result.resourceVersion
			listedPages = result.pages
			listedObjects = result.objects
			lastSynchronized = result.synchronizedAt
			needsList = false
			firstWatch = false
			retryAttempt = 0
		} else if firstWatch {
			p.emitStatus(Status{
				Phase:            PhaseResuming,
				Stale:            true,
				ResourceVersion:  resourceVersion,
				LastSynchronized: lastSynchronized,
			})
			firstWatch = false
		}

		result := p.watch(ctx, resourceVersion, Status{
			Phase:            PhaseWatching,
			Stale:            false,
			ResourceVersion:  resourceVersion,
			LastSynchronized: lastSynchronized,
			PagesListed:      listedPages,
			ObjectsListed:    listedObjects,
		})
		if result.lastSynchronized.After(lastSynchronized) {
			lastSynchronized = result.lastSynchronized
		}
		if ctxErr := ctx.Err(); ctxErr != nil {
			return ctxErr
		}
		resourceVersion = p.store.ResourceVersion()
		if result.expired {
			needsList = true
			retryAttempt = 0
			continue
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
		page, err := p.client.List(ctx, options)
		if err != nil {
			return listResult{}, err
		}
		if page == nil {
			return listResult{}, errors.New("server returned a nil list")
		}
		pageResourceVersion := page.GetResourceVersion()
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
		for i := range page.Items {
			if page.Items[i].GetUID() == "" {
				return listResult{}, fmt.Errorf("list page item %d has no UID", i)
			}
		}

		pages++
		objects += len(page.Items)
		upserts := make([]*unstructured.Unstructured, 0, len(page.Items))
		removed := make([]types.UID, 0)
		for i := range page.Items {
			object := &page.Items[i]
			present[object.GetUID()] = struct{}{}
			change := p.store.Upsert(object)
			if change.ReplacedUID != "" {
				removed = append(removed, change.ReplacedUID)
			}
			upserts = append(upserts, object)
		}

		continueToken := page.GetContinue()
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

	stream, err := p.client.Watch(ctx, options)
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
				return result
			}
		}
	}
}

func (p *Pipeline) applyWatchEvent(event watch.Event, result *watchResult) error {
	accessor, err := meta.Accessor(event.Object)
	if err != nil {
		return fmt.Errorf("read %s event metadata: %w", event.Type, err)
	}
	resourceVersion := accessor.GetResourceVersion()
	if resourceVersion == "" {
		return fmt.Errorf("%s event has no resourceVersion", event.Type)
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
		p.store.SetResourceVersion(resourceVersion)
		var removed []types.UID
		if change.ReplacedUID != "" {
			removed = []types.UID{change.ReplacedUID}
		}
		p.emitBatch(Batch{
			Upserts:         []*unstructured.Unstructured{object},
			RemovedUIDs:     removed,
			ResourceVersion: resourceVersion,
			SynchronizedAt:  synchronizedAt,
		})
	case watch.Deleted:
		uid := accessor.GetUID()
		if uid == "" {
			return errors.New("DELETED event object has no UID")
		}
		p.store.Delete(uid)
		p.store.SetResourceVersion(resourceVersion)
		p.emitBatch(Batch{
			RemovedUIDs:     []types.UID{uid},
			ResourceVersion: resourceVersion,
			SynchronizedAt:  synchronizedAt,
		})
	case watch.Bookmark:
		p.store.SetResourceVersion(resourceVersion)
		p.emitBatch(Batch{
			ResourceVersion: resourceVersion,
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
