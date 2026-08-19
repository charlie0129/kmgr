package metrics

import (
	"container/list"
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	metricsapi "k8s.io/metrics/pkg/apis/metrics/v1beta1"
	metricsclient "k8s.io/metrics/pkg/client/clientset/versioned/typed/metrics/v1beta1"
)

const (
	DefaultPodSampleRefreshTTL        = DefaultRefreshInterval
	DefaultPodSampleNegativeTTL       = 2 * time.Second
	DefaultPodSampleEntryLimit        = 100_000
	DefaultPodSampleLimit             = 100_000
	DefaultPodSampleMaxConcurrentGETs = 16
)

var (
	ErrPodSampleCacheClosed  = errors.New("Pod metrics sample cache is closed")
	ErrInvalidPodReference   = errors.New("invalid Pod metrics reference")
	ErrPodMetricsUIDMismatch = errors.New("PodMetrics UID does not match the base Pod UID")
)

// PodReference pins an exact Metrics API lookup to the observed base Pod.
// Namespace and name identify the GET endpoint; UID prevents a sample for a
// rapidly recreated Pod from being reused for its predecessor.
type PodReference struct {
	Namespace string
	Name      string
	UID       types.UID
}

// PodSampleCacheConfig configures one authority-owned exact PodMetrics cache.
// Client must be the authority's existing shared client so its common rate
// limiter continues to govern these GETs together with every other request.
type PodSampleCacheConfig struct {
	Client            metricsclient.MetricsV1beta1Interface
	RefreshTTL        time.Duration
	NegativeTTL       time.Duration
	EntryLimit        int
	SampleLimit       int
	MaxConcurrentGETs int

	// Now is optional and exists for deterministic TTL tests.
	Now func() time.Time
}

// PodSampleCache coalesces exact PodMetrics GETs and retains a bounded LRU of
// positive, negative, and short-lived failure results. A fixed worker pool
// bounds actual API concurrency without creating one waiting goroutine per Pod.
type PodSampleCache struct {
	client      metricsclient.MetricsV1beta1Interface
	refreshTTL  time.Duration
	negativeTTL time.Duration
	entryLimit  int
	sampleLimit int
	now         func() time.Time

	ctx    context.Context
	cancel context.CancelFunc

	mu          sync.Mutex
	workReady   *sync.Cond
	entries     map[podSampleKey]*podSampleEntry
	lru         list.List
	sampleCount int
	flights     map[podSampleKey]*podSampleFlight
	work        []podSampleKey
	closed      bool
	closeDone   chan struct{}
	workers     sync.WaitGroup
}

type podSampleKey struct {
	namespace string
	name      string
	uid       types.UID
}

type podSampleEntry struct {
	key       podSampleKey
	result    podSampleResult
	expiresAt time.Time
	element   *list.Element
}

type podSampleFlight struct {
	done     chan struct{}
	fallback *Sample
	result   podSampleResult
}

type podSampleLookup struct {
	result podSampleResult
	flight *podSampleFlight
}

type podSampleResult struct {
	sample    Sample
	hasSample bool
	state     MeasurementState
	updatedAt time.Time
	err       error
	cacheable bool
}

