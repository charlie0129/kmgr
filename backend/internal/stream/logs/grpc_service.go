package logs

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/kubeerrors"
	"github.com/charlie0129/kmgr/backend/internal/podidentity"
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
	session, lease, ok := r.Sessions.Acquire(sessionID)
	if !ok {
		return ResolvedSession{}, ErrSessionNotFound
	}
	if session.Core() == nil || session.Metadata() == nil {
		lease.Release()
		return ResolvedSession{}, ErrLogClientUnavailable
	}
	return ResolvedSession{
		ContextName: session.Context().Name,
		Opener: ClientGoSource{
			Core: session.Core(), PodUIDs: podidentity.MetadataGetter{Client: session.Metadata()},
		},
		Release: lease.Release,
	}, nil
}

type GRPCService struct {
	kmgrv1.UnimplementedLogServiceServer
	manager  *Manager
	resolver WorkloadSourceResolver
}

func NewGRPCService(manager *Manager, resolvers ...WorkloadSourceResolver) (*GRPCService, error) {
	if manager == nil {
		return nil, errors.New("log stream manager must not be nil")
	}
	if len(resolvers) > 1 {
		return nil, errors.New("at most one workload log resolver may be configured")
	}
	service := &GRPCService{manager: manager}
	if len(resolvers) == 1 {
		service.resolver = resolvers[0]
	}
	return service, nil
}

