package cluster

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"mime"
	"slices"
	"sort"
	"strings"
	"sync"

	apidiscoveryv2 "k8s.io/api/apidiscovery/v2"
	apidiscoveryv2beta1 "k8s.io/api/apidiscovery/v2beta1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sruntime "k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	utilvalidation "k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/rest"
)

const (
	discoveryParallelism  = 8
	namespaceListPageSize = int64(500)

	aggregatedDiscoveryAcceptHeader = discovery.AcceptV2 + "," + discovery.AcceptV2Beta1 + "," + discovery.AcceptV1
)

var (
	aggregatedDiscoveryV2GVK = schema.GroupVersionKind{
		Group: "apidiscovery.k8s.io", Version: "v2", Kind: "APIGroupDiscoveryList",
	}
	aggregatedDiscoveryV2Beta1GVK = schema.GroupVersionKind{
		Group: "apidiscovery.k8s.io", Version: "v2beta1", Kind: "APIGroupDiscoveryList",
	}
)

type APIResource struct {
	Group            string
	Version          string
	Resource         string
	Kind             string
	Namespaced       bool
	Verbs            []string
	ShortNames       []string
	Categories       []string
	PreferredVersion bool
}

// DiscoveryFailure identifies one discovery endpoint that did not return a
// resource list. Err is kept inside the Go helper so the transport can classify
// the failure without ever forwarding an arbitrary server response body.
type DiscoveryFailure struct {
	Target string
	Err    error
}

// ResourceDiscovery is useful even when PotentiallyIncomplete is true. The UI
// must keep Resources available and surface the corresponding warning.
type ResourceDiscovery struct {
	Resources             []APIResource
	Revision              string
	PotentiallyIncomplete bool
	Failures              []DiscoveryFailure
	// MetricsAPIAvailable reports whether discovery returned at least one
	// listable resource in metrics.k8s.io. It stays backend-internal so callers
	// can gate optional metrics traffic without changing the wire protocol.
	MetricsAPIAvailable bool
}

// discoveryResultCache belongs to one sharedBackend. It intentionally stores
// only the API catalog and redacted failure structure, never REST configs,
// response bodies, or authentication material. Sessions that share an
// authority therefore reuse discovery while independently loaded catalog
// snapshots remain isolated. An explicit refresh keeps the last successful
// snapshot readable until its replacement succeeds.
type discoveryResultCache struct {
	mu         sync.RWMutex
	generation uint64
	result     *ResourceDiscovery
	inFlight   *discoveryCacheLoad
}

type discoveryCacheLoad struct {
	generation uint64
	refresh    bool
	done       chan struct{}
	result     ResourceDiscovery
	err        error
	contextErr error
}

func (c *discoveryResultCache) resolve(
	ctx context.Context,
	refresh bool,
	load func(context.Context) (ResourceDiscovery, error),
) (ResourceDiscovery, error) {
	if load == nil {
		return ResourceDiscovery{}, errors.New("cluster discovery loader is unavailable")
	}
	if err := ctx.Err(); err != nil {
		return ResourceDiscovery{}, err
	}
	if refresh {
		for {
			c.mu.Lock()
			request := c.inFlight
			if request != nil && request.refresh && request.generation == c.generation {
				c.mu.Unlock()
				result, err := waitForDiscoveryLoad(ctx, request)
				if contextErr := ctx.Err(); contextErr != nil {
					return ResourceDiscovery{}, contextErr
				}
				if err != nil && request.contextErr != nil {
					// The leader's context ended, not this caller's. Start or
					// join a replacement refresh so cancellation remains local
					// to the caller that owned it.
					continue
				}
				return result, err
			}
			c.generation++
			request = &discoveryCacheLoad{
				generation: c.generation,
				refresh:    true,
				done:       make(chan struct{}),
			}
			c.inFlight = request
			c.mu.Unlock()
			return c.executeLoad(ctx, request, load)
		}
	}

	for {
		if err := ctx.Err(); err != nil {
			return ResourceDiscovery{}, err
		}
		c.mu.Lock()
		if c.result != nil {
			cached := c.result
			c.mu.Unlock()
			result := cloneResourceDiscovery(*cached)
			if err := ctx.Err(); err != nil {
				return ResourceDiscovery{}, err
			}
			return result, nil
		}
		request := c.inFlight
		if request == nil || request.generation != c.generation {
			request = &discoveryCacheLoad{
				generation: c.generation,
				done:       make(chan struct{}),
			}
			c.inFlight = request
			c.mu.Unlock()
			return c.executeLoad(ctx, request, load)
		}
		c.mu.Unlock()

		result, err := waitForDiscoveryLoad(ctx, request)
		if contextErr := ctx.Err(); contextErr != nil {
			return ResourceDiscovery{}, contextErr
		}
		c.mu.RLock()
		current := request.generation == c.generation
		c.mu.RUnlock()
		if !current || (err != nil && request.contextErr != nil) {
			// A refresh superseded this request, or the leader's context
			// ended while this caller remains live. Join or start the load
			// that is authoritative for the current generation.
			continue
		}
		return result, err
	}
}

