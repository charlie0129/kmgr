package cluster

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
)

// apiOperationErrorMessage keeps the original Go error text. HTTP failures do
// not produce a RoundTripper error, so those use a small status-only fallback.
func apiOperationErrorMessage(
	contextError, terminalError error,
	statusCode int,
) string {
	if terminalError != nil && !errors.Is(terminalError, io.EOF) {
		return terminalError.Error()
	}
	if contextError != nil {
		return contextError.Error()
	}
	if statusCode >= http.StatusBadRequest {
		return fmt.Sprintf("HTTP %d %s", statusCode, http.StatusText(statusCode))
	}
	if statusCode == 0 {
		return "no HTTP response"
	}
	return ""
}

// kubernetesWatchErrorMessage preserves the server's Status message and its
// exact reason/code metadata. It deliberately performs no sanitized or
// user-facing error classification.
func kubernetesWatchErrorMessage(err error) string {
	if err == nil {
		return ""
	}
	var apiStatus apierrors.APIStatus
	if errors.As(err, &apiStatus) {
		status := apiStatus.Status()
		message := status.Message
		if message == "" {
			message = err.Error()
		}
		if status.Reason != "" && status.Code != 0 {
			return fmt.Sprintf(
				"Kubernetes server (%s, HTTP %d): %s",
				status.Reason,
				status.Code,
				message,
			)
		}
		if status.Code != 0 {
			return fmt.Sprintf("Kubernetes server (HTTP %d): %s", status.Code, message)
		}
		if status.Reason != "" {
			return fmt.Sprintf("Kubernetes server (%s): %s", status.Reason, message)
		}
		return "Kubernetes server: " + message
	}
	return "Kubernetes watch: " + err.Error()
}

func combinedAPIOperationErrorMessage(serverMessage, goMessage string) string {
	switch {
	case serverMessage != "" && goMessage != "":
		return serverMessage + "\nGo: " + goMessage
	case serverMessage != "":
		return serverMessage
	default:
		return goMessage
	}
}

func requestContextError(request *http.Request) error {
	if request == nil {
		return nil
	}
	return request.Context().Err()
}

func requestWasCancelled(request *http.Request, roundTripError error) bool {
	return errors.Is(requestContextError(request), context.Canceled) ||
		errors.Is(roundTripError, context.Canceled)
}
