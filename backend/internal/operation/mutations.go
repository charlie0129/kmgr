package operation

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/object"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/client-go/dynamic"
)

const (
	operationFieldManager = "kmgr"
	restartedAtAnnotation = "kubectl.kubernetes.io/restartedAt"
)

type ResourceBackend interface {
	Resource(object.Identity) (dynamic.ResourceInterface, error)
}

// DataUpdater is the narrow mutation contract implemented by object.Reader.
// Sensitive values remain confined to the request/worker path and never enter
// operation status or diagnostic models.
type DataUpdater interface {
	UpdateData(context.Context, object.Identity, string, []object.DataMutation) (object.Data, error)
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
	return patchResource(ctx, backend, identity, expectedResourceVersion, map[string]any{
		"spec": map[string]any{"replicas": replicas},
	}, "scale")
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
	return patchResource(ctx, backend, identity, expectedResourceVersion, map[string]any{
		"spec": map[string]any{
			"template": map[string]any{
				"metadata": map[string]any{
					"annotations": map[string]any{
						restartedAtAnnotation: now.UTC().Format(time.RFC3339),
					},
				},
			},
		},
	})
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
	metadata := make(map[string]any, 2)
	labels := make(map[string]any, len(changes.Labels)+len(changes.RemoveLabelKeys))
	annotations := make(map[string]any, len(changes.Annotations)+len(changes.RemoveAnnotationKeys))
	for key, value := range changes.Labels {
		labels[key] = value
	}
	for _, key := range changes.RemoveLabelKeys {
		labels[key] = nil
	}
	for key, value := range changes.Annotations {
		annotations[key] = value
	}
	for _, key := range changes.RemoveAnnotationKeys {
		annotations[key] = nil
	}
	if len(labels) > 0 {
		metadata["labels"] = labels
	}
	if len(annotations) > 0 {
		metadata["annotations"] = annotations
	}
	return patchResource(ctx, backend, identity, expectedResourceVersion, map[string]any{
		"metadata": metadata,
	})
}

// patchResource performs one server-side merge patch. Supplying UID and
// resourceVersion in the patched metadata makes same-name recreation and
// concurrent writes fail atomically in the API server. Merge patch is used
// instead of JSON patch because per-key metadata edits must also work when the
// labels or annotations parent map does not yet exist.
func patchResource(
	ctx context.Context,
	backend ResourceBackend,
	identity object.Identity,
	expectedResourceVersion string,
	material map[string]any,
	subresources ...string,
) (string, error) {
	metadata, _ := material["metadata"].(map[string]any)
	if metadata == nil {
		metadata = make(map[string]any, 2)
		material["metadata"] = metadata
	}
	metadata["uid"] = identity.UID
	metadata["resourceVersion"] = expectedResourceVersion
	patch, err := json.Marshal(material)
	if err != nil {
		return "", fmt.Errorf("encode resource mutation patch: %w", err)
	}
	resource, err := backend.Resource(identity)
	if err != nil {
		return "", err
	}
	updated, err := resource.Patch(
		ctx,
		identity.Name,
		types.MergePatchType,
		patch,
		metav1.PatchOptions{FieldManager: operationFieldManager},
		subresources...,
	)
	if err != nil {
		return "", err
	}
	if updated == nil {
		return "", errors.New("Kubernetes API returned no object for resource mutation")
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
