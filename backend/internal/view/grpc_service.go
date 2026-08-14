package view

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/kubeerrors"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	viewcolumns "github.com/charlie0129/kmgr/backend/internal/view/columns"
)

var _ kmgrv1.ViewServiceServer = (*GRPCService)(nil)

// GRPCService is intentionally a thin protocol adapter. Runtime owns all
// consumer lifetimes, generation gating, warm caches, and bounded batching.
type GRPCService struct {
	kmgrv1.UnimplementedViewServiceServer
	runtime  *Runtime
	compiler *viewcolumns.Compiler
	searchMu sync.Mutex
	searches map[searchStreamKey]*searchRegistration
}

type searchStreamKey struct {
	sessionID  string
	searchID   string
	generation uint64
	revision   uint64
}

type searchRegistration struct {
	cancel context.CancelFunc
}

func NewGRPCService(runtime *Runtime, compilers ...*viewcolumns.Compiler) (*GRPCService, error) {
	if runtime == nil {
		return nil, errors.New("view runtime must not be nil")
	}
	var compiler *viewcolumns.Compiler
	if len(compilers) != 0 {
		compiler = compilers[0]
	}
	if compiler == nil {
		var err error
		compiler, err = viewcolumns.NewCompiler(viewcolumns.DefaultCostLimit)
		if err != nil {
			return nil, err
		}
	}
	return &GRPCService{
		runtime: runtime, compiler: compiler,
		searches: make(map[searchStreamKey]*searchRegistration),
	}, nil
}

// PreviewColumn is deliberately independent from the active columns file. A
// draft is compiled and evaluated without replacing the manager's last valid
// compiled configuration or starting a LIST/WATCH consumer.
func (s *GRPCService) PreviewColumn(
	ctx context.Context,
	request *kmgrv1.PreviewColumnRequest,
) (*kmgrv1.PreviewColumnResponse, error) {
	requestID, operationContext, cancel, err := viewRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	if request.GetResource() == nil || request.GetColumn() == nil {
		return nil, status.Error(codes.InvalidArgument, "resource and CEL column definition are required")
	}
	resource := request.GetResource()
	if strings.TrimSpace(resource.GetVersion()) == "" || strings.TrimSpace(resource.GetResource()) == "" {
		return nil, status.Error(codes.InvalidArgument, "resource version and name are required")
	}
	definition := request.GetColumn()
	program, err := s.compiler.Compile(viewcolumns.Definition{
		ID: definition.GetId(), Title: definition.GetTitle(),
		Expression: definition.GetExpression(), ResultType: viewcolumns.ResultType(definition.GetResultType()),
		Missing: definition.GetMissing(), ListJoiner: definition.GetListJoiner(),
	})
	response := &kmgrv1.PreviewColumnResponse{
		RequestId: requestID, CelEnvironment: viewcolumns.EnvironmentVersion,
	}
	if err != nil {
		response.Error = previewColumnError("CELCompileFailed", err, "compile CEL column")
		return response, nil
	}

	object, identity, sample, err := s.previewObject(operationContext, request)
	if err != nil {
		response.Error = previewColumnObjectError(err, request.GetSelectedObject())
		return response, nil
	}
	response.UsedSampleObject = sample
	response.EvaluatedObject = identity
	isSecret := resource.GetGroup() == "" && resource.GetVersion() == "v1" && resource.GetResource() == "secrets"
	value, err := program.Evaluate(viewcolumns.Activation{
		Object:  viewcolumns.SanitizeObjectActivation(object.Object, isSecret),
		Metrics: map[string]any{},
		Context: previewContext(request),
		Now:     time.Now(),
	})
	if err != nil {
		response.Error = previewColumnError("CELEvaluationFailed", err, "evaluate CEL column")
		return response, nil
	}
	response.Preview = cellForCELValue(definition.GetId(), value)
	return response, nil
}

