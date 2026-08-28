package object

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"reflect"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/pmezard/go-difflib/difflib"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	kubejson "k8s.io/apimachinery/pkg/util/json"
	utilyaml "k8s.io/apimachinery/pkg/util/yaml"
	sigyaml "sigs.k8s.io/yaml"
)

const YAMLFieldManager = "kmgr"

const maximumUnifiedYAMLDiffBytes = 16 << 10

var (
	ErrInvalidYAML                   = errors.New("YAML does not contain exactly one Kubernetes object")
	ErrYAMLForceOwnershipUnsupported = errors.New("force field ownership is unavailable for material-diff YAML edits")
)

type YAMLIdentityMismatchError struct {
	Field    string
	Expected string
	Actual   string
}

func (e *YAMLIdentityMismatchError) Error() string {
	return fmt.Sprintf("YAML %s changed from %q to %q", e.Field, e.Expected, e.Actual)
}

type SemanticDiff struct {
	Path                        string
	BeforeSummary               string
	AfterSummary                string
	BeforeDecodedSecretValue    []byte
	HasBeforeDecodedSecretValue bool
	AfterDecodedSecretValue     []byte
	HasAfterDecodedSecretValue  bool
}

type PreparedYAML struct {
	Identity               Identity
	CurrentResourceVersion string
	NormalizedYAML         []byte
	Diff                   []SemanticDiff
	UnifiedDiff            []byte
	UnifiedDiffTruncated   bool
}

type AppliedYAML struct {
	Identity           Identity
	NewResourceVersion string
}

// PrepareYAML always starts with an authoritative GET and asks the API server
// to dry-run the exact minimal JSON patch that ApplyYAML would perform.
func (r *Reader) PrepareYAML(
	ctx context.Context,
	identity Identity,
	yamlUTF8 []byte,
	expectedResourceVersion string,
	forceFieldOwnership bool,
) (PreparedYAML, error) {
	if forceFieldOwnership {
		return PreparedYAML{}, ErrYAMLForceOwnershipUnsupported
	}
	prepared, err := r.prepareYAMLInput(
		ctx, identity, yamlUTF8, expectedResourceVersion,
	)
	if err != nil {
		return PreparedYAML{}, err
	}
	dryRun := prepared.current
	if len(prepared.patch) != 0 {
		dryRun, err = prepared.resource.Patch(
			ctx,
			identity.Name,
			types.JSONPatchType,
			prepared.patch,
			metav1.PatchOptions{DryRun: []string{metav1.DryRunAll}, FieldManager: YAMLFieldManager},
		)
		if err != nil {
			err = r.classifyYAMLPatchError(ctx, identity, expectedResourceVersion, err)
			return PreparedYAML{}, fmt.Errorf("dry-run JSON patch: %w", err)
		}
		if err := validatePatchedYAMLIdentity(identity, dryRun); err != nil {
			return PreparedYAML{}, err
		}
	}
	secret := identity.Group == "" && identity.Version == "v1" && identity.Resource == "secrets"
	unifiedDiff, unifiedDiffTruncated, err := unifiedYAMLDisplayDiff(
		prepared.current, dryRun, secret,
	)
	if err != nil {
		return PreparedYAML{}, fmt.Errorf("build YAML display diff: %w", err)
	}
	return PreparedYAML{
		Identity: identity, CurrentResourceVersion: prepared.current.GetResourceVersion(),
		NormalizedYAML: prepared.normalized,
		Diff: semanticYAMLDiff(
			prepared.current, dryRun, secret,
		),
		UnifiedDiff: unifiedDiff, UnifiedDiffTruncated: unifiedDiffTruncated,
	}, nil
}

