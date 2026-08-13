package object

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"reflect"
	"sort"
	"strings"
	"unicode/utf8"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	utilyaml "k8s.io/apimachinery/pkg/util/yaml"
	sigyaml "sigs.k8s.io/yaml"
)

const YAMLFieldManager = "kmgr"

var ErrInvalidYAML = errors.New("YAML does not contain exactly one Kubernetes object")

type YAMLIdentityMismatchError struct {
	Field    string
	Expected string
	Actual   string
}

func (e *YAMLIdentityMismatchError) Error() string {
	return fmt.Sprintf("YAML %s changed from %q to %q", e.Field, e.Expected, e.Actual)
}

type SemanticDiff struct {
	Path          string
	BeforeSummary string
	AfterSummary  string
}

type PreparedYAML struct {
	Identity               Identity
	CurrentResourceVersion string
	NormalizedYAML         []byte
	Diff                   []SemanticDiff
}

type AppliedYAML struct {
	Identity           Identity
	NewResourceVersion string
}

// PrepareYAML always starts with an authoritative GET and asks the API server
// to dry-run the exact server-side apply that ApplyYAML would perform.
func (r *Reader) PrepareYAML(
	ctx context.Context,
	identity Identity,
	yamlUTF8 []byte,
	expectedResourceVersion string,
	forceFieldOwnership bool,
) (PreparedYAML, error) {
	current, desired, normalized, resource, err := r.prepareYAMLInput(
		ctx, identity, yamlUTF8, expectedResourceVersion,
	)
	if err != nil {
		return PreparedYAML{}, err
	}
	dryRun, err := resource.Apply(ctx, identity.Name, desired.DeepCopy(), metav1.ApplyOptions{
		DryRun:       []string{metav1.DryRunAll},
		Force:        forceFieldOwnership,
		FieldManager: YAMLFieldManager,
	})
	if err != nil {
		return PreparedYAML{}, fmt.Errorf("dry-run server-side apply: %w", err)
	}
	return PreparedYAML{
		Identity: identity, CurrentResourceVersion: current.GetResourceVersion(),
		NormalizedYAML: normalized, Diff: semanticYAMLDiff(current, dryRun),
	}, nil
}

// ApplyYAML repeats all preparation checks immediately before mutation. The
// resourceVersion embedded in the apply object is also an API-side
// precondition, closing the race between the fresh GET, dry-run, and apply.
func (r *Reader) ApplyYAML(
	ctx context.Context,
	identity Identity,
	yamlUTF8 []byte,
	expectedResourceVersion string,
	forceFieldOwnership bool,
) (AppliedYAML, error) {
	_, desired, _, resource, err := r.prepareYAMLInput(ctx, identity, yamlUTF8, expectedResourceVersion)
	if err != nil {
		return AppliedYAML{}, err
	}
	options := metav1.ApplyOptions{
		Force: forceFieldOwnership, FieldManager: YAMLFieldManager,
	}
	if _, err := resource.Apply(ctx, identity.Name, desired.DeepCopy(), metav1.ApplyOptions{
		DryRun: []string{metav1.DryRunAll}, Force: options.Force,
		FieldManager: options.FieldManager,
	}); err != nil {
		return AppliedYAML{}, fmt.Errorf("dry-run server-side apply: %w", err)
	}
	updated, err := resource.Apply(ctx, identity.Name, desired, options)
	if err != nil {
		return AppliedYAML{}, fmt.Errorf("server-side apply: %w", err)
	}
	if string(updated.GetUID()) != identity.UID {
		return AppliedYAML{}, &IdentityChangedError{
			ExpectedUID: identity.UID, ActualUID: string(updated.GetUID()),
			Namespace: identity.Namespace, Name: identity.Name,
		}
	}
	return AppliedYAML{Identity: identity, NewResourceVersion: updated.GetResourceVersion()}, nil
}

func (r *Reader) prepareYAMLInput(
	ctx context.Context,
	identity Identity,
	yamlUTF8 []byte,
	expectedResourceVersion string,
) (*unstructured.Unstructured, *unstructured.Unstructured, []byte, dynamicResource, error) {
	if err := identity.Validate(); err != nil {
		return nil, nil, nil, nil, err
	}
	if strings.TrimSpace(expectedResourceVersion) == "" {
		return nil, nil, nil, nil, &ResourceVersionConflictError{Expected: expectedResourceVersion}
	}
	desired, err := parseSingleYAMLObject(yamlUTF8)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	current, err := r.Get(ctx, identity)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	if current.GetResourceVersion() != expectedResourceVersion {
		return nil, nil, nil, nil, &ResourceVersionConflictError{
			Expected: expectedResourceVersion, Current: current.GetResourceVersion(),
		}
	}
	if err := validateYAMLIdentity(identity, current, desired, expectedResourceVersion); err != nil {
		return nil, nil, nil, nil, err
	}

	// These fields are owned by the API server or status controllers and are
	// never part of a generic editor apply.
	unstructured.RemoveNestedField(desired.Object, "status")
	unstructured.RemoveNestedField(desired.Object, "metadata", "managedFields")
	desired.SetResourceVersion(expectedResourceVersion)

	normalizedJSON, err := desired.MarshalJSON()
	if err != nil {
		return nil, nil, nil, nil, fmt.Errorf("normalize YAML object: %w", err)
	}
	normalized, err := sigyaml.JSONToYAML(normalizedJSON)
	if err != nil {
		return nil, nil, nil, nil, fmt.Errorf("format normalized YAML: %w", err)
	}
	resource, err := r.resolver.Resource(identity.SessionID, identity.GVR(), identity.Namespace)
	if err != nil {
		return nil, nil, nil, nil, err
	}
	return current, desired, normalized, resource, nil
}

