package view

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"slices"
	"sort"
	"strings"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"

	"github.com/charlie0129/kmgr/backend/internal/store"
)

const (
	DefaultSearchResultLimit    = 100
	MaximumSearchResultLimit    = 500
	DefaultSearchPageSize       = 500
	DefaultCacheExamination     = 50_000
	MaximumCacheExamination     = 250_000
	MaximumCacheResourceFilters = 64
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

type CachedSearchQuery struct {
	SessionID        string
	NamespaceScope   NamespaceScope
	Query            string
	ResultLimit      int
	ExaminationLimit int
	ResourceFilters  []ResourceType
}

type CachedSearchResult struct {
	Results   []*kmgrv1.SearchResult
	Examined  uint64
	Truncated bool
}

// SearchCached answers the root Command Palette strictly from process-memory
// stores. It resolves only the already-open session authority and never calls
// OpenResource, so it cannot issue Kubernetes GET, LIST, or WATCH requests.
func (r *Runtime) SearchCached(ctx context.Context, query CachedSearchQuery) (CachedSearchResult, error) {
	query.SessionID = strings.TrimSpace(query.SessionID)
	query.Query = strings.TrimSpace(query.Query)
	if query.SessionID == "" || query.Query == "" {
		return CachedSearchResult{}, fmt.Errorf("%w: cached search session and query are required", ErrInvalidView)
	}
	if err := ctx.Err(); err != nil {
		return CachedSearchResult{}, err
	}
	limit := query.ResultLimit
	if limit == 0 {
		limit = DefaultSearchResultLimit
	}
	if limit < 1 || limit > MaximumSearchResultLimit {
		return CachedSearchResult{}, fmt.Errorf("%w: cached search result limit must be 1..%d", ErrInvalidView, MaximumSearchResultLimit)
	}
	examinationLimit := query.ExaminationLimit
	if examinationLimit == 0 {
		examinationLimit = DefaultCacheExamination
	}
	if examinationLimit < 1 || examinationLimit > MaximumCacheExamination {
		return CachedSearchResult{}, fmt.Errorf("%w: cache examination limit must be 1..%d", ErrInvalidView, MaximumCacheExamination)
	}
	resourceFilters, err := cachedSearchResourceFilters(query.ResourceFilters)
	if err != nil {
		return CachedSearchResult{}, err
	}
	authoritySource, ok := r.source.(interface {
		AuthorityID(string) (string, bool)
	})
	if !ok {
		return CachedSearchResult{}, ErrSessionNotFound
	}
	authorityID, ok := authoritySource.AuthorityID(query.SessionID)
	if !ok {
		return CachedSearchResult{}, ErrSessionNotFound
	}

	// Capture entry pointers under Runtime.mu, then snapshot stores, normalize,
	// rank, and sort after releasing it. Stores own their synchronization and
	// resource runtimes remain alive until Runtime.Close.
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return CachedSearchResult{}, ErrViewClosed
	}
	type cachedSearchEntry struct {
		key   resourceKey
		store *store.UIDStore
	}
	entries := make([]cachedSearchEntry, 0, len(r.resources))
	for key, entry := range r.resources {
		if key.authorityID == authorityID && entry != nil && entry.store != nil {
			entries = append(entries, cachedSearchEntry{key: key, store: entry.store})
		}
	}
	r.mu.Unlock()
	slices.SortFunc(entries, func(left, right cachedSearchEntry) int {
		_, leftMatched := resourceFilters[cachedSearchResourceKey(left.key)]
		_, rightMatched := resourceFilters[cachedSearchResourceKey(right.key)]
		if leftMatched != rightMatched {
			if leftMatched {
				return -1
			}
			return 1
		}
		return cmp.Compare(searchResourceKey(left.key), searchResourceKey(right.key))
	})

	retained := newBoundedSearchResults(limit)
	normalizedQuery := strings.ToLower(query.Query)
	seen := make(map[string]struct{}, min(examinationLimit, 4096))
	result := CachedSearchResult{}
	for _, entry := range entries {
		for _, indexed := range entry.store.SearchSnapshot() {
			if err := ctx.Err(); err != nil {
				return CachedSearchResult{}, err
			}
			value := indexed.Object
			if value == nil || value.GetUID() == "" {
				continue
			}
			unique := searchObjectKey(entry.key, string(value.GetUID()))
			if _, duplicate := seen[unique]; duplicate {
				continue
			}
			if len(seen) >= examinationLimit {
				result.Truncated = true
				result.Results = retained.Sorted()
				return result, nil
			}
			seen[unique] = struct{}{}
			result.Examined++
			resource := ResourceType{
				Group: entry.key.group, Version: entry.key.version,
				Resource: entry.key.resource, Namespaced: value.GetNamespace() != "",
			}
			matchedResource, resourceMatched := resourceFilters[cachedSearchGVRKey(resource)]
			if resourceMatched {
				// The filter comes from the GUI's discovery snapshot. It may enrich
				// presentation with Kind, but the retained object remains authority
				// for namespace-scope enforcement.
				resource.Kind = matchedResource.Kind
			}
			if !includesSearchNamespace(value.GetNamespace(), resource, query.NamespaceScope) {
				continue
			}
			rank, nameMatched := searchRankNormalized(
				normalizedQuery, indexed.NormalizedName, indexed.NormalizedQualified,
			)
			if !nameMatched && resourceMatched {
				rank = 600
			}
			if nameMatched || resourceMatched {
				retained.Add(makeSearchResult(query.SessionID, resource, value, rank, true))
			}
		}
	}
	result.Results = retained.Sorted()
	return result, nil
}