func (s *GRPCService) ResolveLogSources(
	ctx context.Context,
	request *kmgrv1.ResolveLogSourcesRequest,
) (*kmgrv1.ResolveLogSourcesResponse, error) {
	if request == nil || request.GetContext() == nil {
		return nil, status.Error(codes.InvalidArgument, "request context is required")
	}
	operationContext, cancel, err := logRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	if s.resolver == nil {
		return nil, status.Error(codes.FailedPrecondition, "workload log resolution is unavailable")
	}
	if len(request.GetResources()) == 0 || len(request.GetResources()) > DefaultMaxResolvedPods {
		return nil, status.Errorf(
			codes.InvalidArgument,
			"resource count must be between 1 and %d",
			DefaultMaxResolvedPods,
		)
	}
	identities := make([]Identity, 0, len(request.GetResources()))
	for _, value := range request.GetResources() {
		identity, identityErr := resolutionIdentityFromProto(
			value, request.GetContext().GetClusterSessionId(),
		)
		if identityErr != nil {
			return nil, status.Error(codes.InvalidArgument, identityErr.Error())
		}
		identities = append(identities, identity)
	}
	resolved, err := s.resolver.Resolve(
		operationContext,
		request.GetContext().GetClusterSessionId(),
		identities,
		DefaultMaxResolvedPods,
	)
	response := &kmgrv1.ResolveLogSourcesResponse{RequestId: request.GetContext().GetRequestId()}
	if err != nil {
		response.Error = structuredResolutionError(err, request.GetResources(), "resolve-workload-logs")
		return response, nil
	}
	response.StaticWorkloadSnapshot = resolved.StaticWorkloadSnapshot
	response.Pods = make([]*kmgrv1.ResolvedPodLogSource, 0, len(resolved.Pods))
	for _, pod := range resolved.Pods {
		response.Pods = append(response.Pods, &kmgrv1.ResolvedPodLogSource{
			Identity: &kmgrv1.ResourceIdentity{
				ClusterSessionId: pod.Identity.SessionID,
				Group:            pod.Identity.Group,
				Version:          pod.Identity.Version,
				Resource:         pod.Identity.Resource,
				Namespace:        pod.Identity.Namespace,
				Name:             pod.Identity.Name,
				Uid:              pod.Identity.UID,
			},
			Containers: slices.Clone(pod.Containers),
		})
	}
	return response, nil
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
					SourceId: record.SourceID, Data: slices.Clone(record.Data), ContinuesLine: !record.StartsLine,
					EndsWithNewline: record.EndsWithNewline,
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
			// Keep the RPC—and therefore its independent cluster-session
			// lease—alive for the log window. A replacement generation can
			// reuse that authority even after the workspace has closed.
			select {
			case <-subscription.Done():
				return nil
			case <-stream.Context().Done():
				return logStatusError(stream.Context().Err())
			}
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

func resolutionIdentityFromProto(value *kmgrv1.ResourceIdentity, sessionID string) (Identity, error) {
	if value == nil || sessionID == "" || value.GetClusterSessionId() != sessionID ||
		value.GetVersion() == "" || value.GetResource() == "" || value.GetNamespace() == "" ||
		value.GetName() == "" || value.GetUid() == "" {
		return Identity{}, fmt.Errorf("%w: every resource must be a complete namespaced identity in this session", ErrInvalidRequest)
	}
	if len(value.GetGroup()) > 253 || len(value.GetVersion()) > 63 || len(value.GetResource()) > 253 ||
		len(value.GetNamespace()) > 253 || len(value.GetName()) > 253 || len(value.GetUid()) > 256 {
		return Identity{}, fmt.Errorf("%w: resource identity field is too long", ErrInvalidRequest)
	}
	return Identity{
		SessionID: sessionID,
		Group:     value.GetGroup(),
		Version:   value.GetVersion(),
		Resource:  value.GetResource(),
		Namespace: value.GetNamespace(),
		Name:      value.GetName(),
		UID:       value.GetUid(),
	}, nil
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
	kubeerrors.Enrich(result, err)
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

func structuredResolutionError(
	err error,
	requested []*kmgrv1.ResourceIdentity,
	operation string,
) *kmgrv1.StructuredError {
	result := &kmgrv1.StructuredError{
		Category:  kmgrv1.ErrorCategory_ERROR_CATEGORY_INTERNAL,
		Reason:    "WorkloadLogResolutionFailed",
		Message:   "The selected resources could not be resolved to a UID-pinned Pod snapshot.",
		Operation: operation,
	}
	if len(requested) > 0 && requested[0] != nil {
		result.Resource = requested[0]
	}
	kubeerrors.Enrich(result, err)
	var tooMany *TooManyResolvedPodsError
	var scanLimit *ResolutionScanLimitError
	var requestLimit *ResolutionRequestLimitError
	var unsupported *UnsupportedLogResourceError
	var uidMismatch *ResolutionUIDMismatchError
	var apiStatus apierrors.APIStatus
	switch {
	case errors.As(err, &tooMany):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_RESOURCE_EXHAUSTED
		result.Reason = "TooManyResolvedPods"
		result.Message = fmt.Sprintf(
			"The selected resources resolve to more than %d Pods. Select a narrower workload or a smaller Pod subset.",
			tooMany.Limit,
		)
		result.SafeDetails = map[string]string{"maximum_pods": fmt.Sprint(tooMany.Limit)}
	case errors.As(err, &requestLimit):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_RESOURCE_EXHAUSTED
		result.Reason = "WorkloadResolutionRequestLimit"
		result.Message = "The static workload snapshot required too many Kubernetes API requests. Select fewer workloads or select Pods directly."
		result.SafeDetails = map[string]string{
			"api_call_limit": fmt.Sprint(requestLimit.Limit),
		}
	case errors.As(err, &scanLimit):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_RESOURCE_EXHAUSTED
		result.Reason = "WorkloadResolutionTooBroad"
		result.Message = "The static workload snapshot was too broad to resolve safely. Select Pods directly or narrow the workload."
		result.SafeDetails = map[string]string{
			"resource":              scanLimit.Resource,
			"examined_object_limit": fmt.Sprint(scanLimit.Limit),
		}
	case errors.As(err, &unsupported):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION
		result.Reason = "UnsupportedLogResource"
		result.Message = "Logs are available for Pods and supported workload controllers only."
		result.Resource = &kmgrv1.ResourceIdentity{
			ClusterSessionId: unsupported.Identity.SessionID,
			Group:            unsupported.Identity.Group,
			Version:          unsupported.Identity.Version,
			Resource:         unsupported.Identity.Resource,
			Namespace:        unsupported.Identity.Namespace,
			Name:             unsupported.Identity.Name,
			Uid:              unsupported.Identity.UID,
		}
	case errors.As(err, &uidMismatch):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT
		result.Reason = "ResourceRecreated"
		result.Message = "A selected resource was replaced before its Pod snapshot could be resolved. Select it again and reopen Logs."
		result.Resource = &kmgrv1.ResourceIdentity{
			ClusterSessionId: uidMismatch.Identity.SessionID,
			Group:            uidMismatch.Identity.Group,
			Version:          uidMismatch.Identity.Version,
			Resource:         uidMismatch.Identity.Resource,
			Namespace:        uidMismatch.Identity.Namespace,
			Name:             uidMismatch.Identity.Name,
			Uid:              uidMismatch.Identity.UID,
		}
		result.SafeDetails = map[string]string{
			"expected_uid": uidMismatch.Identity.UID,
			"current_uid":  uidMismatch.Actual,
		}
	case errors.Is(err, ErrSessionNotFound):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND
		result.Reason = "ClusterSessionNotFound"
		result.Message = "The cluster session closed before workload logs could be resolved."
	case errors.Is(err, ErrWorkloadResolutionUnavailable):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_INTERNAL
		result.Reason = "WorkloadResolutionUnavailable"
		result.Message = "The cluster session cannot resolve workload Pods."
	case apierrors.IsNotFound(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND
		result.Reason = "ResourceNotFound"
		result.Message = "A selected resource no longer exists. Select it again and reopen Logs."
	case apierrors.IsUnauthorized(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHENTICATION
		result.Reason = "AuthenticationRejected"
		result.Message = "The Kubernetes API server rejected the configured credentials."
	case apierrors.IsForbidden(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHORIZATION
		result.Reason = "Forbidden"
		result.Message = "The configured identity is not authorized to resolve this workload's Pods."
	case errors.Is(err, context.DeadlineExceeded):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_TIMEOUT
		result.Reason = "WorkloadResolutionTimedOut"
		result.Message = "Resolving the workload's Pod snapshot timed out."
		result.Retryable = true
	case errors.Is(err, context.Canceled):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CANCELLED
		result.Reason = "WorkloadResolutionCancelled"
		result.Message = "Resolving workload logs was cancelled."
	case errors.As(err, &apiStatus):
		value := apiStatus.Status()
		result.HttpStatusCode = value.Code
		result.Reason = string(value.Reason)
		result.Retryable = value.Code == 408 || value.Code == 429 || value.Code >= 500
	}
	return result
}
