package execstream

import (
	"context"
	"errors"
	"fmt"
	"io"
	"slices"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/kubeerrors"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
)

var _ kmgrv1.ExecServiceServer = (*GRPCService)(nil)

type ClusterResolver struct {
	Sessions        *cluster.SessionRegistry
	ExecutorFactory ExecutorFactory
}

func (r ClusterResolver) Resolve(sessionID string) (ResolvedSession, error) {
	if r.Sessions == nil {
		return ResolvedSession{}, ErrSessionNotFound
	}
	session, lease, ok := r.Sessions.Acquire(sessionID)
	if !ok {
		return ResolvedSession{}, ErrSessionNotFound
	}
	config := session.RESTConfig()
	if session.Core() == nil || config == nil {
		lease.Release()
		return ResolvedSession{}, ErrExecutorUnavailable
	}
	return ResolvedSession{
		ContextName: session.Context().Name,
		Runner: ClientGoRunner{
			Core: session.Core(), Config: config, ExecutorFactory: r.ExecutorFactory,
		},
		Release: lease.Release,
	}, nil
}

type GRPCService struct {
	kmgrv1.UnimplementedExecServiceServer
	manager *Manager
}

func NewGRPCService(manager *Manager) (*GRPCService, error) {
	if manager == nil {
		return nil, errors.New("exec manager must not be nil")
	}
	return &GRPCService{manager: manager}, nil
}

type receiveResult struct {
	err  error
	done bool
}

type deliveryResult struct {
	delivery Delivery
	err      error
}

func (s *GRPCService) Exec(stream grpc.BidiStreamingServer[kmgrv1.ExecClientMessage, kmgrv1.ExecServerMessage]) error {
	if stream == nil {
		return status.Error(codes.InvalidArgument, "exec stream is required")
	}
	first, err := stream.Recv()
	if err != nil {
		if errors.Is(err, io.EOF) {
			return status.Error(codes.InvalidArgument, "the first message must start an exec session")
		}
		return err
	}
	request, err := startFromProto(first)
	if err != nil {
		return execStatusError(err)
	}
	rpcContext, cancel, err := execRequestContext(stream.Context(), first.GetStart().GetContext())
	if err != nil {
		return err
	}
	defer cancel()
	session, err := s.manager.Start(rpcContext, request)
	if err != nil {
		return execStatusError(err)
	}
	defer session.Close()

	receiveResults := make(chan receiveResult, 1)
	go receiveExecMessages(stream, session, first.GetSequence(), request, receiveResults)
	deliveries := make(chan deliveryResult, 1)
	go deliverExecMessages(rpcContext, session, deliveries)

	var serverSequence uint64
	for {
		select {
		case result := <-receiveResults:
			if result.err != nil {
				session.Cancel()
				if status.Code(result.err) == codes.Unknown {
					return execStatusError(result.err)
				}
				return result.err
			}
			if result.done {
				receiveResults = nil
			}
		case result := <-deliveries:
			if result.err != nil {
				if errors.Is(result.err, ErrSessionClosed) {
					return nil
				}
				return execStatusError(result.err)
			}
			serverSequence++
			message := deliveryToProto(
				result.delivery, request.ExecSessionID, request.Generation, serverSequence,
				session.ContextName(), session.Pod(),
			)
			if err := stream.Send(message); err != nil {
				return err
			}
			if result.delivery.Status != nil && isTerminal(result.delivery.Status.State) {
				return nil
			}
		}
	}
}

