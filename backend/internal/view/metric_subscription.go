package view

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
)

// metricSubscription is the lifecycle seam used by a view. A single namespace
// is backed directly by metrics.Subscription; a small exact namespace set uses
// metricFanInSubscription to merge those same independently shared providers.
type metricSubscription interface {
	Updates() <-chan metrics.Snapshot
	RequestRefresh()
	Close()
}

type metricFanInSubscription struct {
	scopes   []string
	children []*metrics.Subscription
	updates  chan metrics.Snapshot
	incoming chan indexedMetricSnapshot
	refresh  chan time.Time
	now      func() time.Time

	ctx       context.Context
	cancel    context.CancelFunc
	waitGroup sync.WaitGroup
	closeOnce sync.Once
}

type indexedMetricSnapshot struct {
	index  int
	value  metrics.Snapshot
	closed bool
}

// subscribeMetricProviders consumes all leases atomically from Runtime's point
// of view. Providers themselves remain independently keyed by exact namespace,
// so a one-namespace view and an overlapping 2-8 namespace view reuse the same
// fetch loop and retained snapshot.
func subscribeMetricProviders(
	scopes []string,
	leases []*metrics.ProviderLease,
) metricSubscription {
	if len(leases) == 0 || len(scopes) != len(leases) {
		closeMetricProviderLeases(leases)
		return nil
	}
	children := make([]*metrics.Subscription, 0, len(leases))
	for _, lease := range leases {
		if lease == nil {
			closeMetricSubscriptions(children)
			closeMetricProviderLeases(leases)
			return nil
		}
		child := lease.Subscribe()
		if child == nil {
			closeMetricSubscriptions(children)
			closeMetricProviderLeases(leases)
			return nil
		}
		children = append(children, child)
	}
	if len(children) == 1 {
		return children[0]
	}
	return newMetricFanInSubscription(scopes, children)
}

func closeMetricProviderLeases(values []*metrics.ProviderLease) {
	for _, value := range values {
		if value != nil {
			value.Close()
		}
	}
}

func closeMetricSubscriptions(values []*metrics.Subscription) {
	for _, value := range values {
		if value != nil {
			value.Close()
		}
	}
}

func newMetricFanInSubscription(
	scopes []string,
	children []*metrics.Subscription,
) *metricFanInSubscription {
	ctx, cancel := context.WithCancel(context.Background())
	result := &metricFanInSubscription{
		scopes: append([]string(nil), scopes...), children: append([]*metrics.Subscription(nil), children...),
		updates: make(chan metrics.Snapshot, 1), incoming: make(chan indexedMetricSnapshot, len(children)*2),
		refresh: make(chan time.Time), now: time.Now, ctx: ctx, cancel: cancel,
	}
	result.waitGroup.Add(1)
	go result.run()
	for index, child := range result.children {
		result.waitGroup.Add(1)
		go result.receiveChild(index, child)
	}
	return result
}

func (s *metricFanInSubscription) Updates() <-chan metrics.Snapshot {
	if s == nil {
		return nil
	}
	return s.updates
}

func (s *metricFanInSubscription) RequestRefresh() {
	if s == nil {
		return
	}
	barrier := time.Now()
	if s.now != nil {
		barrier = s.now()
	}
	// The unbuffered handoff installs the aggregate barrier before any child is
	// asked to refresh. An already-running pre-barrier fetch cannot accidentally
	// satisfy this round; its provider will consume the queued refresh afterward.
	select {
	case <-s.ctx.Done():
		return
	case s.refresh <- barrier:
	}
	for _, child := range s.children {
		child.RequestRefresh()
	}
}

func (s *metricFanInSubscription) Close() {
	if s == nil {
		return
	}
	s.closeOnce.Do(func() {
		s.cancel()
		closeMetricSubscriptions(s.children)
		s.waitGroup.Wait()
	})
}

func (s *metricFanInSubscription) receiveChild(index int, child *metrics.Subscription) {
	defer s.waitGroup.Done()
	for {
		select {
		case <-s.ctx.Done():
			return
		case snapshot, open := <-child.Updates():
			update := indexedMetricSnapshot{index: index, value: snapshot, closed: !open}
			select {
			case <-s.ctx.Done():
				return
			case s.incoming <- update:
			}
			if !open {
				return
			}
		}
	}
}

