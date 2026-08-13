package transport

import (
	"context"
	"strings"
	"testing"

	"google.golang.org/grpc/metadata"
)

func TestTokenAuthenticator(t *testing.T) {
	t.Parallel()
	token := strings.Repeat("a", 32)
	authenticator, err := NewTokenAuthenticator(token)
	if err != nil {
		t.Fatalf("NewTokenAuthenticator: %v", err)
	}

	tests := []struct {
		name    string
		values  []string
		wantErr bool
	}{
		{name: "valid", values: []string{"Bearer " + token}},
		{name: "missing", wantErr: true},
		{name: "wrong scheme", values: []string{token}, wantErr: true},
		{name: "wrong token", values: []string{"Bearer " + strings.Repeat("b", 32)}, wantErr: true},
		{name: "duplicate", values: []string{"Bearer " + token, "Bearer " + token}, wantErr: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx := metadata.NewIncomingContext(
				context.Background(),
				metadata.MD{AuthorizationMetadataKey: test.values},
			)
			err := authenticator.Authenticate(ctx)
			if (err != nil) != test.wantErr {
				t.Fatalf("Authenticate() error = %v, wantErr %v", err, test.wantErr)
			}
			if err != nil && strings.Contains(err.Error(), token) {
				t.Fatal("authentication error exposed the launch token")
			}
		})
	}
}

func TestTokenAuthenticatorRejectsShortToken(t *testing.T) {
	t.Parallel()
	if _, err := NewTokenAuthenticator("short"); err == nil {
		t.Fatal("NewTokenAuthenticator accepted a short token")
	}
}