func waitForDiscoveryLoad(ctx context.Context, request *discoveryCacheLoad) (ResourceDiscovery, error) {
	select {
	case <-ctx.Done():
		return ResourceDiscovery{}, ctx.Err()
	case <-request.done:
		if request.err != nil {
			return ResourceDiscovery{}, request.err
		}
		return cloneResourceDiscovery(request.result), nil
	}
}

func (c *discoveryResultCache) executeLoad(
	ctx context.Context,
	request *discoveryCacheLoad,
	load func(context.Context) (ResourceDiscovery, error),
) (ResourceDiscovery, error) {
	result, err := load(ctx)
	loadContextErr := ctx.Err()
	if err == nil || loadContextErr == nil || !errors.Is(err, loadContextErr) {
		loadContextErr = nil
	}
	if err == nil {
		result = cloneResourceDiscovery(result)
	}
	c.mu.Lock()
	request.result = result
	request.err = err
	request.contextErr = loadContextErr
	if err == nil && request.generation == c.generation {
		cached := result
		c.result = &cached
	}
	if c.inFlight == request {
		c.inFlight = nil
	}
	close(request.done)
	c.mu.Unlock()
	if err != nil {
		return ResourceDiscovery{}, err
	}
	return cloneResourceDiscovery(result), nil
}

func (c *discoveryResultCache) metricsAPIAvailability() (available, known bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.result == nil {
		return false, false
	}
	if c.result.MetricsAPIAvailable {
		return true, true
	}
	for _, failure := range c.result.Failures {
		// Failure of the aggregate group catalog can hide metrics.k8s.io
		// entirely. Failure of one of its advertised versions likewise makes
		// absence uncertain. Failures in core or unrelated API groups do not.
		if failure.Target == "/apis" || failure.Target == "metrics.k8s.io" ||
			strings.HasPrefix(failure.Target, "metrics.k8s.io/") {
			return false, false
		}
	}
	return false, true
}

func cloneResourceDiscovery(source ResourceDiscovery) ResourceDiscovery {
	result := source
	result.Resources = make([]APIResource, len(source.Resources))
	for index := range source.Resources {
		result.Resources[index] = source.Resources[index]
		result.Resources[index].Verbs = append([]string(nil), source.Resources[index].Verbs...)
		result.Resources[index].ShortNames = append([]string(nil), source.Resources[index].ShortNames...)
		result.Resources[index].Categories = append([]string(nil), source.Resources[index].Categories...)
	}
	result.Failures = make([]DiscoveryFailure, len(source.Failures))
	for index := range source.Failures {
		result.Failures[index] = DiscoveryFailure{
			Target: source.Failures[index].Target,
			Err:    redactedDiscoveryError(source.Failures[index].Err),
		}
	}
	return result
}

func redactedDiscoveryError(err error) error {
	if err == nil {
		return nil
	}
	var apiStatus apierrors.APIStatus
	if !errors.As(err, &apiStatus) {
		return errors.New("Kubernetes discovery endpoint failed")
	}
	statusValue := apiStatus.Status()
	status := statusValue.DeepCopy()
	status.Message = ""
	if status.Details != nil {
		for index := range status.Details.Causes {
			status.Details.Causes[index].Message = ""
		}
	}
	return &apierrors.StatusError{ErrStatus: *status}
}

type discoveryTarget struct {
	group   string
	version string
	path    string
}

func (t discoveryTarget) name() string {
	return schema.GroupVersion{Group: t.group, Version: t.version}.String()
}