// dynamicResource names the subset used here without widening Resolver's
// public contract.
type dynamicResource interface {
	Apply(context.Context, string, *unstructured.Unstructured, metav1.ApplyOptions, ...string) (*unstructured.Unstructured, error)
}

func parseSingleYAMLObject(value []byte) (*unstructured.Unstructured, error) {
	if len(value) == 0 || !utf8.Valid(value) {
		return nil, fmt.Errorf("%w: input must be non-empty UTF-8", ErrInvalidYAML)
	}
	reader := utilyaml.NewYAMLReader(bufio.NewReader(bytes.NewReader(value)))
	var result *unstructured.Unstructured
	for {
		document, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("%w: %v", ErrInvalidYAML, err)
		}
		jsonValue, err := sigyaml.YAMLToJSONStrict(document)
		if err != nil {
			return nil, fmt.Errorf("%w: %v", ErrInvalidYAML, err)
		}
		if bytes.Equal(bytes.TrimSpace(jsonValue), []byte("null")) {
			continue
		}
		if result != nil {
			return nil, fmt.Errorf("%w: multiple YAML documents are not supported", ErrInvalidYAML)
		}
		var object map[string]any
		if err := json.Unmarshal(jsonValue, &object); err != nil || object == nil {
			return nil, fmt.Errorf("%w: document must be a mapping", ErrInvalidYAML)
		}
		result = &unstructured.Unstructured{Object: object}
	}
	if result == nil {
		return nil, ErrInvalidYAML
	}
	return result, nil
}

func validateYAMLIdentity(
	identity Identity,
	current, desired *unstructured.Unstructured,
	expectedResourceVersion string,
) error {
	checks := []struct {
		field, expected, actual string
	}{
		{"apiVersion", current.GetAPIVersion(), desired.GetAPIVersion()},
		{"kind", current.GetKind(), desired.GetKind()},
		{"metadata.name", identity.Name, desired.GetName()},
		{"metadata.namespace", identity.Namespace, desired.GetNamespace()},
		{"metadata.uid", identity.UID, string(desired.GetUID())},
	}
	for _, check := range checks {
		if check.expected != check.actual {
			return &YAMLIdentityMismatchError{Field: check.field, Expected: check.expected, Actual: check.actual}
		}
	}
	if current.GetAPIVersion() != identity.GVR().GroupVersion().String() {
		return &YAMLIdentityMismatchError{
			Field: "apiVersion", Expected: identity.GVR().GroupVersion().String(), Actual: current.GetAPIVersion(),
		}
	}
	if value := desired.GetResourceVersion(); value != "" && value != expectedResourceVersion {
		return &YAMLIdentityMismatchError{
			Field: "metadata.resourceVersion", Expected: expectedResourceVersion, Actual: value,
		}
	}
	return nil
}

func semanticYAMLDiff(before, after *unstructured.Unstructured) []SemanticDiff {
	left := sanitizeDiffObject(before)
	right := sanitizeDiffObject(after)
	result := make([]SemanticDiff, 0, 16)
	appendSemanticDiff(&result, "", left, right)
	return result
}

func sanitizeDiffObject(value *unstructured.Unstructured) map[string]any {
	if value == nil {
		return nil
	}
	copy := value.DeepCopy()
	unstructured.RemoveNestedField(copy.Object, "status")
	for _, field := range []string{"managedFields", "resourceVersion", "generation", "creationTimestamp"} {
		unstructured.RemoveNestedField(copy.Object, "metadata", field)
	}
	return copy.Object
}

func appendSemanticDiff(result *[]SemanticDiff, path string, before, after any) {
	if reflect.DeepEqual(before, after) || len(*result) >= 200 {
		return
	}
	left, leftMap := before.(map[string]any)
	right, rightMap := after.(map[string]any)
	if leftMap && rightMap {
		keys := make([]string, 0, len(left)+len(right))
		seen := make(map[string]struct{}, len(left)+len(right))
		for key := range left {
			seen[key] = struct{}{}
			keys = append(keys, key)
		}
		for key := range right {
			if _, ok := seen[key]; !ok {
				keys = append(keys, key)
			}
		}
		sort.Strings(keys)
		for _, key := range keys {
			child := key
			if path != "" {
				child = path + "." + key
			}
			appendSemanticDiff(result, child, left[key], right[key])
		}
		return
	}
	*result = append(*result, SemanticDiff{
		Path: path, BeforeSummary: summarizeDiffValue(before, path), AfterSummary: summarizeDiffValue(after, path),
	})
}

func summarizeDiffValue(value any, path string) string {
	if value == nil {
		return "<absent>"
	}
	if strings.HasPrefix(path, "data.") || strings.HasPrefix(path, "stringData.") || strings.HasPrefix(path, "binaryData.") {
		return "<redacted>"
	}
	switch typed := value.(type) {
	case map[string]any:
		return fmt.Sprintf("{%d fields}", len(typed))
	case []any:
		return fmt.Sprintf("[%d items]", len(typed))
	case string:
		if len(typed) > 120 {
			return fmt.Sprintf("%q…", typed[:117])
		}
		return fmt.Sprintf("%q", typed)
	default:
		encoded, _ := json.Marshal(value)
		return string(encoded)
	}
}
