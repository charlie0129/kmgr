package operation

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/object"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/client-go/dynamic"
)

const (
	operationFieldManager = "kmgr"
	restartedAtAnnotation = "kubectl.kubernetes.io/restartedAt"
)

type ResourceBackend interface {
	Get(context.Context, object.Identity) (*unstructured.Unstructured, error)
	Resource(object.Identity) (dynamic.ResourceInterface, error)
}

type MutationBackend interface {
	YAMLEditor
	DataUpdater
	ResourceBackend
}

type ValidationError struct {
	Field   string
	Message string
}

func (e *ValidationError) Error() string {
	if e.Field == "" {
		return e.Message
	}
	return fmt.Sprintf("%s: %s", e.Field, e.Message)
}

type MetadataChanges struct {
	Labels               map[string]string
	Annotations          map[string]string
	RemoveLabelKeys      []string
	RemoveAnnotationKeys []string
}

func ScaleResource(
	ctx context.Context,
	backend ResourceBackend,
	identity object.Identity,
	expectedResourceVersion string,
	replicas int32,
) (string, error) {
	if backend == nil {
		return "", errors.New("operation backend is unavailable")
	}
	if replicas < 0 {
		return "", &ValidationError{Field: "replicas", Message: "replica count must not be negative"}
	}
	if expectedResourceVersion == "" {
		return "", &ValidationError{Field: "expected_resource_version", Message: "expected resource version is required"}
	}
	current, err := backend.Get(ctx, identity)
	if err != nil {
		return "", err
	}
	if current.GetResourceVersion() != expectedResourceVersion {
		return "", &object.ResourceVersionConflictError{
			Expected: expectedResourceVersion, Current: current.GetResourceVersion(),
		}
	}
	resource, err := backend.Resource(identity)
	if err != nil {
		return "", err
	}
	scale, err := resource.Get(ctx, identity.Name, metav1.GetOptions{}, "scale")
	if err != nil {
		return "", err
	}
	if scale.GetResourceVersion() != expectedResourceVersion {
		return "", &object.ResourceVersionConflictError{
			Expected: expectedResourceVersion, Current: scale.GetResourceVersion(),
		}
	}
	if err := unstructured.SetNestedField(scale.Object, int64(replicas), "spec", "replicas"); err != nil {
		return "", fmt.Errorf("set scale replicas: %w", err)
	}
	scale.SetResourceVersion(expectedResourceVersion)
	updated, err := resource.Update(ctx, scale, metav1.UpdateOptions{FieldManager: operationFieldManager}, "scale")
	if err != nil {
		return "", err
	}
	return updated.GetResourceVersion(), nil
}

func RestartResource(
	ctx context.Context,
	backend ResourceBackend,
	identity object.Identity,
	expectedResourceVersion string,
	now time.Time,
) (string, error) {
	if backend == nil {
		return "", errors.New("operation backend is unavailable")
	}
	if identity.Group != "apps" || identity.Version != "v1" ||
		(identity.Resource != "deployments" && identity.Resource != "statefulsets" && identity.Resource != "daemonsets") {
		return "", &ValidationError{
			Field:   "identity.resource",
			Message: "rollout restart supports apps/v1 Deployments, StatefulSets, and DaemonSets",
		}
	}
	if expectedResourceVersion == "" {
		return "", &ValidationError{Field: "expected_resource_version", Message: "expected resource version is required"}
	}
	current, err := backend.Get(ctx, identity)
	if err != nil {
		return "", err
	}
	if current.GetResourceVersion() != expectedResourceVersion {
		return "", &object.ResourceVersionConflictError{
			Expected: expectedResourceVersion, Current: current.GetResourceVersion(),
		}
	}
	annotations, found, err := unstructured.NestedStringMap(current.Object, "spec", "template", "metadata", "annotations")
	if err != nil {
		return "", fmt.Errorf("read pod template annotations: %w", err)
	}
	if !found {
		annotations = make(map[string]string)
	}
	annotations[restartedAtAnnotation] = now.UTC().Format(time.RFC3339)
	if err := unstructured.SetNestedStringMap(current.Object, annotations, "spec", "template", "metadata", "annotations"); err != nil {
		return "", fmt.Errorf("set rollout restart annotation: %w", err)
	}
	resource, err := backend.Resource(identity)
	if err != nil {
		return "", err
	}
	updated, err := resource.Update(ctx, current, metav1.UpdateOptions{FieldManager: operationFieldManager})
	if err != nil {
		return "", err
	}
	return updated.GetResourceVersion(), nil
}

