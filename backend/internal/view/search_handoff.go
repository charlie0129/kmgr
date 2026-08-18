package view

import (
	"context"
	"errors"
	"fmt"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"

	"github.com/charlie0129/kmgr/backend/internal/store"
	"github.com/charlie0129/kmgr/backend/internal/watcher"
)

// transientSearchPage is immutable once published. Search consumers receive
// it through a one-slot coalescing mailbox; views receive object changes via
// their existing bounded Subscription mailbox.
type transientSearchPage struct {
	items           []*unstructured.Unstructured
	examined        uint64
	complete        bool
	reusable        bool
	resourceVersion string
	err             error
}

type transientSearchAttachment struct {
	page      *transientSearchPage
	wake      chan struct{}
	replaying bool
}

type transientSearchList struct {
	key    searchSnapshotKey
	client watcher.ListerWatcher
	store  *store.UIDStore

	ctx    context.Context
	cancel context.CancelFunc
	done   chan struct{}
	// released closes after this coordinator no longer owns its key in
	// Runtime.transientSearchLists. A completed LIST can close done before its
	// final rows finish projection, so joiners need this second lifecycle gate
	// to avoid replacing the coordinator during that delivery window.
	released chan struct{}

	searches         map[*transientSearchAttachment]struct{}
	progress         chan struct{}
	view             *resourceRuntime
	storeBounded     bool
	joinable         bool
	terminal         bool
	examined         uint64
	reusableObserved bool
	reusablePending  int
}

func (r *Runtime) startTransientSearchList(
	callerCtx context.Context,
	key searchSnapshotKey,
	client watcher.ListerWatcher,
) (*transientSearchList, *transientSearchAttachment, error) {
	for {
		r.mu.Lock()
		if r.closed {
			r.mu.Unlock()
			return nil, nil, ErrViewClosed
		}
		if current := r.transientSearchLists[key]; current != nil {
			if current.terminal {
				released := current.released
				r.mu.Unlock()
				select {
				case <-callerCtx.Done():
					return nil, nil, callerCtx.Err()
				case <-released:
					continue
				}
			}
			if current.joinable && current.store != nil {
				attachment := &transientSearchAttachment{wake: make(chan struct{}, 1), replaying: true}
				current.searches[attachment] = struct{}{}
				// Replay the coordinator snapshot so a rapid query revision can
				// join after any page without another Kubernetes response.
				examined := current.examined
				resourceVersion := current.store.ResourceVersion()
				store := current.store
				r.mu.Unlock()
				var items []*unstructured.Unstructured
				if examined != 0 {
					items = store.Snapshot()
				}
				r.mu.Lock()
				if r.completeTransientSearchReplayLocked(
					current, attachment, items, examined, resourceVersion,
				) {
					r.mu.Unlock()
					return current, attachment, nil
				}
				r.mu.Unlock()
				select {
				case <-callerCtx.Done():
					return nil, nil, callerCtx.Err()
				case <-current.done:
					continue
				}
			}
			done := current.done
			r.mu.Unlock()
			select {
			case <-callerCtx.Done():
				return nil, nil, callerCtx.Err()
			case <-done:
				continue
			}
		}
		listCtx, cancel := context.WithCancel(context.Background())
		attachment := &transientSearchAttachment{wake: make(chan struct{}, 1)}
		transient := &transientSearchList{
			key: key, client: client, store: store.New(), ctx: listCtx, cancel: cancel,
			done: make(chan struct{}), searches: map[*transientSearchAttachment]struct{}{attachment: {}},
			released: make(chan struct{}), progress: make(chan struct{}, 1),
			storeBounded: true, joinable: true,
		}
		r.transientSearchLists[key] = transient
		go r.runTransientSearchList(transient)
		r.mu.Unlock()
		return transient, attachment, nil
	}
}

// completeTransientSearchReplayLocked installs an unlocked store snapshot only
// if its attachment still belongs to a live coordinator. Runtime.mu must be
// held. A terminal race removes the provisional attachment here so it cannot
// inflate snapshot acknowledgement or keep producer backpressure alive.
func (r *Runtime) completeTransientSearchReplayLocked(
	transient *transientSearchList,
	attachment *transientSearchAttachment,
	items []*unstructured.Unstructured,
	examined uint64,
	resourceVersion string,
) bool {
	_, attached := transient.searches[attachment]
	if !attached || transient.terminal {
		attachment.replaying = false
		r.detachTransientSearchLocked(transient, attachment)
		return false
	}
	attachment.replaying = false
	if attachment.page == nil && examined != 0 {
		attachment.page = &transientSearchPage{
			items: items, examined: examined, resourceVersion: resourceVersion,
		}
	}
	signalTransientProgress(transient.progress)
	return true
}

