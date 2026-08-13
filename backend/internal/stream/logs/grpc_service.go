package logs

import (
	"context"
	"errors"
	"slices"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
)

var _ kmgrv1.LogServiceServer = (*GRPCService)(nil)

type ClusterResolver struct {
	Sessions *cluster.SessionRegistry
}

func (r ClusterResolver) Resolve(sessionID string) (ResolvedSession, error) {
	if r.Sessions == nil {
		return ResolvedSession{}, ErrSessionNotFound
	}
	session, ok := r.Sessions.Get(sessionID)
	if !ok {
		return ResolvedSession{}, ErrSessionNotFound
	}
	if session.Core() == nil {
		return ResolvedSession{}, ErrLogClientUnavailable
	}
	return ResolvedSession{
		ContextName: session.Context().Name,
		Opener:      ClientGoSource{Core: session.Core()},
	}, nil
}

type GRPCService struct {
	kmgrv1.UnimplementedLogServiceServer
	manager *Manager
}

func NewGRPCService(manager *Manager) (*GRPCService, error) {
	if manager == nil {
		return nil, errors.New("log stream manager must not be nil")
	}
	return &GRPCService{manager: manager}, nil
}

func (s *GRPCService) StreamLogs(
	request *kmgrv1.StartLogsRequest,
	stream grpc.ServerStreamingServer[kmgrv1.LogEvent],
) error {
	if request == nil || stream == nil {
		return status.Error(codes.InvalidArgument, "request and stream are required")
	}
	operationContext, cancel, err := logRequestContext(stream.Context(), request.GetContext())
	if err != nil {
		return err
	}
	defer cancel()
	start, err := startFromProto(request)
	if err != nil {
		return logStatusError(err)
	}
	subscription, err := s.manager.Start(operationContext, start)
	if err != nil {
		return logStatusError(err)
	}
	defer subscription.Close()

	var sequence uint64
	for {
		delivery, err := subscription.Next(operationContext)
		if err != nil {
			switch {
			case errors.Is(err, ErrStreamClosed):
				return nil
			case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
				return logStatusError(err)
			default:
				return status.Error(codes.Internal, "log delivery failed")
			}
		}
		sequence++
		event := &kmgrv1.LogEvent{Cursor: &kmgrv1.StreamCursor{
			StreamId: request.GetLogStreamId(), Generation: request.GetGeneration(), Sequence: sequence,
		}}
		if delivery.Status != nil {
			event.Payload = &kmgrv1.LogEvent_Status{Status: statusToProto(*delivery.Status, subscription.ContextName())}
		} else {
			batch := &kmgrv1.LogBatch{TotalBytes: delivery.TotalBytes, Records: make([]*kmgrv1.LogRecord, 0, len(delivery.Records))}
			for _, record := range delivery.Records {
				converted := &kmgrv1.LogRecord{
					SourceId: record.SourceID, Data: slices.Clone(record.Data), EndsWithNewline: record.EndsWithNewline,
				}
				if !record.Timestamp.IsZero() {
					converted.TimestampUnixMs = record.Timestamp.UnixMilli()
				}
				batch.Records = append(batch.Records, converted)
			}
			event.Payload = &kmgrv1.LogEvent_Batch{Batch: batch}
		}
		if err := stream.Send(event); err != nil {
			return err
		}
		if delivery.Status != nil && delivery.Status.SourceID == "" && isTerminal(delivery.Status.State) {
			return nil
		}
	}
}

func (s *GRPCService) CancelLogs(
	ctx context.Context,
	request *kmgrv1.CancelLogsRequest,
) (*kmgrv1.Acknowledgement, error) {
	if request == nil || request.GetLogStreamId() == "" || request.GetGeneration() == 0 {
		return nil, status.Error(codes.InvalidArgument, "request, stream ID, and generation are required")
	}
	operationContext, cancel, err := logRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	if err := operationContext.Err(); err != nil {
		return nil, logStatusError(err)
	}
	accepted := s.manager.Cancel(
		request.GetContext().GetClusterSessionId(), request.GetLogStreamId(), request.GetGeneration(),
	)
	return &kmgrv1.Acknowledgement{
		RequestId: request.GetContext().GetRequestId(), Accepted: accepted,
	}, nil
}

