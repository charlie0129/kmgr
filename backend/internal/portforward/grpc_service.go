package portforward

import (
	"context"
	"errors"
	"fmt"
	"net"
	"slices"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/kubeerrors"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/types"
)

var _ kmgrv1.PortForwardServiceServer = (*GRPCService)(nil)

type GRPCService struct {
	kmgrv1.UnimplementedPortForwardServiceServer
	manager *Manager
}

func NewGRPCService(manager *Manager) (*GRPCService, error) {
	if manager == nil {
		return nil, errors.New("port-forward manager must not be nil")
	}
	return &GRPCService{manager: manager}, nil
}

func (s *GRPCService) Start(
	ctx context.Context,
	request *kmgrv1.StartPortForwardRequest,
) (*kmgrv1.StartPortForwardResponse, error) {
	requestID, operationContext, cancel, err := portForwardRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	if err := operationContext.Err(); err != nil {
		return nil, portForwardStatusError(err)
	}
	response := &kmgrv1.StartPortForwardResponse{RequestId: requestID, PortForwardId: request.GetPortForwardId()}
	start, err := startFromProto(request)
	if err != nil {
		response.Error = structuredPortForwardError(err, request.GetTarget(), "start-port-forward", "")
		return response, nil
	}
	_, err = s.manager.Start(start)
	if err != nil {
		response.Error = structuredPortForwardError(err, request.GetTarget(), "start-port-forward", "")
		return response, nil
	}
	response.Accepted = true
	return response, nil
}

func (s *GRPCService) Stop(
	ctx context.Context,
	request *kmgrv1.StopPortForwardRequest,
) (*kmgrv1.Acknowledgement, error) {
	requestID, operationContext, cancel, err := portForwardRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	if request.GetPortForwardId() == "" {
		return nil, status.Error(codes.InvalidArgument, "port-forward ID is required")
	}
	if err := operationContext.Err(); err != nil {
		return nil, portForwardStatusError(err)
	}
	return &kmgrv1.Acknowledgement{
		RequestId: requestID,
		Accepted:  s.manager.Stop(request.GetPortForwardId(), request.GetContext().GetClusterSessionId()),
	}, nil
}

func (s *GRPCService) Restart(
	ctx context.Context,
	request *kmgrv1.RestartPortForwardRequest,
) (*kmgrv1.Acknowledgement, error) {
	requestID, operationContext, cancel, err := portForwardRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	if request.GetPortForwardId() == "" {
		return nil, status.Error(codes.InvalidArgument, "port-forward ID is required")
	}
	if err := operationContext.Err(); err != nil {
		return nil, portForwardStatusError(err)
	}
	return &kmgrv1.Acknowledgement{
		RequestId: requestID,
		Accepted:  s.manager.Restart(request.GetPortForwardId(), request.GetContext().GetClusterSessionId()),
	}, nil
}

func (s *GRPCService) List(
	ctx context.Context,
	request *kmgrv1.ListPortForwardsRequest,
) (*kmgrv1.ListPortForwardsResponse, error) {
	requestID, operationContext, cancel, err := portForwardRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	if err := operationContext.Err(); err != nil {
		return nil, portForwardStatusError(err)
	}
	values := s.manager.List("", request.GetIncludeStopped())
	response := &kmgrv1.ListPortForwardsResponse{
		RequestId: requestID, PortForwards: make([]*kmgrv1.PortForward, 0, len(values)),
	}
	for _, value := range values {
		response.PortForwards = append(response.PortForwards, snapshotToProto(value))
	}
	return response, nil
}