// ApplyYAML repeats all preparation checks immediately before mutation. The
// UID and resourceVersion test operations in the JSON patch are API-side
// preconditions, closing the race between the fresh GET and patch. Admission
// preview remains PrepareYAML's responsibility; repeating its identical
// dry-run here would add a redundant API request after confirmation.
func (r *Reader) ApplyYAML(
	ctx context.Context,
	identity Identity,
	yamlUTF8 []byte,
	expectedResourceVersion string,
	forceFieldOwnership bool,
) (AppliedYAML, error) {
	if forceFieldOwnership {
		return AppliedYAML{}, ErrYAMLForceOwnershipUnsupported
	}
	prepared, err := r.prepareYAMLInput(ctx, identity, yamlUTF8, expectedResourceVersion)
	if err != nil {
		return AppliedYAML{}, err
	}
	if len(prepared.patch) == 0 {
		return AppliedYAML{
			Identity: identity, NewResourceVersion: prepared.current.GetResourceVersion(),
		}, nil
	}
	updated, err := prepared.resource.Patch(
		ctx,
		identity.Name,
		types.JSONPatchType,
		prepared.patch,
		metav1.PatchOptions{FieldManager: YAMLFieldManager},
	)
	if err != nil {
		err = r.classifyYAMLPatchError(ctx, identity, expectedResourceVersion, err)
		return AppliedYAML{}, fmt.Errorf("JSON patch: %w", err)
	}
	if err := validatePatchedYAMLIdentity(identity, updated); err != nil {
		return AppliedYAML{}, err
	}
	return AppliedYAML{Identity: identity, NewResourceVersion: updated.GetResourceVersion()}, nil
}

type preparedYAMLInput struct {
	current    *unstructured.Unstructured
	normalized []byte
	patch      []byte
	resource   dynamicResource
}

func (r *Reader) prepareYAMLInput(
	ctx context.Context,
	identity Identity,
	yamlUTF8 []byte,
	expectedResourceVersion string,
) (preparedYAMLInput, error) {
	if err := identity.Validate(); err != nil {
		return preparedYAMLInput{}, err
	}
	if strings.TrimSpace(expectedResourceVersion) == "" {
		return preparedYAMLInput{}, &ResourceVersionConflictError{Expected: expectedResourceVersion}
	}
	desired, err := parseSingleYAMLObject(yamlUTF8)
	if err != nil {
		return preparedYAMLInput{}, err
	}
	current, err := r.Get(ctx, identity)
	if err != nil {
		return preparedYAMLInput{}, err
	}
	if current.GetResourceVersion() != expectedResourceVersion {
		return preparedYAMLInput{}, &ResourceVersionConflictError{
			Expected: expectedResourceVersion, Current: current.GetResourceVersion(),
		}
	}
	if err := validateYAMLIdentity(identity, current, desired, expectedResourceVersion); err != nil {
		return preparedYAMLInput{}, err
	}

	// These fields are owned by the API server or status controllers and are
	// never part of a generic editor patch or its normalized preview. Omitting
	// them from the client YAML therefore leaves their live values untouched.
	desired = sanitizeYAMLEditObject(desired)
	desired.SetResourceVersion(expectedResourceVersion)
	patch, err := minimalYAMLJSONPatch(sanitizeYAMLEditObject(current), desired, identity, expectedResourceVersion)
	if err != nil {
		return preparedYAMLInput{}, err
	}

	normalizedJSON, err := desired.MarshalJSON()
	if err != nil {
		return preparedYAMLInput{}, fmt.Errorf("normalize YAML object: %w", err)
	}
	normalized, err := sigyaml.JSONToYAML(normalizedJSON)
	if err != nil {
		return preparedYAMLInput{}, fmt.Errorf("format normalized YAML: %w", err)
	}
	resource, err := r.resolver.Resource(identity.SessionID, identity.GVR(), identity.Namespace)
	if err != nil {
		return preparedYAMLInput{}, err
	}
	return preparedYAMLInput{current: current, normalized: normalized, patch: patch, resource: resource}, nil
}

// dynamicResource names the subset used here without widening Resolver's
// public contract.
type dynamicResource interface {
	Patch(context.Context, string, types.PatchType, []byte, metav1.PatchOptions, ...string) (*unstructured.Unstructured, error)
}

func sanitizeYAMLEditObject(value *unstructured.Unstructured) *unstructured.Unstructured {
	if value == nil {
		return nil
	}
	result := value.DeepCopy()
	unstructured.RemoveNestedField(result.Object, "status")
	for _, field := range []string{
		"managedFields",
		"generation",
		"creationTimestamp",
		"deletionTimestamp",
		"deletionGracePeriodSeconds",
		"selfLink",
	} {
		unstructured.RemoveNestedField(result.Object, "metadata", field)
	}
	return result
}