func cachedSearchResourceFilters(values []ResourceType) (map[string]ResourceType, error) {
	if len(values) > MaximumCacheResourceFilters {
		return nil, fmt.Errorf(
			"%w: cached search resource filters must not exceed %d",
			ErrInvalidView, MaximumCacheResourceFilters,
		)
	}
	result := make(map[string]ResourceType, len(values))
	for _, value := range values {
		value.Group = strings.TrimSpace(value.Group)
		value.Version = strings.TrimSpace(value.Version)
		value.Resource = strings.TrimSpace(value.Resource)
		value.Kind = strings.TrimSpace(value.Kind)
		if value.Version == "" || value.Resource == "" {
			return nil, fmt.Errorf(
				"%w: cached search resource filters require version and resource",
				ErrInvalidView,
			)
		}
		result[cachedSearchGVRKey(value)] = value
	}
	return result, nil
}

func cachedSearchGVRKey(value ResourceType) string {
	return strings.Join([]string{value.Group, value.Version, value.Resource}, "\x00")
}

func cachedSearchResourceKey(value resourceKey) string {
	return strings.Join([]string{value.group, value.version, value.resource}, "\x00")
}

func searchResourceKey(key resourceKey) string {
	return strings.Join([]string{key.group, key.version, key.resource, key.namespace, key.labels, key.fields}, "\x00")
}