func (r *Runtime) waitTransientSearchPage(
	ctx context.Context,
	transient *transientSearchList,
	attachment *transientSearchAttachment,
) (*transientSearchPage, error) {
	for {
		r.mu.Lock()
		if attachment.page != nil {
			page := attachment.page
			attachment.page = nil
			signalTransientProgress(transient.progress)
			r.mu.Unlock()
			return page, nil
		}
		done := transient.done
		wake := attachment.wake
		r.mu.Unlock()
		select {
		case <-ctx.Done():
			r.detachTransientSearch(transient, attachment)
			return nil, ctx.Err()
		case <-done:
			// The terminal page is installed before done is closed. Loop once
			// more so it wins over a simultaneously-ready done signal.
		case <-wake:
		}
	}
}

func (r *Runtime) detachTransientSearch(
	transient *transientSearchList,
	attachment *transientSearchAttachment,
) {
	if transient == nil || attachment == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.detachTransientSearchLocked(transient, attachment)
}

// detachTransientSearchLocked is the single idempotent attachment-removal
// path. Runtime.mu must be held so terminal snapshot acknowledgement and
// producer backpressure advance atomically with membership removal.
func (r *Runtime) detachTransientSearchLocked(
	transient *transientSearchList,
	attachment *transientSearchAttachment,
) {
	if _, attached := transient.searches[attachment]; !attached {
		return
	}
	delete(transient.searches, attachment)
	if transient.reusablePending > 0 {
		transient.reusablePending--
	}
	attachment.page = nil
	signalTransientProgress(transient.progress)
	if transient.terminal && transient.view == nil && transient.reusablePending == 0 {
		if !transient.reusableObserved {
			if snapshot := r.searchSnapshots[transient.key]; snapshot != nil && snapshot.store == transient.store {
				r.removeSearchSnapshotLocked(transient.key, snapshot)
			}
		}
	}
	if transient.view == nil && len(transient.searches) == 0 && !transient.terminal {
		r.cancelTransientSearchListLocked(transient)
	}
}

func (r *Runtime) observeTransientSearchSnapshot(
	transient *transientSearchList,
	attachment *transientSearchAttachment,
) {
	if transient == nil || attachment == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	transient.reusableObserved = true
}

func (r *Runtime) cancelTransientSearchListLocked(transient *transientSearchList) {
	if transient == nil || transient.terminal {
		return
	}
	r.closeTransientSearchListLocked(transient, context.Canceled)
}

// closeTransientSearchListLocked publishes one terminal result and releases
// every waiter. Runtime.mu must be held. It is safe against late LIST returns
// from clients that ignore context cancellation.
func (r *Runtime) closeTransientSearchListLocked(
	transient *transientSearchList,
	err error,
) *resourceRuntime {
	if transient == nil || transient.terminal {
		if transient != nil && transient.terminal {
			r.releaseTransientSearchListLocked(transient)
		}
		return nil
	}
	transient.terminal = true
	transient.cancel()
	r.releaseTransientSearchListLocked(transient)
	view := transient.view
	if view != nil && view.transientSearchList == transient {
		view.transientSearchList = nil
		view.transientSearchUsesStore = false
		view.store.SetResourceVersion("")
	}
	for attachment := range transient.searches {
		// Preserve an already-published terminal success. Close may race after
		// final publication but before a search consumes that page.
		if attachment.page == nil || !attachment.page.complete {
			attachment.page = &transientSearchPage{err: err}
		}
		select {
		case attachment.wake <- struct{}{}:
		default:
		}
	}
	close(transient.done)
	return view
}

// releaseTransientSearchListLocked relinquishes the coordinator key and wakes
// every search waiting for final LIST delivery to finish. Runtime.mu must be
// held. Identity checking makes the operation idempotent.
func (r *Runtime) releaseTransientSearchListLocked(transient *transientSearchList) {
	if transient == nil || r.transientSearchLists[transient.key] != transient {
		return
	}
	delete(r.transientSearchLists, transient.key)
	if transient.released != nil {
		close(transient.released)
		transient.released = nil
	}
}

func signalTransientProgress(progress chan struct{}) {
	select {
	case progress <- struct{}{}:
	default:
	}
}