// minimalYAMLJSONPatch builds the material RFC 6902 change only. Map fields
// omitted from the edited YAML are removed, explicit nulls remain null values,
// and changed lists are replaced atomically. Unchanged maps, lists, scalars,
// and unknown CRD fields do not enter the patch.
func minimalYAMLJSONPatch(
	current, desired *unstructured.Unstructured,
	identity Identity,
	expectedResourceVersion string,
) ([]byte, error) {
	if current == nil || desired == nil {
		return nil, errors.New("cannot create a YAML JSON patch without current and desired objects")
	}
	material := make([]map[string]any, 0, 16)
	appendMinimalJSONPatch(&material, "", current.Object, desired.Object)
	if len(material) == 0 {
		return nil, nil
	}
	// The request URL pins GVR, namespace, and name. Test operations close
	// same-name recreation and concurrent-update races before any mutation.
	operations := make([]map[string]any, 0, len(material)+2)
	operations = append(operations,
		map[string]any{"op": "test", "path": "/metadata/uid", "value": identity.UID},
		map[string]any{"op": "test", "path": "/metadata/resourceVersion", "value": expectedResourceVersion},
	)
	operations = append(operations, material...)
	encoded, err := json.Marshal(operations)
	if err != nil {
		return nil, fmt.Errorf("encode YAML JSON patch: %w", err)
	}
	return encoded, nil
}