func NewPodSampleCache(config PodSampleCacheConfig) (*PodSampleCache, error) {
	if config.Client == nil {
		return nil, errors.New("Pod metrics sample cache requires a Metrics API client")
	}
	refreshTTL, err := positivePodCacheDuration(
		config.RefreshTTL, DefaultPodSampleRefreshTTL, "refresh TTL",
	)
	if err != nil {
		return nil, err
	}
	negativeTTL, err := positivePodCacheDuration(
		config.NegativeTTL, DefaultPodSampleNegativeTTL, "negative TTL",
	)
	if err != nil {
		return nil, err
	}
	if negativeTTL >= refreshTTL {
		return nil, errors.New("Pod metrics sample cache negative TTL must be shorter than its refresh TTL")
	}
	entryLimit, err := positivePodCacheLimit(
		config.EntryLimit, DefaultPodSampleEntryLimit, "entry limit",
	)
	if err != nil {
		return nil, err
	}
	sampleLimit, err := positivePodCacheLimit(
		config.SampleLimit, DefaultPodSampleLimit, "sample limit",
	)
	if err != nil {
		return nil, err
	}
	maxConcurrentGETs, err := positivePodCacheLimit(
		config.MaxConcurrentGETs, DefaultPodSampleMaxConcurrentGETs, "GET concurrency",
	)
	if err != nil {
		return nil, err
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	ctx, cancel := context.WithCancel(context.Background())
	cache := &PodSampleCache{
		client: config.Client, refreshTTL: refreshTTL, negativeTTL: negativeTTL,
		entryLimit: entryLimit, sampleLimit: sampleLimit, now: now,
		ctx: ctx, cancel: cancel, entries: make(map[podSampleKey]*podSampleEntry),
		flights: make(map[podSampleKey]*podSampleFlight), closeDone: make(chan struct{}),
	}
	cache.workReady = sync.NewCond(&cache.mu)
	cache.workers.Add(maxConcurrentGETs)
	for range maxConcurrentGETs {
		go cache.runWorker()
	}
	return cache, nil
}

func positivePodCacheDuration(value, fallback time.Duration, name string) (time.Duration, error) {
	if value < 0 {
		return 0, fmt.Errorf("Pod metrics sample cache %s must be positive", name)
	}
	if value == 0 {
		value = fallback
	}
	if value <= 0 {
		return 0, fmt.Errorf("Pod metrics sample cache %s must be positive", name)
	}
	return value, nil
}

func positivePodCacheLimit(value, fallback int, name string) (int, error) {
	if value < 0 {
		return 0, fmt.Errorf("Pod metrics sample cache %s must be positive", name)
	}
	if value == 0 {
		value = fallback
	}
	if value <= 0 {
		return 0, fmt.Errorf("Pod metrics sample cache %s must be positive", name)
	}
	return value, nil
}

// Resolve returns exact samples keyed by base Pod UID. Remote per-Pod failures
// are represented by Snapshot.State and Snapshot.Err so successful siblings
// remain usable. The returned error is reserved for invalid input, waiter
// cancellation, or a closed cache.
func (c *PodSampleCache) Resolve(ctx context.Context, references []PodReference) (Snapshot, error) {
	if c == nil {
		return Snapshot{}, ErrPodSampleCacheClosed
	}
	if ctx == nil {
		return Snapshot{}, errors.New("Pod metrics sample cache context must not be nil")
	}
	if err := ctx.Err(); err != nil {
		return Snapshot{}, err
	}
	if c.ctx.Err() != nil {
		return Snapshot{}, ErrPodSampleCacheClosed
	}
	references, err := canonicalPodReferences(references)
	if err != nil {
		return Snapshot{}, err
	}

	lookups := make([]podSampleLookup, len(references))
	for index, reference := range references {
		lookup, lookupErr := c.lookupOrStart(reference)
		if lookupErr != nil {
			return Snapshot{}, lookupErr
		}
		lookups[index] = lookup
	}

	results := make([]podSampleResult, len(lookups))
	for index, lookup := range lookups {
		if lookup.flight == nil {
			results[index] = lookup.result
			continue
		}
		select {
		case <-ctx.Done():
			return Snapshot{}, ctx.Err()
		case <-c.ctx.Done():
			if err := ctx.Err(); err != nil {
				return Snapshot{}, err
			}
			return Snapshot{}, ErrPodSampleCacheClosed
		case <-lookup.flight.done:
			results[index] = lookup.flight.result
		}
	}

	if err := ctx.Err(); err != nil {
		return Snapshot{}, err
	}
	return podSampleSnapshot(references, results), nil
}

func canonicalPodReferences(references []PodReference) ([]PodReference, error) {
	result := make([]PodReference, 0, len(references))
	seen := make(map[podSampleKey]struct{}, len(references))
	uidKeys := make(map[types.UID]podSampleKey, len(references))
	for _, reference := range references {
		if strings.TrimSpace(reference.Namespace) == "" ||
			strings.TrimSpace(reference.Name) == "" || reference.UID == "" {
			return nil, ErrInvalidPodReference
		}
		key := podSampleKey{
			namespace: reference.Namespace, name: reference.Name, uid: reference.UID,
		}
		if previous, found := uidKeys[reference.UID]; found && previous != key {
			return nil, fmt.Errorf("%w: one UID identifies multiple Pods", ErrInvalidPodReference)
		}
		uidKeys[reference.UID] = key
		if _, duplicate := seen[key]; duplicate {
			continue
		}
		seen[key] = struct{}{}
		result = append(result, reference)
	}
	return result, nil
}

func (c *PodSampleCache) lookupOrStart(reference PodReference) (podSampleLookup, error) {
	key := podSampleKey{
		namespace: reference.Namespace, name: reference.Name, uid: reference.UID,
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return podSampleLookup{}, ErrPodSampleCacheClosed
	}
	now := c.now()
	if entry := c.entries[key]; entry != nil {
		c.lru.MoveToFront(entry.element)
		if now.Before(entry.expiresAt) {
			return podSampleLookup{result: clonePodSampleResult(entry.result)}, nil
		}
	}
	if flight := c.flights[key]; flight != nil {
		return podSampleLookup{flight: flight}, nil
	}
	flight := &podSampleFlight{done: make(chan struct{})}
	if entry := c.entries[key]; entry != nil && entry.result.hasSample {
		fallback := cloneSample(entry.result.sample)
		flight.fallback = &fallback
	}
	c.flights[key] = flight
	c.work = append(c.work, key)
	c.workReady.Signal()
	return podSampleLookup{flight: flight}, nil
}

func (c *PodSampleCache) runWorker() {
	defer c.workers.Done()
	for {
		c.mu.Lock()
		for len(c.work) == 0 && !c.closed {
			c.workReady.Wait()
		}
		if len(c.work) == 0 && c.closed {
			c.mu.Unlock()
			return
		}
		key := c.work[0]
		c.work[0] = podSampleKey{}
		c.work = c.work[1:]
		if len(c.work) == 0 {
			c.work = nil
		}
		flight := c.flights[key]
		c.mu.Unlock()

		if flight == nil {
			continue
		}
		result := c.refresh(key, flight.fallback)
		c.completeFlight(key, flight, result)
	}
}

func (c *PodSampleCache) refresh(key podSampleKey, fallback *Sample) podSampleResult {
	if err := c.ctx.Err(); err != nil {
		return podSampleResult{state: MeasurementUnavailable, err: ErrPodSampleCacheClosed}
	}
	value, err := c.client.PodMetricses(key.namespace).Get(
		c.ctx, key.name, metav1.GetOptions{},
	)
	completedAt := c.now()
	if err == nil && value == nil {
		err = errors.New("Metrics API returned a nil PodMetrics object")
	}
	if err == nil {
		if value.UID != "" && value.UID != key.uid {
			return podSampleResult{
				state: MeasurementUnavailable, updatedAt: completedAt,
				err: ErrPodMetricsUIDMismatch, cacheable: true,
			}
		}
		return podSampleResult{
			sample: podMetricSample(value), hasSample: true,
			state: MeasurementCurrent, updatedAt: completedAt, cacheable: true,
		}
	}
	if c.ctx.Err() != nil {
		return podSampleResult{state: MeasurementUnavailable, err: ErrPodSampleCacheClosed}
	}
	if apierrors.IsNotFound(err) {
		return podSampleResult{
			state: MeasurementCurrent, updatedAt: completedAt, cacheable: true,
		}
	}
	classified := classifyMetricsError(err)
	safeErr := safeMetricsError(classified)
	if !errors.Is(classified, ErrMetricsAPIForbidden) && fallback != nil {
		return podSampleResult{
			sample: cloneSample(*fallback), hasSample: true,
			state: MeasurementStale, updatedAt: completedAt, err: safeErr, cacheable: true,
		}
	}
	return podSampleResult{
		state: MeasurementUnavailable, updatedAt: completedAt,
		err: safeErr, cacheable: true,
	}
}

func podMetricSample(value *metricsapi.PodMetrics) Sample {
	resources := make(map[string]int64)
	for _, container := range value.Containers {
		addUsage(resources, container.Usage)
	}
	return Sample{MeasuredAt: value.Timestamp.Time, Resources: resources}
}

func (c *PodSampleCache) completeFlight(
	key podSampleKey,
	flight *podSampleFlight,
	result podSampleResult,
) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.flights[key] != flight {
		return
	}
	delete(c.flights, key)
	if !c.closed && result.cacheable {
		c.putLocked(key, result)
	}
	if c.closed {
		result = podSampleResult{state: MeasurementUnavailable, err: ErrPodSampleCacheClosed}
	}
	flight.result = clonePodSampleResult(result)
	close(flight.done)
}

