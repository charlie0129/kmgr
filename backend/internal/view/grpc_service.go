package view

import (
	"context"
	"errors"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

var _ kmgrv1.ViewServiceServer = (*GRPCService)(nil)

// GRPCService is intentionally a thin protocol adapter. Runtime owns all
// consumer lifetimes, generation gating, warm caches, and bounded batching.
type GRPCService struct {
	kmgrv1.UnimplementedViewServiceServer
	runtime *Runtime
}

func NewGRPCService(runtime *Runtime) (*GRPCService, error) {
	if runtime == nil {
		return nil, errors.New("view runtime must not be nil")
	}
	return &GRPCService{runtime: runtime}, nil
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