type resourceListResult struct {
	index int
	list  *metav1.APIResourceList
	err   error
}

type discoveryCatalogPlan struct {
	fallbackTargets []discoveryTarget
	preferred       map[string]string
	resourceLists   []*metav1.APIResourceList
	failures        []DiscoveryFailure
}

type discoveryEndpointResult struct {
	preferred     map[string]string
	resourceLists map[string]*metav1.APIResourceList
	needsFallback map[string]discoveryTarget
	failures      []DiscoveryFailure
}

// DiscoverResources returns listable, non-subresource API resources in stable
// GVR order. Discovery is an explicit connection action and is never triggered
// merely by rendering the sidebar.
//
// DiscoveryInterface's convenience methods are contextless. Use its existing
// REST client directly so the exact client-go authentication, TLS, proxy, rate
// limiting, and transport wrappers remain in force while cancellation and
// deadlines propagate to every HTTP request.
func DiscoverResources(ctx context.Context, session *Session) (ResourceDiscovery, error) {
	if session == nil || session.Discovery() == nil {
		return ResourceDiscovery{}, errors.New("cluster session discovery client is unavailable")
	}
	return DiscoverResourcesWithClient(ctx, session.Discovery())
}

// DiscoverResourcesCached returns the discovery catalog shared by every
// session using the same Kubernetes backend. refresh starts or joins an
// authority-wide refresh while leaving the last successful snapshot available
// to non-refresh callers. Concurrent misses and refreshes coalesce per
// authority, while each waiter retains independent cancellation. Failed or
// canceled initial discoveries are not cached; failed refreshes leave the last
// successful snapshot intact, and a request started before a refresh can never
// repopulate the superseded generation.
func (s *Session) DiscoverResourcesCached(ctx context.Context, refresh bool) (ResourceDiscovery, error) {
	if s == nil || s.backend == nil || s.Discovery() == nil {
		return ResourceDiscovery{}, errors.New("cluster session discovery client is unavailable")
	}
	return s.backend.discovery.resolve(ctx, refresh, func(loadContext context.Context) (ResourceDiscovery, error) {
		result, err := DiscoverResourcesWithClient(loadContext, s.Discovery())
		return result, err
	})
}

// CachedMetricsAPIAvailability reports only what a prior discovery established
// and never contacts Kubernetes. known is false before discovery and when a
// partial result could have hidden metrics.k8s.io. An observed metrics resource
// is known available even if an unrelated API group failed discovery.
func (s *Session) CachedMetricsAPIAvailability() (available, known bool) {
	if s == nil || s.backend == nil {
		return false, false
	}
	return s.backend.discovery.metricsAPIAvailability()
}

// DiscoverResourcesWithClient is the context-aware discovery path for callers
// that already hold a client-go discovery client. It uses that client's REST
// transport so authentication, TLS, proxy, rate limiting, and transport
// wrappers remain identical while the caller's cancellation reaches every
// request.
func DiscoverResourcesWithClient(
	ctx context.Context,
	client discovery.DiscoveryInterface,
) (ResourceDiscovery, error) {
	if client == nil {
		return ResourceDiscovery{}, errors.New("Kubernetes discovery client is unavailable")
	}
	restClient := client.RESTClient()
	if restClient == nil {
		return ResourceDiscovery{}, errors.New("Kubernetes discovery REST client is unavailable")
	}
	if err := ctx.Err(); err != nil {
		return ResourceDiscovery{}, err
	}

	plan, err := discoverCatalog(ctx, restClient)
	if err != nil {
		return ResourceDiscovery{}, err
	}
	fallbackLists, resourceFailures, successfulFallbacks, err := fetchResourceLists(
		ctx, restClient, plan.fallbackTargets,
	)
	if err != nil {
		return ResourceDiscovery{}, err
	}
	resourceLists := append(plan.resourceLists, fallbackLists...)
	successfulLists := len(plan.resourceLists) + successfulFallbacks
	failures := append(plan.failures, resourceFailures...)
	sort.Slice(failures, func(i, j int) bool { return failures[i].Target < failures[j].Target })

	if len(failures) != 0 && successfulLists == 0 {
		causes := make([]error, 0, len(failures))
		for _, failure := range failures {
			causes = append(causes, failure.Err)
		}
		return ResourceDiscovery{}, fmt.Errorf("discover Kubernetes API resources: %w", errors.Join(causes...))
	}

	resources := make([]APIResource, 0)
	metricsAPIAvailable := false
	for _, list := range resourceLists {
		if list == nil {
			continue
		}
		groupVersion, parseErr := schema.ParseGroupVersion(list.GroupVersion)
		if parseErr != nil {
			continue
		}
		for _, resource := range list.APIResources {
			if strings.Contains(resource.Name, "/") || !slices.Contains(resource.Verbs, "list") {
				continue
			}
			if groupVersion.Group == "metrics.k8s.io" {
				metricsAPIAvailable = true
			}
			resources = append(resources, APIResource{
				Group:            groupVersion.Group,
				Version:          groupVersion.Version,
				Resource:         resource.Name,
				Kind:             resource.Kind,
				Namespaced:       resource.Namespaced,
				Verbs:            sortedUnique(resource.Verbs),
				ShortNames:       sortedUnique(resource.ShortNames),
				Categories:       sortedUnique(resource.Categories),
				PreferredVersion: plan.preferred[groupVersion.Group] == groupVersion.Version,
			})
		}
	}
	sort.Slice(resources, func(i, j int) bool {
		left, right := resources[i], resources[j]
		return strings.Join([]string{left.Group, left.Version, left.Resource}, "\x00") <
			strings.Join([]string{right.Group, right.Version, right.Resource}, "\x00")
	})
	return ResourceDiscovery{
		Resources:             resources,
		Revision:              discoveryRevision(resources),
		PotentiallyIncomplete: len(failures) != 0,
		Failures:              failures,
		MetricsAPIAvailable:   metricsAPIAvailable,
	}, nil
}

