package object

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
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

func TestResourceReturnsExactNamespacedAndClusterScopedInterfaces(t *testing.T) {
	t.Parallel()
	resolver := &recordingResolver{resource: &fakeResourceInterface{}}
	reader, err := NewReader(resolver)
	if err != nil {
		t.Fatal(err)
	}
	namespaced := Identity{
		SessionID: "session", Group: "apps", Version: "v1", Resource: "deployments",
		Namespace: "team-a", Name: "web", UID: "uid-web",
	}
	resource, err := reader.Resource(namespaced)
	if err != nil || resource != resolver.resource {
		t.Fatalf("Resource() = %#v, %v", resource, err)
	}
	if resolver.sessionID != "session" || resolver.gvr != namespaced.GVR() || resolver.namespace != "team-a" {
		t.Fatalf("resolver call = %q %#v %q", resolver.sessionID, resolver.gvr, resolver.namespace)
	}
	clusterScoped := namespaced
	clusterScoped.Namespace = ""
	clusterScoped.Name = "node-a"
	clusterScoped.Resource = "nodes"
	clusterScoped.Group = ""
	if _, err := reader.Resource(clusterScoped); err != nil || resolver.namespace != "" || resolver.gvr != clusterScoped.GVR() {
		t.Fatalf("cluster-scoped Resource() = %v, call = %#v %q", err, resolver.gvr, resolver.namespace)
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

func TestPodSummaryIncludesBoundedContainerChoicesAndDeclaredPorts(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "uid")
	value.Object["spec"] = map[string]any{
		"containers": []any{
			map[string]any{
				"name": "main", "image": "private.example/application:secret-tag",
				"env": []any{map[string]any{"name": "PASSWORD", "value": "must-not-leak"}},
				"ports": []any{
					map[string]any{"name": "http", "containerPort": int64(8080), "protocol": "TCP"},
				},
			},
		},
		"initContainers":      []any{map[string]any{"name": "migrate"}},
		"ephemeralContainers": []any{map[string]any{"name": "debugger"}},
	}
	detail, err := testReader(t, value).Detail(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "ns", Name: "pod", UID: "uid",
	}, false, true)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]struct{ section, value string }{
		"container:main":              {section: "containers", value: "main"},
		"port:TCP:8080:http":          {section: "ports", value: "http: 8080/TCP"},
		"initContainer:migrate":       {section: "containers", value: "migrate"},
		"ephemeralContainer:debugger": {section: "containers", value: "debugger"},
	}
	for _, field := range detail.Summary {
		if expected, found := want[field.ID]; found {
			if field.Section != expected.section || field.Value != expected.value {
				t.Fatalf("summary field %#v, want %#v", field, expected)
			}
			delete(want, field.ID)
		}
		if strings.Contains(field.Value, "must-not-leak") || strings.Contains(field.Value, "secret-tag") {
			t.Fatalf("summary leaked an image or environment value: %#v", field)
		}
	}
	if len(want) != 0 {
		t.Fatalf("missing summary fields: %#v", want)
	}
}

func TestServiceSummaryIncludesDeclaredAndTargetPorts(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Service", "services", "ns", "web", "uid")
	value.Object["spec"] = map[string]any{"ports": []any{
		map[string]any{"name": "http", "port": int64(80), "targetPort": int64(8080)},
		map[string]any{"name": "admin", "port": int64(8443), "targetPort": "admin", "protocol": "TCP"},
	}}
	detail, err := testReader(t, value).Detail(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "services", Namespace: "ns", Name: "web", UID: "uid",
	}, false, true)
	if err != nil {
		t.Fatal(err)
	}
	ports := make([]string, 0, 2)
	ids := make([]string, 0, 2)
	for _, field := range detail.Summary {
		if field.Section == "ports" {
			ports = append(ports, field.Value)
			ids = append(ids, field.ID)
		}
	}
	if got, want := strings.Join(ports, ","), "http: 80/TCP → 8080,admin: 8443/TCP → admin"; got != want {
		t.Fatalf("service port summary = %q, want %q", got, want)
	}
	if got, want := strings.Join(ids, ","), "port:TCP:80:http,port:TCP:8443:admin"; got != want {
		t.Fatalf("service port IDs = %q, want %q", got, want)
	}
}

func TestPodSummaryBoundsUntrustedContainerAndPortCounts(t *testing.T) {
	t.Parallel()
	containers := make([]any, maximumSummaryContainers+20)
	ports := make([]any, maximumSummaryPorts+20)
	for index := range ports {
		ports[index] = map[string]any{"containerPort": int64(index + 1)}
	}
	for index := range containers {
		containers[index] = map[string]any{"name": fmt.Sprintf("container-%d", index), "ports": ports}
	}
	value := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "uid")
	value.Object["spec"] = map[string]any{"containers": containers}
	detail, err := testReader(t, value).Detail(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "ns", Name: "pod", UID: "uid",
	}, false, true)
	if err != nil {
		t.Fatal(err)
	}
	containerFields := 0
	portFields := 0
	for _, field := range detail.Summary {
		if field.Section == "ports" {
			portFields++
		} else if field.Section == "containers" {
			containerFields++
		}
	}
	if containerFields != maximumSummaryContainers || portFields != maximumSummaryPorts {
		t.Fatalf("bounded summary counts = containers %d, ports %d", containerFields, portFields)
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

func TestUpdateDataCreateOnlySetRejectsAnExistingKey(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	value.Object["data"] = map[string]any{"claimed": "server value"}
	reader := testReader(t, value)
	identity := Identity{SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid"}

	_, err := reader.UpdateData(context.Background(), identity, "rv-1", []DataMutation{{
		Type: MutationSet, Key: "claimed", Kind: DataText, Value: []byte("local value"),
	}})
	var conflict *DataConflictError
	if !errors.As(err, &conflict) || conflict.Key != "claimed" || len(conflict.CurrentHash) != 32 {
		t.Fatalf("create-only set error = %#v, want DataConflictError with current hash", err)
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

type recordingResolver struct {
	resource  dynamic.ResourceInterface
	sessionID string
	gvr       schema.GroupVersionResource
	namespace string
}

func (r *recordingResolver) Resource(sessionID string, gvr schema.GroupVersionResource, namespace string) (dynamic.ResourceInterface, error) {
	r.sessionID, r.gvr, r.namespace = sessionID, gvr, namespace
	return r.resource, nil
}

type fakeResourceInterface struct{ dynamic.ResourceInterface }

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
