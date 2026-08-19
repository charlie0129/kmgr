package view

import (
	"context"
	"errors"
	"fmt"
	"slices"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/watch"

	"github.com/charlie0129/kmgr/backend/internal/watcher"
)

type searchNamespaceListStream struct {
	namespace string
	client    searchLister
}

// newExactNamespaceSearchLister uses the same canonical pagination and vector
// checkpoint implementation as live views. The exact-scope threshold bounds
// each LIST round to at most eight concurrent Kubernetes requests. Search only
// consumes LIST, so child adapters deliberately reject WATCH.
func newExactNamespaceSearchLister(
	streams []searchNamespaceListStream,
) (searchLister, error) {
	if len(streams) < 2 || len(streams) > maxExactNamespaceStreams {
		return nil, fmt.Errorf(
			"exact namespace search requires 2..%d streams", maxExactNamespaceStreams,
		)
	}
	children := make([]watcher.NamespaceStream, len(streams))
	for index, stream := range streams {
		if stream.client == nil {
			return nil, fmt.Errorf(
				"exact namespace search client for %q is unavailable", stream.namespace,
			)
		}
		children[index] = watcher.NamespaceStream{
			Namespace: stream.namespace,
			Client:    searchListOnlyWatcher{searchLister: stream.client},
		}
	}
	return watcher.NewNamespaceFanIn(children)
}

type searchListOnlyWatcher struct {
	searchLister
}

func (searchListOnlyWatcher) Watch(
	context.Context,
	metav1.ListOptions,
) (watch.Interface, error) {
	return nil, errors.New("metadata search namespace stream does not support WATCH")
}

func canonicalSearchNamespaces(scope NamespaceScope) []string {
	if scope.All {
		return nil
	}
	namespaces := make([]string, 0, len(scope.Namespaces))
	seen := make(map[string]struct{}, len(scope.Namespaces))
	for _, namespace := range scope.Namespaces {
		if namespace == "" {
			continue
		}
		if _, duplicate := seen[namespace]; duplicate {
			continue
		}
		seen[namespace] = struct{}{}
		namespaces = append(namespaces, namespace)
	}
	if len(namespaces) == 0 {
		return []string{"default"}
	}
	slices.Sort(namespaces)
	return namespaces
}

func exactSearchMetadataNamespaces(resource ResourceType, scope NamespaceScope) []string {
	if !resource.Namespaced || scope.All {
		return nil
	}
	namespaces := canonicalSearchNamespaces(scope)
	if len(namespaces) < 2 || len(namespaces) > maxExactNamespaceStreams {
		return nil
	}
	return namespaces
}