func discoverCatalog(
	ctx context.Context,
	restClient rest.Interface,
) (discoveryCatalogPlan, error) {
	plan := discoveryCatalogPlan{preferred: make(map[string]string)}
	resourceLists := make(map[string]*metav1.APIResourceList)
	fallbackTargets := make(map[string]discoveryTarget)
	merge := func(result discoveryEndpointResult) {
		plan.failures = append(plan.failures, result.failures...)
		for group, version := range result.preferred {
			if _, exists := plan.preferred[group]; !exists {
				plan.preferred[group] = version
			}
		}
		for name, list := range result.resourceLists {
			if list != nil {
				resourceLists[name] = list
				delete(fallbackTargets, name)
			}
		}
		for name, target := range result.needsFallback {
			if resourceLists[name] == nil {
				fallbackTargets[name] = target
			}
		}
	}

	core, err := fetchDiscoveryEndpoint(ctx, restClient, "/api")
	switch {
	case err == nil:
		merge(core)
	case ctx.Err() != nil:
		return discoveryCatalogPlan{}, ctx.Err()
	case apierrors.IsNotFound(err):
		// Match client-go's tolerance for aggregated API servers without /api.
	default:
		plan.failures = append(plan.failures, DiscoveryFailure{Target: "/api", Err: err})
	}

	apis, err := fetchDiscoveryEndpoint(ctx, restClient, "/apis")
	switch {
	case err == nil:
		merge(apis)
	case ctx.Err() != nil:
		return discoveryCatalogPlan{}, ctx.Err()
	default:
		plan.failures = append(plan.failures, DiscoveryFailure{Target: "/apis", Err: err})
	}

	listNames := make([]string, 0, len(resourceLists))
	for name := range resourceLists {
		listNames = append(listNames, name)
	}
	sort.Strings(listNames)
	for _, name := range listNames {
		plan.resourceLists = append(plan.resourceLists, resourceLists[name])
	}
	targetNames := make([]string, 0, len(fallbackTargets))
	for name := range fallbackTargets {
		targetNames = append(targetNames, name)
	}
	sort.Strings(targetNames)
	for _, name := range targetNames {
		plan.fallbackTargets = append(plan.fallbackTargets, fallbackTargets[name])
	}
	return plan, nil
}

