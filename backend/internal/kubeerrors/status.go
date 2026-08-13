package kubeerrors

import (
	"errors"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Enrich preserves the structured, display-safe portion of a Kubernetes
// Status error. It deliberately avoids copying arbitrary response bodies or
// headers into the protocol.
func Enrich(result *kmgrv1.StructuredError, err error) {
	if result == nil || err == nil {
		return
	}
	var apiStatus apierrors.APIStatus
	if !errors.As(err, &apiStatus) {
		return
	}
	status := apiStatus.Status()
	result.HttpStatusCode = status.Code
	if status.Reason != "" {
		result.Reason = string(status.Reason)
	}
	result.Retryable = status.Code == 0 || status.Code == 408 || status.Code == 429 || status.Code >= 500
	if seconds, ok := apierrors.SuggestsClientDelay(err); ok && seconds > 0 {
		result.RetryAfterMs = int64(seconds) * 1000
	}
	result.KubernetesStatus = details(status)
}

func details(status metav1.Status) *kmgrv1.KubernetesStatusDetails {
	statusDetails := status.Details
	if statusDetails == nil && status.Reason == "" {
		return nil
	}
	result := &kmgrv1.KubernetesStatusDetails{
		Reason: string(status.Reason),
	}
	if statusDetails == nil {
		return result
	}
	result.Name = statusDetails.Name
	result.Group = statusDetails.Group
	result.Kind = statusDetails.Kind
	result.Uid = string(statusDetails.UID)
	result.RetryAfterSeconds = statusDetails.RetryAfterSeconds
	result.Causes = make([]*kmgrv1.KubernetesStatusCause, 0, len(statusDetails.Causes))
	for _, cause := range statusDetails.Causes {
		result.Causes = append(result.Causes, &kmgrv1.KubernetesStatusCause{
			Reason: string(cause.Type), Field: cause.Field,
		})
	}
	return result
}
