package object

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

func TestGetRejectsSameNameRecreatedUID(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "new-uid")
	reader := testReader(t, value)
	_, err := reader.Get(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "ns", Name: "pod", UID: "old-uid",
	})
	var changed *IdentityChangedError
	if !errors.As(err, &changed) || changed.ActualUID != "new-uid" {
		t.Fatalf("Get error = %#v, want IdentityChangedError", err)
	}
}

func TestDetailReturnsReadableYAMLWithoutJSONCrossingBoundary(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "uid")
	value.Object["status"] = map[string]any{"phase": "Running"}
	reader := testReader(t, value)
	detail, err := reader.Detail(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "ns", Name: "pod", UID: "uid",
	}, true, true)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(detail.YAML, []byte("kind: Pod")) || bytes.HasPrefix(bytes.TrimSpace(detail.YAML), []byte("{")) {
		t.Fatalf("detail YAML = %q", detail.YAML)
	}
	if len(detail.Summary) == 0 || detail.Summary[len(detail.Summary)-1].Value != "Running" {
		t.Fatalf("summary = %#v", detail.Summary)
	}
}

func TestSecretDataDecodesRawBytesAndNeverFormatsValues(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Secret", "secrets", "ns", "credentials", "uid")
	value.Object["data"] = map[string]any{
		"binary": base64.StdEncoding.EncodeToString([]byte{0, 1, 2, 255}),
		"token":  base64.StdEncoding.EncodeToString([]byte("super-secret-token")),
	}
	reader := testReader(t, value)
	data, err := reader.GetData(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "secrets", Namespace: "ns", Name: "credentials", UID: "uid",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !data.Secret || len(data.Entries) != 2 {
		t.Fatalf("data = %#v", data)
	}
	if data.Entries[0].Key != "binary" || data.Entries[0].Kind != DataBinary || !bytes.Equal(data.Entries[0].Value, []byte{0, 1, 2, 255}) {
		t.Fatalf("binary entry = %#v", data.Entries[0])
	}
	if data.Entries[1].Key != "token" || data.Entries[1].Kind != DataText || string(data.Entries[1].Value) != "super-secret-token" {
		t.Fatalf("token entry metadata mismatch")
	}
	if strings.Contains(strings.ToLower(errors.New("redacted").Error()), "super-secret") {
		t.Fatal("test sentinel unexpectedly leaked")
	}
}

func TestConfigMapPreservesTextAndBinaryKinds(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	value.Object["data"] = map[string]any{"config.yaml": "enabled: true\n"}
	value.Object["binaryData"] = map[string]any{"icon": base64.StdEncoding.EncodeToString([]byte{0x89, 0x50, 0x4e, 0x47})}
	reader := testReader(t, value)
	data, err := reader.GetData(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(data.Entries) != 2 || data.Entries[0].Kind != DataText || data.Entries[1].Kind != DataBinary {
		t.Fatalf("entries = %#v", data.Entries)
	}
	if data.Entries[0].ContentHash == ([32]byte{}) || data.Entries[1].ContentHash == ([32]byte{}) {
		t.Fatal("content hashes were not populated")
	}
}

func TestConfigMapRejectsDuplicateTextAndBinaryKey(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	value.Object["data"] = map[string]any{"same": "text"}
	value.Object["binaryData"] = map[string]any{"same": base64.StdEncoding.EncodeToString([]byte("binary"))}
	reader := testReader(t, value)
	_, err := reader.GetData(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid",
	})
	if err == nil || !strings.Contains(err.Error(), "both data and binaryData") {
		t.Fatalf("GetData error = %v", err)
	}
}

func TestUpdateSecretUsesRawBytesAndOptimisticConcurrency(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Secret", "secrets", "ns", "credentials", "uid")
	value.Object["data"] = map[string]any{"token": base64.StdEncoding.EncodeToString([]byte("old"))}
	reader := testReader(t, value)
	loaded, err := reader.GetData(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "secrets", Namespace: "ns", Name: "credentials", UID: "uid",
	})
	if err != nil {
		t.Fatal(err)
	}
	updated, err := reader.UpdateData(context.Background(), loaded.Identity, loaded.ResourceVersion, []DataMutation{{
		Type: MutationSet, Key: "token", Kind: DataText, Value: []byte("new-value"),
		ExpectedContentHash: loaded.Entries[0].ContentHash[:],
	}})
	if err != nil {
		t.Fatal(err)
	}
	if !updated.Secret || len(updated.Entries) != 1 || string(updated.Entries[0].Value) != "new-value" {
		t.Fatalf("updated data metadata mismatch: %#v", updated)
	}
	fresh, err := reader.GetData(context.Background(), loaded.Identity)
	if err != nil {
		t.Fatal(err)
	}
	if string(fresh.Entries[0].Value) != "new-value" {
		t.Fatalf("fresh value = %q", fresh.Entries[0].Value)
	}
}

