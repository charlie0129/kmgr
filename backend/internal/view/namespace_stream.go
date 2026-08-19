package view

import (
	"errors"
	"fmt"
	"slices"
	"strings"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"

	"github.com/charlie0129/kmgr/backend/internal/watcher"
)

const maxExactNamespaceStreams = 8

type namespaceStreamPlan struct {
	apiNamespaces   []string
	cacheNamespace  string
	metricNamespace string
	exactFanIn      bool
}

// planNamespaceStream keeps small explicit selections exact at the API server.
// Large selections intentionally share the complete all-namespaces stream and
// rely on Projector's mandatory local namespace filter.
func planNamespaceStream(spec *kmgrv1.ViewSpec) (namespaceStreamPlan, error) {
	if spec == nil || spec.GetResource() == nil {
		return namespaceStreamPlan{}, errors.New("resource is required")
	}
	if !spec.GetResource().GetNamespaced() {
		return namespaceStreamPlan{apiNamespaces: []string{""}}, nil
	}
	scope := spec.GetNamespaceScope()
	if scope == nil || (!scope.GetAllNamespaces() && len(scope.GetNamespaces()) == 0) {
		return namespaceStreamPlan{
			apiNamespaces: []string{"default"}, cacheNamespace: "default", metricNamespace: "default",
		}, nil
	}
	if scope.GetAllNamespaces() {
		return namespaceStreamPlan{apiNamespaces: []string{""}}, nil
	}

	namespaces := make([]string, 0, len(scope.GetNamespaces()))
	seen := make(map[string]struct{}, len(scope.GetNamespaces()))
	for _, namespace := range scope.GetNamespaces() {
		if namespace == "" {
			return namespaceStreamPlan{}, errors.New("namespace must not be empty")
		}
		if _, duplicate := seen[namespace]; duplicate {
			continue
		}
		seen[namespace] = struct{}{}
		namespaces = append(namespaces, namespace)
	}
	slices.Sort(namespaces)
	if len(namespaces) == 1 {
		return namespaceStreamPlan{
			apiNamespaces: namespaces, cacheNamespace: namespaces[0], metricNamespace: namespaces[0],
		}, nil
	}
	if len(namespaces) <= maxExactNamespaceStreams {
		return namespaceStreamPlan{
			apiNamespaces:  namespaces,
			cacheNamespace: exactNamespaceCacheKey(namespaces),
			exactFanIn:     true,
		}, nil
	}
	return namespaceStreamPlan{apiNamespaces: []string{""}}, nil
}

func exactNamespaceCacheKey(namespaces []string) string {
	// '@' and ',' are both invalid in Kubernetes namespace names, so this
	// canonical value cannot collide with a real single-namespace stream.
	return "@namespaces/" + strings.Join(namespaces, ",")
}

func openNamespaceStream(
	source ResourceSource,
	sessionID string,
	resource schema.GroupVersionResource,
	plan namespaceStreamPlan,
	useTable bool,
	tableObject metav1.IncludeObjectPolicy,
) (string, watcher.ListerWatcher, error) {
	if source == nil {
		return "", nil, errors.New("resource source is unavailable")
	}
	if len(plan.apiNamespaces) == 0 {
		return "", nil, errors.New("namespace stream plan is empty")
	}
	tableSource, tableAvailable := source.(TableResourceSource)
	streams := make([]watcher.NamespaceStream, len(plan.apiNamespaces))
	authorityID := ""
	for index, namespace := range plan.apiNamespaces {
		var (
			streamAuthority string
			client          watcher.ListerWatcher
			err             error
		)
		if useTable && tableAvailable {
			streamAuthority, client, err = tableSource.OpenTableResource(
				sessionID, resource, namespace, tableObject,
			)
		} else {
			streamAuthority, client, err = source.OpenResource(sessionID, resource, namespace)
		}
		if err != nil {
			return "", nil, err
		}
		if client == nil {
			return "", nil, fmt.Errorf("resource source returned a nil client for namespace %q", namespace)
		}
		if index == 0 {
			authorityID = streamAuthority
		} else if streamAuthority != authorityID {
			return "", nil, errors.New("namespace streams resolved to different cluster authorities")
		}
		streams[index] = watcher.NamespaceStream{Namespace: namespace, Client: client}
	}
	if len(streams) == 1 {
		return authorityID, streams[0].Client, nil
	}
	client, err := watcher.NewNamespaceFanIn(streams)
	if err != nil {
		return "", nil, err
	}
	return authorityID, client, nil
}
