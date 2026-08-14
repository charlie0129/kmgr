package object

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"sync"
	"testing"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/validation/field"
	"k8s.io/client-go/dynamic"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	"k8s.io/client-go/rest"
	ktesting "k8s.io/client-go/testing"
)

func TestPrepareYAMLUsesMinimalJSONPatchAndProtectsServerFields(t *testing.T) {
	t.Parallel()
	current := kubernetesObject("apps/v1", "Deployment", "deployments", "ns", "web", "uid")
	current.Object["spec"] = map[string]any{
		"replicas": int64(1), "unknownField": "preserve-me", "largeInteger": int64(9_007_199_254_740_993),
	}
	current.Object["status"] = map[string]any{"readyReplicas": int64(1)}
	metadata := current.Object["metadata"].(map[string]any)
	metadata["generation"] = int64(7)
	metadata["creationTimestamp"] = "2026-08-14T00:00:00Z"
	current.SetManagedFields([]metav1.ManagedFieldsEntry{{Manager: "controller"}})
	reader, client := fakeYAMLReader(t, current)
	var calls []ktesting.PatchActionImpl
	client.PrependReactor("patch", "deployments", func(action ktesting.Action) (bool, runtime.Object, error) {
		patch := requirePatchAction(t, action)
		calls = append(calls, patch)
		result := current.DeepCopy()
		result.Object["spec"].(map[string]any)["replicas"] = int64(2)
		return true, result, nil
	})
	identity := Identity{
		SessionID: "session", Group: "apps", Version: "v1", Resource: "deployments",
		Namespace: "ns", Name: "web", UID: "uid",
	}
	yaml := []byte(`apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: ns
  uid: uid
  resourceVersion: rv-1
  generation: 99
  creationTimestamp: "2099-01-01T00:00:00Z"
  managedFields:
  - manager: malicious
spec:
  replicas: 2
  unknownField: preserve-me
  largeInteger: 9007199254740993
status:
  readyReplicas: 99
`)
	prepared, err := reader.PrepareYAML(context.Background(), identity, yaml, "rv-1", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(calls) != 1 {
		t.Fatalf("patch calls = %d, want 1", len(calls))
	}
	assertJSONPatchAction(t, calls[0], true)
	assertJSONEqual(t, calls[0].GetPatch(), `[
  {"op":"test","path":"/metadata/uid","value":"uid"},
  {"op":"test","path":"/metadata/resourceVersion","value":"rv-1"},
  {"op":"replace","path":"/spec/replicas","value":2}
]`)
	patch := string(calls[0].GetPatch())
	if strings.Contains(patch, "unknownField") || strings.Contains(patch, "largeInteger") || strings.Contains(patch, "managedFields") ||
		strings.Contains(patch, "readyReplicas") || strings.Contains(patch, "generation") ||
		strings.Contains(patch, "creationTimestamp") {
		t.Fatalf("unchanged or protected fields reached API: %s", patch)
	}
	normalized := string(prepared.NormalizedYAML)
	if !strings.Contains(normalized, "replicas: 2") || !strings.Contains(normalized, "unknownField: preserve-me") ||
		strings.Contains(normalized, "managedFields") || strings.Contains(normalized, "status:") ||
		strings.Contains(normalized, "generation:") || strings.Contains(normalized, "creationTimestamp:") {
		t.Fatalf("normalized YAML = %s", normalized)
	}
	if len(prepared.Diff) != 1 || prepared.Diff[0].Path != "spec.replicas" {
		t.Fatalf("diff = %#v", prepared.Diff)
	}
}

func TestPrepareYAMLJSONPatchSupportsCRDExactNullDeletionArraysAndEscapedKeys(t *testing.T) {
	t.Parallel()
	current := kubernetesObject("example.io/v1alpha1", "Widget", "widgets", "ns", "sample", "uid")
	current.Object["spec"] = map[string]any{
		"keep":       "preserve-me",
		"opaque":     map[string]any{"vendorField": "preserve-me"},
		"removeMe":   "old",
		"omitted":    "old",
		"nested":     map[string]any{"keep": "same", "remove": "old"},
		"items":      []any{"first", "second"},
		"toMap":      "legacy",
		"toScalar":   map[string]any{"old": true},
		"stillNull":  nil,
		"deleteNull": nil,
		"escaped":    map[string]any{"a/b~c": "old"},
	}
	reader, client := fakeYAMLReader(t, current)
	var calls []ktesting.PatchActionImpl
	client.PrependReactor("patch", "widgets", func(action ktesting.Action) (bool, runtime.Object, error) {
		patch := requirePatchAction(t, action)
		calls = append(calls, patch)
		result := current.DeepCopy()
		spec := result.Object["spec"].(map[string]any)
		spec["removeMe"] = nil
		delete(spec, "omitted")
		spec["nested"].(map[string]any)["remove"] = nil
		spec["items"] = []any{"second"}
		spec["toMap"] = map[string]any{"enabled": true}
		spec["toScalar"] = "current"
		spec["newNull"] = nil
		delete(spec, "deleteNull")
		spec["escaped"].(map[string]any)["a/b~c"] = "new"
		return true, result, nil
	})
	identity := Identity{
		SessionID: "session", Group: "example.io", Version: "v1alpha1", Resource: "widgets",
		Namespace: "ns", Name: "sample", UID: "uid",
	}
	yaml := []byte(`apiVersion: example.io/v1alpha1
kind: Widget
metadata:
  name: sample
  namespace: ns
  uid: uid
  resourceVersion: rv-1
spec:
  keep: preserve-me
  opaque:
    vendorField: preserve-me
  removeMe: null
  newNull: null
  stillNull: null
  nested:
    keep: same
    remove: null
  items:
  - second
  toMap:
    enabled: true
  toScalar: current
  escaped:
    "a/b~c": new
`)
	prepared, err := reader.PrepareYAML(context.Background(), identity, yaml, "rv-1", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(calls) != 1 {
		t.Fatalf("patch calls = %d, want 1", len(calls))
	}
	assertJSONPatchAction(t, calls[0], true)
	assertJSONEqual(t, calls[0].GetPatch(), `[
  {"op":"test","path":"/metadata/uid","value":"uid"},
  {"op":"test","path":"/metadata/resourceVersion","value":"rv-1"},
  {"op":"remove","path":"/spec/deleteNull"},
  {"op":"replace","path":"/spec/escaped/a~1b~0c","value":"new"},
  {"op":"replace","path":"/spec/items","value":["second"]},
  {"op":"replace","path":"/spec/nested/remove","value":null},
  {"op":"add","path":"/spec/newNull","value":null},
  {"op":"remove","path":"/spec/omitted"},
  {"op":"replace","path":"/spec/removeMe","value":null},
  {"op":"replace","path":"/spec/toMap","value":{"enabled":true}},
  {"op":"replace","path":"/spec/toScalar","value":"current"}
]`)
	assertSemanticDiff(t, prepared.Diff, "spec.newNull", "<absent>", "null")
	assertSemanticDiff(t, prepared.Diff, "spec.deleteNull", "null", "<absent>")
}

func TestPrepareYAMLRejectsIdentityResourceVersionAndMultipleDocuments(t *testing.T) {
	t.Parallel()
	current := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	reader, _ := fakeYAMLReader(t, current)
	identity := Identity{
		SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid",
	}
	base := `apiVersion: v1
kind: ConfigMap
metadata:
  name: %s
  namespace: ns
  uid: uid
`
	_, err := reader.PrepareYAML(context.Background(), identity, []byte(fmtSprintf(base, "other")), "rv-1", false)
	var mismatch *YAMLIdentityMismatchError
	if !errors.As(err, &mismatch) || mismatch.Field != "metadata.name" {
		t.Fatalf("identity error = %#v", err)
	}
	_, err = reader.PrepareYAML(context.Background(), identity, []byte(fmtSprintf(base, "settings")), "stale", false)
	var conflict *ResourceVersionConflictError
	if !errors.As(err, &conflict) || conflict.Current != "rv-1" {
		t.Fatalf("resourceVersion error = %#v", err)
	}
	_, err = reader.PrepareYAML(context.Background(), identity, []byte(fmtSprintf(base, "settings")+"---\n{}\n"), "rv-1", false)
	if !errors.Is(err, ErrInvalidYAML) {
		t.Fatalf("multiple-document error = %#v", err)
	}
}

func TestYAMLEditRejectsForceFieldOwnership(t *testing.T) {
	t.Parallel()
	current := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	reader, client := fakeYAMLReader(t, current)
	identity := Identity{
		SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid",
	}
	yaml := []byte(`apiVersion: v1
kind: ConfigMap
metadata:
  name: settings
  namespace: ns
  uid: uid
`)
	if _, err := reader.PrepareYAML(context.Background(), identity, yaml, "rv-1", true); !errors.Is(err, ErrYAMLForceOwnershipUnsupported) {
		t.Fatalf("PrepareYAML force error = %#v", err)
	}
	if _, err := reader.ApplyYAML(context.Background(), identity, yaml, "rv-1", true); !errors.Is(err, ErrYAMLForceOwnershipUnsupported) {
		t.Fatalf("ApplyYAML force error = %#v", err)
	}
	if actions := client.Actions(); len(actions) != 0 {
		t.Fatalf("force option reached Kubernetes client: %#v", actions)
	}
}

func TestYAMLEditNoOpSkipsDryRunAndMutation(t *testing.T) {
	t.Parallel()
	current := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	current.Object["data"] = map[string]any{"mode": "fast"}
	reader, client := fakeYAMLReader(t, current)
	var patches int
	client.PrependReactor("patch", "configmaps", func(action ktesting.Action) (bool, runtime.Object, error) {
		patches++
		return true, nil, errors.New("no-op YAML edit must not patch")
	})
	identity := Identity{
		SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid",
	}
	yaml := []byte(`apiVersion: v1
kind: ConfigMap
metadata:
  name: settings
  namespace: ns
  uid: uid
  resourceVersion: rv-1
data:
  mode: fast
`)
	prepared, err := reader.PrepareYAML(context.Background(), identity, yaml, "rv-1", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(prepared.Diff) != 0 {
		t.Fatalf("no-op diff = %#v", prepared.Diff)
	}
	applied, err := reader.ApplyYAML(context.Background(), identity, yaml, "rv-1", false)
	if err != nil {
		t.Fatal(err)
	}
	if patches != 0 || applied.NewResourceVersion != "rv-1" {
		t.Fatalf("patches = %d, applied = %#v", patches, applied)
	}
}

func TestApplyYAMLUsesSameMinimalJSONPatchForDryRunAndMutation(t *testing.T) {
	t.Parallel()
	current := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	reader, client := fakeYAMLReader(t, current)
	var calls []ktesting.PatchActionImpl
	client.PrependReactor("patch", "configmaps", func(action ktesting.Action) (bool, runtime.Object, error) {
		patch := requirePatchAction(t, action)
		calls = append(calls, patch)
		result := current.DeepCopy()
		result.Object["data"] = map[string]any{"mode": "fast"}
		if len(calls) == 2 {
			result.SetResourceVersion("rv-2")
		}
		return true, result, nil
	})
	identity := Identity{
		SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid",
	}
	yaml := []byte(`apiVersion: v1
kind: ConfigMap
metadata:
  name: settings
  namespace: ns
  uid: uid
data:
  mode: fast
`)
	applied, err := reader.ApplyYAML(context.Background(), identity, yaml, "rv-1", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(calls) != 2 || applied.NewResourceVersion != "rv-2" {
		t.Fatalf("patches = %d, applied = %#v", len(calls), applied)
	}
	assertJSONPatchAction(t, calls[0], true)
	assertJSONPatchAction(t, calls[1], false)
	if !reflect.DeepEqual(calls[0].GetPatch(), calls[1].GetPatch()) {
		t.Fatalf("dry-run patch %s != mutation patch %s", calls[0].GetPatch(), calls[1].GetPatch())
	}
	assertJSONEqual(t, calls[0].GetPatch(), `[
  {"op":"test","path":"/metadata/uid","value":"uid"},
  {"op":"test","path":"/metadata/resourceVersion","value":"rv-1"},
  {"op":"add","path":"/data","value":{"mode":"fast"}}
]`)
}

func TestApplyYAMLSendsJSONPatchHTTPProtocol(t *testing.T) {
	t.Parallel()
	current := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	var mu sync.Mutex
	var requests []recordedHTTPRequest
	patches := 0
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		recorded, err := recordHTTPRequest(request)
		if err != nil {
			http.Error(writer, err.Error(), http.StatusInternalServerError)
			return
		}
		mu.Lock()
		requests = append(requests, recorded)
		if request.Method == http.MethodPatch {
			patches++
		}
		patchNumber := patches
		mu.Unlock()
		switch request.Method {
		case http.MethodGet:
			writeJSONResponse(writer, http.StatusOK, current)
		case http.MethodPatch:
			result := current.DeepCopy()
			result.Object["data"] = map[string]any{"mode": "fast"}
			if patchNumber == 2 {
				result.SetResourceVersion("rv-2")
			}
			writeJSONResponse(writer, http.StatusOK, result)
		default:
			http.Error(writer, "unexpected method", http.StatusMethodNotAllowed)
		}
	}))
	t.Cleanup(server.Close)
	reader := httpYAMLReader(t, server.URL)
	identity := Identity{
		SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid",
	}
	yaml := []byte(`apiVersion: v1
kind: ConfigMap
metadata:
  name: settings
  namespace: ns
  uid: uid
data:
  mode: fast
`)
	applied, err := reader.ApplyYAML(context.Background(), identity, yaml, "rv-1", false)
	if err != nil {
		t.Fatal(err)
	}
	if applied.NewResourceVersion != "rv-2" {
		t.Fatalf("applied = %#v", applied)
	}
	mu.Lock()
	values := append([]recordedHTTPRequest(nil), requests...)
	mu.Unlock()
	if len(values) != 3 || values[0].Method != http.MethodGet ||
		values[1].Method != http.MethodPatch || values[2].Method != http.MethodPatch {
		t.Fatalf("HTTP requests = %#v", values)
	}
	for index, request := range values[1:] {
		if request.Path != "/api/v1/namespaces/ns/configmaps/settings" ||
			request.ContentType != string(types.JSONPatchType) || request.Query.Get("fieldManager") != YAMLFieldManager {
			t.Fatalf("patch request %d = %#v", index, request)
		}
		wantDryRun := ""
		if index == 0 {
			wantDryRun = metav1.DryRunAll
		}
		if request.Query.Get("dryRun") != wantDryRun {
			t.Fatalf("patch request %d dryRun = %q, want %q", index, request.Query.Get("dryRun"), wantDryRun)
		}
		assertJSONEqual(t, request.Body, `[
  {"op":"test","path":"/metadata/uid","value":"uid"},
  {"op":"test","path":"/metadata/resourceVersion","value":"rv-1"},
  {"op":"add","path":"/data","value":{"mode":"fast"}}
]`)
	}
}

func TestApplyYAMLMapsAPIRaceToResourceVersionConflict(t *testing.T) {
	t.Parallel()
	current := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	reader, client := fakeYAMLReader(t, current)
	gvr := schema.GroupVersionResource{Version: "v1", Resource: "configmaps"}
	var patches int
	client.PrependReactor("patch", "configmaps", func(action ktesting.Action) (bool, runtime.Object, error) {
		patches++
		if patches == 1 {
			result := current.DeepCopy()
			result.Object["data"] = map[string]any{"mode": "fast"}
			return true, result, nil
		}
		changed := current.DeepCopy()
		changed.SetResourceVersion("rv-2")
		if err := client.Tracker().Update(gvr, changed, "ns"); err != nil {
			t.Fatal(err)
		}
		return true, nil, apierrors.NewInvalid(
			schema.GroupKind{Kind: "ConfigMap"},
			"settings",
			field.ErrorList{field.Invalid(
				field.NewPath("metadata", "resourceVersion"), "rv-1", "JSON patch test operation failed",
			)},
		)
	})
	identity := Identity{
		SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid",
	}
	yaml := []byte(`apiVersion: v1
kind: ConfigMap
metadata:
  name: settings
  namespace: ns
  uid: uid
data:
  mode: fast
`)
	_, err := reader.ApplyYAML(context.Background(), identity, yaml, "rv-1", false)
	var conflict *ResourceVersionConflictError
	if !errors.As(err, &conflict) || conflict.Expected != "rv-1" || conflict.Current != "rv-2" {
		t.Fatalf("ApplyYAML conflict = %#v", err)
	}
}

func TestApplyYAMLClassifiesHTTPDryRunTestFailureAsRecreation(t *testing.T) {
	t.Parallel()
	current := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	recreated := current.DeepCopy()
	recreated.SetUID("new-uid")
	recreated.SetResourceVersion("rv-2")
	var mu sync.Mutex
	getRequests := 0
	patchRequests := 0
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch request.Method {
		case http.MethodGet:
			getRequests++
			if patchRequests == 0 {
				writeJSONResponse(writer, http.StatusOK, current)
			} else {
				writeJSONResponse(writer, http.StatusOK, recreated)
			}
		case http.MethodPatch:
			patchRequests++
			writeJSONResponse(writer, http.StatusUnprocessableEntity, metav1.Status{
				TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Status"},
				Status:   metav1.StatusFailure,
				Reason:   metav1.StatusReasonInvalid,
				Code:     http.StatusUnprocessableEntity,
				Message:  "JSON patch UID test operation failed",
			})
		default:
			http.Error(writer, "unexpected method", http.StatusMethodNotAllowed)
		}
	}))
	t.Cleanup(server.Close)
	reader := httpYAMLReader(t, server.URL)
	identity := Identity{
		SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid",
	}
	yaml := []byte(`apiVersion: v1
kind: ConfigMap
metadata:
  name: settings
  namespace: ns
  uid: uid
data:
  mode: fast
`)
	_, err := reader.ApplyYAML(context.Background(), identity, yaml, "rv-1", false)
	var changed *IdentityChangedError
	if !errors.As(err, &changed) || changed.ExpectedUID != "uid" || changed.ActualUID != "new-uid" {
		t.Fatalf("ApplyYAML recreation = %#v", err)
	}
	mu.Lock()
	gets, patches := getRequests, patchRequests
	mu.Unlock()
	if gets != 2 || patches != 1 {
		t.Fatalf("HTTP requests: GET = %d, PATCH = %d", gets, patches)
	}
}