// DiscoverOptionalResources returns one typed, point-in-time catalog from
// stores the runtime already retains. Keeping this separate from StreamView
// ensures optional scheduler discovery can never delay base rows or wake a
// Pod, Node, or Metrics API watcher merely to populate the Columns UI.
func (s *GRPCService) DiscoverOptionalResources(
	ctx context.Context,
	request *kmgrv1.DiscoverOptionalResourcesRequest,
) (*kmgrv1.DiscoverOptionalResourcesResponse, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestID, operationContext, cancel, err := viewRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	applicable := request.GetApplicableResource()
	if applicable == nil || applicable.GetGroup() != "" || applicable.GetVersion() != "v1" ||
		(applicable.GetResource() != "pods" && applicable.GetResource() != "nodes") {
		return nil, status.Error(codes.InvalidArgument, "optional resources apply only to core/v1 Pods and Nodes")
	}
	canonicalResource := optionalCatalogResourceType(applicable.GetResource())
	response := &kmgrv1.DiscoverOptionalResourcesResponse{RequestId: requestID}
	catalog, err := s.runtime.DiscoverOptionalResources(operationContext, request.GetContext().GetClusterSessionId())
	if err != nil {
		response.Error = structuredOptionalResourceError(err)
		return response, nil
	}
	response.NodesCacheAvailable = catalog.NodesCacheAvailable
	response.PodsCacheAvailable = catalog.PodsCacheAvailable
	response.NodesSnapshotComplete = catalog.NodesSnapshotComplete
	response.PodsSnapshotComplete = catalog.PodsSnapshotComplete
	response.PotentiallyIncomplete = catalog.PotentiallyIncomplete
	response.Resources = optionalResourceMessages(catalog, canonicalResource)
	return response, nil
}

func optionalResourceMessages(
	catalog OptionalResourceCatalog,
	applicable *kmgrv1.ResourceType,
) []*kmgrv1.OptionalResource {
	result := make([]*kmgrv1.OptionalResource, 0,
		1+len(catalog.Discovered.HugePages)+len(catalog.Discovered.Accelerators))
	result = append(result, &kmgrv1.OptionalResource{
		ExactKey: "ephemeral-storage", DisplayName: "Ephemeral Storage",
		Category: kmgrv1.OptionalResourceCategory_OPTIONAL_RESOURCE_CATEGORY_EPHEMERAL_STORAGE,
		Present:  catalog.Discovered.EphemeralStorage, ApplicableResource: applicable,
	})
	for _, name := range catalog.Discovered.HugePages {
		exact := string(name)
		result = append(result, &kmgrv1.OptionalResource{
			ExactKey: exact, DisplayName: "Huge Pages (" + strings.TrimPrefix(exact, "hugepages-") + ")",
			Category: kmgrv1.OptionalResourceCategory_OPTIONAL_RESOURCE_CATEGORY_HUGE_PAGE,
			Present:  catalog.Discovered.Present[name], ApplicableResource: applicable,
		})
	}
	for _, name := range catalog.Discovered.Accelerators {
		_, configured := catalog.Accelerators.Resources[string(name)]
		result = append(result, &kmgrv1.OptionalResource{
			ExactKey: string(name), DisplayName: metrics.AcceleratorDisplayName(name, catalog.Accelerators),
			Category: kmgrv1.OptionalResourceCategory_OPTIONAL_RESOURCE_CATEGORY_ACCELERATOR,
			Present:  catalog.Discovered.Present[name], ApplicableResource: applicable,
			ExplicitlyConfigured: configured,
		})
	}
	return result
}

func optionalCatalogResourceType(resource string) *kmgrv1.ResourceType {
	if resource == "nodes" {
		return &kmgrv1.ResourceType{Version: "v1", Resource: "nodes", Kind: "Node"}
	}
	return &kmgrv1.ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true}
}

func (s *GRPCService) previewObject(
	ctx context.Context,
	request *kmgrv1.PreviewColumnRequest,
) (*unstructured.Unstructured, *kmgrv1.ResourceIdentity, bool, error) {
	selected := request.GetSelectedObject()
	if selected == nil || selected.GetName() == "" || selected.GetUid() == "" {
		return samplePreviewObject(request.GetResource()), nil, true, nil
	}
	if selected.GetClusterSessionId() != "" && selected.GetClusterSessionId() != request.GetContext().GetClusterSessionId() {
		return nil, nil, false, errors.New("selected object belongs to another cluster session")
	}
	resource := request.GetResource()
	if selected.GetGroup() != resource.GetGroup() || selected.GetVersion() != resource.GetVersion() ||
		selected.GetResource() != resource.GetResource() {
		return nil, nil, false, errors.New("selected object belongs to another resource type")
	}
	_, client, err := s.runtime.source.OpenResource(
		request.GetContext().GetClusterSessionId(),
		schema.GroupVersionResource{Group: resource.GetGroup(), Version: resource.GetVersion(), Resource: resource.GetResource()},
		selected.GetNamespace(),
	)
	if err != nil {
		return nil, nil, false, err
	}
	getter, ok := client.(interface {
		Get(context.Context, string, metav1.GetOptions, ...string) (*unstructured.Unstructured, error)
	})
	if !ok {
		return nil, nil, false, errors.New("resource client does not support authoritative GET")
	}
	object, err := getter.Get(ctx, selected.GetName(), metav1.GetOptions{})
	if err != nil {
		return nil, nil, false, err
	}
	if object == nil {
		return nil, nil, false, errors.New("Kubernetes API returned no object")
	}
	if string(object.GetUID()) != selected.GetUid() {
		return nil, nil, false, fmt.Errorf(
			"selected object was recreated (expected UID %q, found %q)",
			selected.GetUid(), object.GetUID(),
		)
	}
	return object, selected, false, nil
}

