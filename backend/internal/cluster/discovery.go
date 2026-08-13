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

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
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

// DiscoverResources returns listable, non-subresource API resources in stable
// GVR order. Discovery is an explicit connection action and is never triggered
// merely by rendering the sidebar.
func DiscoverResources(ctx context.Context, session *Session) ([]APIResource, string, error) {
	if session == nil || session.Discovery() == nil {
		return nil, "", errors.New("cluster session discovery client is unavailable")
	}
	groups, resourceLists, err := session.Discovery().ServerGroupsAndResources()
	if err != nil && len(resourceLists) == 0 {
		return nil, "", fmt.Errorf("discover Kubernetes API resources: %w", err)
	}
	preferred := make(map[string]string, len(groups))
	for _, group := range groups {
		if group == nil {
			continue
		}
		preferred[group.Name] = group.PreferredVersion.Version
	}
	// Core/v1 is not represented as an APIGroup in every discovery response.
	preferred[""] = "v1"

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
	revision := discoveryRevision(resources)
	if err != nil {
		// client-go returns partial discovery results alongside a typed error.
		// Keep useful resources available; the caller can surface a warning on a
		// subsequent refresh if desired without blanking the sidebar.
		return resources, revision, nil
	}
	return resources, revision, nil
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