func TestUpdateDataRejectsResourceVersionAndPerKeyConflicts(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	value.Object["data"] = map[string]any{"one": "server"}
	reader := testReader(t, value)
	identity := Identity{SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid"}

	_, err := reader.UpdateData(context.Background(), identity, "stale-rv", []DataMutation{{
		Type: MutationSet, Key: "one", Kind: DataText, Value: []byte("local"),
	}})
	var versionConflict *ResourceVersionConflictError
	if !errors.As(err, &versionConflict) {
		t.Fatalf("resource version error = %#v", err)
	}

	wrongHash := make([]byte, 32)
	_, err = reader.UpdateData(context.Background(), identity, "rv-1", []DataMutation{{
		Type: MutationSet, Key: "one", Kind: DataText, Value: []byte("local"), ExpectedContentHash: wrongHash,
	}})
	var dataConflict *DataConflictError
	if !errors.As(err, &dataConflict) || len(dataConflict.CurrentHash) != 32 {
		t.Fatalf("key conflict error = %#v", err)
	}
}

func TestUpdateConfigMapRenamePreservesBinaryKind(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	value.Object["binaryData"] = map[string]any{"old.bin": base64.StdEncoding.EncodeToString([]byte{0, 1})}
	reader := testReader(t, value)
	identity := Identity{SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid"}
	loaded, err := reader.GetData(context.Background(), identity)
	if err != nil {
		t.Fatal(err)
	}
	updated, err := reader.UpdateData(context.Background(), identity, "rv-1", []DataMutation{{
		Type: MutationRename, Key: "old.bin", NewKey: "new.bin", ExpectedContentHash: loaded.Entries[0].ContentHash[:],
	}})
	if err != nil {
		t.Fatal(err)
	}
	if len(updated.Entries) != 1 || updated.Entries[0].Key != "new.bin" || updated.Entries[0].Kind != DataBinary {
		t.Fatalf("renamed entry = %#v", updated.Entries)
	}
}

type fakeResolver struct{ client dynamic.Interface }

func (r fakeResolver) Resource(_ string, gvr schema.GroupVersionResource, namespace string) (dynamic.ResourceInterface, error) {
	resource := r.client.Resource(gvr)
	if namespace != "" {
		return resource.Namespace(namespace), nil
	}
	return resource, nil
}

func testReader(t *testing.T, objects ...runtime.Object) *Reader {
	t.Helper()
	scheme := runtime.NewScheme()
	client := dynamicfake.NewSimpleDynamicClient(scheme, objects...)
	reader, err := NewReader(fakeResolver{client: client})
	if err != nil {
		t.Fatal(err)
	}
	return reader
}

func kubernetesObject(apiVersion, kind, resource, namespace, name, uid string) *unstructured.Unstructured {
	value := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": apiVersion,
		"kind":       kind,
		"metadata": map[string]any{
			"namespace":       namespace,
			"name":            name,
			"uid":             uid,
			"resourceVersion": "rv-1",
		},
	}}
	value.SetGroupVersionKind(schema.FromAPIVersionAndKind(apiVersion, kind))
	_ = resource
	return value
}