func TestApplyYAMLMapsSameNameRecreationAfterDryRun(t *testing.T) {
	t.Parallel()
	current := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	reader, client := fakeYAMLReader(t, current)
	gvr := schema.GroupVersionResource{Version: "v1", Resource: "configmaps"}
	var patches int
	client.PrependReactor("patch", "configmaps", func(action ktesting.Action) (bool, runtime.Object, error) {
		patches++
		if patches == 1 {
			result := current.DeepCopy()
			result.Object["data"] = map[string]any{"mode": "fast"}
			return true, result, nil
		}
		recreated := current.DeepCopy()
		recreated.SetUID("new-uid")
		recreated.SetResourceVersion("rv-2")
		if err := client.Tracker().Update(gvr, recreated, "ns"); err != nil {
			t.Fatal(err)
		}
		return true, nil, apierrors.NewInvalid(
			schema.GroupKind{Kind: "ConfigMap"},
			"settings",
			field.ErrorList{field.Invalid(field.NewPath("metadata", "uid"), "uid", "field is immutable")},
		)
	})
	identity := Identity{
		SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid",
	}
	yaml := []byte(`apiVersion: v1
kind: ConfigMap
metadata:
  name: settings
  namespace: ns
  uid: uid
data:
  mode: fast
`)
	_, err := reader.ApplyYAML(context.Background(), identity, yaml, "rv-1", false)
	var changed *IdentityChangedError
	if !errors.As(err, &changed) || changed.ExpectedUID != "uid" || changed.ActualUID != "new-uid" {
		t.Fatalf("ApplyYAML recreation = %#v", err)
	}
}

