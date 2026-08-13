package transport

import (
	"context"
	"log/slog"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Logging deliberately records only the RPC method, duration, and status. It
// never formats request or response messages, metadata, tokens, mutation
// payloads, kubeconfig errors, Secret values, logs, or terminal bytes.
func unaryLoggingInterceptor(logger *slog.Logger) grpc.UnaryServerInterceptor {
	return func(
		ctx context.Context,
		request any,
		info *grpc.UnaryServerInfo,
		handler grpc.UnaryHandler,
	) (any, error) {
		started := time.Now()
		response, err := handler(ctx, request)
		logRPC(logger, info.FullMethod, time.Since(started), status.Code(err))
		return response, err
	}
}

func streamLoggingInterceptor(logger *slog.Logger) grpc.StreamServerInterceptor {
	return func(
		srv any,
		stream grpc.ServerStream,
		info *grpc.StreamServerInfo,
		handler grpc.StreamHandler,
	) error {
		started := time.Now()
		err := handler(srv, stream)
		logRPC(logger, info.FullMethod, time.Since(started), status.Code(err))
		return err
	}
}

func logRPC(logger *slog.Logger, method string, duration time.Duration, code codes.Code) {
	if logger == nil {
		return
	}
	level := slog.LevelDebug
	if code != codes.OK && code != codes.Canceled {
		level = slog.LevelWarn
	}
	logger.Log(
		context.Background(),
		level,
		"rpc completed",
		"method", method,
		"duration_ms", duration.Milliseconds(),
		"status", code.String(),
	)
}