func (s *GRPCService) Watch(
	request *kmgrv1.WatchPortForwardsRequest,
	stream grpc.ServerStreamingServer[kmgrv1.PortForwardEvent],
) error {
	if request == nil || stream == nil || request.GetContext() == nil ||
		request.GetContext().GetRequestId() == "" || request.GetContext().GetClusterSessionId() == "" ||
		request.GetStreamId() == "" || request.GetGeneration() == 0 {
		return status.Error(codes.InvalidArgument, "request context, stream ID, and generation are required")
	}
	updates, unsubscribe := s.manager.Subscribe()
	defer unsubscribe()
	sequence := uint64(1)
	initial := s.manager.List("", request.GetIncludeStopped())
	event := &kmgrv1.PortForwardEvent{
		Cursor: &kmgrv1.StreamCursor{
			StreamId: request.GetStreamId(), Generation: request.GetGeneration(), Sequence: sequence,
		},
		Delta: &kmgrv1.PortForwardDelta{Upserts: make([]*kmgrv1.PortForward, 0, len(initial))},
	}
	for _, value := range initial {
		event.Delta.Upserts = append(event.Delta.Upserts, snapshotToProto(value))
	}
	if err := stream.Send(event); err != nil {
		return err
	}
	for {
		select {
		case <-stream.Context().Done():
			return stream.Context().Err()
		case value := <-updates:
			sequence++
			delta := &kmgrv1.PortForwardDelta{}
			if value.State == StateStopped && !request.GetIncludeStopped() {
				delta.RemovedPortForwardIds = []string{value.ID}
			} else {
				delta.Upserts = []*kmgrv1.PortForward{snapshotToProto(value)}
			}
			if err := stream.Send(&kmgrv1.PortForwardEvent{
				Cursor: &kmgrv1.StreamCursor{
					StreamId: request.GetStreamId(), Generation: request.GetGeneration(), Sequence: sequence,
				},
				Delta: delta,
			}); err != nil {
				return err
			}
		}
	}
}

func startFromProto(request *kmgrv1.StartPortForwardRequest) (StartRequest, error) {
	if request == nil || request.GetContext() == nil || request.GetTarget() == nil ||
		request.GetRemotePort() == 0 || request.GetRemotePort() > 65535 || request.GetLocalPort() > 65535 {
		return StartRequest{}, ErrInvalidRequest
	}
	target := request.GetTarget()
	if target.GetClusterSessionId() != "" && target.GetClusterSessionId() != request.GetContext().GetClusterSessionId() {
		return StartRequest{}, fmt.Errorf("%w: target belongs to another cluster session", ErrInvalidRequest)
	}
	return StartRequest{
		ID: request.GetPortForwardId(),
		Target: Identity{
			SessionID: request.GetContext().GetClusterSessionId(), Group: target.GetGroup(), Version: target.GetVersion(),
			Resource: target.GetResource(), Namespace: target.GetNamespace(), Name: target.GetName(), UID: types.UID(target.GetUid()),
		},
		RemotePort: uint16(request.GetRemotePort()), LocalPort: uint16(request.GetLocalPort()),
		BindAddress: request.GetBindAddress(), Label: request.GetLabel(), AllowNonLoopback: request.GetAllowNonLoopback(),
	}, nil
}

func snapshotToProto(value Snapshot) *kmgrv1.PortForward {
	result := &kmgrv1.PortForward{
		PortForwardId: value.ID, ClusterSessionId: value.Target.SessionID, ContextName: value.ContextName,
		Target: identityToProto(value.Target), RemotePort: uint32(value.RemotePort), LocalPort: uint32(value.LocalPort),
		BindAddress: value.BindAddress, Label: value.Label, State: stateToProto(value.State),
		StartedAtUnixMs: value.StartedAt.UnixMilli(), UpdatedAtUnixMs: value.UpdatedAt.UnixMilli(),
	}
	if value.ResolvedPod != nil {
		result.ResolvedPod = identityToProto(*value.ResolvedPod)
	}
	if value.LastError != nil {
		result.LastError = structuredPortForwardError(
			value.LastError, result.Target, "port-forward", value.ContextName,
		)
	}
	if value.NonLoopbackBind {
		if result.LastError == nil {
			result.LastError = &kmgrv1.StructuredError{
				Category: kmgrv1.ErrorCategory_ERROR_CATEGORY_UNSPECIFIED, Reason: "NonLoopbackBind",
				Message: "This port-forward is accessible beyond the local machine.", Operation: "port-forward",
				Resource: result.Target,
			}
		}
		if result.LastError.SafeDetails == nil {
			result.LastError.SafeDetails = make(map[string]string)
		}
		result.LastError.SafeDetails["exposure_warning"] = "non_loopback_bind"
	}
	return result
}

func identityToProto(value Identity) *kmgrv1.ResourceIdentity {
	return &kmgrv1.ResourceIdentity{
		ClusterSessionId: value.SessionID, Group: value.Group, Version: value.Version, Resource: value.Resource,
		Namespace: value.Namespace, Name: value.Name, Uid: string(value.UID),
	}
}

