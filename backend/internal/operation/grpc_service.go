package operation

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/object"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
)

var _ kmgrv1.OperationServiceServer = (*GRPCService)(nil)

type YAMLEditor interface {
	PrepareYAML(context.Context, object.Identity, []byte, string, bool) (object.PreparedYAML, error)
	ApplyYAML(context.Context, object.Identity, []byte, string, bool) (object.AppliedYAML, error)
}

type GRPCService struct {
	kmgrv1.UnimplementedOperationServiceServer
	editor  YAMLEditor
	manager *Manager
}

func NewGRPCService(editor YAMLEditor, manager *Manager) (*GRPCService, error) {
	if editor == nil {
		return nil, errors.New("YAML editor must not be nil")
	}
	if manager == nil {
		manager = NewManager()
	}
	return &GRPCService{editor: editor, manager: manager}, nil
}

func (s *GRPCService) PrepareYamlEdit(
	ctx context.Context,
	request *kmgrv1.PrepareYamlEditRequest,
) (*kmgrv1.PrepareYamlEditResponse, error) {
	requestID, operationContext, cancel, err := operationRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	identity, err := identityFromProto(request.GetIdentity(), request.GetContext().GetClusterSessionId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, err.Error())
	}
	response := &kmgrv1.PrepareYamlEditResponse{RequestId: requestID, Identity: request.GetIdentity()}
	prepared, err := s.editor.PrepareYAML(
		operationContext, identity, request.GetYamlUtf8(), request.GetExpectedResourceVersion(),
		request.GetForceFieldOwnership(),
	)
	if err != nil {
		structured := structuredOperationError(err, request.GetIdentity(), "prepare-yaml")
		if structured.GetCategory() == kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION {
			response.ValidationErrors = []*kmgrv1.StructuredError{structured}
		} else {
			response.Error = structured
		}
		return response, nil
	}
	response.NormalizedYamlUtf8 = append([]byte(nil), prepared.NormalizedYAML...)
	response.CurrentResourceVersion = prepared.CurrentResourceVersion
	for _, entry := range prepared.Diff {
		response.Diff = append(response.Diff, &kmgrv1.SemanticDiffEntry{
			Path: entry.Path, BeforeSummary: entry.BeforeSummary, AfterSummary: entry.AfterSummary,
			Severity: kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL,
		})
	}
	return response, nil
}

func (s *GRPCService) ApplyYaml(
	ctx context.Context,
	request *kmgrv1.ApplyYamlRequest,
) (*kmgrv1.StartOperationResponse, error) {
	requestID, _, cancel, err := operationRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	identity, err := identityFromProto(request.GetIdentity(), request.GetContext().GetClusterSessionId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, err.Error())
	}
	response := &kmgrv1.StartOperationResponse{RequestId: requestID, OperationId: request.GetOperationId()}
	if request.GetOperationId() == "" {
		return nil, status.Error(codes.InvalidArgument, "operation ID is required")
	}
	fieldManager := strings.TrimSpace(request.GetFieldManager())
	if fieldManager != "" && fieldManager != object.YAMLFieldManager {
		response.Error = structuredOperationError(
			fmt.Errorf("field manager must be %q", object.YAMLFieldManager), request.GetIdentity(), "apply-yaml",
		)
		return response, nil
	}
	// Operation lifetime follows the cluster session/helper, not the unary RPC.
	// Explicit cancellation is provided through CancelOperation.
	yamlCopy := append([]byte(nil), request.GetYamlUtf8()...)
	_, err = s.manager.Start(context.Background(), request.GetOperationId(), identity, func(ctx context.Context) (string, error) {
		defer clear(yamlCopy)
		applied, err := s.editor.ApplyYAML(
			ctx, identity, yamlCopy, request.GetExpectedResourceVersion(), request.GetForceFieldOwnership(),
		)
		return applied.NewResourceVersion, err
	})
	if err != nil {
		clear(yamlCopy)
		response.Error = structuredOperationError(err, request.GetIdentity(), "apply-yaml")
		return response, nil
	}
	response.Accepted = true
	return response, nil
}