func appendMinimalJSONPatch(result *[]map[string]any, path string, current, desired map[string]any) {
	keys := make([]string, 0, len(current)+len(desired))
	seen := make(map[string]struct{}, len(current)+len(desired))
	for key := range current {
		seen[key] = struct{}{}
		keys = append(keys, key)
	}
	for key := range desired {
		if _, exists := seen[key]; !exists {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	for _, key := range keys {
		currentValue, currentExists := current[key]
		desiredValue, desiredExists := desired[key]
		fieldPath := path + "/" + escapeJSONPointerToken(key)
		switch {
		case !desiredExists:
			*result = append(*result, map[string]any{"op": "remove", "path": fieldPath})
		case !currentExists:
			*result = append(*result, map[string]any{"op": "add", "path": fieldPath, "value": desiredValue})
		default:
			currentMap, currentIsMap := currentValue.(map[string]any)
			desiredMap, desiredIsMap := desiredValue.(map[string]any)
			if currentIsMap && desiredIsMap {
				appendMinimalJSONPatch(result, fieldPath, currentMap, desiredMap)
				continue
			}
			if !reflect.DeepEqual(currentValue, desiredValue) {
				*result = append(*result, map[string]any{"op": "replace", "path": fieldPath, "value": desiredValue})
			}
		}
	}
}

func escapeJSONPointerToken(value string) string {
	value = strings.ReplaceAll(value, "~", "~0")
	return strings.ReplaceAll(value, "/", "~1")
}

func validatePatchedYAMLIdentity(identity Identity, value *unstructured.Unstructured) error {
	if value == nil {
		return errors.New("Kubernetes API returned no object for YAML patch")
	}
	if actualUID := string(value.GetUID()); actualUID != identity.UID {
		return &IdentityChangedError{
			ExpectedUID: identity.UID, ActualUID: actualUID,
			Namespace: identity.Namespace, Name: identity.Name,
		}
	}
	return nil
}

func (r *Reader) classifyYAMLPatchError(
	ctx context.Context,
	identity Identity,
	expectedResourceVersion string,
	patchErr error,
) error {
	if !apierrors.IsConflict(patchErr) && !apierrors.IsInvalid(patchErr) && !apierrors.IsBadRequest(patchErr) {
		return patchErr
	}
	latest, err := r.Get(ctx, identity)
	var changed *IdentityChangedError
	if errors.As(err, &changed) {
		return err
	}
	if apierrors.IsNotFound(err) {
		return err
	}
	if err == nil && latest.GetResourceVersion() != expectedResourceVersion {
		return &ResourceVersionConflictError{
			Expected: expectedResourceVersion,
			Current:  latest.GetResourceVersion(),
		}
	}
	return patchErr
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
		if err := kubejson.Unmarshal(jsonValue, &object); err != nil || object == nil {
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

func semanticYAMLDiff(before, after *unstructured.Unstructured, secret bool) []SemanticDiff {
	left := sanitizeDiffObject(before)
	right := sanitizeDiffObject(after)
	result := make([]SemanticDiff, 0, 16)
	appendSemanticDiff(&result, "", left, right, secret)
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

func appendSemanticDiff(result *[]SemanticDiff, path string, before, after any, secret bool) {
	if reflect.DeepEqual(before, after) || len(*result) >= 200 {
		return
	}
	left, leftMap := before.(map[string]any)
	right, rightMap := after.(map[string]any)
	// A Secret may legitimately gain its first data key or lose its last one.
	// Descend through a one-sided data map so those transitions still carry the
	// explicitly requested decoded bytes instead of collapsing to a map count.
	if secret && path == "data" {
		if _, missing := before.(missingSemanticDiffValue); missing {
			left, leftMap = map[string]any{}, true
		}
		if _, missing := after.(missingSemanticDiffValue); missing {
			right, rightMap = map[string]any{}, true
		}
	}
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
			leftValue, leftExists := left[key]
			if !leftExists {
				leftValue = missingSemanticDiffValue{}
			}
			rightValue, rightExists := right[key]
			if !rightExists {
				rightValue = missingSemanticDiffValue{}
			}
			appendSemanticDiff(result, child, leftValue, rightValue, secret)
		}
		return
	}
	entry := SemanticDiff{
		Path: path, BeforeSummary: summarizeDiffValue(before, path), AfterSummary: summarizeDiffValue(after, path),
	}
	if secret && strings.HasPrefix(path, "data.") {
		entry.BeforeDecodedSecretValue, entry.HasBeforeDecodedSecretValue = decodedSecretValue(before)
		entry.AfterDecodedSecretValue, entry.HasAfterDecodedSecretValue = decodedSecretValue(after)
	}
	*result = append(*result, entry)
}

func decodedSecretValue(value any) ([]byte, bool) {
	if _, missing := value.(missingSemanticDiffValue); missing {
		return nil, false
	}
	switch typed := value.(type) {
	case string:
		decoded, err := base64.StdEncoding.DecodeString(typed)
		if err != nil {
			return nil, false
		}
		return decoded, true
	case []byte:
		return append([]byte(nil), typed...), true
	default:
		return nil, false
	}
}

func unifiedYAMLDisplayDiff(
	before, after *unstructured.Unstructured,
	secret bool,
) ([]byte, bool, error) {
	left, err := yamlDiffDocument(before, secret)
	if err != nil {
		return nil, false, err
	}
	right, err := yamlDiffDocument(after, secret)
	if err != nil {
		return nil, false, err
	}
	output := boundedYAMLDiffWriter{limit: maximumUnifiedYAMLDiffBytes}
	err = difflib.WriteUnifiedDiff(&output, difflib.UnifiedDiff{
		A: difflib.SplitLines(string(left)), B: difflib.SplitLines(string(right)),
		FromFile: "server", ToFile: "edited", Context: 3,
	})
	if err != nil {
		return nil, false, err
	}
	if !output.truncated {
		return output.value, false, nil
	}
	marker := []byte("\n... unified diff truncated for display ...\n")
	limit := maximumUnifiedYAMLDiffBytes - len(marker)
	for limit > 0 && !utf8.Valid(output.value[:limit]) {
		limit--
	}
	bounded := make([]byte, 0, maximumUnifiedYAMLDiffBytes)
	bounded = append(bounded, output.value[:limit]...)
	bounded = append(bounded, marker...)
	return bounded, true, nil
}

// boundedYAMLDiffWriter reports successful writes after its display budget is
// full so difflib can finish its comparison without retaining an unbounded
// rendered result. The caller appends a visible truncation marker afterward.
type boundedYAMLDiffWriter struct {
	value     []byte
	limit     int
	truncated bool
}

func (w *boundedYAMLDiffWriter) Write(value []byte) (int, error) {
	written := len(value)
	remaining := w.limit - len(w.value)
	if remaining <= 0 {
		w.truncated = w.truncated || written > 0
		return written, nil
	}
	if written > remaining {
		w.value = append(w.value, value[:remaining]...)
		w.truncated = true
		return written, nil
	}
	w.value = append(w.value, value...)
	return written, nil
}

func yamlDiffDocument(value *unstructured.Unstructured, secret bool) ([]byte, error) {
	display := sanitizeDiffObject(value)
	if secret {
		if data, ok := display["data"].(map[string]any); ok {
			for key, encoded := range data {
				decoded, valid := decodedSecretValue(encoded)
				if !valid {
					data[key] = "<decoded value unavailable>"
					continue
				}
				digest := sha256.Sum256(decoded)
				data[key] = fmt.Sprintf(
					"<decoded %d bytes · SHA-256 %x · see decoded diff below>",
					len(decoded), digest[:6],
				)
			}
		}
		delete(display, "stringData")
	}
	return sigyaml.Marshal(display)
}

type missingSemanticDiffValue struct{}

func summarizeDiffValue(value any, path string) string {
	if _, missing := value.(missingSemanticDiffValue); missing {
		return "<absent>"
	}
	if value == nil {
		return "null"
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