func (s *metricFanInSubscription) run() {
	defer s.waitGroup.Done()
	defer close(s.updates)
	latest := make([]metrics.Snapshot, len(s.children))
	dirty := make([]bool, len(s.children))
	dirtyCount := 0
	var refreshBarrier time.Time
	for {
		select {
		case <-s.ctx.Done():
			return
		case barrier := <-s.refresh:
			if refreshBarrier.IsZero() || barrier.After(refreshBarrier) {
				refreshBarrier = barrier
			}
			clear(dirty)
			dirtyCount = 0
			if metricSnapshotsMeetBarrier(latest, refreshBarrier) {
				s.publish(mergeMetricSnapshots(s.scopes, latest))
				refreshBarrier = time.Time{}
			}
		case update := <-s.incoming:
			if update.closed || update.index < 0 || update.index >= len(latest) {
				return
			}
			latest[update.index] = update.value
			if !refreshBarrier.IsZero() {
				if metricSnapshotsMeetBarrier(latest, refreshBarrier) {
					s.publish(mergeMetricSnapshots(s.scopes, latest))
					refreshBarrier = time.Time{}
					clear(dirty)
					dirtyCount = 0
				}
				continue
			}
			if !dirty[update.index] {
				dirty[update.index] = true
				dirtyCount++
			}
			if dirtyCount != len(latest) {
				continue
			}
			s.publish(mergeMetricSnapshots(s.scopes, latest))
			clear(dirty)
			dirtyCount = 0
		}
	}
}

func metricSnapshotsMeetBarrier(values []metrics.Snapshot, barrier time.Time) bool {
	if barrier.IsZero() || len(values) == 0 {
		return false
	}
	for _, value := range values {
		if value.UpdatedAt.IsZero() || value.UpdatedAt.Before(barrier) {
			return false
		}
	}
	return true
}

func (s *metricFanInSubscription) publish(snapshot metrics.Snapshot) {
	select {
	case s.updates <- snapshot:
		return
	default:
	}
	select {
	case <-s.updates:
	default:
	}
	select {
	case s.updates <- snapshot:
	case <-s.ctx.Done():
	}
}

// mergeMetricSnapshots uses the oldest child start time as the aggregate
// barrier. A complete-coverage view can therefore commit only after every
// namespace has produced a snapshot at least as new as its requested barrier.
// Partial failures retain successful samples but mark the aggregate stale.
func mergeMetricSnapshots(scopes []string, snapshots []metrics.Snapshot) metrics.Snapshot {
	result := metrics.Snapshot{Samples: make(map[string]metrics.Sample)}
	available := 0
	allCurrent := true
	var failures []error
	for index, snapshot := range snapshots {
		if index == 0 || snapshot.UpdatedAt.Before(result.UpdatedAt) {
			result.UpdatedAt = snapshot.UpdatedAt
		}
		switch snapshot.State {
		case metrics.MeasurementCurrent:
			available++
		case metrics.MeasurementStale:
			available++
			allCurrent = false
		default:
			allCurrent = false
		}
		if snapshot.Err != nil {
			allCurrent = false
			scope := ""
			if index < len(scopes) {
				scope = scopes[index]
			}
			if scope == "" {
				failures = append(failures, snapshot.Err)
			} else {
				failures = append(failures, fmt.Errorf("namespace %q: %w", scope, snapshot.Err))
			}
		}
		for key, sample := range snapshot.Samples {
			if _, collision := result.Samples[key]; collision {
				allCurrent = false
				failures = append(failures, fmt.Errorf(
					"metric sample identity %q occurred in multiple namespace snapshots", key,
				))
				continue
			}
			resources := make(map[string]int64, len(sample.Resources))
			for name, value := range sample.Resources {
				resources[name] = value
			}
			sample.Resources = resources
			result.Samples[key] = sample
		}
	}
	result.Err = errors.Join(failures...)
	switch {
	case len(snapshots) != 0 && available == len(snapshots) && allCurrent:
		result.State = metrics.MeasurementCurrent
	case available != 0:
		result.State = metrics.MeasurementStale
	default:
		result.State = metrics.MeasurementUnavailable
	}
	return result
}