func samplePreviewObject(resource *kmgrv1.ResourceType) *unstructured.Unstructured {
	apiVersion := resource.GetVersion()
	if resource.GetGroup() != "" {
		apiVersion = resource.GetGroup() + "/" + resource.GetVersion()
	}
	object := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": apiVersion,
		"kind":       resource.GetKind(),
		"metadata": map[string]any{
			"name": "sample", "namespace": "default",
			"labels": map[string]any{}, "annotations": map[string]any{},
		},
	}}
	if !resource.GetNamespaced() {
		object.SetNamespace("")
	}
	return object
}

func previewContext(request *kmgrv1.PreviewColumnRequest) map[string]any {
	resource, scope := request.GetResource(), request.GetNamespaceScope()
	return map[string]any{
		"clusterSessionID": request.GetContext().GetClusterSessionId(),
		"group":            resource.GetGroup(), "version": resource.GetVersion(),
		"resource": resource.GetResource(), "kind": resource.GetKind(),
		"namespaced": resource.GetNamespaced(), "allNamespaces": scope.GetAllNamespaces(),
		"namespaces": append([]string(nil), scope.GetNamespaces()...),
	}
}

func cellForCELValue(columnID string, value viewcolumns.Value) *kmgrv1.Cell {
	cell := &kmgrv1.Cell{
		ColumnId: columnID, DisplayText: value.Display,
		Severity: kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL,
	}
	switch {
	case value.String != nil:
		cell.TypedValue = &kmgrv1.Cell_StringValue{StringValue: *value.String}
	case value.Quantity != nil:
		cell.TypedValue = quantityCellValue(*value.Quantity, value.Display)
	case value.Integer != nil:
		cell.TypedValue = &kmgrv1.Cell_IntegerValue{IntegerValue: *value.Integer}
	case value.Number != nil:
		cell.TypedValue = &kmgrv1.Cell_NumberValue{NumberValue: *value.Number}
	case value.Boolean != nil:
		cell.TypedValue = &kmgrv1.Cell_BoolValue{BoolValue: *value.Boolean}
	case value.Time != nil:
		cell.TypedValue = &kmgrv1.Cell_TimestampUnixMs{TimestampUnixMs: value.Time.UnixMilli()}
	case value.Duration != nil:
		cell.TypedValue = &kmgrv1.Cell_NumberValue{NumberValue: value.Duration.Seconds()}
	}
	return cell
}

func previewColumnError(reason string, err error, operation string) *kmgrv1.StructuredError {
	return &kmgrv1.StructuredError{
		Category: kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION,
		Reason:   reason, Message: err.Error(), Operation: operation,
	}
}

func previewColumnObjectError(err error, identity *kmgrv1.ResourceIdentity) *kmgrv1.StructuredError {
	return &kmgrv1.StructuredError{
		Category: kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE,
		Reason:   "ColumnPreviewObjectUnavailable", Message: err.Error(),
		Operation: "load CEL preview object", Resource: identity,
	}
}

