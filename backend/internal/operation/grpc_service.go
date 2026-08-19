package operation

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math"
	"slices"
	"strings"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/kubeerrors"
	"github.com/charlie0129/kmgr/backend/internal/object"
	"github.com/charlie0129/kmgr/backend/internal/view"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const (
	maxUnaryDeleteTargets       = 512
	maxStreamDeleteTargets      = 250_000
	maxDeleteTargetChunkItems   = 256
	maxResourceIdentityBytes    = 8 << 10
	maxDeleteTargetChunkBytes   = 256 << 10
	maxDeleteStreamPayloadBytes = 64 << 20
	maxOperationEventItems      = 1_024
	maxOperationEventBytes      = 512 << 10
	maxStructuredOperationError = 32 << 10
	operationProgressCoalesce   = 20 * time.Millisecond
)

var _ kmgrv1.OperationServiceServer = (*GRPCService)(nil)

type YAMLEditor interface {
	PrepareYAML(context.Context, object.Identity, []byte, string, bool) (object.PreparedYAML, error)
	ApplyYAML(context.Context, object.Identity, []byte, string, bool) (object.AppliedYAML, error)
}

type SelectionDeleteProvider interface {
	PrepareSelectionDelete(
		ctx context.Context,
		sessionID, viewID, token string,
		generation, indexRevision uint64,
		previewLimit uint32,
	) (view.SelectionDeleteDescription, error)
	AcquireSelectionLease(sessionID, viewID, token string) (SelectionDeleteLease, error)
}

type SelectionDeleteLease interface {
	State() view.SelectionState
	Resource() (view.SelectionResource, bool)
	MaxPageSize() uint32
	Page(offset uint64, limit uint32) (view.SelectionPage, error)
	Release()
}

// ViewSelectionDeleteProvider adapts the shared view runtime without exposing
// its concrete lease type to the operation service or tests.
type ViewSelectionDeleteProvider struct {
	Runtime *view.Runtime
}

func (p ViewSelectionDeleteProvider) PrepareSelectionDelete(
	ctx context.Context,
	sessionID, viewID, token string,
	generation, indexRevision uint64,
	previewLimit uint32,
) (view.SelectionDeleteDescription, error) {
	if p.Runtime == nil {
		return view.SelectionDeleteDescription{}, view.ErrSelectionStoreUnavailable
	}
	return p.Runtime.PrepareSelectionDelete(
		ctx, sessionID, viewID, token, generation, indexRevision, previewLimit,
	)
}

func (p ViewSelectionDeleteProvider) AcquireSelectionLease(
	sessionID, viewID, token string,
) (SelectionDeleteLease, error) {
	if p.Runtime == nil {
		return nil, view.ErrSelectionStoreUnavailable
	}
	return p.Runtime.AcquireSelectionLease(sessionID, viewID, token)
}

type GRPCService struct {
	kmgrv1.UnimplementedOperationServiceServer
	backend    MutationBackend
	acquirer   MutationBackendAcquirer
	selections SelectionDeleteProvider
	manager    *Manager
	now        func() time.Time
}

// ConfigureSelectionDeletes wires the shared resource-view selection runtime
// before the gRPC server starts accepting requests.
func (s *GRPCService) ConfigureSelectionDeletes(provider SelectionDeleteProvider) error {
	if s == nil {
		return errors.New("operation service is nil")
	}
	if provider == nil {
		return errors.New("selection delete provider must not be nil")
	}
	if s.selections != nil {
		return errors.New("selection delete provider is already configured")
	}
	s.selections = provider
	return nil
}

func NewGRPCService(
	backend MutationBackend,
	manager *Manager,
	acquirers ...MutationBackendAcquirer,
) (*GRPCService, error) {
	if backend == nil {
		return nil, errors.New("operation backend must not be nil")
	}
	if len(acquirers) > 1 {
		return nil, errors.New("at most one mutation backend acquirer may be configured")
	}
	var acquirer MutationBackendAcquirer = staticMutationBackendAcquirer{backend: backend}
	if len(acquirers) == 1 {
		if acquirers[0] == nil {
			return nil, errors.New("mutation backend acquirer must not be nil")
		}
		acquirer = acquirers[0]
	}
	if manager == nil {
		manager = NewManager()
	}
	return &GRPCService{backend: backend, acquirer: acquirer, manager: manager, now: time.Now}, nil
}