func (s *GRPCService) WatchOperation(
	request *kmgrv1.WatchOperationRequest,
	stream kmgrv1.OperationService_WatchOperationServer,
) error {
	if request == nil || request.GetContext() == nil || request.GetContext().GetRequestId() == "" ||
		request.GetContext().GetClusterSessionId() == "" || request.GetStreamId() == "" ||
		request.GetGeneration() == 0 || request.GetOperationId() == "" {
		return status.Error(codes.InvalidArgument, "request context, stream ID, generation, and operation ID are required")
	}
	operation, found := s.manager.Get(request.GetOperationId())
	if !found {
		return status.Error(codes.NotFound, "operation was not found")
	}
	if operation.Status().Identity.SessionID != request.GetContext().GetClusterSessionId() {
		return status.Error(codes.NotFound, "operation was not found")
	}
	var sequence uint64
	var last State
	for {
		current := operation.Status()
		if current.State != last {
			sequence++
			if err := stream.Send(operationEvent(request, sequence, current)); err != nil {
				return err
			}
			last = current.State
		}
		if terminalState(current.State) {
			return nil
		}
		changed := operation.Changed()
		select {
		case <-stream.Context().Done():
			return stream.Context().Err()
		case <-operation.Done():
		case <-changed:
		}
	}
}

func (s *GRPCService) CancelOperation(
	ctx context.Context,
	request *kmgrv1.CancelOperationRequest,
) (*kmgrv1.Acknowledgement, error) {
	requestID, _, cancel, err := operationRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	operation, found := s.manager.Get(request.GetOperationId())
	if !found || operation.Status().Identity.SessionID != request.GetContext().GetClusterSessionId() {
		return &kmgrv1.Acknowledgement{RequestId: requestID, Accepted: false}, nil
	}
	// A single-item YAML operation is either not started or cancellable through
	// its context; cancel_not_started_only leaves a running request untouched.
	if request.GetCancelNotStartedOnly() && operation.Status().State != StatePending {
		return &kmgrv1.Acknowledgement{RequestId: requestID, Accepted: false}, nil
	}
	operation.Cancel()
	return &kmgrv1.Acknowledgement{RequestId: requestID, Accepted: true}, nil
}

func operationEvent(request *kmgrv1.WatchOperationRequest, sequence uint64, value Status) *kmgrv1.OperationEvent {
	state := protoOperationState(value.State)
	identity := identityToProto(value.Identity)
	item := &kmgrv1.OperationItemResult{
		Identity: identity, State: protoItemState(value.State), NewResourceVersion: value.NewResourceVersion,
	}
	var operationError *kmgrv1.StructuredError
	if value.Err != nil {
		operationError = structuredOperationError(value.Err, identity, "apply-yaml")
		item.Error = operationError
	}
	return &kmgrv1.OperationEvent{
		Cursor: &kmgrv1.StreamCursor{
			StreamId: request.GetStreamId(), Generation: request.GetGeneration(), Sequence: sequence,
		},
		OperationId: value.OperationID, State: state, CompletedItems: value.CompletedItems,
		TotalItems: value.TotalItems, ItemResults: []*kmgrv1.OperationItemResult{item}, Error: operationError,
	}
}

func identityFromProto(value *kmgrv1.ResourceIdentity, sessionID string) (object.Identity, error) {
	if value == nil {
		return object.Identity{}, object.ErrInvalidIdentity
	}
	if value.GetClusterSessionId() != "" && value.GetClusterSessionId() != sessionID {
		return object.Identity{}, errors.New("resource identity belongs to another cluster session")
	}
	identity := object.Identity{
		SessionID: sessionID, Group: value.GetGroup(), Version: value.GetVersion(), Resource: value.GetResource(),
		Namespace: value.GetNamespace(), Name: value.GetName(), UID: value.GetUid(),
	}
	return identity, identity.Validate()
}

func identityToProto(value object.Identity) *kmgrv1.ResourceIdentity {
	return &kmgrv1.ResourceIdentity{
		ClusterSessionId: value.SessionID, Group: value.Group, Version: value.Version, Resource: value.Resource,
		Namespace: value.Namespace, Name: value.Name, Uid: value.UID,
	}
}

