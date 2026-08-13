package kubeerrors

import (
	"errors"
	"testing"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

func TestEnrichPreservesKubernetesStatusStructureWithoutRawMessages(t *testing.T) {
	t.Parallel()
	err := &apierrors.StatusError{ErrStatus: metav1.Status{
		Status:  metav1.StatusFailure,
		Reason:  metav1.StatusReasonInvalid,
		Message: "Secret token super-secret is invalid",
		Code:    422,
		Details: &metav1.StatusDetails{
			Name: "settings", Group: "apps", Kind: "Deployment", UID: types.UID("uid-1"),
			RetryAfterSeconds: 7,
			Causes: []metav1.StatusCause{{
				Type:    metav1.CauseTypeFieldValueInvalid,
				Field:   "spec.template.spec.containers[0].image",
				Message: "Invalid value super-secret",
			}},
		},
	}}
	result := &kmgrv1.StructuredError{Message: "The server rejected the object."}

	Enrich(result, err)

	if result.GetHttpStatusCode() != 422 || result.GetReason() != "Invalid" || result.GetRetryAfterMs() != 7000 {
		t.Fatalf("status envelope = %#v", result)
	}
	details := result.GetKubernetesStatus()
	if details.GetName() != "settings" || details.GetGroup() != "apps" ||
		details.GetKind() != "Deployment" || details.GetUid() != "uid-1" ||
		details.GetReason() != "Invalid" || details.GetRetryAfterSeconds() != 7 {
		t.Fatalf("status details = %#v", details)
	}
	if details.GetMessage() != "" || len(details.GetCauses()) != 1 ||
		details.GetCauses()[0].GetReason() != "FieldValueInvalid" ||
		details.GetCauses()[0].GetField() != "spec.template.spec.containers[0].image" ||
		details.GetCauses()[0].GetMessage() != "" {
		t.Fatalf("status causes = %#v", details)
	}
}

func TestEnrichIgnoresOrdinaryErrors(t *testing.T) {
	t.Parallel()
	result := &kmgrv1.StructuredError{Reason: "Original"}
	Enrich(result, errors.New("ordinary failure"))
	if result.GetReason() != "Original" || result.GetKubernetesStatus() != nil {
		t.Fatalf("ordinary error changed result: %#v", result)
	}
}