func fetchDiscoveryEndpoint(
	ctx context.Context,
	restClient rest.Interface,
	path string,
) (discoveryEndpointResult, error) {
	var contentType string
	body, err := restClient.Get().
		AbsPath(path).
		SetHeader("Accept", aggregatedDiscoveryAcceptHeader).
		Do(ctx).
		ContentType(&contentType).
		Raw()
	if err != nil {
		return discoveryEndpointResult{}, err
	}
	mediaType, _, err := mime.ParseMediaType(contentType)
	if err != nil {
		return discoveryEndpointResult{}, fmt.Errorf("parse discovery content type from %s: %w", path, err)
	}
	if mediaType != k8sruntime.ContentTypeJSON {
		return discoveryEndpointResult{}, fmt.Errorf(
			"unsupported discovery content type %q from %s", mediaType, path,
		)
	}
	if matchesDiscoveryContentType(contentType, aggregatedDiscoveryV2GVK) {
		if err := requireDiscoveryJSONField(body, "items", path); err != nil {
			return discoveryEndpointResult{}, err
		}
		var value apidiscoveryv2.APIGroupDiscoveryList
		if err := json.Unmarshal(body, &value); err != nil {
			return discoveryEndpointResult{}, fmt.Errorf("decode aggregated discovery v2 from %s: %w", path, err)
		}
		_, lists, stale := discovery.SplitGroupsAndResources(value)
		return aggregatedDiscoveryEndpointV2(value, lists, stale), nil
	}
	if matchesDiscoveryContentType(contentType, aggregatedDiscoveryV2Beta1GVK) {
		if err := requireDiscoveryJSONField(body, "items", path); err != nil {
			return discoveryEndpointResult{}, err
		}
		var value apidiscoveryv2beta1.APIGroupDiscoveryList
		if err := json.Unmarshal(body, &value); err != nil {
			return discoveryEndpointResult{}, fmt.Errorf("decode aggregated discovery v2beta1 from %s: %w", path, err)
		}
		_, lists, stale := discovery.SplitGroupsAndResourcesV2Beta1(value)
		return aggregatedDiscoveryEndpointV2Beta1(value, lists, stale), nil
	}
	return legacyDiscoveryEndpoint(path, body)
}

func matchesDiscoveryContentType(contentType string, gvk schema.GroupVersionKind) bool {
	matches, err := discovery.ContentTypeIsGVK(contentType, gvk)
	return err == nil && matches
}

func aggregatedDiscoveryEndpointV2(
	value apidiscoveryv2.APIGroupDiscoveryList,
	lists map[schema.GroupVersion]*metav1.APIResourceList,
	stale map[schema.GroupVersion]error,
) discoveryEndpointResult {
	groups := make([]aggregatedDiscoveryGroup, 0, len(value.Items))
	for _, group := range value.Items {
		versions := make([]string, 0, len(group.Versions))
		for _, version := range group.Versions {
			versions = append(versions, version.Version)
		}
		groups = append(groups, aggregatedDiscoveryGroup{name: group.Name, versions: versions})
	}
	return aggregatedDiscoveryEndpoint(groups, lists, stale)
}

func aggregatedDiscoveryEndpointV2Beta1(
	value apidiscoveryv2beta1.APIGroupDiscoveryList,
	lists map[schema.GroupVersion]*metav1.APIResourceList,
	stale map[schema.GroupVersion]error,
) discoveryEndpointResult {
	groups := make([]aggregatedDiscoveryGroup, 0, len(value.Items))
	for _, group := range value.Items {
		versions := make([]string, 0, len(group.Versions))
		for _, version := range group.Versions {
			versions = append(versions, version.Version)
		}
		groups = append(groups, aggregatedDiscoveryGroup{name: group.Name, versions: versions})
	}
	return aggregatedDiscoveryEndpoint(groups, lists, stale)
}

type aggregatedDiscoveryGroup struct {
	name     string
	versions []string
}