func viewRequestContext(
	ctx context.Context,
	request *kmgrv1.RequestContext,
) (string, context.Context, context.CancelFunc, error) {
	if request == nil || strings.TrimSpace(request.GetRequestId()) == "" ||
		strings.TrimSpace(request.GetClusterSessionId()) == "" {
		return "", nil, nil, status.Error(codes.InvalidArgument, "request ID and cluster session ID are required")
	}
	if err := ctx.Err(); err != nil {
		return "", nil, nil, viewStatusError(err)
	}
	if request.GetDeadlineUnixMs() == 0 {
		derived, cancel := context.WithCancel(ctx)
		return request.GetRequestId(), derived, cancel, nil
	}
	deadline := time.UnixMilli(request.GetDeadlineUnixMs())
	if !deadline.After(time.Now()) {
		return "", nil, nil, status.Error(codes.DeadlineExceeded, "request deadline exceeded")
	}
	derived, cancel := context.WithDeadline(ctx, deadline)
	return request.GetRequestId(), derived, cancel, nil
}

func (s *GRPCService) SearchCachedObjects(
	ctx context.Context,
	request *kmgrv1.SearchCachedObjectsRequest,
) (*kmgrv1.SearchCachedObjectsResponse, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestID, operationContext, cancel, err := viewRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	if err := operationContext.Err(); err != nil {
		return nil, viewStatusError(err)
	}
	if strings.TrimSpace(request.GetQuery()) == "" {
		return nil, status.Error(codes.InvalidArgument, "request, session, and query are required")
	}
	scope := request.GetNamespaceScope()
	result, err := s.runtime.SearchCached(operationContext, CachedSearchQuery{
		SessionID: request.GetContext().GetClusterSessionId(),
		NamespaceScope: NamespaceScope{
			All: scope.GetAllNamespaces(), Namespaces: append([]string(nil), scope.GetNamespaces()...),
		},
		Query: request.GetQuery(), ResultLimit: int(request.GetResultLimit()),
		ExaminationLimit: int(request.GetExaminationLimit()),
	})
	response := &kmgrv1.SearchCachedObjectsResponse{RequestId: requestID}
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return nil, viewStatusError(err)
		}
		response.Error = structuredCachedSearchError(err)
		return response, nil
	}
	response.Results = result.Results
	response.ObjectsExamined = result.Examined
	response.ExaminationTruncated = result.Truncated
	return response, nil
}

func (s *GRPCService) SearchObjects(
	request *kmgrv1.SearchObjectsRequest,
	stream grpc.ServerStreamingServer[kmgrv1.SearchObjectsEvent],
) error {
	if request == nil {
		return status.Error(codes.InvalidArgument, "request is required")
	}
	_, ctx, cancel, err := viewRequestContext(stream.Context(), request.GetContext())
	if err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		cancel()
		return viewStatusError(err)
	}
	if request.GetSearchId() == "" || request.GetGeneration() == 0 ||
		request.GetQueryRevision() == 0 || request.GetResource() == nil {
		cancel()
		return status.Error(codes.InvalidArgument, "session, search ID, generation, revision, and resource are required")
	}
	key := searchStreamKey{
		sessionID: request.GetContext().GetClusterSessionId(), searchID: request.GetSearchId(),
		generation: request.GetGeneration(), revision: request.GetQueryRevision(),
	}
	registration, err := s.registerSearch(key, cancel)
	if err != nil {
		cancel()
		return err
	}
	defer func() {
		cancel()
		s.unregisterSearch(key, registration)
	}()

	resource := request.GetResource()
	scope := request.GetNamespaceScope()
	sequence := uint64(0)
	err = s.runtime.Search(ctx, SearchQuery{
		SessionID: key.sessionID,
		Resource: ResourceType{
			Group: resource.GetGroup(), Version: resource.GetVersion(), Resource: resource.GetResource(),
			Kind: resource.GetKind(), Namespaced: resource.GetNamespaced(),
		},
		NamespaceScope: NamespaceScope{All: scope.GetAllNamespaces(), Namespaces: append([]string(nil), scope.GetNamespaces()...)},
		Query:          request.GetQuery(), ResultLimit: int(request.GetResultLimit()),
		AllowPaginatedList: request.GetAllowPaginatedList(),
	}, func(batch SearchBatch) error {
		sequence++
		return stream.Send(&kmgrv1.SearchObjectsEvent{
			Cursor:        &kmgrv1.StreamCursor{StreamId: key.searchID, Generation: key.generation, Sequence: sequence},
			QueryRevision: key.revision,
			Results:       batch.Results,
			Progress: &kmgrv1.SearchProgress{
				QueryRevision: key.revision, ObjectsExamined: batch.Examined, Complete: batch.Complete,
				UsedDirectGet: batch.UsedDirectGet, ReusableSnapshotAvailable: batch.Reusable,
			},
		})
	})
	if err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
		structured := &kmgrv1.StructuredError{
			Category: kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE,
			Reason:   "ObjectSearchFailed", Message: "The Kubernetes object search failed.",
			Operation: "search objects", Retryable: true,
		}
		kubeerrors.Enrich(structured, err)
		sequence++
		if sendErr := stream.Send(&kmgrv1.SearchObjectsEvent{
			Cursor: &kmgrv1.StreamCursor{
				StreamId: key.searchID, Generation: key.generation, Sequence: sequence,
			},
			QueryRevision: key.revision,
			Error:         structured,
		}); sendErr != nil {
			return sendErr
		}
		return nil
	}
	return viewStatusError(err)
}