func (r *Runtime) runTransientSearchList(transient *transientSearchList) {
	options := metav1.ListOptions{Limit: DefaultSearchPageSize}
	seenContinueTokens := make(map[string]struct{})
	var snapshotResourceVersion string
	var examined uint64
	pageNumber := 0

	for {
		if !r.waitTransientSearchCapacity(transient) {
			return
		}
		list, err := transient.client.List(transient.ctx, options)
		if err != nil {
			r.finishTransientSearchList(transient, err)
			return
		}
		if list == nil {
			r.finishTransientSearchList(transient, errors.New("search list returned nil page"))
			return
		}
		// A compatible search may attach with a replay page while this network
		// call is in flight. Recheck its one-slot mailbox before publishing so
		// the live page cannot overwrite that replay.
		if !r.waitTransientSearchCapacity(transient) {
			return
		}
		pageResourceVersion := list.GetResourceVersion()
		if pageResourceVersion == "" {
			r.finishTransientSearchList(transient, errors.New("search list page has no resourceVersion"))
			return
		}
		if snapshotResourceVersion == "" {
			snapshotResourceVersion = pageResourceVersion
		} else if pageResourceVersion != snapshotResourceVersion {
			r.finishTransientSearchList(transient, fmt.Errorf(
				"search paginated list resourceVersion changed from %q to %q",
				snapshotResourceVersion, pageResourceVersion,
			))
			return
		}
		for index := range list.Items {
			if list.Items[index].GetUID() == "" {
				r.finishTransientSearchList(transient, fmt.Errorf("search list page item %d has no UID", index))
				return
			}
		}

		continueToken := list.GetContinue()
		complete := continueToken == ""
		if !complete {
			if _, duplicate := seenContinueTokens[continueToken]; duplicate {
				r.finishTransientSearchList(transient, fmt.Errorf("search server repeated continue token %q", continueToken))
				return
			}
			seenContinueTokens[continueToken] = struct{}{}
		}
		pageNumber++
		examined += uint64(len(list.Items))
		items := make([]*unstructured.Unstructured, 0, len(list.Items))
		for index := range list.Items {
			object := &list.Items[index]
			items = append(items, object)
		}
		if !r.publishTransientSearchPage(transient, transientSearchPage{
			items: items, examined: examined, complete: complete, resourceVersion: snapshotResourceVersion,
		}, pageNumber) {
			return
		}
		if complete {
			return
		}
		options.Continue = continueToken
	}
}

func (r *Runtime) waitTransientSearchCapacity(transient *transientSearchList) bool {
	for {
		r.mu.Lock()
		full := false
		for attachment := range transient.searches {
			if attachment.page != nil || attachment.replaying {
				full = true
				break
			}
		}
		terminal := transient.terminal
		r.mu.Unlock()
		if terminal {
			return false
		}
		if !full {
			return true
		}
		select {
		case <-transient.ctx.Done():
			return false
		case <-transient.progress:
		}
	}
}