func receiveExecMessages(
	stream grpc.BidiStreamingServer[kmgrv1.ExecClientMessage, kmgrv1.ExecServerMessage],
	session *Session,
	lastSequence uint64,
	request StartRequest,
	results chan<- receiveResult,
) {
	for {
		message, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			session.CloseStdin()
			results <- receiveResult{done: true}
			return
		}
		if err != nil {
			select {
			case results <- receiveResult{err: err}:
			case <-stream.Context().Done():
			}
			return
		}
		if err := validateClientEnvelope(message, request, &lastSequence); err != nil {
			results <- receiveResult{err: err}
			return
		}
		switch payload := message.GetPayload().(type) {
		case *kmgrv1.ExecClientMessage_Stdin:
			if !request.Stdin {
				results <- receiveResult{err: fmt.Errorf("%w: stdin was not enabled", ErrInvalidRequest)}
				return
			}
			if err := session.SendStdin(payload.Stdin); err != nil {
				if errors.Is(err, ErrInputClosed) {
					err = fmt.Errorf("%w: stdin is already closed", ErrInvalidRequest)
				}
				results <- receiveResult{err: err}
				return
			}
		case *kmgrv1.ExecClientMessage_Resize:
			if !request.TTY || payload.Resize == nil {
				results <- receiveResult{err: fmt.Errorf("%w: resize requires a TTY", ErrInvalidRequest)}
				return
			}
			if err := session.Resize(TerminalSize{Columns: payload.Resize.GetColumns(), Rows: payload.Resize.GetRows()}); err != nil {
				results <- receiveResult{err: err}
				return
			}
		case *kmgrv1.ExecClientMessage_CloseStdin:
			if !payload.CloseStdin {
				results <- receiveResult{err: fmt.Errorf("%w: close_stdin must be true", ErrInvalidRequest)}
				return
			}
			session.CloseStdin()
		case *kmgrv1.ExecClientMessage_Cancel:
			if !payload.Cancel {
				results <- receiveResult{err: fmt.Errorf("%w: cancel must be true", ErrInvalidRequest)}
				return
			}
			session.Cancel()
			results <- receiveResult{done: true}
			return
		default:
			results <- receiveResult{err: fmt.Errorf("%w: start is allowed only as the first message", ErrInvalidRequest)}
			return
		}
	}
}

func deliverExecMessages(ctx context.Context, session *Session, results chan<- deliveryResult) {
	for {
		delivery, err := session.Next(ctx)
		select {
		case results <- deliveryResult{delivery: delivery, err: err}:
		case <-ctx.Done():
			return
		}
		if err != nil || (delivery.Status != nil && isTerminal(delivery.Status.State)) {
			return
		}
	}
}

func startFromProto(message *kmgrv1.ExecClientMessage) (StartRequest, error) {
	if message == nil || message.GetSequence() == 0 || message.GetExecSessionId() == "" || message.GetGeneration() == 0 {
		return StartRequest{}, fmt.Errorf("%w: stream ID, generation, and sequence are required", ErrInvalidRequest)
	}
	start := message.GetStart()
	if start == nil || start.GetContext() == nil || start.GetPod() == nil {
		return StartRequest{}, fmt.Errorf("%w: the first payload must be a complete start request", ErrInvalidRequest)
	}
	if start.GetExecSessionId() != message.GetExecSessionId() || start.GetGeneration() != message.GetGeneration() {
		return StartRequest{}, fmt.Errorf("%w: start and stream envelopes do not match", ErrInvalidRequest)
	}
	identity := start.GetPod()
	request := StartRequest{
		SessionID: start.GetContext().GetClusterSessionId(), ExecSessionID: start.GetExecSessionId(),
		Generation: start.GetGeneration(), Container: start.GetContainer(),
		Command: slices.Clone(start.GetCommand()), TTY: start.GetTty(), Stdin: start.GetStdin(),
		Pod: Identity{
			SessionID: identity.GetClusterSessionId(), Group: identity.GetGroup(), Version: identity.GetVersion(),
			Resource: identity.GetResource(), Namespace: identity.GetNamespace(), Name: identity.GetName(), UID: identity.GetUid(),
		},
	}
	if start.GetInitialColumns() != 0 || start.GetInitialRows() != 0 {
		request.InitialSize = &TerminalSize{Columns: start.GetInitialColumns(), Rows: start.GetInitialRows()}
	}
	return request, nil
}

func validateClientEnvelope(message *kmgrv1.ExecClientMessage, request StartRequest, lastSequence *uint64) error {
	if message == nil || message.GetExecSessionId() != request.ExecSessionID || message.GetGeneration() != request.Generation {
		return fmt.Errorf("%w: message belongs to another exec generation", ErrInvalidRequest)
	}
	if message.GetSequence() == 0 || message.GetSequence() <= *lastSequence {
		return fmt.Errorf("%w: client sequence must increase monotonically", ErrInvalidRequest)
	}
	*lastSequence = message.GetSequence()
	return nil
}