func (s *GRPCService) CancelSearch(
	ctx context.Context,
	request *kmgrv1.CancelSearchRequest,
) (*kmgrv1.Acknowledgement, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestID, operationContext, cancelContext, err := viewRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancelContext()
	if err := operationContext.Err(); err != nil {
		return nil, viewStatusError(err)
	}
	if request.GetSearchId() == "" ||
		request.GetGeneration() == 0 || request.GetQueryRevision() == 0 {
		return nil, status.Error(codes.InvalidArgument, "request, session, search ID, generation, and revision are required")
	}
	key := searchStreamKey{
		sessionID: request.GetContext().GetClusterSessionId(), searchID: request.GetSearchId(),
		generation: request.GetGeneration(), revision: request.GetQueryRevision(),
	}
	s.searchMu.Lock()
	registration := s.searches[key]
	if registration != nil {
		delete(s.searches, key)
	}
	s.searchMu.Unlock()
	if registration != nil {
		registration.cancel()
	}
	return &kmgrv1.Acknowledgement{RequestId: requestID, Accepted: registration != nil}, nil
}

// registerSearch admits one active query revision for a logical palette search.
// Generations are compared before query revisions because the client resets its
// revision counter when it enters a new search generation. Registration uses a
// distinct owner so a canceled handler's delayed defer cannot unregister a
// replacement that later reuses the same exact cursor.
func (s *GRPCService) registerSearch(
	key searchStreamKey,
	cancel context.CancelFunc,
) (*searchRegistration, error) {
	registration := &searchRegistration{cancel: cancel}
	s.searchMu.Lock()
	defer s.searchMu.Unlock()

	// Reject before canceling anything. This keeps a crossed stale request from
	// partially disturbing an authoritative registration even if an invariant
	// violation ever leaves more than one entry for the logical search.
	for existing := range s.searches {
		if !sameLogicalSearch(existing, key) {
			continue
		}
		switch compareSearchVersion(existing, key) {
		case 1:
			return nil, status.Error(codes.FailedPrecondition, "search generation or query revision is stale")
		case 0:
			return nil, status.Error(codes.AlreadyExists, "search generation and query revision are already active")
		}
	}
	for existing, current := range s.searches {
		if !sameLogicalSearch(existing, key) {
			continue
		}
		current.cancel()
		delete(s.searches, existing)
	}
	if s.searches == nil {
		s.searches = make(map[searchStreamKey]*searchRegistration)
	}
	s.searches[key] = registration
	return registration, nil
}

func (s *GRPCService) unregisterSearch(key searchStreamKey, owner *searchRegistration) {
	s.searchMu.Lock()
	if s.searches[key] == owner {
		delete(s.searches, key)
	}
	s.searchMu.Unlock()
}

func sameLogicalSearch(left, right searchStreamKey) bool {
	return left.sessionID == right.sessionID && left.searchID == right.searchID
}

// compareSearchVersion returns -1, 0, or 1 when left is older, equal,
// or newer than right. Query revisions are meaningful only within a generation.
func compareSearchVersion(left, right searchStreamKey) int {
	switch {
	case left.generation < right.generation:
		return -1
	case left.generation > right.generation:
		return 1
	case left.revision < right.revision:
		return -1
	case left.revision > right.revision:
		return 1
	default:
		return 0
	}
}

