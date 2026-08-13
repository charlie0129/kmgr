package view

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

const (
	DefaultSearchResultLimit = 100
	MaximumSearchResultLimit = 500
	DefaultSearchPageSize    = 500
)

type SearchQuery struct {
	SessionID          string
	Resource           ResourceType
	NamespaceScope     NamespaceScope
	Query              string
	ResultLimit        int
	AllowPaginatedList bool
}

type SearchBatch struct {
	Results       []*kmgrv1.SearchResult
	Examined      uint64
	Complete      bool
	UsedDirectGet bool
	Reusable      bool
}

// Search uses compatible active/warm stores without waking a stopped watcher.
// For unloaded partial queries it optionally performs cancellable paginated
// LISTs but deliberately never starts a WATCH.
func (r *Runtime) Search(
	ctx context.Context,
	query SearchQuery,
	emit func(SearchBatch) error,
) error {
	if query.SessionID == "" || query.Resource.Version == "" || query.Resource.Resource == "" {
		return fmt.Errorf("%w: search session and resource are required", ErrInvalidView)
	}
	if emit == nil {
		return errors.New("search emitter must not be nil")
	}
	query.Query = strings.TrimSpace(query.Query)
	if query.Query == "" {
		return fmt.Errorf("%w: search query must not be empty", ErrInvalidView)
	}
	limit := query.ResultLimit
	if limit == 0 {
		limit = DefaultSearchResultLimit
	}
	if limit < 1 || limit > MaximumSearchResultLimit {
		return fmt.Errorf("%w: search result limit must be 1..%d", ErrInvalidView, MaximumSearchResultLimit)
	}
	gvr := schema.GroupVersionResource{
		Group: query.Resource.Group, Version: query.Resource.Version, Resource: query.Resource.Resource,
	}
	serverNamespace := searchServerNamespace(query.Resource, query.NamespaceScope)
	authorityID, client, err := r.source.OpenResource(query.SessionID, gvr, serverNamespace)
	if err != nil {
		return err
	}
	keyPrefix := resourceKey{
		authorityID: authorityID, group: gvr.Group, version: gvr.Version,
		resource: gvr.Resource, namespace: serverNamespace,
	}

	// Exact namespace/name can use one authoritative GET even if this kind has
	// never been listed. It is never satisfied solely from stale cache.
	if namespace, name, exact := exactSearchIdentity(query.Query, query.Resource, query.NamespaceScope); exact {
		exactClient := client
		if query.Resource.Namespaced && namespace != serverNamespace {
			_, exactClient, err = r.source.OpenResource(query.SessionID, gvr, namespace)
			if err != nil {
				return err
			}
		}
		value, getErr := getFromLister(ctx, exactClient, name)
		if getErr == nil && includesSearchNamespace(value.GetNamespace(), query.Resource, query.NamespaceScope) {
			result := makeSearchResult(query.SessionID, query.Resource, value, 10_000, false)
			return emit(SearchBatch{Results: []*kmgrv1.SearchResult{result}, Examined: 1, Complete: true, UsedDirectGet: true})
		}
		if getErr != nil {
			return getErr
		}
	}

	r.mu.Lock()
	var cachedObjects []*unstructured.Unstructured
	for key, entry := range r.resources {
		if compatibleSearchKey(keyPrefix, key) {
			cachedObjects = append(cachedObjects, entry.store.Snapshot()...)
		}
	}
	r.mu.Unlock()
	if len(cachedObjects) != 0 {
		results := rankSearchObjects(query, cachedObjects, limit, true)
		if err := emit(SearchBatch{Results: results, Examined: uint64(len(cachedObjects)), Complete: !query.AllowPaginatedList}); err != nil {
			return err
		}
		if !query.AllowPaginatedList {
			return nil
		}
	}
	if !query.AllowPaginatedList {
		return emit(SearchBatch{Complete: true})
	}

	options := metav1.ListOptions{Limit: DefaultSearchPageSize}
	seen := make(map[string]*kmgrv1.SearchResult)
	var examined uint64
	for {
		list, err := client.List(ctx, options)
		if err != nil {
			return err
		}
		examined += uint64(len(list.Items))
		for index := range list.Items {
			value := &list.Items[index]
			if !includesSearchNamespace(value.GetNamespace(), query.Resource, query.NamespaceScope) {
				continue
			}
			if rank, match := searchRank(query.Query, value.GetNamespace(), value.GetName()); match {
				seen[string(value.GetUID())] = makeSearchResult(query.SessionID, query.Resource, value, rank, false)
			}
		}
		results := sortedSearchResults(seen, limit)
		complete := list.GetContinue() == ""
		if err := emit(SearchBatch{Results: results, Examined: examined, Complete: complete, Reusable: complete}); err != nil {
			return err
		}
		if complete {
			return nil
		}
		options.Continue = list.GetContinue()
	}
}

