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
	restClient := session.Discovery().RESTClient()
	if restClient == nil {
		return ResourceDiscovery{}, errors.New("cluster session discovery REST client is unavailable")
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