func (c *PodSampleCache) putLocked(key podSampleKey, result podSampleResult) {
	entry := c.entries[key]
	if entry == nil {
		entry = &podSampleEntry{key: key}
		entry.element = c.lru.PushFront(entry)
		c.entries[key] = entry
	} else {
		if entry.result.hasSample {
			c.sampleCount--
		}
		c.lru.MoveToFront(entry.element)
	}
	entry.result = clonePodSampleResult(result)
	if result.hasSample {
		c.sampleCount++
	}
	ttl := c.negativeTTL
	if result.state == MeasurementCurrent && result.hasSample && result.err == nil {
		ttl = c.refreshTTL
	}
	entry.expiresAt = result.updatedAt.Add(ttl)
	c.enforceLimitsLocked()
}

func (c *PodSampleCache) enforceLimitsLocked() {
	for len(c.entries) > c.entryLimit || c.sampleCount > c.sampleLimit {
		element := c.lru.Back()
		if element == nil {
			return
		}
		entry := element.Value.(*podSampleEntry)
		delete(c.entries, entry.key)
		c.lru.Remove(element)
		if entry.result.hasSample {
			c.sampleCount--
		}
	}
}

func podSampleSnapshot(references []PodReference, results []podSampleResult) Snapshot {
	snapshot := Snapshot{
		Samples: make(map[string]Sample, len(results)), State: MeasurementCurrent,
	}
	anyFailure := false
	anyStale := false
	for index, result := range results {
		if result.hasSample {
			snapshot.Samples[string(references[index].UID)] = cloneSample(result.sample)
		}
		if result.state == MeasurementStale {
			anyStale = true
		}
		if result.err != nil {
			anyFailure = true
			if snapshot.Err == nil {
				snapshot.Err = result.err
			}
		}
		if !result.updatedAt.IsZero() &&
			(snapshot.UpdatedAt.IsZero() || result.updatedAt.Before(snapshot.UpdatedAt)) {
			snapshot.UpdatedAt = result.updatedAt
		}
	}
	if anyStale || anyFailure && len(snapshot.Samples) != 0 {
		snapshot.State = MeasurementStale
	} else if anyFailure {
		snapshot.State = MeasurementUnavailable
	}
	return snapshot
}

func clonePodSampleResult(result podSampleResult) podSampleResult {
	if result.hasSample {
		result.sample = cloneSample(result.sample)
	}
	return result
}

func cloneSample(sample Sample) Sample {
	resources := make(map[string]int64, len(sample.Resources))
	for name, value := range sample.Resources {
		resources[name] = value
	}
	sample.Resources = resources
	return sample
}

// Close cancels in-flight GETs, wakes queued workers, and releases retained
// samples. It is idempotent.
func (c *PodSampleCache) Close() {
	if c == nil {
		return
	}
	c.mu.Lock()
	if c.closed {
		done := c.closeDone
		c.mu.Unlock()
		<-done
		return
	}
	c.closed = true
	c.cancel()
	c.workReady.Broadcast()
	c.mu.Unlock()
	c.workers.Wait()

	c.mu.Lock()
	c.client = nil
	c.entries = nil
	c.lru.Init()
	c.sampleCount = 0
	c.flights = nil
	c.work = nil
	close(c.closeDone)
	c.mu.Unlock()
}
