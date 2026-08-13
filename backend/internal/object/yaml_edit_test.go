package object

import (
	"context"
	"errors"
	"strings"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	ktesting "k8s.io/client-go/testing"
)

func TestPrepareYAMLProtectsIdentityAndServerOwnedFields(t *testing.T) {
	t.Parallel()
	current := kubernetesObject("apps/v1", "Deployment", "deployments", "ns", "web", "uid")
	current.Object["spec"] = map[string]any{"replicas": int64(1), "unknownField": "preserve-me"}
	current.Object["status"] = map[string]any{"readyReplicas": int64(1)}
	current.SetManagedFields([]metav1.ManagedFieldsEntry{{Manager: "controller"}})
	reader, client := fakeYAMLReader(t, current)
	var calls []ktesting.PatchAction
	client.PrependReactor("patch", "deployments", func(action ktesting.Action) (bool, runtime.Object, error) {
		patch := action.(ktesting.PatchAction)
		calls = append(calls, patch)
		var desired unstructured.Unstructured
		if err := desired.UnmarshalJSON(patch.GetPatch()); err != nil {
			t.Fatal(err)
		}
		// Simulate admission/defaulting and preservation in a real dry-run.
		result := current.DeepCopy()
		resultSpec := result.Object["spec"].(map[string]any)
		for key, value := range desired.Object["spec"].(map[string]any) {
			resultSpec[key] = value
		}
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
  managedFields:
  - manager: malicious
spec:
  replicas: 2
status:
  readyReplicas: 99
`)
	prepared, err := reader.PrepareYAML(context.Background(), identity, yaml, "rv-1", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(calls) != 1 || calls[0].GetPatchType() != types.ApplyPatchType {
		t.Fatalf("patch calls = %#v", calls)
	}
	patch := string(calls[0].GetPatch())
	if strings.Contains(patch, "managedFields") || strings.Contains(patch, "readyReplicas") {
		t.Fatalf("protected fields reached API: %s", patch)
	}
	if !strings.Contains(string(prepared.NormalizedYAML), "replicas: 2") ||
		strings.Contains(string(prepared.NormalizedYAML), "managedFields") ||
		strings.Contains(string(prepared.NormalizedYAML), "status:") {
		t.Fatalf("normalized YAML = %s", prepared.NormalizedYAML)
	}
	if len(prepared.Diff) != 1 || prepared.Diff[0].Path != "spec.replicas" {
		t.Fatalf("diff = %#v", prepared.Diff)
	}
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

func TestApplyYAMLDryRunsBeforeApplyAndNeverForcesByDefault(t *testing.T) {
	t.Parallel()
	current := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	reader, client := fakeYAMLReader(t, current)
	var patches int
	client.PrependReactor("patch", "configmaps", func(action ktesting.Action) (bool, runtime.Object, error) {
		patches++
		result := current.DeepCopy()
		result.SetResourceVersion("rv-2")
		return true, result, nil
	})
	identity := Identity{SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid"}
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
	if patches != 2 || applied.NewResourceVersion != "rv-2" {
		t.Fatalf("patches = %d, applied = %#v", patches, applied)
	}
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