func assertJSONPatchAction(t *testing.T, action ktesting.PatchActionImpl, dryRun bool) {
	t.Helper()
	if action.GetPatchType() != types.JSONPatchType {
		t.Fatalf("patch type = %q, want %q", action.GetPatchType(), types.JSONPatchType)
	}
	options := action.GetPatchOptions()
	if options.Force != nil || options.FieldManager != YAMLFieldManager {
		t.Fatalf("patch options = %#v", options)
	}
	wantDryRun := []string(nil)
	if dryRun {
		wantDryRun = []string{metav1.DryRunAll}
	}
	if !reflect.DeepEqual(options.DryRun, wantDryRun) {
		t.Fatalf("dry-run options = %#v, want %#v", options.DryRun, wantDryRun)
	}
}

func requirePatchAction(t *testing.T, action ktesting.Action) ktesting.PatchActionImpl {
	t.Helper()
	patch, ok := action.(ktesting.PatchActionImpl)
	if !ok {
		t.Fatalf("action type = %T, want testing.PatchActionImpl", action)
	}
	return patch
}

func assertJSONEqual(t *testing.T, actual []byte, expected string) {
	t.Helper()
	var actualValue, expectedValue any
	if err := json.Unmarshal(actual, &actualValue); err != nil {
		t.Fatalf("decode actual JSON %q: %v", actual, err)
	}
	if err := json.Unmarshal([]byte(expected), &expectedValue); err != nil {
		t.Fatalf("decode expected JSON %q: %v", expected, err)
	}
	if !reflect.DeepEqual(actualValue, expectedValue) {
		t.Fatalf("JSON = %s, want %s", actual, expected)
	}
}

