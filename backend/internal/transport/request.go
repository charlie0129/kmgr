package transport

import (
	"context"
	"errors"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func validateRequestContext(
	ctx context.Context,
	request *kmgrv1.RequestContext,
	requireSession bool,
) (context.Context, context.CancelFunc, error) {
	if request == nil {
		return nil, nil, status.Error(codes.InvalidArgument, "request context is required")
	}
	if request.GetRequestId() == "" {
		return nil, nil, status.Error(codes.InvalidArgument, "request ID is required")
	}
	if requireSession && request.GetClusterSessionId() == "" {
		return nil, nil, status.Error(codes.InvalidArgument, "cluster session ID is required")
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

func contextStatus(err error) error {
	switch {
	case errors.Is(err, context.Canceled):
		return status.Error(codes.Canceled, "request cancelled")
	case errors.Is(err, context.DeadlineExceeded):
		return status.Error(codes.DeadlineExceeded, "request deadline exceeded")
	default:
		return err
	}
}
