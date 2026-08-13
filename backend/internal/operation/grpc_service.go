package operation

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/kubeerrors"
	"github.com/charlie0129/kmgr/backend/internal/object"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

var _ kmgrv1.OperationServiceServer = (*GRPCService)(nil)

type YAMLEditor interface {
	PrepareYAML(context.Context, object.Identity, []byte, string, bool) (object.PreparedYAML, error)
	ApplyYAML(context.Context, object.Identity, []byte, string, bool) (object.AppliedYAML, error)
}

type GRPCService struct {
	kmgrv1.UnimplementedOperationServiceServer
	backend MutationBackend
	manager *Manager
	now     func() time.Time
}

func NewGRPCService(backend MutationBackend, manager *Manager) (*GRPCService, error) {
	if backend == nil {
		return nil, errors.New("operation backend must not be nil")
	}
	if manager == nil {
		manager = NewManager()
	}
	return &GRPCService{backend: backend, manager: manager, now: time.Now}, nil
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
	prepared, err := s.backend.PrepareYAML(
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
			&ValidationError{Field: "field_manager", Message: fmt.Sprintf("field manager must be %q", object.YAMLFieldManager)},
			request.GetIdentity(), "apply-yaml",
		)
		return response, nil
	}
	// Operation lifetime follows the cluster session/helper, not the unary RPC.
	// Explicit cancellation is provided through CancelOperation.
	yamlCopy := append([]byte(nil), request.GetYamlUtf8()...)
	expectedResourceVersion := request.GetExpectedResourceVersion()
	forceFieldOwnership := request.GetForceFieldOwnership()
	_, err = s.manager.Start(context.Background(), request.GetOperationId(), identity, func(ctx context.Context) (string, error) {
		defer clear(yamlCopy)
		applied, err := s.backend.ApplyYAML(
			ctx, identity, yamlCopy, expectedResourceVersion, forceFieldOwnership,
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

func (s *GRPCService) UpdateData(
	ctx context.Context,
	request *kmgrv1.UpdateDataRequest,
) (*kmgrv1.StartOperationResponse, error) {
	requestID, _, cancel, identity, response, err := s.startRequest(ctx, request.GetContext(), request.GetOperationId(), request.GetIdentity())
	if err != nil {
		return nil, err
	}
	defer cancel()
	response.RequestId = requestID
	mutations, err := dataMutationsFromProto(request.GetMutations())
	if err != nil {
		response.Error = structuredOperationError(err, request.GetIdentity(), "update-data")
		return response, nil
	}
	expectedResourceVersion := request.GetExpectedResourceVersion()
	if expectedResourceVersion == "" {
		clearDataMutations(mutations)
		response.Error = structuredOperationError(
			&ValidationError{Field: "expected_resource_version", Message: "expected resource version is required"},
			request.GetIdentity(), "update-data",
		)
		return response, nil
	}
	_, err = s.manager.StartOne(context.Background(), request.GetOperationId(), "update-data", identity, func(ctx context.Context) (string, error) {
		defer clearDataMutations(mutations)
		updated, err := s.backend.UpdateData(ctx, identity, expectedResourceVersion, mutations)
		return updated.ResourceVersion, err
	})
	if err != nil {
		clearDataMutations(mutations)
		response.Error = structuredOperationError(err, request.GetIdentity(), "update-data")
		return response, nil
	}
	response.Accepted = true
	return response, nil
}

func (s *GRPCService) Delete(
	ctx context.Context,
	request *kmgrv1.DeleteRequest,
) (*kmgrv1.StartOperationResponse, error) {
	requestID, _, cancel, err := operationRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	response := &kmgrv1.StartOperationResponse{RequestId: requestID, OperationId: request.GetOperationId()}
	if request.GetOperationId() == "" {
		return nil, status.Error(codes.InvalidArgument, "operation ID is required")
	}
	targets, identities, err := deleteTargetsFromProto(request.GetTargets(), request.GetContext().GetClusterSessionId())
	if err != nil {
		response.Error = structuredOperationError(err, nil, "delete")
		return response, nil
	}
	options, err := deleteOptionsFromProto(request)
	if err != nil {
		response.Error = structuredOperationError(err, nil, "delete")
		return response, nil
	}
	_, err = s.manager.StartMany(context.Background(), request.GetOperationId(), "delete", identities, func(ctx context.Context, report Reporter) error {
		DeleteManyWithProgress(ctx, s.backend, targets, options, func(index int, state ItemState, result DeleteResult) {
			report(index, ItemUpdate{State: state, Err: result.Err})
		})
		return nil
	})
	if err != nil {
		response.Error = structuredOperationError(err, nil, "delete")
		return response, nil
	}
	response.Accepted = true
	return response, nil
}

func (s *GRPCService) Scale(
	ctx context.Context,
	request *kmgrv1.ScaleRequest,
) (*kmgrv1.StartOperationResponse, error) {
	requestID, _, cancel, identity, response, err := s.startRequest(ctx, request.GetContext(), request.GetOperationId(), request.GetIdentity())
	if err != nil {
		return nil, err
	}
	defer cancel()
	response.RequestId = requestID
	if request.GetReplicas() < 0 {
		response.Error = structuredOperationError(&ValidationError{Field: "replicas", Message: "replica count must not be negative"}, request.GetIdentity(), "scale")
		return response, nil
	}
	expectedResourceVersion := request.GetExpectedResourceVersion()
	if expectedResourceVersion == "" {
		response.Error = structuredOperationError(
			&ValidationError{Field: "expected_resource_version", Message: "expected resource version is required"},
			request.GetIdentity(), "scale",
		)
		return response, nil
	}
	replicas := request.GetReplicas()
	_, err = s.manager.StartOne(context.Background(), request.GetOperationId(), "scale", identity, func(ctx context.Context) (string, error) {
		return ScaleResource(ctx, s.backend, identity, expectedResourceVersion, replicas)
	})
	if err != nil {
		response.Error = structuredOperationError(err, request.GetIdentity(), "scale")
		return response, nil
	}
	response.Accepted = true
	return response, nil
}

func (s *GRPCService) RolloutRestart(
	ctx context.Context,
	request *kmgrv1.RolloutRestartRequest,
) (*kmgrv1.StartOperationResponse, error) {
	requestID, _, cancel, identity, response, err := s.startRequest(ctx, request.GetContext(), request.GetOperationId(), request.GetIdentity())
	if err != nil {
		return nil, err
	}
	defer cancel()
	response.RequestId = requestID
	if err := validateRestartIdentity(identity); err != nil {
		response.Error = structuredOperationError(err, request.GetIdentity(), "rollout-restart")
		return response, nil
	}
	expectedResourceVersion := request.GetExpectedResourceVersion()
	if expectedResourceVersion == "" {
		response.Error = structuredOperationError(
			&ValidationError{Field: "expected_resource_version", Message: "expected resource version is required"},
			request.GetIdentity(), "rollout-restart",
		)
		return response, nil
	}
	_, err = s.manager.StartOne(context.Background(), request.GetOperationId(), "rollout-restart", identity, func(ctx context.Context) (string, error) {
		return RestartResource(ctx, s.backend, identity, expectedResourceVersion, s.now())
	})
	if err != nil {
		response.Error = structuredOperationError(err, request.GetIdentity(), "rollout-restart")
		return response, nil
	}
	response.Accepted = true
	return response, nil
}

func (s *GRPCService) UpdateMetadata(
	ctx context.Context,
	request *kmgrv1.UpdateMetadataRequest,
) (*kmgrv1.StartOperationResponse, error) {
	requestID, _, cancel, identity, response, err := s.startRequest(ctx, request.GetContext(), request.GetOperationId(), request.GetIdentity())
	if err != nil {
		return nil, err
	}
	defer cancel()
	response.RequestId = requestID
	changes, err := metadataChangesFromProto(request)
	if err != nil {
		response.Error = structuredOperationError(err, request.GetIdentity(), "update-metadata")
		return response, nil
	}
	expectedResourceVersion := request.GetExpectedResourceVersion()
	if expectedResourceVersion == "" {
		response.Error = structuredOperationError(
			&ValidationError{Field: "expected_resource_version", Message: "expected resource version is required"},
			request.GetIdentity(), "update-metadata",
		)
		return response, nil
	}
	_, err = s.manager.StartOne(context.Background(), request.GetOperationId(), "update-metadata", identity, func(ctx context.Context) (string, error) {
		return UpdateResourceMetadata(ctx, s.backend, identity, expectedResourceVersion, changes)
	})
	if err != nil {
		response.Error = structuredOperationError(err, request.GetIdentity(), "update-metadata")
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
	if operation.Status().SessionID != request.GetContext().GetClusterSessionId() {
		return status.Error(codes.NotFound, "operation was not found")
	}
	var sequence uint64
	var lastRevision uint64
	for {
		current, changed := operation.Snapshot()
		if current.Revision != lastRevision {
			sequence++
			if err := stream.Send(operationEvent(request, sequence, current)); err != nil {
				return err
			}
			lastRevision = current.Revision
		}
		if terminalState(current.State) {
			return nil
		}
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
	if !found || operation.Status().SessionID != request.GetContext().GetClusterSessionId() {
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
	items := make([]*kmgrv1.OperationItemResult, 0, len(value.Items))
	for _, current := range value.Items {
		identity := identityToProto(current.Identity)
		item := &kmgrv1.OperationItemResult{
			Identity: identity, State: protoItemState(current.State), NewResourceVersion: current.NewResourceVersion,
		}
		if current.Err != nil {
			item.Error = structuredOperationError(current.Err, identity, value.Operation)
		}
		items = append(items, item)
	}
	var operationError *kmgrv1.StructuredError
	if value.Err != nil {
		operationError = structuredOperationError(value.Err, nil, value.Operation)
	}
	return &kmgrv1.OperationEvent{
		Cursor: &kmgrv1.StreamCursor{
			StreamId: request.GetStreamId(), Generation: request.GetGeneration(), Sequence: sequence,
		},
		OperationId: value.OperationID, State: state, CompletedItems: value.CompletedItems,
		TotalItems: value.TotalItems, ItemResults: items, Error: operationError,
	}
}

func (s *GRPCService) startRequest(
	ctx context.Context,
	requestContext *kmgrv1.RequestContext,
	operationID string,
	protoIdentity *kmgrv1.ResourceIdentity,
) (string, context.Context, context.CancelFunc, object.Identity, *kmgrv1.StartOperationResponse, error) {
	requestID, operationContext, cancel, err := operationRequestContext(ctx, requestContext)
	if err != nil {
		return "", nil, nil, object.Identity{}, nil, err
	}
	if operationID == "" {
		cancel()
		return "", nil, nil, object.Identity{}, nil, status.Error(codes.InvalidArgument, "operation ID is required")
	}
	identity, err := identityFromProto(protoIdentity, requestContext.GetClusterSessionId())
	if err != nil {
		cancel()
		return "", nil, nil, object.Identity{}, nil, status.Error(codes.InvalidArgument, err.Error())
	}
	return requestID, operationContext, cancel, identity, &kmgrv1.StartOperationResponse{OperationId: operationID}, nil
}

func dataMutationsFromProto(values []*kmgrv1.DataMutation) ([]object.DataMutation, error) {
	if len(values) == 0 {
		return nil, &ValidationError{Field: "mutations", Message: "at least one data mutation is required"}
	}
	result := make([]object.DataMutation, len(values))
	for index, value := range values {
		if value == nil {
			clearDataMutations(result)
			return nil, &ValidationError{Field: fmt.Sprintf("mutations[%d]", index), Message: "mutation is required"}
		}
		switch value.GetType() {
		case kmgrv1.DataMutationType_DATA_MUTATION_TYPE_SET:
			result[index].Type = object.MutationSet
		case kmgrv1.DataMutationType_DATA_MUTATION_TYPE_DELETE:
			result[index].Type = object.MutationDelete
		case kmgrv1.DataMutationType_DATA_MUTATION_TYPE_RENAME:
			result[index].Type = object.MutationRename
		default:
			clearDataMutations(result)
			return nil, &ValidationError{Field: fmt.Sprintf("mutations[%d].type", index), Message: "mutation type is invalid"}
		}
		switch value.GetEntryKind() {
		case kmgrv1.DataEntryKind_DATA_ENTRY_KIND_TEXT:
			result[index].Kind = object.DataText
		case kmgrv1.DataEntryKind_DATA_ENTRY_KIND_BINARY:
			result[index].Kind = object.DataBinary
		case kmgrv1.DataEntryKind_DATA_ENTRY_KIND_UNSPECIFIED:
			if result[index].Type == object.MutationSet {
				clearDataMutations(result)
				return nil, &ValidationError{Field: fmt.Sprintf("mutations[%d].entry_kind", index), Message: "entry kind is required for set mutations"}
			}
		default:
			clearDataMutations(result)
			return nil, &ValidationError{Field: fmt.Sprintf("mutations[%d].entry_kind", index), Message: "entry kind is invalid"}
		}
		result[index].Key = value.GetKey()
		result[index].NewKey = value.GetNewKey()
		result[index].Value = slices.Clone(value.GetValue())
		result[index].ExpectedContentHash = slices.Clone(value.GetExpectedContentHash())
	}
	return result, nil
}

func clearDataMutations(values []object.DataMutation) {
	for index := range values {
		clear(values[index].Value)
		clear(values[index].ExpectedContentHash)
	}
}

func deleteTargetsFromProto(values []*kmgrv1.DeleteTarget, sessionID string) ([]DeleteTarget, []object.Identity, error) {
	if len(values) == 0 {
		return nil, nil, &ValidationError{Field: "targets", Message: "at least one delete target is required"}
	}
	targets := make([]DeleteTarget, len(values))
	identities := make([]object.Identity, len(values))
	seen := make(map[string]struct{}, len(values))
	for index, value := range values {
		if value == nil {
			return nil, nil, &ValidationError{Field: fmt.Sprintf("targets[%d]", index), Message: "delete target is required"}
		}
		identity, err := identityFromProto(value.GetIdentity(), sessionID)
		if err != nil {
			return nil, nil, &ValidationError{Field: fmt.Sprintf("targets[%d].identity", index), Message: err.Error()}
		}
		key := strings.Join([]string{identity.Group, identity.Version, identity.Resource, identity.Namespace, identity.Name, identity.UID}, "\x00")
		if _, duplicate := seen[key]; duplicate {
			return nil, nil, &ValidationError{Field: fmt.Sprintf("targets[%d]", index), Message: "delete target is duplicated"}
		}
		seen[key] = struct{}{}
		targets[index] = DeleteTarget{Identity: identity}
		identities[index] = identity
	}
	return targets, identities, nil
}

func deleteOptionsFromProto(request *kmgrv1.DeleteRequest) (DeleteOptions, error) {
	options := DeleteOptions{MaxConcurrency: int(request.GetMaxConcurrency())}
	switch request.GetPropagationPolicy() {
	case kmgrv1.PropagationPolicy_PROPAGATION_POLICY_BACKGROUND:
		options.PropagationPolicy = metav1.DeletePropagationBackground
	case kmgrv1.PropagationPolicy_PROPAGATION_POLICY_FOREGROUND:
		options.PropagationPolicy = metav1.DeletePropagationForeground
	case kmgrv1.PropagationPolicy_PROPAGATION_POLICY_ORPHAN:
		options.PropagationPolicy = metav1.DeletePropagationOrphan
	default:
		return DeleteOptions{}, &ValidationError{Field: "propagation_policy", Message: "delete propagation policy is required"}
	}
	if request.GracePeriodSeconds != nil {
		grace := request.GetGracePeriodSeconds()
		if grace < 0 {
			return DeleteOptions{}, &ValidationError{Field: "grace_period_seconds", Message: "grace period must not be negative"}
		}
		options.GracePeriodSeconds = &grace
	}
	return options, nil
}

func metadataChangesFromProto(request *kmgrv1.UpdateMetadataRequest) (MetadataChanges, error) {
	labels, err := mapEntriesFromProto("labels", request.GetLabels())
	if err != nil {
		return MetadataChanges{}, err
	}
	annotations, err := mapEntriesFromProto("annotations", request.GetAnnotations())
	if err != nil {
		return MetadataChanges{}, err
	}
	changes := MetadataChanges{
		Labels: labels, Annotations: annotations,
		RemoveLabelKeys:      slices.Clone(request.GetRemoveLabelKeys()),
		RemoveAnnotationKeys: slices.Clone(request.GetRemoveAnnotationKeys()),
	}
	return changes, ValidateMetadataChanges(changes)
}

func mapEntriesFromProto(field string, values []*kmgrv1.StringMapEntry) (map[string]string, error) {
	result := make(map[string]string, len(values))
	for index, entry := range values {
		if entry == nil {
			return nil, &ValidationError{Field: fmt.Sprintf("%s[%d]", field, index), Message: "entry is required"}
		}
		if _, duplicate := result[entry.GetKey()]; duplicate {
			return nil, &ValidationError{Field: fmt.Sprintf("%s[%d]", field, index), Message: fmt.Sprintf("key %q is duplicated", entry.GetKey())}
		}
		result[entry.GetKey()] = entry.GetValue()
	}
	return result, nil
}

func validateRestartIdentity(identity object.Identity) error {
	if identity.Group != "apps" || identity.Version != "v1" ||
		(identity.Resource != "deployments" && identity.Resource != "statefulsets" && identity.Resource != "daemonsets") {
		return &ValidationError{Field: "identity.resource", Message: "rollout restart supports apps/v1 Deployments, StatefulSets, and DaemonSets"}
	}
	return nil
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
	kubeerrors.Enrich(result, err)
	var identityMismatch *object.YAMLIdentityMismatchError
	var uidMismatch *object.IdentityChangedError
	var versionConflict *object.ResourceVersionConflictError
	var dataConflict *object.DataConflictError
	var validationError *ValidationError
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
	case errors.As(err, &dataConflict):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT
		result.Reason, result.Message, result.FieldPath = "DataConflict", dataConflict.Error(), "data."+dataConflict.Key
		result.SafeDetails = map[string]string{
			"key": dataConflict.Key, "missing": fmt.Sprint(dataConflict.Missing),
			"expected_content_hash": hex.EncodeToString(dataConflict.ExpectedHash),
			"current_content_hash":  hex.EncodeToString(dataConflict.CurrentHash),
		}
	case errors.As(err, &validationError):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION
		result.Reason, result.Message, result.FieldPath = "InvalidRequest", validationError.Error(), validationError.Field
	case errors.Is(err, object.ErrInvalidIdentity):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION
		result.Reason, result.Message = "InvalidIdentity", "The Kubernetes resource identity is incomplete."
	case errors.Is(err, object.ErrUnsupportedDataObject):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_UNSUPPORTED
		result.Reason, result.Message = "DataEditorUnsupported", "Key/value data editing is available only for ConfigMaps and Secrets."
	case errors.Is(err, object.ErrSessionNotFound):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND
		result.Reason, result.Message = "SessionNotFound", "The cluster session is no longer open."
	case errors.Is(err, context.Canceled):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CANCELLED
		result.Reason, result.Message = "OperationCancelled", "The operation was cancelled."
	case errors.Is(err, context.DeadlineExceeded):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_TIMEOUT
		result.Reason, result.Message, result.Retryable = "OperationTimedOut", "The operation timed out.", true
	case errors.Is(err, ErrManagerClosed):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE
		result.Reason, result.Message = "EngineStopping", "The operation manager is shutting down."
	case errors.Is(err, ErrManagerFull):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_RESOURCE_EXHAUSTED
		result.Reason, result.Message = "TooManyOperations", "Too many mutations are still being tracked."
	case apierrors.IsConflict(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT
		result.Reason, result.Message = "ApplyConflict", "The object changed or another field manager owns an edited field."
	case apierrors.IsInvalid(err) || apierrors.IsBadRequest(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION
		result.Reason, result.Message = "ServerValidationFailed", "The Kubernetes API server rejected one or more object fields."
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
	case StatePartiallySucceeded:
		return kmgrv1.OperationState_OPERATION_STATE_PARTIALLY_SUCCEEDED
	case StateFailed:
		return kmgrv1.OperationState_OPERATION_STATE_FAILED
	case StateCancelled:
		return kmgrv1.OperationState_OPERATION_STATE_CANCELLED
	default:
		return kmgrv1.OperationState_OPERATION_STATE_UNSPECIFIED
	}
}

func protoItemState(value ItemState) kmgrv1.OperationItemState {
	switch value {
	case ItemStatePending:
		return kmgrv1.OperationItemState_OPERATION_ITEM_STATE_PENDING
	case ItemStateRunning:
		return kmgrv1.OperationItemState_OPERATION_ITEM_STATE_RUNNING
	case ItemStateSucceeded:
		return kmgrv1.OperationItemState_OPERATION_ITEM_STATE_SUCCEEDED
	case ItemStateFailed:
		return kmgrv1.OperationItemState_OPERATION_ITEM_STATE_FAILED
	case ItemStateSkipped:
		return kmgrv1.OperationItemState_OPERATION_ITEM_STATE_SKIPPED
	case ItemStateCancelled:
		return kmgrv1.OperationItemState_OPERATION_ITEM_STATE_CANCELLED
	default:
		return kmgrv1.OperationItemState_OPERATION_ITEM_STATE_UNSPECIFIED
	}
}

func terminalState(value State) bool {
	return value == StateSucceeded || value == StatePartiallySucceeded || value == StateFailed || value == StateCancelled
}