func assertSemanticDiff(t *testing.T, values []SemanticDiff, path, before, after string) {
	t.Helper()
	for _, value := range values {
		if value.Path == path {
			if value.BeforeSummary != before || value.AfterSummary != after {
				t.Fatalf("diff %q = %#v, want %q -> %q", path, value, before, after)
			}
			return
		}
	}
	t.Fatalf("diff %q not found in %#v", path, values)
}

type recordedHTTPRequest struct {
	Method      string
	Path        string
	ContentType string
	Query       url.Values
	Body        []byte
}

func recordHTTPRequest(request *http.Request) (recordedHTTPRequest, error) {
	body, err := io.ReadAll(request.Body)
	if err != nil {
		return recordedHTTPRequest{}, err
	}
	return recordedHTTPRequest{
		Method: request.Method, Path: request.URL.Path,
		ContentType: request.Header.Get("Content-Type"), Query: request.URL.Query(), Body: body,
	}, nil
}

func writeJSONResponse(writer http.ResponseWriter, statusCode int, value any) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(statusCode)
	_ = json.NewEncoder(writer).Encode(value)
}

func httpYAMLReader(t *testing.T, serverURL string) *Reader {
	t.Helper()
	client, err := dynamic.NewForConfig(&rest.Config{Host: serverURL})
	if err != nil {
		t.Fatal(err)
	}
	reader, err := NewReader(fakeResolver{client: client})
	if err != nil {
		t.Fatal(err)
	}
	return reader
}

func fakeYAMLReader(t *testing.T, values ...runtime.Object) (*Reader, *dynamicfake.FakeDynamicClient) {
	t.Helper()
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), values...)
	reader, err := NewReader(fakeResolver{client: client})
	if err != nil {
		t.Fatal(err)
	}
	return reader, client
}

// Keeps the YAML fixtures readable without importing fmt solely for Sprintf.
func fmtSprintf(format, value string) string { return strings.Replace(format, "%s", value, 1) }