func stateToProto(value State) kmgrv1.PortForwardState {
	switch value {
	case StateStarting:
		return kmgrv1.PortForwardState_PORT_FORWARD_STATE_STARTING
	case StateListening:
		return kmgrv1.PortForwardState_PORT_FORWARD_STATE_LISTENING
	case StateReconnecting:
		return kmgrv1.PortForwardState_PORT_FORWARD_STATE_RECONNECTING
	case StateFailed:
		return kmgrv1.PortForwardState_PORT_FORWARD_STATE_FAILED
	case StateStopped:
		return kmgrv1.PortForwardState_PORT_FORWARD_STATE_STOPPED
	default:
		return kmgrv1.PortForwardState_PORT_FORWARD_STATE_UNSPECIFIED
	}
}

func portForwardRequestContext(
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

func portForwardStatusError(err error) error {
	switch {
	case errors.Is(err, context.Canceled):
		return status.Error(codes.Canceled, "port-forward request was cancelled")
	case errors.Is(err, context.DeadlineExceeded):
		return status.Error(codes.DeadlineExceeded, "port-forward request deadline exceeded")
	default:
		return status.Error(codes.Internal, "port-forward request failed")
	}
}

func structuredPortForwardError(
	err error,
	identity *kmgrv1.ResourceIdentity,
	operation, contextName string,
) *kmgrv1.StructuredError {
	result := &kmgrv1.StructuredError{
		Category: kmgrv1.ErrorCategory_ERROR_CATEGORY_INTERNAL, Reason: "PortForwardFailed",
		Message: "The Kubernetes port-forward failed.", Operation: operation, ContextName: contextName,
		Resource: identity,
	}
	kubeerrors.Enrich(result, err)
	var apiStatus apierrors.APIStatus
	switch {
	case errors.Is(err, ErrInvalidRequest):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION
		result.Reason, result.Message = "InvalidPortForward", err.Error()
	case errors.Is(err, ErrNonLoopbackUnapproved):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION
		result.Reason = "NonLoopbackApprovalRequired"
		result.Message = "Binding outside loopback requires explicit confirmation."
		result.SafeDetails = map[string]string{"exposure_warning": "non_loopback_bind"}
	case errors.Is(err, ErrDuplicatePortForward):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT
		result.Reason, result.Message = "DuplicatePortForwardID", "That port-forward ID is already active or retained."
	case errors.Is(err, ErrSessionNotFound):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND
		result.Reason, result.Message = "SessionNotFound", "The cluster session is no longer open."
	case errors.Is(err, ErrPodRecreated):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT
		result.Reason, result.Message = "PodRecreated", "The selected Pod was replaced; this UID-pinned forward will not switch automatically."
	case errors.Is(err, ErrNoEligiblePod):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE
		result.Reason, result.Message, result.Retryable = "NoEligiblePod", "The Service has no eligible Ready backing Pod.", true
	case apierrors.IsNotFound(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND
		result.Reason, result.Message = "TargetNotFound", "The selected Pod or Service no longer exists."
	case apierrors.IsUnauthorized(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHENTICATION
		result.Reason, result.Message = "AuthenticationRejected", "The API server rejected the configured credentials."
	case apierrors.IsForbidden(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHORIZATION
		result.Reason, result.Message = "Forbidden", "The configured identity is not authorized to port-forward this target."
	case errors.Is(err, context.Canceled):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CANCELLED
		result.Reason, result.Message = "PortForwardStopped", "The port-forward was stopped."
	case errors.Is(err, context.DeadlineExceeded):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_TIMEOUT
		result.Reason, result.Message, result.Retryable = "PortForwardTimedOut", "The port-forward attempt timed out.", true
	case errors.As(err, &apiStatus):
		value := apiStatus.Status()
		result.HttpStatusCode, result.Reason = value.Code, string(value.Reason)
		result.Retryable = slices.Contains([]int32{408, 429, 500, 502, 503, 504}, value.Code)
	}
	var networkError net.Error
	if errors.As(err, &networkError) {
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE
		result.Reason, result.Message, result.Retryable = "NetworkUnavailable", "The port-forward connection was interrupted.", true
	}
	return result
}