func aggregatedDiscoveryEndpoint(
	groups []aggregatedDiscoveryGroup,
	lists map[schema.GroupVersion]*metav1.APIResourceList,
	stale map[schema.GroupVersion]error,
) discoveryEndpointResult {
	result := discoveryEndpointResult{
		preferred: make(map[string]string), resourceLists: make(map[string]*metav1.APIResourceList),
		needsFallback: make(map[string]discoveryTarget),
	}
	seen := make(map[string]struct{})
	for _, group := range groups {
		if group.name != "" && len(utilvalidation.IsDNS1123Subdomain(group.name)) != 0 {
			result.failures = append(result.failures, DiscoveryFailure{
				Target: "apis/invalid-group",
				Err:    errors.New("the API discovery document contained an invalid group name"),
			})
			continue
		}
		for _, version := range group.versions {
			if !validDiscoveryVersion(version) {
				result.failures = append(result.failures, invalidDiscoveryVersionFailure(group.name))
				continue
			}
			target := discoveryTargetFor(group.name, version)
			name := target.name()
			if _, duplicate := seen[name]; duplicate {
				continue
			}
			seen[name] = struct{}{}
			if _, preferred := result.preferred[group.name]; !preferred {
				// Aggregated versions are ordered by server preference. Preserve
				// that declared preference even while its stale representation is
				// being refreshed; a failed fallback must not relabel a different
				// API version as the server's preferred version.
				result.preferred[group.name] = version
			}
			gv := schema.GroupVersion{Group: group.name, Version: version}
			if _, isStale := stale[gv]; isStale {
				result.needsFallback[name] = target
				continue
			}
			if list := lists[gv]; list != nil {
				result.resourceLists[name] = list
			} else {
				result.needsFallback[name] = target
			}
		}
	}
	return result
}

func legacyDiscoveryEndpoint(path string, body []byte) (discoveryEndpointResult, error) {
	if path == "/api" {
		if err := requireDiscoveryJSONField(body, "versions", path); err != nil {
			return discoveryEndpointResult{}, err
		}
		var versions metav1.APIVersions
		if err := json.Unmarshal(body, &versions); err != nil {
			return discoveryEndpointResult{}, fmt.Errorf("decode legacy discovery from /api: %w", err)
		}
		result := discoveryEndpointResult{
			preferred: make(map[string]string), resourceLists: make(map[string]*metav1.APIResourceList),
			needsFallback: make(map[string]discoveryTarget),
		}
		firstValidVersion := ""
		for _, version := range versions.Versions {
			if !validDiscoveryVersion(version) {
				result.failures = append(result.failures, invalidDiscoveryVersionFailure(""))
				continue
			}
			target := discoveryTargetFor("", version)
			if firstValidVersion == "" {
				firstValidVersion = version
			}
			result.needsFallback[target.name()] = target
		}
		if slices.Contains(versions.Versions, "v1") {
			result.preferred[""] = "v1"
		} else if firstValidVersion != "" {
			result.preferred[""] = firstValidVersion
		}
		return result, nil
	}

	if err := requireDiscoveryJSONField(body, "groups", path); err != nil {
		return discoveryEndpointResult{}, err
	}
	var groups metav1.APIGroupList
	if err := json.Unmarshal(body, &groups); err != nil {
		return discoveryEndpointResult{}, fmt.Errorf("decode legacy discovery from /apis: %w", err)
	}
	result := discoveryEndpointResult{
		preferred: make(map[string]string), resourceLists: make(map[string]*metav1.APIResourceList),
		needsFallback: make(map[string]discoveryTarget),
	}
	seen := make(map[string]struct{})
	for index := range groups.Groups {
		group := &groups.Groups[index]
		if len(utilvalidation.IsDNS1123Subdomain(group.Name)) != 0 {
			result.failures = append(result.failures, DiscoveryFailure{
				Target: "apis/invalid-group",
				Err:    errors.New("the API discovery document contained an invalid group name"),
			})
			continue
		}
		if group.PreferredVersion.Version != "" {
			result.preferred[group.Name] = group.PreferredVersion.Version
		}
		for _, version := range group.Versions {
			parsed, parseErr := schema.ParseGroupVersion(version.GroupVersion)
			if parseErr != nil || parsed.Group != group.Name || parsed.Version != version.Version ||
				!validDiscoveryVersion(version.Version) {
				result.failures = append(result.failures, invalidDiscoveryVersionFailure(group.Name))
				continue
			}
			target := discoveryTargetFor(group.Name, version.Version)
			if _, duplicate := seen[target.name()]; duplicate {
				continue
			}
			seen[target.name()] = struct{}{}
			result.needsFallback[target.name()] = target
		}
	}
	return result, nil
}

func requireDiscoveryJSONField(body []byte, field, path string) error {
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(body, &envelope); err != nil {
		return fmt.Errorf("decode discovery document from %s: %w", path, err)
	}
	if _, exists := envelope[field]; !exists {
		return fmt.Errorf("discovery document from %s is missing %q", path, field)
	}
	return nil
}