func startFromProto(request *kmgrv1.StartLogsRequest) (StartRequest, error) {
	if request.GetOptions().GetFollowWorkloadMembership() {
		return StartRequest{}, status.Error(codes.Unimplemented, "dynamic workload log membership is not implemented")
	}
	requestContext := request.GetContext()
	result := StartRequest{
		SessionID: requestContext.GetClusterSessionId(), StreamID: request.GetLogStreamId(), Generation: request.GetGeneration(),
		Sources: make([]Source, 0, len(request.GetSources())),
		Options: Options{
			Follow: request.GetOptions().GetFollow(), Previous: request.GetOptions().GetPrevious(),
			Timestamps: request.GetOptions().GetTimestamps(),
		},
	}
	options := request.GetOptions()
	if options != nil && options.SinceUnixMs != nil {
		value := time.UnixMilli(options.GetSinceUnixMs())
		result.Options.SinceTime = &value
	}
	if options != nil && options.SinceSeconds != nil {
		value := options.GetSinceSeconds()
		result.Options.SinceSeconds = &value
	}
	if options != nil && options.TailLines != nil {
		value := options.GetTailLines()
		result.Options.TailLines = &value
	}
	if options != nil && options.ByteLimit != nil {
		value := options.GetByteLimit()
		result.Options.ByteLimit = &value
	}
	for _, source := range request.GetSources() {
		if source == nil || source.GetIdentity() == nil {
			return StartRequest{}, ErrInvalidRequest
		}
		identity := source.GetIdentity()
		result.Sources = append(result.Sources, Source{
			Identity: Identity{
				SessionID: identity.GetClusterSessionId(), Group: identity.GetGroup(), Version: identity.GetVersion(),
				Resource: identity.GetResource(), Namespace: identity.GetNamespace(), Name: identity.GetName(), UID: identity.GetUid(),
			},
			ID: source.GetSourceId(), Label: source.GetSourceLabel(), Container: source.GetContainer(),
		})
	}
	return result, nil
}

func logRequestContext(
	ctx context.Context,
	request *kmgrv1.RequestContext,
) (context.Context, context.CancelFunc, error) {
	if request == nil || request.GetRequestId() == "" || request.GetClusterSessionId() == "" {
		return nil, nil, status.Error(codes.InvalidArgument, "request ID and cluster session ID are required")
	}
	if request.GetDeadlineUnixMs() == 0 {
		derived, cancel := context.WithCancel(ctx)
		return derived, cancel, nil
	}
	deadline := time.UnixMilli(request.GetDeadlineUnixMs())
	if !deadline.After(time.Now()) {
		return nil, nil, status.Error(codes.DeadlineExceeded, "request deadline exceeded")
	}
	derived, cancel := context.WithDeadline(ctx, deadline)
	return derived, cancel, nil
}

func statusToProto(value Status, contextName string) *kmgrv1.LogStatus {
	result := &kmgrv1.LogStatus{
		State: stateToProto(value.State), SourceId: value.SourceID,
		DroppedRecords: value.DroppedRecords, DroppedBytes: value.DroppedBytes,
	}
	if value.Err != nil {
		result.Error = structuredLogError(value.Err, value.Source, contextName)
	}
	return result
}