func operationRequestContext(
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

func structuredOperationError(err error, identity *kmgrv1.ResourceIdentity, operation string) *kmgrv1.StructuredError {
	result := &kmgrv1.StructuredError{
		Category: kmgrv1.ErrorCategory_ERROR_CATEGORY_INTERNAL, Reason: "OperationFailed",
		Message: "The Kubernetes operation failed.", Operation: operation, Resource: identity,
	}
	var identityMismatch *object.YAMLIdentityMismatchError
	var uidMismatch *object.IdentityChangedError
	var versionConflict *object.ResourceVersionConflictError
	var apiStatus apierrors.APIStatus
	switch {
	case errors.As(err, &identityMismatch):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION
		result.Reason, result.Message, result.FieldPath = "IdentityChanged", identityMismatch.Error(), identityMismatch.Field
	case errors.Is(err, object.ErrInvalidYAML):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION
		result.Reason, result.Message = "InvalidYAML", err.Error()
	case errors.As(err, &uidMismatch):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT
		result.Reason, result.Message = "ObjectRecreated", uidMismatch.Error()
		result.SafeDetails = map[string]string{"expected_uid": uidMismatch.ExpectedUID, "current_uid": uidMismatch.ActualUID}
	case errors.As(err, &versionConflict):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT
		result.Reason, result.Message = "ResourceVersionConflict", versionConflict.Error()
		result.SafeDetails = map[string]string{"expected_resource_version": versionConflict.Expected, "current_resource_version": versionConflict.Current}
	case errors.Is(err, object.ErrSessionNotFound):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND
		result.Reason, result.Message = "SessionNotFound", "The cluster session is no longer open."
	case errors.Is(err, context.Canceled):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CANCELLED
		result.Reason, result.Message = "OperationCancelled", "The operation was cancelled."
	case errors.Is(err, context.DeadlineExceeded):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_TIMEOUT
		result.Reason, result.Message, result.Retryable = "OperationTimedOut", "The operation timed out.", true
	case apierrors.IsConflict(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT
		result.Reason, result.Message = "ApplyConflict", "The object changed or another field manager owns an edited field."
	case apierrors.IsInvalid(err) || apierrors.IsBadRequest(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION
		result.Reason, result.Message = "ServerValidationFailed", err.Error()
	case apierrors.IsNotFound(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND
		result.Reason, result.Message = "NotFound", "The Kubernetes object no longer exists."
	case apierrors.IsUnauthorized(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHENTICATION
		result.Reason, result.Message = "AuthenticationRejected", "The API server rejected the configured credentials."
	case apierrors.IsForbidden(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHORIZATION
		result.Reason, result.Message = "Forbidden", "The configured identity is not authorized for this operation."
	case errors.As(err, &apiStatus):
		value := apiStatus.Status()
		result.HttpStatusCode, result.Reason = value.Code, string(value.Reason)
		result.Retryable = value.Code == 408 || value.Code == 429 || value.Code >= 500
	}
	return result
}

func protoOperationState(value State) kmgrv1.OperationState {
	switch value {
	case StatePending:
		return kmgrv1.OperationState_OPERATION_STATE_PENDING
	case StateRunning:
		return kmgrv1.OperationState_OPERATION_STATE_RUNNING
	case StateSucceeded:
		return kmgrv1.OperationState_OPERATION_STATE_SUCCEEDED
	case StateFailed:
		return kmgrv1.OperationState_OPERATION_STATE_FAILED
	case StateCancelled:
		return kmgrv1.OperationState_OPERATION_STATE_CANCELLED
	default:
		return kmgrv1.OperationState_OPERATION_STATE_UNSPECIFIED
	}
}

func protoItemState(value State) kmgrv1.OperationItemState {
	switch value {
	case StatePending:
		return kmgrv1.OperationItemState_OPERATION_ITEM_STATE_PENDING
	case StateRunning:
		return kmgrv1.OperationItemState_OPERATION_ITEM_STATE_RUNNING
	case StateSucceeded:
		return kmgrv1.OperationItemState_OPERATION_ITEM_STATE_SUCCEEDED
	case StateFailed:
		return kmgrv1.OperationItemState_OPERATION_ITEM_STATE_FAILED
	case StateCancelled:
		return kmgrv1.OperationItemState_OPERATION_ITEM_STATE_CANCELLED
	default:
		return kmgrv1.OperationItemState_OPERATION_ITEM_STATE_UNSPECIFIED
	}
}

func terminalState(value State) bool {
	return value == StateSucceeded || value == StateFailed || value == StateCancelled
}