func UpdateResourceMetadata(
	ctx context.Context,
	backend ResourceBackend,
	identity object.Identity,
	expectedResourceVersion string,
	changes MetadataChanges,
) (string, error) {
	if backend == nil {
		return "", errors.New("operation backend is unavailable")
	}
	if expectedResourceVersion == "" {
		return "", &ValidationError{Field: "expected_resource_version", Message: "expected resource version is required"}
	}
	if err := ValidateMetadataChanges(changes); err != nil {
		return "", err
	}
	current, err := backend.Get(ctx, identity)
	if err != nil {
		return "", err
	}
	if current.GetResourceVersion() != expectedResourceVersion {
		return "", &object.ResourceVersionConflictError{
			Expected: expectedResourceVersion, Current: current.GetResourceVersion(),
		}
	}
	labels := cloneStringMap(current.GetLabels())
	annotations := cloneStringMap(current.GetAnnotations())
	for key, value := range changes.Labels {
		labels[key] = value
	}
	for _, key := range changes.RemoveLabelKeys {
		delete(labels, key)
	}
	for key, value := range changes.Annotations {
		annotations[key] = value
	}
	for _, key := range changes.RemoveAnnotationKeys {
		delete(annotations, key)
	}
	current.SetLabels(labels)
	current.SetAnnotations(annotations)
	resource, err := backend.Resource(identity)
	if err != nil {
		return "", err
	}
	updated, err := resource.Update(ctx, current, metav1.UpdateOptions{FieldManager: operationFieldManager})
	if err != nil {
		return "", err
	}
	return updated.GetResourceVersion(), nil
}

func ValidateMetadataChanges(changes MetadataChanges) error {
	if len(changes.Labels) == 0 && len(changes.Annotations) == 0 &&
		len(changes.RemoveLabelKeys) == 0 && len(changes.RemoveAnnotationKeys) == 0 {
		return &ValidationError{Field: "metadata", Message: "at least one metadata change is required"}
	}
	for key, value := range changes.Labels {
		if messages := validation.IsQualifiedName(key); len(messages) > 0 {
			return &ValidationError{Field: "labels[" + key + "]", Message: strings.Join(messages, "; ")}
		}
		if messages := validation.IsValidLabelValue(value); len(messages) > 0 {
			return &ValidationError{Field: "labels[" + key + "]", Message: strings.Join(messages, "; ")}
		}
	}
	for key := range changes.Annotations {
		if messages := validation.IsQualifiedName(key); len(messages) > 0 {
			return &ValidationError{Field: "annotations[" + key + "]", Message: strings.Join(messages, "; ")}
		}
	}
	if err := validateRemoveKeys("remove_label_keys", changes.RemoveLabelKeys, changes.Labels); err != nil {
		return err
	}
	if err := validateRemoveKeys("remove_annotation_keys", changes.RemoveAnnotationKeys, changes.Annotations); err != nil {
		return err
	}
	return nil
}

func validateRemoveKeys(field string, keys []string, set map[string]string) error {
	seen := make(map[string]struct{}, len(keys))
	for index, key := range keys {
		if messages := validation.IsQualifiedName(key); len(messages) > 0 {
			return &ValidationError{Field: fmt.Sprintf("%s[%d]", field, index), Message: strings.Join(messages, "; ")}
		}
		if _, duplicate := seen[key]; duplicate {
			return &ValidationError{Field: fmt.Sprintf("%s[%d]", field, index), Message: fmt.Sprintf("key %q is duplicated", key)}
		}
		seen[key] = struct{}{}
		if _, overlap := set[key]; overlap {
			return &ValidationError{Field: field, Message: fmt.Sprintf("key %q cannot be both set and removed", key)}
		}
	}
	return nil
}

func cloneStringMap(value map[string]string) map[string]string {
	result := make(map[string]string, len(value))
	for key, item := range value {
		result[key] = item
	}
	return result
}