func stateToProto(value State) kmgrv1.LogStreamState {
	switch value {
	case StateConnecting:
		return kmgrv1.LogStreamState_LOG_STREAM_STATE_CONNECTING
	case StateStreaming:
		return kmgrv1.LogStreamState_LOG_STREAM_STATE_STREAMING
	case StateCompleted:
		return kmgrv1.LogStreamState_LOG_STREAM_STATE_COMPLETED
	case StateCancelled:
		return kmgrv1.LogStreamState_LOG_STREAM_STATE_CANCELLED
	case StateFailed:
		return kmgrv1.LogStreamState_LOG_STREAM_STATE_FAILED
	default:
		return kmgrv1.LogStreamState_LOG_STREAM_STATE_UNSPECIFIED
	}
}

func isTerminal(value State) bool {
	return value == StateCompleted || value == StateCancelled || value == StateFailed
}

func logStatusError(err error) error {
	switch {
	case err == nil:
		return nil
	case status.Code(err) != codes.Unknown:
		return err
	case errors.Is(err, ErrInvalidRequest):
		return status.Error(codes.InvalidArgument, err.Error())
	case errors.Is(err, ErrSessionNotFound):
		return status.Error(codes.NotFound, "cluster session was not found")
	case errors.Is(err, ErrStaleGeneration):
		return status.Error(codes.FailedPrecondition, err.Error())
	case errors.Is(err, ErrTooManyStreams):
		return status.Error(codes.ResourceExhausted, "too many active log streams")
	case errors.Is(err, ErrLogClientUnavailable):
		return status.Error(codes.FailedPrecondition, "Kubernetes Pod log client is unavailable")
	case errors.Is(err, context.Canceled):
		return status.Error(codes.Canceled, "log stream cancelled")
	case errors.Is(err, context.DeadlineExceeded):
		return status.Error(codes.DeadlineExceeded, "log stream deadline exceeded")
	default:
		return status.Error(codes.Internal, "log stream failed")
	}
}

func structuredLogError(err error, source *Source, contextName string) *kmgrv1.StructuredError {
	result := &kmgrv1.StructuredError{
		Category: kmgrv1.ErrorCategory_ERROR_CATEGORY_INTERNAL,
		Reason:   "PodLogFailed", Message: "The Kubernetes Pod log request failed.",
		ContextName: contextName, Operation: "stream-pod-logs",
	}
	if source != nil {
		identity := source.Identity
		result.Resource = &kmgrv1.ResourceIdentity{
			ClusterSessionId: identity.SessionID, Group: identity.Group, Version: identity.Version,
			Resource: identity.Resource, Namespace: identity.Namespace, Name: identity.Name, Uid: identity.UID,
		}
	}
	var uidMismatch *UIDMismatchError
	var apiStatus apierrors.APIStatus
	switch {
	case errors.As(err, &uidMismatch):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT
		result.Reason = "PodRecreated"
		result.Message = "The selected Pod was replaced before its log stream opened."
		result.SafeDetails = map[string]string{"expected_uid": uidMismatch.Expected, "current_uid": uidMismatch.Actual}
	case apierrors.IsNotFound(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND
		result.Reason = "PodNotFound"
		result.Message = "The selected Pod or requested previous log was not found."
	case apierrors.IsUnauthorized(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHENTICATION
		result.Reason = "AuthenticationRejected"
		result.Message = "The Kubernetes API server rejected the configured credentials."
	case apierrors.IsForbidden(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHORIZATION
		result.Reason = "Forbidden"
		result.Message = "The configured identity is not authorized to read these Pod logs."
	case errors.Is(err, context.DeadlineExceeded):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_TIMEOUT
		result.Reason = "LogRequestTimedOut"
		result.Message = "The Pod log request timed out."
		result.Retryable = true
	case errors.Is(err, context.Canceled):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CANCELLED
		result.Reason = "LogRequestCancelled"
		result.Message = "The Pod log request was cancelled."
	case errors.As(err, &apiStatus):
		value := apiStatus.Status()
		result.HttpStatusCode = value.Code
		result.Reason = string(value.Reason)
		result.Retryable = value.Code == 408 || value.Code == 429 || value.Code >= 500
	}
	return result
}
