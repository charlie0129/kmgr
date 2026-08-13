package transport

import (
	"context"
	"crypto/subtle"
	"errors"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

const AuthorizationMetadataKey = "authorization"

var ErrInvalidLaunchToken = errors.New("invalid launch token")

// TokenAuthenticator authenticates every RPC with the random token inherited
// by the app-owned engine. Tokens are deliberately never included in errors.
type TokenAuthenticator struct {
	token string
}

func NewTokenAuthenticator(token string) (*TokenAuthenticator, error) {
	if len(token) < 32 {
		return nil, errors.New("launch token must contain at least 32 bytes")
	}
	return &TokenAuthenticator{token: token}, nil
}

func (a *TokenAuthenticator) Authenticate(ctx context.Context) error {
	values := metadata.ValueFromIncomingContext(ctx, AuthorizationMetadataKey)
	if len(values) != 1 {
		return ErrInvalidLaunchToken
	}

	const prefix = "Bearer "
	if !strings.HasPrefix(values[0], prefix) {
		return ErrInvalidLaunchToken
	}
	candidate := strings.TrimPrefix(values[0], prefix)
	if len(candidate) != len(a.token) || subtle.ConstantTimeCompare([]byte(candidate), []byte(a.token)) != 1 {
		return ErrInvalidLaunchToken
	}
	return nil
}

func (a *TokenAuthenticator) UnaryServerInterceptor(
	ctx context.Context,
	req any,
	info *grpc.UnaryServerInfo,
	handler grpc.UnaryHandler,
) (any, error) {
	if err := a.Authenticate(ctx); err != nil {
		return nil, status.Error(codes.Unauthenticated, "invalid engine credentials")
	}
	return handler(ctx, req)
}

func (a *TokenAuthenticator) StreamServerInterceptor(
	srv any,
	stream grpc.ServerStream,
	info *grpc.StreamServerInfo,
	handler grpc.StreamHandler,
) error {
	if err := a.Authenticate(stream.Context()); err != nil {
		return status.Error(codes.Unauthenticated, "invalid engine credentials")
	}
	return handler(srv, stream)
}