func (s *GRPCService) structuredError(
	err error,
	identity *kmgrv1.ResourceIdentity,
	operation string,
	sessionID string,
) *kmgrv1.StructuredError {
	contextName := ""
	if provider, ok := s.backend.(mutationContextNameProvider); ok {
		contextName, _ = provider.ContextName(sessionID)
	}
	return structuredOperationError(err, identity, operation, contextName)
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
		structured := s.structuredError(
			err, request.GetIdentity(), "prepare-yaml", request.GetContext().GetClusterSessionId(),
		)
		if structured.GetCategory() == kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION {
			response.ValidationErrors = []*kmgrv1.StructuredError{structured}
		} else {
			response.Error = structured
		}
		return response, nil
	}
	response.NormalizedYamlUtf8 = append([]byte(nil), prepared.NormalizedYAML...)
	response.CurrentResourceVersion = prepared.CurrentResourceVersion
	response.UnifiedDiffUtf8 = append([]byte(nil), prepared.UnifiedDiff...)
	response.UnifiedDiffTruncated = prepared.UnifiedDiffTruncated
	for _, entry := range prepared.Diff {
		response.Diff = append(response.Diff, &kmgrv1.SemanticDiffEntry{
			Path: entry.Path, BeforeSummary: entry.BeforeSummary, AfterSummary: entry.AfterSummary,
			Severity:                    kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL,
			BeforeDecodedSecretValue:    append([]byte(nil), entry.BeforeDecodedSecretValue...),
			HasBeforeDecodedSecretValue: entry.HasBeforeDecodedSecretValue,
			AfterDecodedSecretValue:     append([]byte(nil), entry.AfterDecodedSecretValue...),
			HasAfterDecodedSecretValue:  entry.HasAfterDecodedSecretValue,
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
		response.Error = s.structuredError(
			&ValidationError{Field: "field_manager", Message: fmt.Sprintf("field manager must be %q", object.YAMLFieldManager)},
			request.GetIdentity(), "apply-yaml", request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}
	// Operation lifetime follows the application deadline and cluster
	// session/helper, not the unary transport RPC. Explicit cancellation is
	// provided through CancelOperation.
	yamlCopy := append([]byte(nil), request.GetYamlUtf8()...)
	expectedResourceVersion := request.GetExpectedResourceVersion()
	forceFieldOwnership := request.GetForceFieldOwnership()
	_, err = s.startAcceptedOne(request.GetContext(), request.GetOperationId(), "apply-yaml", identity, func(
		ctx context.Context, backend MutationBackend,
	) (string, error) {
		defer clear(yamlCopy)
		applied, err := backend.ApplyYAML(
			ctx, identity, yamlCopy, expectedResourceVersion, forceFieldOwnership,
		)
		return applied.NewResourceVersion, err
	})
	if err != nil {
		clear(yamlCopy)
		response.Error = s.structuredError(
			err, request.GetIdentity(), "apply-yaml", request.GetContext().GetClusterSessionId(),
		)
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
		response.Error = s.structuredError(
			err, request.GetIdentity(), "update-data", request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}
	expectedResourceVersion := request.GetExpectedResourceVersion()
	if expectedResourceVersion == "" {
		clearDataMutations(mutations)
		response.Error = s.structuredError(
			&ValidationError{Field: "expected_resource_version", Message: "expected resource version is required"},
			request.GetIdentity(), "update-data", request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}
	_, err = s.startAcceptedOne(request.GetContext(), request.GetOperationId(), "update-data", identity, func(
		ctx context.Context, backend MutationBackend,
	) (string, error) {
		defer clearDataMutations(mutations)
		updated, err := backend.UpdateData(ctx, identity, expectedResourceVersion, mutations)
		return updated.ResourceVersion, err
	})
	if err != nil {
		clearDataMutations(mutations)
		response.Error = s.structuredError(
			err, request.GetIdentity(), "update-data", request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}
	response.Accepted = true
	return response, nil
}

func (s *GRPCService) PrepareDeleteSelection(
	ctx context.Context,
	request *kmgrv1.PrepareDeleteSelectionRequest,
) (*kmgrv1.PrepareDeleteSelectionResponse, error) {
	requestID, prepareContext, cancel, err := operationRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	response := &kmgrv1.PrepareDeleteSelectionResponse{
		RequestId: requestID, ViewId: request.GetViewId(),
		SelectionToken: request.GetSelectionToken(), Generation: request.GetGeneration(),
		IndexRevision: request.GetIndexRevision(),
	}
	if s.selections == nil {
		response.Error = s.selectionDeleteError(
			view.ErrSelectionStoreUnavailable, "prepare-delete-selection",
			request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}
	description, err := s.selections.PrepareSelectionDelete(
		prepareContext,
		request.GetContext().GetClusterSessionId(), request.GetViewId(),
		request.GetSelectionToken(), request.GetGeneration(), request.GetIndexRevision(),
		request.GetPreviewLimit(),
	)
	if err != nil {
		response.Error = s.selectionDeleteError(
			err, "prepare-delete-selection", request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}
	response.SelectedCount = description.State.SelectedCount
	response.HiddenCount = description.HiddenCount
	response.ExpiresAtUnixMs = description.State.ExpiresAt.UnixMilli()
	response.Resource = selectionResourceToProto(description.Resource)
	response.PreviewTruncated = uint64(len(description.Preview)) < description.State.SelectedCount
	response.Preview = make([]*kmgrv1.DeleteTarget, 0, len(description.Preview))
	for _, item := range description.Preview {
		response.Preview = append(response.Preview, &kmgrv1.DeleteTarget{
			Identity: selectionIdentityToProto(
				request.GetContext().GetClusterSessionId(), item.Identity,
			),
			HiddenByFilter: item.Hidden,
		})
	}
	return response, nil
}

func (s *GRPCService) DeleteSelection(
	ctx context.Context,
	request *kmgrv1.DeleteSelectionRequest,
) (*kmgrv1.StartOperationResponse, error) {
	requestID, _, requestCancel, err := operationRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer requestCancel()
	response := &kmgrv1.StartOperationResponse{
		RequestId: requestID, OperationId: request.GetOperationId(),
	}
	if request.GetOperationId() == "" {
		return nil, status.Error(codes.InvalidArgument, "operation ID is required")
	}
	if s.selections == nil {
		response.Error = s.selectionDeleteError(
			view.ErrSelectionStoreUnavailable, "delete", request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}
	if request.GetSelectedCount() == 0 || request.GetSelectedCount() > math.MaxUint32 {
		response.Error = s.structuredError(&ValidationError{
			Field: "selected_count", Message: fmt.Sprintf(
				"selected count must be between 1 and %d", uint64(math.MaxUint32),
			),
		}, nil, "delete", request.GetContext().GetClusterSessionId())
		return response, nil
	}
	expectedResource, err := selectionResourceFromProto(request.GetResource())
	if err != nil {
		response.Error = s.structuredError(err, nil, "delete", request.GetContext().GetClusterSessionId())
		return response, nil
	}
	options, err := deleteSelectionOptionsFromProto(request)
	if err != nil {
		response.Error = s.structuredError(err, nil, "delete", request.GetContext().GetClusterSessionId())
		return response, nil
	}

	// Acquire the relatively expensive Kubernetes authority first, then make
	// token expiry the final admission gate immediately before manager start.
	parent, cancel, err := acceptedMutationContext(request.GetContext())
	if err != nil {
		response.Error = s.structuredError(err, nil, "delete", request.GetContext().GetClusterSessionId())
		return response, nil
	}
	acquired, err := s.acquireMutationBackend(request.GetContext().GetClusterSessionId())
	if err != nil {
		cancel()
		response.Error = s.structuredError(err, nil, "delete", request.GetContext().GetClusterSessionId())
		return response, nil
	}
	lease, err := s.selections.AcquireSelectionLease(
		request.GetContext().GetClusterSessionId(), request.GetViewId(), request.GetSelectionToken(),
	)
	if err != nil {
		cancel()
		acquired.Release()
		response.Error = s.selectionDeleteError(err, "delete", request.GetContext().GetClusterSessionId())
		return response, nil
	}
	state := lease.State()
	actualResource, hasResource := lease.Resource()
	if state.SelectedCount != request.GetSelectedCount() || !hasResource || actualResource != expectedResource {
		lease.Release()
		cancel()
		acquired.Release()
		response.Error = s.selectionDeleteError(
			view.ErrSelectionSnapshotConflict, "delete", request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}

	source := selectionDeletePageSource{
		lease: lease, sessionID: request.GetContext().GetClusterSessionId(),
		expectedResource: expectedResource,
	}
	operation, err := s.manager.StartAggregate(
		parent, request.GetOperationId(), "delete", request.GetContext().GetClusterSessionId(),
		uint32(state.SelectedCount),
		func(ctx context.Context, report AggregateReporter) error {
			defer lease.Release()
			return DeletePagedWithProgress(
				ctx, acquired.Backend, uint32(state.SelectedCount), source, options,
				func(target DeleteTarget, itemState ItemState, result DeleteResult) bool {
					return report(target.Identity, ItemUpdate{State: itemState, Err: result.Err})
				},
			)
		},
	)
	if err != nil {
		lease.Release()
		cancel()
		acquired.Release()
		response.Error = s.structuredError(err, nil, "delete", request.GetContext().GetClusterSessionId())
		return response, nil
	}
	operation.SetContextName(acquired.ContextName)
	releaseAcceptedMutationContext(operation, cancel, acquired.Release)
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
	if len(request.GetTargets()) > maxUnaryDeleteTargets {
		response.Error = s.structuredError(&ValidationError{
			Field: "targets",
			Message: fmt.Sprintf(
				"unary delete accepts at most %d targets; use the chunked DeleteMany RPC",
				maxUnaryDeleteTargets,
			),
		}, nil, "delete", request.GetContext().GetClusterSessionId())
		return response, nil
	}
	targets, identities, err := deleteTargetsFromProto(request.GetTargets(), request.GetContext().GetClusterSessionId())
	if err != nil {
		response.Error = s.structuredError(
			err, nil, "delete", request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}
	options, err := deleteOptionsFromProto(request)
	if err != nil {
		response.Error = s.structuredError(
			err, nil, "delete", request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}
	_, err = s.startAcceptedMany(request.GetContext(), request.GetOperationId(), "delete", identities, func(
		ctx context.Context, backend MutationBackend, report Reporter,
	) error {
		DeleteManyWithProgress(ctx, backend, targets, options, func(index int, state ItemState, result DeleteResult) bool {
			return report(index, ItemUpdate{State: state, Err: result.Err})
		})
		return nil
	})
	if err != nil {
		response.Error = s.structuredError(
			err, nil, "delete", request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}
	response.Accepted = true
	return response, nil
}

// DeleteMany receives one bounded start envelope followed by contiguous,
// bounded target chunks. Work is accepted only after the complete selection
// has been validated, so a broken upload can never execute a partial delete.
func (s *GRPCService) DeleteMany(
	stream grpc.ClientStreamingServer[kmgrv1.DeleteManyRequest, kmgrv1.StartOperationResponse],
) error {
	if stream == nil {
		return status.Error(codes.InvalidArgument, "delete stream is required")
	}
	first, err := stream.Recv()
	if err != nil {
		if errors.Is(err, io.EOF) {
			return status.Error(codes.InvalidArgument, "delete start message is required")
		}
		return err
	}
	start := first.GetStart()
	if first.GetSequence() != 1 || start == nil {
		return status.Error(codes.InvalidArgument, "delete stream must begin with sequence 1 and a start message")
	}
	requestID, _, cancel, err := operationRequestContext(stream.Context(), start.GetContext())
	if err != nil {
		return err
	}
	defer cancel()
	response := &kmgrv1.StartOperationResponse{
		RequestId: requestID, OperationId: start.GetOperationId(),
	}
	respondError := func(err error) error {
		response.Error = s.structuredError(
			err, nil, "delete", start.GetContext().GetClusterSessionId(),
		)
		return stream.SendAndClose(response)
	}
	if start.GetOperationId() == "" {
		return respondError(&ValidationError{Field: "operation_id", Message: "operation ID is required"})
	}
	total := int(start.GetTotalTargets())
	if total < 1 || total > maxStreamDeleteTargets {
		return respondError(&ValidationError{
			Field:   "total_targets",
			Message: fmt.Sprintf("target count must be between 1 and %d", maxStreamDeleteTargets),
		})
	}
	options, err := deleteManyOptionsFromProto(start)
	if err != nil {
		return respondError(err)
	}
	targets := make([]DeleteTarget, 0, total)
	identities := make([]object.Identity, 0, total)
	seen := make(map[string]struct{}, total)
	payloadBytes := proto.Size(first)
	expectedSequence := uint64(2)

	for len(targets) < total {
		message, receiveErr := stream.Recv()
		if receiveErr != nil {
			if errors.Is(receiveErr, io.EOF) {
				return respondError(&ValidationError{
					Field:   "targets",
					Message: fmt.Sprintf("delete stream ended after %d of %d targets", len(targets), total),
				})
			}
			return receiveErr
		}
		chunk := message.GetTargets()
		if message.GetSequence() != expectedSequence || chunk == nil {
			return respondError(&ValidationError{
				Field: "sequence", Message: "delete target chunks must have contiguous sequence numbers",
			})
		}
		expectedSequence++
		encodedBytes := proto.Size(message)
		payloadBytes += encodedBytes
		if encodedBytes > maxDeleteTargetChunkBytes || payloadBytes > maxDeleteStreamPayloadBytes {
			return respondError(&ValidationError{
				Field: "targets", Message: fmt.Sprintf("delete target payload exceeds the %d-byte budget", maxDeleteStreamPayloadBytes),
			})
		}
		values := chunk.GetTargets()
		if len(values) < 1 || len(values) > maxDeleteTargetChunkItems {
			return respondError(&ValidationError{
				Field: "targets", Message: fmt.Sprintf("each delete chunk must contain between 1 and %d targets", maxDeleteTargetChunkItems),
			})
		}
		if int(chunk.GetStartIndex()) != len(targets) || len(targets)+len(values) > total {
			return respondError(&ValidationError{
				Field: "targets", Message: "delete target chunks must be contiguous and match total_targets",
			})
		}
		if err := appendDeleteTargets(
			&targets, &identities, seen, values, start.GetContext().GetClusterSessionId(), len(targets),
		); err != nil {
			return respondError(err)
		}
	}
	if extra, receiveErr := stream.Recv(); receiveErr == nil {
		_ = extra
		return respondError(&ValidationError{Field: "targets", Message: "delete stream contains more targets than total_targets"})
	} else if !errors.Is(receiveErr, io.EOF) {
		return receiveErr
	}

	_, err = s.startAcceptedMany(start.GetContext(), start.GetOperationId(), "delete", identities, func(
		ctx context.Context, backend MutationBackend, report Reporter,
	) error {
		DeleteManyWithProgress(ctx, backend, targets, options, func(index int, state ItemState, result DeleteResult) bool {
			return report(index, ItemUpdate{State: state, Err: result.Err})
		})
		return nil
	})
	if err != nil {
		return respondError(err)
	}
	response.Accepted = true
	return stream.SendAndClose(response)
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
		response.Error = s.structuredError(
			&ValidationError{Field: "replicas", Message: "replica count must not be negative"},
			request.GetIdentity(), "scale", request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}
	expectedResourceVersion := request.GetExpectedResourceVersion()
	if expectedResourceVersion == "" {
		response.Error = s.structuredError(
			&ValidationError{Field: "expected_resource_version", Message: "expected resource version is required"},
			request.GetIdentity(), "scale", request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}
	replicas := request.GetReplicas()
	_, err = s.startAcceptedOne(request.GetContext(), request.GetOperationId(), "scale", identity, func(
		ctx context.Context, backend MutationBackend,
	) (string, error) {
		return ScaleResource(ctx, backend, identity, expectedResourceVersion, replicas)
	})
	if err != nil {
		response.Error = s.structuredError(
			err, request.GetIdentity(), "scale", request.GetContext().GetClusterSessionId(),
		)
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
		response.Error = s.structuredError(
			err, request.GetIdentity(), "rollout-restart", request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}
	expectedResourceVersion := request.GetExpectedResourceVersion()
	if expectedResourceVersion == "" {
		response.Error = s.structuredError(
			&ValidationError{Field: "expected_resource_version", Message: "expected resource version is required"},
			request.GetIdentity(), "rollout-restart", request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}
	_, err = s.startAcceptedOne(request.GetContext(), request.GetOperationId(), "rollout-restart", identity, func(
		ctx context.Context, backend MutationBackend,
	) (string, error) {
		return RestartResource(ctx, backend, identity, expectedResourceVersion, s.now())
	})
	if err != nil {
		response.Error = s.structuredError(
			err, request.GetIdentity(), "rollout-restart", request.GetContext().GetClusterSessionId(),
		)
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
		response.Error = s.structuredError(
			err, request.GetIdentity(), "update-metadata", request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}
	expectedResourceVersion := request.GetExpectedResourceVersion()
	if expectedResourceVersion == "" {
		response.Error = s.structuredError(
			&ValidationError{Field: "expected_resource_version", Message: "expected resource version is required"},
			request.GetIdentity(), "update-metadata", request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}
	_, err = s.startAcceptedOne(request.GetContext(), request.GetOperationId(), "update-metadata", identity, func(
		ctx context.Context, backend MutationBackend,
	) (string, error) {
		return UpdateResourceMetadata(ctx, backend, identity, expectedResourceVersion, changes)
	})
	if err != nil {
		response.Error = s.structuredError(
			err, request.GetIdentity(), "update-metadata", request.GetContext().GetClusterSessionId(),
		)
		return response, nil
	}
	response.Accepted = true
	return response, nil
}

func (s *GRPCService) WatchOperation(
	request *kmgrv1.WatchOperationRequest,
	stream kmgrv1.OperationService_WatchOperationServer,
) error {
	if request == nil || stream == nil || request.GetContext() == nil || request.GetContext().GetRequestId() == "" ||
		request.GetContext().GetClusterSessionId() == "" || request.GetStreamId() == "" ||
		request.GetGeneration() == 0 || request.GetOperationId() == "" {
		return status.Error(codes.InvalidArgument, "request context, stream ID, generation, and operation ID are required")
	}
	_, watchContext, cancel, err := operationRequestContext(stream.Context(), request.GetContext())
	if err != nil {
		return err
	}
	defer cancel()
	operation, found := s.manager.Get(request.GetOperationId())
	if !found {
		return status.Error(codes.NotFound, "operation was not found")
	}
	if operation.Status().SessionID != request.GetContext().GetClusterSessionId() {
		return status.Error(codes.NotFound, "operation was not found")
	}
	var sequence uint64
	var lastState State
	var lastCompletedItems uint32
	var lastOmittedItemResults uint32
	completedOffset := 0
	for {
		current, candidates, _, changed := operation.Progress(completedOffset, maxOperationEventItems)
		retainedResults := int(current.RetainedItemResults)
		if len(candidates) > 0 {
			items, consumed := operationItemResults(candidates, current.Operation, current.ContextName)
			completedOffset += consumed
			eventState := current.State
			if terminalState(eventState) && completedOffset < retainedResults {
				eventState = StateRunning
			}
			sequence++
			if err := stream.Send(operationEvent(request, sequence, current, eventState, items)); err != nil {
				return err
			}
			lastState = eventState
			lastCompletedItems = current.CompletedItems
			lastOmittedItemResults = current.OmittedItemResults
			continue
		}
		aggregateCountersAdvanced := current.AggregateOnly &&
			(current.CompletedItems > lastCompletedItems ||
				current.OmittedItemResults > lastOmittedItemResults)
		if sequence == 0 || current.State != lastState || aggregateCountersAdvanced {
			sequence++
			if err := stream.Send(operationEvent(request, sequence, current, current.State, nil)); err != nil {
				return err
			}
			lastState = current.State
			lastCompletedItems = current.CompletedItems
			lastOmittedItemResults = current.OmittedItemResults
		}
		if terminalState(current.State) && completedOffset == retainedResults {
			return nil
		}
		select {
		case <-watchContext.Done():
			return operationWatchStatusError(watchContext.Err())
		case <-operation.Done():
		case <-changed:
			timer := time.NewTimer(operationProgressCoalesce)
			select {
			case <-watchContext.Done():
				stopTimer(timer)
				return operationWatchStatusError(watchContext.Err())
			case <-operation.Done():
				stopTimer(timer)
			case <-timer.C:
			}
		}
	}
}

func stopTimer(timer *time.Timer) {
	if timer == nil || timer.Stop() {
		return
	}
	select {
	case <-timer.C:
	default:
	}
}

func operationWatchStatusError(err error) error {
	switch {
	case errors.Is(err, context.Canceled):
		return status.Error(codes.Canceled, "operation watch was cancelled")
	case errors.Is(err, context.DeadlineExceeded):
		return status.Error(codes.DeadlineExceeded, "operation watch request deadline exceeded")
	default:
		return status.Error(codes.Internal, "operation watch failed")
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
	if request.GetCancelNotStartedOnly() {
		return &kmgrv1.Acknowledgement{
			RequestId: requestID, Accepted: operation.CancelNotStarted(),
		}, nil
	}
	operation.Cancel()
	return &kmgrv1.Acknowledgement{RequestId: requestID, Accepted: true}, nil
}

func operationItemResults(
	values []ItemStatus,
	operation string,
	contextName string,
) ([]*kmgrv1.OperationItemResult, int) {
	items := make([]*kmgrv1.OperationItemResult, 0, len(values))
	encodedBytes := 0
	for _, current := range values {
		identity := identityToProto(current.Identity)
		item := &kmgrv1.OperationItemResult{
			Identity: identity, State: protoItemState(current.State), NewResourceVersion: current.NewResourceVersion,
		}
		if current.Err != nil {
			item.Error = structuredOperationError(current.Err, identity, operation, contextName)
		}
		itemBytes := proto.Size(item)
		if itemBytes > maxOperationEventBytes/4 {
			item.NewResourceVersion = ""
			if item.Error != nil {
				item.Error = &kmgrv1.StructuredError{
					Category:    kmgrv1.ErrorCategory_ERROR_CATEGORY_INTERNAL,
					Reason:      "OperationResultTooLarge",
					Message:     "The per-resource result exceeded the safe display budget; details were omitted.",
					Operation:   operation,
					ContextName: contextName,
					Resource:    identity,
				}
			}
			itemBytes = proto.Size(item)
		}
		if len(items) > 0 && encodedBytes+itemBytes > maxOperationEventBytes-(16<<10) {
			break
		}
		items = append(items, item)
		encodedBytes += itemBytes
	}
	return items, len(items)
}

func operationEvent(
	request *kmgrv1.WatchOperationRequest,
	sequence uint64,
	value Status,
	state State,
	items []*kmgrv1.OperationItemResult,
) *kmgrv1.OperationEvent {
	var operationError *kmgrv1.StructuredError
	if value.Err != nil && state == value.State {
		operationError = structuredOperationError(value.Err, nil, value.Operation, value.ContextName)
	}
	return &kmgrv1.OperationEvent{
		Cursor: &kmgrv1.StreamCursor{
			StreamId: request.GetStreamId(), Generation: request.GetGeneration(), Sequence: sequence,
		},
		OperationId: value.OperationID, State: protoOperationState(state), CompletedItems: value.CompletedItems,
		TotalItems: value.TotalItems, ItemResults: items, Error: operationError,
		AggregateOnly: value.AggregateOnly, OmittedItemResults: value.OmittedItemResults,
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

type acceptedRunner func(context.Context, MutationBackend) (string, error)
type acceptedMultiRunner func(context.Context, MutationBackend, Reporter) error

func (s *GRPCService) startAcceptedOne(
	requestContext *kmgrv1.RequestContext,
	operationID string,
	operationName string,
	identity object.Identity,
	run acceptedRunner,
) (*TrackedOperation, error) {
	if run == nil {
		return nil, errors.New("accepted operation runner must not be nil")
	}
	parent, cancel, err := acceptedMutationContext(requestContext)
	if err != nil {
		return nil, err
	}
	acquired, err := s.acquireMutationBackend(requestContext.GetClusterSessionId())
	if err != nil {
		cancel()
		return nil, err
	}
	operation, err := s.manager.StartOne(parent, operationID, operationName, identity, func(ctx context.Context) (string, error) {
		return run(ctx, acquired.Backend)
	})
	if err != nil {
		cancel()
		acquired.Release()
		return nil, err
	}
	operation.SetContextName(acquired.ContextName)
	releaseAcceptedMutationContext(operation, cancel, acquired.Release)
	return operation, nil
}

func (s *GRPCService) startAcceptedMany(
	requestContext *kmgrv1.RequestContext,
	operationID string,
	operationName string,
	identities []object.Identity,
	run acceptedMultiRunner,
) (*TrackedOperation, error) {
	if run == nil {
		return nil, errors.New("accepted multi-operation runner must not be nil")
	}
	parent, cancel, err := acceptedMutationContext(requestContext)
	if err != nil {
		return nil, err
	}
	acquired, err := s.acquireMutationBackend(requestContext.GetClusterSessionId())
	if err != nil {
		cancel()
		return nil, err
	}
	operation, err := s.manager.StartMany(parent, operationID, operationName, identities, func(
		ctx context.Context, report Reporter,
	) error {
		return run(ctx, acquired.Backend, report)
	})
	if err != nil {
		cancel()
		acquired.Release()
		return nil, err
	}
	operation.SetContextName(acquired.ContextName)
	releaseAcceptedMutationContext(operation, cancel, acquired.Release)
	return operation, nil
}

func (s *GRPCService) acquireMutationBackend(sessionID string) (AcquiredMutationBackend, error) {
	if s == nil || s.acquirer == nil {
		return AcquiredMutationBackend{}, errors.New("mutation backend acquirer is unavailable")
	}
	acquired, err := s.acquirer.AcquireMutationBackend(sessionID)
	if err != nil {
		return AcquiredMutationBackend{}, err
	}
	if acquired.Backend == nil {
		if acquired.Release != nil {
			acquired.Release()
		}
		return AcquiredMutationBackend{}, errors.New("acquired mutation backend is unavailable")
	}
	if acquired.Release == nil {
		acquired.Release = func() {}
	}
	return acquired, nil
}

// acceptedMutationContext deliberately detaches accepted work from the unary
// transport context while retaining the protocol's application deadline.
// The manager independently adds helper/session shutdown cancellation.
func acceptedMutationContext(request *kmgrv1.RequestContext) (context.Context, context.CancelFunc, error) {
	if request == nil {
		return nil, nil, status.Error(codes.InvalidArgument, "request context is required")
	}
	if request.GetDeadlineUnixMs() == 0 {
		ctx, cancel := context.WithCancel(context.Background())
		return ctx, cancel, nil
	}
	deadline := time.UnixMilli(request.GetDeadlineUnixMs())
	if !deadline.After(time.Now()) {
		return nil, nil, status.Error(codes.DeadlineExceeded, "request deadline exceeded")
	}
	ctx, cancel := context.WithDeadline(context.Background(), deadline)
	return ctx, cancel, nil
}

func releaseAcceptedMutationContext(
	operation *TrackedOperation,
	cancel context.CancelFunc,
	release func(),
) {
	go func() {
		<-operation.Done()
		cancel()
		release()
	}()
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

type selectionDeletePageSource struct {
	lease            SelectionDeleteLease
	sessionID        string
	expectedResource view.SelectionResource
}

func (s selectionDeletePageSource) Page(offset uint64, limit uint32) ([]DeleteTarget, error) {
	if s.lease == nil {
		return nil, errors.New("selection lease is unavailable")
	}
	maxPageSize := s.lease.MaxPageSize()
	if maxPageSize == 0 {
		return nil, errors.New("selection lease page limit is unavailable")
	}
	limit = min(limit, maxPageSize)
	page, err := s.lease.Page(offset, limit)
	if err != nil {
		return nil, err
	}
	result := make([]DeleteTarget, 0, len(page.Items))
	for _, item := range page.Items {
		identity := object.Identity{
			SessionID: s.sessionID,
			Group:     item.Identity.Group,
			Version:   item.Identity.Version,
			Resource:  item.Identity.Resource,
			Namespace: item.Identity.Namespace,
			Name:      item.Identity.Name,
			UID:       item.Identity.UID,
		}
		if identity.Group != s.expectedResource.Group ||
			identity.Version != s.expectedResource.Version ||
			identity.Resource != s.expectedResource.Resource {
			return nil, fmt.Errorf("selection page contains an unexpected GVR")
		}
		if err := identity.Validate(); err != nil {
			return nil, fmt.Errorf("invalid selection delete identity: %w", err)
		}
		result = append(result, DeleteTarget{Identity: identity})
	}
	return result, nil
}

func selectionResourceFromProto(value *kmgrv1.ResourceType) (view.SelectionResource, error) {
	if value == nil {
		return view.SelectionResource{}, &ValidationError{
			Field: "resource", Message: "selection resource GVR is required",
		}
	}
	resource := view.SelectionResource{
		Group: value.GetGroup(), Version: value.GetVersion(), Resource: value.GetResource(),
	}
	if strings.TrimSpace(resource.Group) != resource.Group || resource.Version == "" ||
		strings.TrimSpace(resource.Version) != resource.Version || resource.Resource == "" ||
		strings.TrimSpace(resource.Resource) != resource.Resource {
		return view.SelectionResource{}, &ValidationError{
			Field: "resource", Message: "selection resource group, version, and resource must be canonical",
		}
	}
	return resource, nil
}

func selectionResourceToProto(value view.SelectionResource) *kmgrv1.ResourceType {
	return &kmgrv1.ResourceType{
		Group: value.Group, Version: value.Version, Resource: value.Resource,
	}
}

func selectionIdentityToProto(sessionID string, value view.SelectionIdentity) *kmgrv1.ResourceIdentity {
	return &kmgrv1.ResourceIdentity{
		ClusterSessionId: sessionID,
		Group:            value.Group,
		Version:          value.Version,
		Resource:         value.Resource,
		Namespace:        value.Namespace,
		Name:             value.Name,
		Uid:              value.UID,
	}
}

func (s *GRPCService) selectionDeleteError(
	err error,
	operation string,
	sessionID string,
) *kmgrv1.StructuredError {
	contextName := ""
	if provider, ok := s.backend.(mutationContextNameProvider); ok {
		contextName, _ = provider.ContextName(sessionID)
	}
	result := &kmgrv1.StructuredError{
		Category: kmgrv1.ErrorCategory_ERROR_CATEGORY_INTERNAL,
		Reason:   "SelectionDeleteUnavailable", Message: "The selected resources could not be resolved safely.",
		Operation: operation, ContextName: contextName,
	}
	switch {
	case errors.Is(err, context.Canceled):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CANCELLED
		result.Reason = "SelectionPreparationCancelled"
		result.Message = "Preparing the selection for deletion was cancelled."
	case errors.Is(err, context.DeadlineExceeded):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_TIMEOUT
		result.Reason = "SelectionPreparationTimedOut"
		result.Message = "Preparing the selection for deletion timed out."
		result.Retryable = true
	case errors.Is(err, view.ErrSelectionTokenExpired):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT
		result.Reason = "SelectionTokenExpired"
		result.Message = "The selection expired. Select the resources again before deleting."
	case errors.Is(err, view.ErrSelectionTokenNotFound), errors.Is(err, view.ErrSelectionScopeMismatch):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT
		result.Reason = "SelectionTokenUnavailable"
		result.Message = "The selection is no longer available in this resource view."
	case errors.Is(err, view.ErrStaleViewGeneration), errors.Is(err, view.ErrStaleViewRevision),
		errors.Is(err, view.ErrViewNotFound), errors.Is(err, view.ErrViewClosed):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT
		result.Reason = "SelectionViewChanged"
		result.Message = "The resource view changed while preparing deletion. Review the current selection again."
	case errors.Is(err, view.ErrSelectionSnapshotConflict):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT
		result.Reason = "SelectionConfirmationMismatch"
		result.Message = "The confirmed selection count or resource type no longer matches the immutable selection."
	case errors.Is(err, view.ErrInvalidSelectionScope), errors.Is(err, view.ErrInvalidSelectionPage),
		errors.Is(err, view.ErrInvalidViewRange):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION
		result.Reason = "InvalidSelectionDeleteRequest"
		result.Message = "The selection deletion request is invalid."
	case errors.Is(err, view.ErrSelectionCapacityExhausted):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_RESOURCE_EXHAUSTED
		result.Reason = "SelectionCapacityExhausted"
		result.Message = "The engine selection capacity is temporarily exhausted."
	case errors.Is(err, view.ErrSelectionStoreUnavailable):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE
		result.Reason = "SelectionTransportUnavailable"
		result.Message = "Token-backed selection deletion is unavailable."
	}
	return result
}

func deleteTargetsFromProto(values []*kmgrv1.DeleteTarget, sessionID string) ([]DeleteTarget, []object.Identity, error) {
	if len(values) == 0 {
		return nil, nil, &ValidationError{Field: "targets", Message: "at least one delete target is required"}
	}
	targets := make([]DeleteTarget, 0, len(values))
	identities := make([]object.Identity, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	if err := appendDeleteTargets(&targets, &identities, seen, values, sessionID, 0); err != nil {
		return nil, nil, err
	}
	return targets, identities, nil
}

func appendDeleteTargets(
	targets *[]DeleteTarget,
	identities *[]object.Identity,
	seen map[string]struct{},
	values []*kmgrv1.DeleteTarget,
	sessionID string,
	baseIndex int,
) error {
	for index, value := range values {
		absoluteIndex := baseIndex + index
		if value == nil {
			return &ValidationError{Field: fmt.Sprintf("targets[%d]", absoluteIndex), Message: "delete target is required"}
		}
		if proto.Size(value) > maxResourceIdentityBytes {
			return &ValidationError{
				Field:   fmt.Sprintf("targets[%d]", absoluteIndex),
				Message: fmt.Sprintf("delete target exceeds the %d-byte identity budget", maxResourceIdentityBytes),
			}
		}
		identity, err := identityFromProto(value.GetIdentity(), sessionID)
		if err != nil {
			return &ValidationError{Field: fmt.Sprintf("targets[%d].identity", absoluteIndex), Message: err.Error()}
		}
		key := strings.Join([]string{identity.Group, identity.Version, identity.Resource, identity.Namespace, identity.Name, identity.UID}, "\x00")
		if _, duplicate := seen[key]; duplicate {
			return &ValidationError{Field: fmt.Sprintf("targets[%d]", absoluteIndex), Message: "delete target is duplicated"}
		}
		seen[key] = struct{}{}
		*targets = append(*targets, DeleteTarget{Identity: identity})
		*identities = append(*identities, identity)
	}
	return nil
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

func deleteManyOptionsFromProto(request *kmgrv1.DeleteManyStart) (DeleteOptions, error) {
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
	if options.MaxConcurrency < 0 || options.MaxConcurrency > MaxDeleteConcurrency {
		return DeleteOptions{}, &ValidationError{
			Field: "max_concurrency", Message: fmt.Sprintf("delete concurrency must be between 0 and %d", MaxDeleteConcurrency),
		}
	}
	return options, nil
}

func deleteSelectionOptionsFromProto(request *kmgrv1.DeleteSelectionRequest) (DeleteOptions, error) {
	options := DeleteOptions{MaxConcurrency: int(request.GetMaxConcurrency())}
	switch request.GetPropagationPolicy() {
	case kmgrv1.PropagationPolicy_PROPAGATION_POLICY_BACKGROUND:
		options.PropagationPolicy = metav1.DeletePropagationBackground
	case kmgrv1.PropagationPolicy_PROPAGATION_POLICY_FOREGROUND:
		options.PropagationPolicy = metav1.DeletePropagationForeground
	case kmgrv1.PropagationPolicy_PROPAGATION_POLICY_ORPHAN:
		options.PropagationPolicy = metav1.DeletePropagationOrphan
	default:
		return DeleteOptions{}, &ValidationError{
			Field: "propagation_policy", Message: "delete propagation policy is required",
		}
	}
	if request.GracePeriodSeconds != nil {
		grace := request.GetGracePeriodSeconds()
		if grace < 0 {
			return DeleteOptions{}, &ValidationError{
				Field: "grace_period_seconds", Message: "grace period must not be negative",
			}
		}
		options.GracePeriodSeconds = &grace
	}
	if options.MaxConcurrency < 0 || options.MaxConcurrency > MaxDeleteConcurrency {
		return DeleteOptions{}, &ValidationError{
			Field: "max_concurrency", Message: fmt.Sprintf(
				"delete concurrency must be between 0 and %d", MaxDeleteConcurrency,
			),
		}
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
	if proto.Size(value) > maxResourceIdentityBytes {
		return object.Identity{}, fmt.Errorf("resource identity exceeds the %d-byte budget", maxResourceIdentityBytes)
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

func structuredOperationError(
	err error,
	identity *kmgrv1.ResourceIdentity,
	operation string,
	contextNames ...string,
) *kmgrv1.StructuredError {
	result := &kmgrv1.StructuredError{
		Category: kmgrv1.ErrorCategory_ERROR_CATEGORY_INTERNAL, Reason: "OperationFailed",
		Message: "The Kubernetes operation failed.", Operation: operation, Resource: identity,
	}
	if len(contextNames) > 0 {
		result.ContextName = contextNames[0]
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
	case errors.Is(err, object.ErrYAMLForceOwnershipUnsupported):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_UNSUPPORTED
		result.Reason = "YAMLForceOwnershipUnsupported"
		result.Message = "Force field ownership is unavailable for YAML edits. Save without forcing ownership."
		result.FieldPath = "force_field_ownership"
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
	if proto.Size(result) > maxStructuredOperationError {
		return &kmgrv1.StructuredError{
			Category: result.GetCategory(), Reason: "OperationErrorDetailsOmitted",
			Message:   "The Kubernetes error exceeded the safe display budget; oversized details were omitted.",
			Retryable: result.GetRetryable(), HttpStatusCode: result.GetHttpStatusCode(),
			ContextName: result.GetContextName(), Operation: result.GetOperation(), Resource: result.GetResource(),
		}
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
