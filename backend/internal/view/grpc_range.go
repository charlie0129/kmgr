package view

import (
	"context"
	"errors"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func (s *GRPCService) FetchViewRange(
	ctx context.Context,
	request *kmgrv1.FetchViewRangeRequest,
) (*kmgrv1.FetchViewRangeResponse, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestID, operationContext, cancel, err := viewRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	if err := operationContext.Err(); err != nil {
		return nil, viewRangeStatusError(err)
	}
	result, err := s.runtime.FetchRange(
		request.GetContext().GetClusterSessionId(),
		request.GetViewId(),
		request.GetGeneration(),
		request.GetPresentationRevision(),
		request.GetIndexRevision(),
		request.GetStartIndex(),
		request.GetLength(),
	)
	if err != nil {
		return nil, viewRangeStatusError(err)
	}
	return &kmgrv1.FetchViewRangeResponse{
		RequestId:            requestID,
		ViewId:               request.GetViewId(),
		Generation:           result.Generation,
		PresentationRevision: result.PresentationRevision,
		IndexRevision:        result.IndexRevision,
		StartIndex:           result.StartIndex,
		RowsVisible:          result.RowsVisible,
		Rows:                 result.Rows,
	}, nil
}

func (s *GRPCService) UpdateMetricInterest(
	ctx context.Context,
	request *kmgrv1.UpdateMetricInterestRequest,
) (*kmgrv1.Acknowledgement, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestID, operationContext, cancel, err := viewRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	if err := operationContext.Err(); err != nil {
		return nil, viewRangeStatusError(err)
	}
	err = s.runtime.UpdateMetricInterest(
		request.GetContext().GetClusterSessionId(),
		request.GetViewId(),
		request.GetGeneration(),
		request.GetIndexRevision(),
		request.GetStartIndex(),
		request.GetLength(),
	)
	if err != nil {
		return nil, viewRangeStatusError(err)
	}
	return &kmgrv1.Acknowledgement{RequestId: requestID, Accepted: true}, nil
}

func viewRangeStatusError(err error) error {
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return status.Error(codes.DeadlineExceeded, "request deadline exceeded")
	case errors.Is(err, context.Canceled):
		return status.Error(codes.Canceled, "request cancelled")
	case errors.Is(err, ErrViewNotFound):
		return status.Error(codes.NotFound, err.Error())
	case errors.Is(err, ErrStaleViewGeneration), errors.Is(err, ErrStaleViewRevision):
		return status.Error(codes.FailedPrecondition, err.Error())
	case errors.Is(err, ErrInvalidViewRange):
		return status.Error(codes.InvalidArgument, err.Error())
	case errors.Is(err, ErrViewClosed):
		return status.Error(codes.Canceled, "resource view closed")
	default:
		return status.Error(codes.Internal, "resource view range failed")
	}
}