func (r *Runtime) publishTransientSearchPage(
	transient *transientSearchList,
	page transientSearchPage,
	pageNumber int,
) bool {
	r.mu.Lock()
	for {
		if r.closed || r.transientSearchLists[transient.key] != transient || transient.terminal {
			r.mu.Unlock()
			return false
		}
		replaying := false
		for attachment := range transient.searches {
			if attachment.replaying {
				replaying = true
				break
			}
		}
		if !replaying {
			break
		}
		r.mu.Unlock()
		select {
		case <-transient.ctx.Done():
			return false
		case <-transient.progress:
		}
		r.mu.Lock()
	}
	view := transient.view
	transient.examined = page.examined
	if transient.storeBounded && transient.store != nil &&
		len(page.items) > r.searchSnapshotObjectLimit-transient.store.Len() {
		transient.storeBounded = false
		if view == nil {
			transient.joinable = false
			transient.store = nil
		}
	}
	usesStore := view != nil && view.transientSearchUsesStore
	removed := make([]types.UID, 0)
	if transient.store != nil {
		for _, object := range page.items {
			if change := transient.store.Upsert(object); change.ReplacedUID != "" {
				removed = append(removed, change.ReplacedUID)
			}
		}
	}
	if view != nil && !usesStore {
		for _, object := range page.items {
			if change := view.store.Upsert(object); change.ReplacedUID != "" {
				removed = append(removed, change.ReplacedUID)
			}
		}
	}
	if page.complete {
		now := time.Now()
		if transient.store != nil {
			// The transient store starts empty and this LIST is its sole writer,
			// so every retained object is present by construction. Advancing the
			// RV avoids an O(n) snapshot/sort/reconcile while Runtime.mu is held.
			transient.store.SetResourceVersion(page.resourceVersion)
		}
		if view != nil && !usesStore {
			view.store.SetResourceVersion(page.resourceVersion)
		}
		// Mark terminal for producers/search joiners, but retain the map entry
		// as an Open gate until the final page reaches every captured view.
		transient.terminal = true
		if view != nil {
			view.lastStatus = watcher.Status{
				Phase: watcher.PhaseResuming, Stale: true,
				ResourceVersion: page.resourceVersion, LastSynchronized: now,
			}
			page.reusable = true
		} else if transient.storeBounded && transient.store != nil {
			// No view joined while listing. Retain the completed snapshot using
			// the same bounded cache semantics as the completed-only path.
			page.reusable = r.installCompletedSearchSnapshotLocked(transient.key, transient.store, now)
		}
	}
	batch := watcher.Batch{
		Upserts: page.items, RemovedUIDs: removed, ResourceVersion: page.resourceVersion, FromList: true,
		ListPage: pageNumber, ObjectsListed: int(page.examined), SnapshotComplete: page.complete,
	}
	if page.complete {
		batch.SynchronizedAt = time.Now()
	}
	var subscriptions []*Subscription
	if view != nil {
		subscriptions = r.prepareEntryBatchLocked(view, batch)
	}
	for attachment := range transient.searches {
		copy := page
		attachment.page = &copy
		select {
		case attachment.wake <- struct{}{}:
		default:
		}
	}
	if page.complete && page.reusable {
		transient.reusablePending = len(transient.searches)
	}
	if page.complete {
		close(transient.done)
	}
	r.mu.Unlock()

	for _, subscription := range subscriptions {
		subscription.applyBatch(batch)
	}
	if page.complete {
		// Keep the transient gate set until every older LIST row has reached the
		// subscription mailboxes. WATCH startup after this point therefore cannot
		// be overtaken by a stale final-page upsert.
		r.mu.Lock()
		finalView := transient.view
		if finalView != nil && finalView.transientSearchList == transient {
			finalView.transientSearchList = nil
			finalView.transientSearchUsesStore = false
		}
		r.releaseTransientSearchListLocked(transient)
		r.mu.Unlock()
		r.finishTransientView(transient, finalView, nil)
		return false
	}
	return true
}

func (r *Runtime) installCompletedSearchSnapshotLocked(
	key searchSnapshotKey,
	snapshotStore *store.UIDStore,
	now time.Time,
) bool {
	if r.closed || snapshotStore == nil || snapshotStore.ResourceVersion() == "" ||
		snapshotStore.Len() > r.searchSnapshotObjectLimit {
		return false
	}
	if previous := r.searchSnapshots[key]; previous != nil {
		r.removeSearchSnapshotLocked(key, previous)
	}
	r.searchSnapshotSequence++
	snapshot := &completedSearchSnapshot{
		store: snapshotStore, objectCount: snapshotStore.Len(), completedAt: now,
		sequence: r.searchSnapshotSequence, expiresAt: now.Add(r.searchSnapshotTTL),
	}
	r.searchSnapshots[key] = snapshot
	r.searchSnapshotObjects += snapshot.objectCount
	snapshot.expirationTimer = time.AfterFunc(r.searchSnapshotTTL, func() {
		r.expireSearchSnapshot(key, snapshot)
	})
	for len(r.searchSnapshots) > r.searchSnapshotLimit ||
		r.searchSnapshotObjects > r.searchSnapshotObjectLimit {
		evictionKey, eviction := r.oldestSearchSnapshotLocked()
		if eviction == nil {
			break
		}
		r.removeSearchSnapshotLocked(evictionKey, eviction)
	}
	return r.searchSnapshots[key] == snapshot
}

func (r *Runtime) finishTransientSearchList(
	transient *transientSearchList,
	err error,
) {
	r.mu.Lock()
	view := r.closeTransientSearchListLocked(transient, err)
	r.mu.Unlock()
	if view != nil {
		r.finishTransientView(transient, view, err)
	}
}

func (r *Runtime) finishTransientView(
	transient *transientSearchList,
	view *resourceRuntime,
	err error,
) {
	if view == nil {
		return
	}
	r.mu.Lock()
	if r.closed || r.resources[view.key] != view || view.transientSearchList != nil ||
		len(view.subscribers) == 0 {
		if !r.closed && r.resources[view.key] == view && view.transientSearchList == nil {
			r.scheduleReleaseLocked(view)
		}
		r.mu.Unlock()
		return
	}
	var startSubscribers []*Subscription
	var startError *kmgrv1.StructuredError
	if view.state == resourceIdle {
		startSubscribers, startError = r.startResourceLocked(view)
	}
	r.mu.Unlock()
	deliverSubscriptionError(startSubscribers, startError)
}