func invalidDiscoveryVersionFailure(group string) DiscoveryFailure {
	if group == "" {
		return DiscoveryFailure{
			Target: "core/invalid-version",
			Err:    errors.New("the core discovery document contained an invalid API version"),
		}
	}
	return DiscoveryFailure{
		Target: group + "/invalid-version",
		Err:    errors.New("the API discovery document contained an invalid group version"),
	}
}

func discoveryTargetFor(group, version string) discoveryTarget {
	if group == "" {
		return discoveryTarget{version: version, path: "/api/" + version}
	}
	return discoveryTarget{
		group: group, version: version, path: "/apis/" + group + "/" + version,
	}
}

func fetchResourceLists(
	ctx context.Context,
	restClient rest.Interface,
	targets []discoveryTarget,
) ([]*metav1.APIResourceList, []DiscoveryFailure, int, error) {
	if len(targets) == 0 {
		return nil, nil, 0, nil
	}
	jobs := make(chan int, len(targets))
	results := make(chan resourceListResult, len(targets))
	for index := range targets {
		jobs <- index
	}
	close(jobs)

	workers := min(discoveryParallelism, len(targets))
	var workerGroup sync.WaitGroup
	workerGroup.Add(workers)
	for range workers {
		go func() {
			defer workerGroup.Done()
			for index := range jobs {
				target := targets[index]
				list := &metav1.APIResourceList{GroupVersion: target.name()}
				err := restClient.Get().AbsPath(target.path).SetHeader("Accept", discovery.AcceptV1).Do(ctx).Into(list)
				if err != nil && target.group == "" && target.version == "v1" && apierrors.IsNotFound(err) {
					err = nil
				}
				results <- resourceListResult{index: index, list: list, err: err}
			}
		}()
	}

	lists := make([]*metav1.APIResourceList, len(targets))
	failures := make([]DiscoveryFailure, 0)
	successful := 0
	for range targets {
		select {
		case <-ctx.Done():
			return nil, nil, 0, ctx.Err()
		case result := <-results:
			if result.err != nil {
				failures = append(failures, DiscoveryFailure{
					Target: targets[result.index].name(), Err: result.err,
				})
				continue
			}
			successful++
			lists[result.index] = result.list
		}
	}
	workerGroup.Wait()
	if err := ctx.Err(); err != nil {
		return nil, nil, 0, err
	}
	return lists, failures, successful, nil
}

func validDiscoveryVersion(value string) bool {
	return len(utilvalidation.IsDNS1035Label(value)) == 0
}

func ListNamespaces(ctx context.Context, session *Session) ([]string, error) {
	if session == nil || session.backend == nil || session.Metadata() == nil {
		return nil, errors.New("cluster session metadata client is unavailable")
	}
	resource := session.Metadata().Resource(schema.GroupVersionResource{Version: "v1", Resource: "namespaces"})
	options := metav1.ListOptions{Limit: namespaceListPageSize}
	seenContinueTokens := make(map[string]struct{})
	namespaces := make([]string, 0)
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		list, err := resource.List(ctx, options)
		if err != nil {
			return nil, err
		}
		for index := range list.Items {
			if name := list.Items[index].GetName(); name != "" {
				namespaces = append(namespaces, name)
			}
		}
		next := list.GetContinue()
		if next == "" {
			break
		}
		if _, duplicate := seenContinueTokens[next]; duplicate {
			return nil, errors.New("namespace pagination returned a repeated continuation token")
		}
		seenContinueTokens[next] = struct{}{}
		options.Continue = next
	}
	sort.Strings(namespaces)
	return slices.Compact(namespaces), nil
}

func sortedUnique(values []string) []string {
	result := append([]string(nil), values...)
	sort.Strings(result)
	return slices.Compact(result)
}

func discoveryRevision(resources []APIResource) string {
	hash := sha256.New()
	for _, resource := range resources {
		_, _ = fmt.Fprintf(hash, "%s\x00%s\x00%s\x00%s\x00%t\x00%t\x00%s\x01%s\x01%s\n",
			resource.Group, resource.Version, resource.Resource, resource.Kind,
			resource.Namespaced, resource.PreferredVersion,
			strings.Join(resource.Verbs, "\x00"),
			strings.Join(resource.ShortNames, "\x00"),
			strings.Join(resource.Categories, "\x00"),
		)
	}
	return "discovery_" + hex.EncodeToString(hash.Sum(nil)[:12])
}