func (s *GRPCService) StreamView(
	request *kmgrv1.OpenViewRequest,
	stream grpc.ServerStreamingServer[kmgrv1.ViewEvent],
) error {
	if request == nil {
		return status.Error(codes.InvalidArgument, "request is required")
	}
	_, operationContext, cancel, err := viewRequestContext(stream.Context(), request.GetContext())
	if err != nil {
		return err
	}
	defer cancel()
	if err := operationContext.Err(); err != nil {
		return viewStatusError(err)
	}
	subscription, err := s.runtime.OpenContext(operationContext, request)
	if err != nil {
		return viewStatusError(err)
	}
	defer subscription.Close()
	for {
		events, err := subscription.Next(operationContext)
		if err != nil {
			if errors.Is(err, ErrViewClosed) {
				return nil
			}
			return viewStatusError(err)
		}
		for _, event := range events {
			if err := stream.Send(event); err != nil {
				return err
			}
		}
		if err := subscription.AcknowledgeDelivery(events); err != nil {
			return viewStatusError(err)
		}
	}
}

func (s *GRPCService) CancelView(
	ctx context.Context,
	request *kmgrv1.CancelViewRequest,
) (*kmgrv1.Acknowledgement, error) {
	// A delayed RPC from an old generation cannot cancel its replacement.
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestID, operationContext, cancel, err := viewRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	if err := operationContext.Err(); err != nil {
		return nil, viewStatusError(err)
	}
	if request.GetViewId() == "" || request.GetGeneration() == 0 {
		return nil, status.Error(codes.InvalidArgument, "request context, session, view ID, and generation are required")
	}
	accepted := s.runtime.Cancel(
		request.GetContext().GetClusterSessionId(),
		request.GetViewId(),
		request.GetGeneration(),
	)
	return &kmgrv1.Acknowledgement{RequestId: requestID, Accepted: accepted}, nil
}

func viewStatusError(err error) error {
	if err == nil {
		return nil
	}
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return status.Error(codes.DeadlineExceeded, "request deadline exceeded")
	case errors.Is(err, context.Canceled):
		return status.Error(codes.Canceled, "request cancelled")
	case errors.Is(err, ErrSessionNotFound):
		return status.Error(codes.NotFound, "cluster session was not found")
	case errors.Is(err, ErrInvalidView):
		return status.Error(codes.InvalidArgument, err.Error())
	case errors.Is(err, ErrStaleViewOpen), errors.Is(err, ErrStaleFilter):
		return status.Error(codes.FailedPrecondition, err.Error())
	case errors.Is(err, ErrViewClosed):
		return status.Error(codes.Canceled, "resource view closed")
	default:
		return status.Error(codes.Internal, "resource view failed")
	}
}

func structuredCachedSearchError(err error) *kmgrv1.StructuredError {
	result := &kmgrv1.StructuredError{
		Category: kmgrv1.ErrorCategory_ERROR_CATEGORY_INTERNAL,
		Reason:   "CachedSearchFailed", Message: "The in-memory object search failed.",
		Operation: "search cached objects",
	}
	switch {
	case errors.Is(err, ErrSessionNotFound):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND
		result.Reason = "ClusterSessionNotFound"
		result.Message = "The cluster session was not found."
	case errors.Is(err, ErrInvalidView):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION
		result.Reason = "InvalidCachedSearch"
		result.Message = err.Error()
	case errors.Is(err, ErrViewClosed):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE
		result.Reason = "ViewRuntimeClosed"
		result.Message = "The in-memory object cache is unavailable."
		result.Retryable = true
	}
	return result
}

func structuredOptionalResourceError(err error) *kmgrv1.StructuredError {
	result := &kmgrv1.StructuredError{
		Category:  kmgrv1.ErrorCategory_ERROR_CATEGORY_INTERNAL,
		Reason:    "OptionalResourceDiscoveryFailed",
		Message:   "The in-memory optional resource catalog could not be read.",
		Operation: "discover optional scheduler resources",
	}
	switch {
	case errors.Is(err, ErrSessionNotFound):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND
		result.Reason = "ClusterSessionNotFound"
		result.Message = "The cluster session was not found."
	case errors.Is(err, ErrInvalidView):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION
		result.Reason = "InvalidOptionalResourceDiscovery"
		result.Message = err.Error()
	case errors.Is(err, ErrViewClosed):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE
		result.Reason = "ViewRuntimeClosed"
		result.Message = "The in-memory object cache is unavailable."
		result.Retryable = true
	}
	return result
}
