package view

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"

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
	searches map[searchStreamKey]context.CancelFunc
}

type searchStreamKey struct {
	sessionID  string
	searchID   string
	generation uint64
	revision   uint64
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
		searches: make(map[searchStreamKey]context.CancelFunc),
	}, nil
}

// PreviewColumn is deliberately independent from the active columns file. A
// draft is compiled and evaluated without replacing the manager's last valid
// compiled configuration or starting a LIST/WATCH consumer.
func (s *GRPCService) PreviewColumn(
	ctx context.Context,
	request *kmgrv1.PreviewColumnRequest,
) (*kmgrv1.PreviewColumnResponse, error) {
	requestID, operationContext, cancel, err := previewRequestContext(ctx, request.GetContext())
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
	case value.Integer != nil:
		cell.TypedValue = &kmgrv1.Cell_NumberValue{NumberValue: float64(*value.Integer)}
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

func previewRequestContext(
	ctx context.Context,
	request *kmgrv1.RequestContext,
) (string, context.Context, context.CancelFunc, error) {
	if request == nil || request.GetRequestId() == "" || request.GetClusterSessionId() == "" {
		return "", nil, nil, status.Error(codes.InvalidArgument, "request ID and cluster session ID are required")
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
	_ context.Context,
	request *kmgrv1.SearchCachedObjectsRequest,
) (*kmgrv1.SearchCachedObjectsResponse, error) {
	if request == nil || request.GetContext() == nil || request.GetContext().GetRequestId() == "" ||
		strings.TrimSpace(request.GetContext().GetClusterSessionId()) == "" ||
		strings.TrimSpace(request.GetQuery()) == "" {
		return nil, status.Error(codes.InvalidArgument, "request, session, and query are required")
	}
	scope := request.GetNamespaceScope()
	result, err := s.runtime.SearchCached(CachedSearchQuery{
		SessionID: request.GetContext().GetClusterSessionId(),
		NamespaceScope: NamespaceScope{
			All: scope.GetAllNamespaces(), Namespaces: append([]string(nil), scope.GetNamespaces()...),
		},
		Query: request.GetQuery(), ResultLimit: int(request.GetResultLimit()),
		ExaminationLimit: int(request.GetExaminationLimit()),
	})
	response := &kmgrv1.SearchCachedObjectsResponse{RequestId: request.GetContext().GetRequestId()}
	if err != nil {
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
	if request == nil || request.GetContext() == nil || request.GetContext().GetClusterSessionId() == "" ||
		request.GetSearchId() == "" || request.GetGeneration() == 0 || request.GetQueryRevision() == 0 || request.GetResource() == nil {
		return status.Error(codes.InvalidArgument, "session, search ID, generation, revision, and resource are required")
	}
	ctx, cancel := context.WithCancel(stream.Context())
	key := searchStreamKey{
		sessionID: request.GetContext().GetClusterSessionId(), searchID: request.GetSearchId(),
		generation: request.GetGeneration(), revision: request.GetQueryRevision(),
	}
	s.searchMu.Lock()
	for existing, existingCancel := range s.searches {
		if existing.sessionID == key.sessionID && existing.searchID == key.searchID &&
			(existing.generation < key.generation || existing.revision < key.revision) {
			existingCancel()
			delete(s.searches, existing)
		}
	}
	s.searches[key] = cancel
	s.searchMu.Unlock()
	defer func() {
		cancel()
		s.searchMu.Lock()
		delete(s.searches, key)
		s.searchMu.Unlock()
	}()

	resource := request.GetResource()
	scope := request.GetNamespaceScope()
	sequence := uint64(0)
	err := s.runtime.Search(ctx, SearchQuery{
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
	return viewStatusError(err)
}

func (s *GRPCService) CancelSearch(
	_ context.Context,
	request *kmgrv1.CancelSearchRequest,
) (*kmgrv1.Acknowledgement, error) {
	if request == nil || request.GetContext() == nil || request.GetContext().GetRequestId() == "" ||
		request.GetContext().GetClusterSessionId() == "" || request.GetSearchId() == "" ||
		request.GetGeneration() == 0 || request.GetQueryRevision() == 0 {
		return nil, status.Error(codes.InvalidArgument, "request, session, search ID, generation, and revision are required")
	}
	key := searchStreamKey{
		sessionID: request.GetContext().GetClusterSessionId(), searchID: request.GetSearchId(),
		generation: request.GetGeneration(), revision: request.GetQueryRevision(),
	}
	s.searchMu.Lock()
	cancel := s.searches[key]
	if cancel != nil {
		delete(s.searches, key)
	}
	s.searchMu.Unlock()
	if cancel != nil {
		cancel()
	}
	return &kmgrv1.Acknowledgement{RequestId: request.GetContext().GetRequestId(), Accepted: cancel != nil}, nil
}

func (s *GRPCService) StreamView(
	request *kmgrv1.OpenViewRequest,
	stream grpc.ServerStreamingServer[kmgrv1.ViewEvent],
) error {
	subscription, err := s.runtime.Open(request)
	if err != nil {
		return viewStatusError(err)
	}
	defer subscription.Close()
	for {
		events, err := subscription.Next(stream.Context())
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
	}
}

func (s *GRPCService) CancelView(
	_ context.Context,
	request *kmgrv1.CancelViewRequest,
) (*kmgrv1.Acknowledgement, error) {
	// A delayed RPC from an old generation cannot cancel its replacement.
	if request == nil || request.GetContext() == nil || request.GetContext().GetRequestId() == "" ||
		request.GetContext().GetClusterSessionId() == "" || request.GetViewId() == "" || request.GetGeneration() == 0 {
		return nil, status.Error(codes.InvalidArgument, "request context, session, view ID, and generation are required")
	}
	accepted := s.runtime.Cancel(
		request.GetContext().GetClusterSessionId(),
		request.GetViewId(),
		request.GetGeneration(),
	)
	return &kmgrv1.Acknowledgement{RequestId: request.GetContext().GetRequestId(), Accepted: accepted}, nil
}

func viewStatusError(err error) error {
	if err == nil {
		return nil
	}
	switch {
	case errors.Is(err, ErrSessionNotFound):
		return status.Error(codes.NotFound, "cluster session was not found")
	case errors.Is(err, ErrInvalidView):
		return status.Error(codes.InvalidArgument, err.Error())
	case errors.Is(err, ErrStaleViewOpen):
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