func execRequestContext(ctx context.Context, request *kmgrv1.RequestContext) (context.Context, context.CancelFunc, error) {
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

func deliveryToProto(
	delivery Delivery,
	execSessionID string,
	generation, sequence uint64,
	contextName string,
	pod Identity,
) *kmgrv1.ExecServerMessage {
	message := &kmgrv1.ExecServerMessage{Cursor: &kmgrv1.StreamCursor{
		StreamId: execSessionID, Generation: generation, Sequence: sequence,
	}}
	if delivery.Output != nil {
		data := slices.Clone(delivery.Output.Data)
		if delivery.Output.Kind == StreamStderr {
			message.Payload = &kmgrv1.ExecServerMessage_Stderr{Stderr: data}
		} else {
			message.Payload = &kmgrv1.ExecServerMessage_Stdout{Stdout: data}
		}
		return message
	}
	if delivery.Status != nil {
		value := delivery.Status
		converted := &kmgrv1.ExecStatus{
			State: stateToProto(value.State), ExitCode: value.ExitCode, StatusReason: value.StatusReason,
		}
		if value.Err != nil {
			converted.Error = structuredExecError(value.Err, contextName, pod)
		}
		message.Payload = &kmgrv1.ExecServerMessage_Status{Status: converted}
	}
	return message
}

func stateToProto(value State) kmgrv1.ExecConnectionState {
	switch value {
	case StateConnecting:
		return kmgrv1.ExecConnectionState_EXEC_CONNECTION_STATE_CONNECTING
	case StateRunning:
		return kmgrv1.ExecConnectionState_EXEC_CONNECTION_STATE_RUNNING
	case StateExited:
		return kmgrv1.ExecConnectionState_EXEC_CONNECTION_STATE_EXITED
	case StateCancelled:
		return kmgrv1.ExecConnectionState_EXEC_CONNECTION_STATE_CANCELLED
	case StateFailed:
		return kmgrv1.ExecConnectionState_EXEC_CONNECTION_STATE_FAILED
	default:
		return kmgrv1.ExecConnectionState_EXEC_CONNECTION_STATE_UNSPECIFIED
	}
}

func isTerminal(value State) bool {
	return value == StateExited || value == StateCancelled || value == StateFailed
}

func execStatusError(err error) error {
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
	case errors.Is(err, ErrTooManySessions), errors.Is(err, ErrInputBackpressure):
		return status.Error(codes.ResourceExhausted, "exec stream capacity was exhausted")
	case errors.Is(err, ErrInputClosed):
		return status.Error(codes.FailedPrecondition, "exec stdin is closed")
	case errors.Is(err, ErrExecutorUnavailable):
		return status.Error(codes.FailedPrecondition, "Kubernetes exec transport is unavailable")
	case errors.Is(err, context.Canceled):
		return status.Error(codes.Canceled, "exec session cancelled")
	case errors.Is(err, context.DeadlineExceeded):
		return status.Error(codes.DeadlineExceeded, "exec session deadline exceeded")
	default:
		return status.Error(codes.Internal, "exec session failed")
	}
}

func structuredExecError(err error, contextName string, pod Identity) *kmgrv1.StructuredError {
	result := &kmgrv1.StructuredError{
		Category: kmgrv1.ErrorCategory_ERROR_CATEGORY_INTERNAL,
		Reason:   "ExecFailed", Message: "The Kubernetes Pod exec session failed.",
		ContextName: contextName, Operation: "exec-pod",
		Resource: &kmgrv1.ResourceIdentity{
			ClusterSessionId: pod.SessionID, Group: pod.Group, Version: pod.Version,
			Resource: pod.Resource, Namespace: pod.Namespace, Name: pod.Name, Uid: pod.UID,
		},
	}
	kubeerrors.Enrich(result, err)
	var mismatch *UIDMismatchError
	var apiStatus apierrors.APIStatus
	switch {
	case errors.As(err, &mismatch):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT
		result.Reason = "PodRecreated"
		result.Message = "The selected Pod was replaced before exec connected."
		result.SafeDetails = map[string]string{"expected_uid": mismatch.Expected, "current_uid": mismatch.Actual}
	case errors.Is(err, ErrOutputBackpressure):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_RESOURCE_EXHAUSTED
		result.Reason = "OutputBackpressure"
		result.Message = "The terminal receiver could not keep up; the exec session was stopped to keep memory bounded."
	case apierrors.IsNotFound(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND
		result.Reason = "PodOrContainerNotFound"
		result.Message = "The selected Pod or container was not found."
	case apierrors.IsUnauthorized(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHENTICATION
		result.Reason = "AuthenticationRejected"
		result.Message = "The Kubernetes API server rejected the configured credentials."
	case apierrors.IsForbidden(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHORIZATION
		result.Reason = "Forbidden"
		result.Message = "The configured identity is not authorized to exec into this Pod."
	case errors.Is(err, context.DeadlineExceeded):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_TIMEOUT
		result.Reason = "ExecTimedOut"
		result.Message = "The Pod exec session timed out."
	case errors.As(err, &apiStatus):
		value := apiStatus.Status()
		result.HttpStatusCode = value.Code
		result.Reason = string(value.Reason)
		result.Retryable = value.Code == 408 || value.Code == 429 || value.Code >= 500
	}
	return result
}
