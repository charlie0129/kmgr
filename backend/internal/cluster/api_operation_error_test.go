package cluster

import (
	"context"
	"errors"
	"net/http"
	"testing"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestAPIOperationErrorMessagePreservesRawGoError(t *testing.T) {
	t.Parallel()
	raw := "proxyconnect tcp: dial private.proxy:8443: connection refused"
	if got := apiOperationErrorMessage(nil, errors.New(raw), 0); got != raw {
		t.Fatalf("message = %q, want raw error %q", got, raw)
	}
}

func TestKubernetesWatchErrorMessagePreservesStatusAndRawGoError(t *testing.T) {
	t.Parallel()
	status := &apierrors.StatusError{ErrStatus: metav1.Status{
		Status:  metav1.StatusFailure,
		Message: "line one\nline two",
		Reason:  metav1.StatusReasonInternalError,
		Code:    http.StatusInternalServerError,
	}}
	server := kubernetesWatchErrorMessage(status)
	wantServer := "Kubernetes server (InternalError, HTTP 500): line one\nline two"
	if server != wantServer {
		t.Fatalf("server message = %q, want %q", server, wantServer)
	}
	if got := combinedAPIOperationErrorMessage(server, "http2: response body closed"); got != wantServer+"\nGo: http2: response body closed" {
		t.Fatalf("combined message = %q", got)
	}
}

func TestAPIOperationErrorMessageFallsBackToContextAndHTTPStatus(t *testing.T) {
	t.Parallel()
	if got := apiOperationErrorMessage(context.DeadlineExceeded, nil, 0); got != "context deadline exceeded" {
		t.Fatalf("deadline message = %q", got)
	}
	if got := apiOperationErrorMessage(nil, nil, http.StatusServiceUnavailable); got != "HTTP 503 Service Unavailable" {
		t.Fatalf("HTTP message = %q", got)
	}
}