func searchObjectKey(key resourceKey, uid string) string {
	return strings.Join([]string{key.group, key.version, key.resource, uid}, "\x00")
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
	if err := ctx.Err(); err != nil {
		return err
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
	snapshotKey := searchSnapshotKey{
		resource:       keyPrefix,
		namespaceScope: canonicalNamespaceScope(query.Resource, query.NamespaceScope),
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
		// A bare query can be both a possible exact identity and a prefix or
		// substring search. NotFound disproves only the exact interpretation, so
		// continue through compatible caches and the scoped paginated LIST.
		if getErr != nil && !apierrors.IsNotFound(getErr) {
			return getErr
		}
	}

	r.mu.Lock()
	var cachedEntries []*resourceRuntime
	for key, entry := range r.resources {
		if compatibleSearchKey(keyPrefix, key) {
			cachedEntries = append(cachedEntries, entry)
		}
	}
	r.mu.Unlock()
	cachedResults := newBoundedSearchResults(limit)
	normalizedQuery := strings.ToLower(query.Query)
	var examined uint64
	for _, entry := range cachedEntries {
		for _, indexed := range entry.store.SearchSnapshot() {
			if err := ctx.Err(); err != nil {
				return err
			}
			value := indexed.Object
			examined++
			if !includesSearchNamespace(value.GetNamespace(), query.Resource, query.NamespaceScope) {
				continue
			}
			if rank, match := searchRankNormalized(
				normalizedQuery, indexed.NormalizedName, indexed.NormalizedQualified,
			); match {
				cachedResults.Add(makeSearchResult(query.SessionID, query.Resource, value, rank, true))
			}
		}
	}
	if examined != 0 {
		if err := emit(SearchBatch{Results: cachedResults.Sorted(), Examined: examined, Complete: !query.AllowPaginatedList}); err != nil {
			return err
		}
		if !query.AllowPaginatedList {
			return nil
		}
	}
	if !query.AllowPaginatedList {
		return emit(SearchBatch{Complete: true})
	}

	seen := newBoundedSearchResults(limit)
	listExaminedBase := examined
	transient, attachment, err := r.startTransientSearchList(ctx, snapshotKey, client)
	if err != nil {
		return err
	}
	defer r.detachTransientSearch(transient, attachment)
	for {
		page, err := r.waitTransientSearchPage(ctx, transient, attachment)
		if err != nil {
			return err
		}
		if page.err != nil {
			return page.err
		}
		for _, value := range page.items {
			if !includesSearchNamespace(value.GetNamespace(), query.Resource, query.NamespaceScope) {
				continue
			}
			if rank, match := searchRank(query.Query, value.GetNamespace(), value.GetName()); match {
				seen.Add(makeSearchResult(query.SessionID, query.Resource, value, rank, false))
			}
		}
		examined = listExaminedBase + page.examined
		results := seen.Sorted()
		batch := SearchBatch{
			Results: results, Examined: examined, Complete: page.complete, Reusable: page.reusable,
		}
		if err := emit(batch); err != nil {
			return err
		}
		if batch.Reusable {
			r.observeTransientSearchSnapshot(transient, attachment)
		}
		if page.complete {
			return nil
		}
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
	if !resource.Namespaced || scope.All || len(scope.Namespaces) > 1 {
		return ""
	}
	if len(scope.Namespaces) == 0 {
		return "default"
	}
	return scope.Namespaces[0]
}

// canonicalNamespaceScope captures logical scope independently from the
// namespace used to construct the dynamic client. Sorting/deduplication makes
// equivalent caller orderings reusable while keeping distinct multi-namespace
// scopes isolated.
func canonicalNamespaceScope(resource ResourceType, scope NamespaceScope) string {
	if !resource.Namespaced {
		return "cluster"
	}
	if scope.All {
		return "all"
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
		namespaces = append(namespaces, "default")
	}
	sort.Strings(namespaces)
	return "namespaces:" + strings.Join(namespaces, "\x00")
}

func exactSearchIdentity(query string, resource ResourceType, scope NamespaceScope) (namespace, name string, ok bool) {
	if resource.Namespaced {
		if before, after, found := strings.Cut(query, "/"); found && before != "" && after != "" && !strings.Contains(after, "/") {
			// Do not probe a namespace outside the captured palette scope. Besides
			// avoiding needless traffic, this prevents a scoped search from leaking
			// whether an object exists elsewhere.
			if !includesSearchNamespace(before, resource, scope) {
				return "", "", false
			}
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
	seen := newBoundedSearchResults(limit)
	for _, value := range objects {
		if !includesSearchNamespace(value.GetNamespace(), query.Resource, query.NamespaceScope) {
			continue
		}
		if rank, match := searchRank(query.Query, value.GetNamespace(), value.GetName()); match {
			seen.Add(makeSearchResult(query.SessionID, query.Resource, value, rank, stale))
		}
	}
	return seen.Sorted()
}

func searchRank(query, namespace, name string) (float64, bool) {
	name = strings.ToLower(name)
	return searchRankNormalized(
		strings.ToLower(query), name, strings.ToLower(namespace)+"/"+name,
	)
}

func searchRankNormalized(query, name, qualified string) (float64, bool) {
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
	kind := resource.Kind
	if kind == "" {
		kind = resource.Resource
	}
	detail += kind
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
	slices.SortFunc(result, compareSearchResults)
	return result[:min(limit, len(result))]
}

// boundedSearchResults retains only the best resultLimit candidates. A partial
// palette search may match every object in a very large resource, so retaining
// all matches until the final page would defeat the bounded result contract.
type boundedSearchResults struct {
	limit  int
	values map[string]*kmgrv1.SearchResult
}

func newBoundedSearchResults(limit int) *boundedSearchResults {
	return &boundedSearchResults{limit: limit, values: make(map[string]*kmgrv1.SearchResult, limit)}
}

func (r *boundedSearchResults) Add(value *kmgrv1.SearchResult) {
	key := searchResultKey(value)
	r.values[key] = value
	if len(r.values) <= r.limit {
		return
	}
	var worstUID string
	var worst *kmgrv1.SearchResult
	for candidateUID, candidate := range r.values {
		if worst == nil || compareSearchResults(candidate, worst) > 0 {
			worstUID = candidateUID
			worst = candidate
		}
	}
	delete(r.values, worstUID)
}

func searchResultKey(value *kmgrv1.SearchResult) string {
	identity := value.GetIdentity()
	return strings.Join([]string{
		identity.GetGroup(), identity.GetVersion(), identity.GetResource(), identity.GetUid(),
	}, "\x00")
}

func (r *boundedSearchResults) Sorted() []*kmgrv1.SearchResult {
	return sortedSearchResults(r.values, r.limit)
}

func compareSearchResults(left, right *kmgrv1.SearchResult) int {
	if result := cmp.Compare(right.GetRank(), left.GetRank()); result != 0 {
		return result
	}
	if result := cmp.Compare(left.GetIdentity().GetNamespace(), right.GetIdentity().GetNamespace()); result != 0 {
		return result
	}
	if result := cmp.Compare(left.GetIdentity().GetName(), right.GetIdentity().GetName()); result != 0 {
		return result
	}
	if result := cmp.Compare(left.GetIdentity().GetGroup(), right.GetIdentity().GetGroup()); result != 0 {
		return result
	}
	if result := cmp.Compare(left.GetIdentity().GetVersion(), right.GetIdentity().GetVersion()); result != 0 {
		return result
	}
	if result := cmp.Compare(left.GetIdentity().GetResource(), right.GetIdentity().GetResource()); result != 0 {
		return result
	}
	return cmp.Compare(left.GetIdentity().GetUid(), right.GetIdentity().GetUid())
}
