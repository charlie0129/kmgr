package cluster

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"slices"
	"sort"
	"strings"
	"sync"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	utilvalidation "k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/rest"
)

const discoveryParallelism = 8

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
// snapshots remain isolated.
type discoveryResultCache struct {
	mu         sync.RWMutex
	generation uint64
	result     *ResourceDiscovery
}

func (c *discoveryResultCache) begin(refresh bool) (ResourceDiscovery, bool, uint64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if refresh {
		c.generation++
		c.result = nil
	}
	if c.result == nil {
		return ResourceDiscovery{}, false, c.generation
	}
	return cloneResourceDiscovery(*c.result), true, c.generation
}

func (c *discoveryResultCache) store(generation uint64, result ResourceDiscovery, replace bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	// A refresh that started after this request invalidates its result. Among
	// ordinary concurrent misses, retain the first complete result. A refresh
	// owns its generation and replaces any ordinary request that raced it.
	if generation != c.generation || (c.result != nil && !replace) {
		return
	}
	cloned := cloneResourceDiscovery(result)
	c.result = &cloned
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
// session using the same Kubernetes backend. refresh invalidates the cached
// value before starting a new request. Failed or canceled discoveries are not
// cached, and a request started before a refresh can never repopulate the
// invalidated generation.
func (s *Session) DiscoverResourcesCached(ctx context.Context, refresh bool) (ResourceDiscovery, error) {
	if s == nil || s.backend == nil || s.Discovery() == nil {
		return ResourceDiscovery{}, errors.New("cluster session discovery client is unavailable")
	}
	if err := ctx.Err(); err != nil {
		return ResourceDiscovery{}, err
	}
	if cached, ok, generation := s.backend.discovery.begin(refresh); ok {
		if err := ctx.Err(); err != nil {
			return ResourceDiscovery{}, err
		}
		return cached, nil
	} else {
		result, err := DiscoverResourcesWithClient(ctx, s.Discovery())
		if err != nil {
			return ResourceDiscovery{}, err
		}
		s.backend.discovery.store(generation, result, refresh)
		return cloneResourceDiscovery(result), nil
	}
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

	targets, preferred, failures, err := discoverTargets(ctx, restClient)
	if err != nil {
		return ResourceDiscovery{}, err
	}
	resourceLists, resourceFailures, successfulLists, err := fetchResourceLists(ctx, restClient, targets)
	if err != nil {
		return ResourceDiscovery{}, err
	}
	failures = append(failures, resourceFailures...)
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
				PreferredVersion: preferred[groupVersion.Group] == groupVersion.Version,
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

func discoverTargets(
	ctx context.Context,
	restClient rest.Interface,
) ([]discoveryTarget, map[string]string, []DiscoveryFailure, error) {
	preferred := map[string]string{}
	failures := make([]DiscoveryFailure, 0, 2)
	targets := make([]discoveryTarget, 0)
	seen := make(map[string]struct{})
	appendTarget := func(target discoveryTarget) {
		name := target.name()
		if _, exists := seen[name]; exists {
			return
		}
		seen[name] = struct{}{}
		targets = append(targets, target)
	}

	legacy := &metav1.APIVersions{}
	err := restClient.Get().AbsPath("/api").SetHeader("Accept", discovery.AcceptV1).Do(ctx).Into(legacy)
	switch {
	case err == nil:
		for _, version := range legacy.Versions {
			if !validDiscoveryVersion(version) {
				failures = append(failures, DiscoveryFailure{
					Target: "core/invalid-version",
					Err:    errors.New("the core discovery document contained an invalid API version"),
				})
				continue
			}
			appendTarget(discoveryTarget{version: version, path: "/api/" + version})
		}
		if slices.Contains(legacy.Versions, "v1") {
			preferred[""] = "v1"
		} else if len(legacy.Versions) != 0 {
			preferred[""] = legacy.Versions[0]
		}
	case ctx.Err() != nil:
		return nil, nil, nil, ctx.Err()
	case apierrors.IsNotFound(err):
		// Match client-go's tolerance for aggregated API servers without /api.
	default:
		failures = append(failures, DiscoveryFailure{Target: "/api", Err: err})
	}

	groups := &metav1.APIGroupList{}
	err = restClient.Get().AbsPath("/apis").SetHeader("Accept", discovery.AcceptV1).Do(ctx).Into(groups)
	switch {
	case err == nil:
		for index := range groups.Groups {
			group := &groups.Groups[index]
			if len(utilvalidation.IsDNS1123Subdomain(group.Name)) != 0 {
				failures = append(failures, DiscoveryFailure{
					Target: "apis/invalid-group",
					Err:    errors.New("the API discovery document contained an invalid group name"),
				})
				continue
			}
			if group.PreferredVersion.Version != "" {
				preferred[group.Name] = group.PreferredVersion.Version
			}
			for _, version := range group.Versions {
				parsed, parseErr := schema.ParseGroupVersion(version.GroupVersion)
				if parseErr != nil || parsed.Group != group.Name || parsed.Version != version.Version ||
					!validDiscoveryVersion(version.Version) {
					failures = append(failures, DiscoveryFailure{
						Target: group.Name + "/invalid-version",
						Err:    errors.New("the API discovery document contained an invalid group version"),
					})
					continue
				}
				appendTarget(discoveryTarget{
					group: group.Name, version: version.Version,
					path: "/apis/" + group.Name + "/" + version.Version,
				})
			}
		}
	case ctx.Err() != nil:
		return nil, nil, nil, ctx.Err()
	default:
		failures = append(failures, DiscoveryFailure{Target: "/apis", Err: err})
	}
	return targets, preferred, failures, nil
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
	if session == nil || session.Dynamic() == nil {
		return nil, errors.New("cluster session dynamic client is unavailable")
	}
	list, err := session.Dynamic().Resource(schema.GroupVersionResource{Version: "v1", Resource: "namespaces"}).List(
		ctx,
		metav1.ListOptions{},
	)
	if err != nil {
		return nil, err
	}
	namespaces := make([]string, 0, len(list.Items))
	for index := range list.Items {
		if name := list.Items[index].GetName(); name != "" {
			namespaces = append(namespaces, name)
		}
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
		_, _ = fmt.Fprintf(hash, "%s\x00%s\x00%s\x00%s\x00%t\x00%t\n",
			resource.Group, resource.Version, resource.Resource, resource.Kind,
			resource.Namespaced, resource.PreferredVersion,
		)
	}
	return "discovery_" + hex.EncodeToString(hash.Sum(nil)[:12])
}