type getter interface {
	Get(context.Context, string, metav1.GetOptions, ...string) (*unstructured.Unstructured, error)
}

func getFromLister(ctx context.Context, client any, name string) (*unstructured.Unstructured, error) {
	value, ok := client.(getter)
	if !ok {
		return nil, errors.New("resource client does not support direct GET")
	}
	return value.Get(ctx, name, metav1.GetOptions{})
}

func compatibleSearchKey(prefix, value resourceKey) bool {
	return prefix.authorityID == value.authorityID && prefix.group == value.group &&
		prefix.version == value.version && prefix.resource == value.resource &&
		(prefix.namespace == "" || prefix.namespace == value.namespace)
}

func searchServerNamespace(resource ResourceType, scope NamespaceScope) string {
	if !resource.Namespaced || scope.All || len(scope.Namespaces) != 1 {
		return ""
	}
	return scope.Namespaces[0]
}

func exactSearchIdentity(query string, resource ResourceType, scope NamespaceScope) (namespace, name string, ok bool) {
	if resource.Namespaced {
		if before, after, found := strings.Cut(query, "/"); found && before != "" && after != "" && !strings.Contains(after, "/") {
			return before, after, true
		}
		if !strings.Contains(query, "/") && !scope.All && len(scope.Namespaces) == 1 {
			return scope.Namespaces[0], query, true
		}
		return "", "", false
	}
	if !strings.Contains(query, "/") {
		return "", query, true
	}
	return "", "", false
}

func includesSearchNamespace(namespace string, resource ResourceType, scope NamespaceScope) bool {
	if !resource.Namespaced || scope.All {
		return true
	}
	if len(scope.Namespaces) == 0 {
		return namespace == "default"
	}
	return slices.Contains(scope.Namespaces, namespace)
}

func rankSearchObjects(query SearchQuery, objects []*unstructured.Unstructured, limit int, stale bool) []*kmgrv1.SearchResult {
	seen := make(map[string]*kmgrv1.SearchResult)
	for _, value := range objects {
		if !includesSearchNamespace(value.GetNamespace(), query.Resource, query.NamespaceScope) {
			continue
		}
		if rank, match := searchRank(query.Query, value.GetNamespace(), value.GetName()); match {
			seen[string(value.GetUID())] = makeSearchResult(query.SessionID, query.Resource, value, rank, stale)
		}
	}
	return sortedSearchResults(seen, limit)
}

func searchRank(query, namespace, name string) (float64, bool) {
	query = strings.ToLower(query)
	name = strings.ToLower(name)
	qualified := strings.ToLower(namespace + "/" + name)
	switch {
	case name == query:
		return 1000, true
	case qualified == query:
		return 990, true
	case strings.HasPrefix(name, query):
		return 900 - float64(len(name)-len(query))/1000, true
	case strings.HasPrefix(qualified, query):
		return 890 - float64(len(qualified)-len(query))/1000, true
	case strings.Contains(name, query):
		return 700 - float64(strings.Index(name, query))/1000, true
	case strings.Contains(qualified, query):
		return 690 - float64(strings.Index(qualified, query))/1000, true
	default:
		return 0, false
	}
}

func makeSearchResult(
	sessionID string,
	resource ResourceType,
	value *unstructured.Unstructured,
	rank float64,
	stale bool,
) *kmgrv1.SearchResult {
	detail := value.GetNamespace()
	if detail != "" {
		detail += " · "
	}
	detail += resource.Kind
	return &kmgrv1.SearchResult{
		Identity: &kmgrv1.ResourceIdentity{
			ClusterSessionId: sessionID, Group: resource.Group, Version: resource.Version,
			Resource: resource.Resource, Namespace: value.GetNamespace(), Name: value.GetName(), Uid: string(value.GetUID()),
		},
		DisplayText: value.GetName(), DetailText: detail, Rank: rank, Stale: stale,
	}
}

func sortedSearchResults(values map[string]*kmgrv1.SearchResult, limit int) []*kmgrv1.SearchResult {
	result := make([]*kmgrv1.SearchResult, 0, len(values))
	for _, value := range values {
		result = append(result, value)
	}
	slices.SortFunc(result, func(left, right *kmgrv1.SearchResult) int {
		if result := cmp.Compare(right.GetRank(), left.GetRank()); result != 0 {
			return result
		}
		if result := cmp.Compare(left.GetIdentity().GetNamespace(), right.GetIdentity().GetNamespace()); result != 0 {
			return result
		}
		if result := cmp.Compare(left.GetIdentity().GetName(), right.GetIdentity().GetName()); result != 0 {
			return result
		}
		return cmp.Compare(left.GetIdentity().GetUid(), right.GetIdentity().GetUid())
	})
	return result[:min(limit, len(result))]
}
