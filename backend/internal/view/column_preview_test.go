package view

import (
	"context"
	"strings"
	"testing"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func TestPreviewColumnCompilesAndEvaluatesDeterministicSample(t *testing.T) {
	t.Parallel()
	service := newPreviewService(t, &fakeResourceSource{authority: "authority", client: newSearchClient()})

	response, err := service.PreviewColumn(context.Background(), previewRequest(
		"object.metadata.name", "string", nil,
	))
	if err != nil {
		t.Fatal(err)
	}
	if response.GetRequestId() != "preview-request" || response.GetCelEnvironment() != "kmgr.cel/v1" ||
		!response.GetUsedSampleObject() || response.GetPreview().GetDisplayText() != "sample" ||
		response.GetPreview().GetStringValue() != "sample" || response.GetError() != nil {
		t.Fatalf("sample preview = %#v", response)
	}
}

func TestPreviewColumnReturnsCompileAndEvaluationErrorsInline(t *testing.T) {
	t.Parallel()
	service := newPreviewService(t, &fakeResourceSource{authority: "authority", client: newSearchClient()})

	compileFailure, err := service.PreviewColumn(context.Background(), previewRequest(
		"object.", "string", nil,
	))
	if err != nil {
		t.Fatal(err)
	}
	if compileFailure.GetError().GetReason() != "CELCompileFailed" ||
		compileFailure.GetError().GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION {
		t.Fatalf("compile failure = %#v", compileFailure)
	}

	evaluationFailure, err := service.PreviewColumn(context.Background(), previewRequest(
		"object['spec']['required']", "string", nil,
	))
	if err != nil {
		t.Fatal(err)
	}
	if evaluationFailure.GetError().GetReason() != "CELEvaluationFailed" {
		t.Fatalf("evaluation failure = %#v", evaluationFailure)
	}
}

func TestPreviewColumnFreshGetsSelectedUIDAndNeverExposesSecretData(t *testing.T) {
	t.Parallel()
	secret := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1", "kind": "Secret",
		"metadata": map[string]any{
			"name": "credentials", "namespace": "team", "uid": "secret-uid",
		},
		"data": map[string]any{"password": "do-not-expose"},
	}}
	client := newSearchClient()
	client.getObjects["credentials"] = secret
	service := newPreviewService(t, &fakeResourceSource{authority: "authority", client: client})
	identity := &kmgrv1.ResourceIdentity{
		ClusterSessionId: "session", Version: "v1", Resource: "secrets",
		Namespace: "team", Name: "credentials", Uid: "secret-uid",
	}
	request := previewRequest("has(object.data)", "boolean", identity)
	request.Resource.Kind = "Secret"
	request.Resource.Resource = "secrets"

	response, err := service.PreviewColumn(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if response.GetUsedSampleObject() || response.GetEvaluatedObject().GetUid() != "secret-uid" ||
		response.GetPreview().GetBoolValue() || client.getCalls.Load() != 1 {
		t.Fatalf("selected Secret preview = %#v, GETs = %d", response, client.getCalls.Load())
	}

	identity.Uid = "old-uid"
	recreated, err := service.PreviewColumn(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if recreated.GetError().GetReason() != "ColumnPreviewObjectUnavailable" ||
		!strings.Contains(recreated.GetError().GetMessage(), "recreated") {
		t.Fatalf("recreated object response = %#v", recreated)
	}
}

func TestPreviewColumnRejectsExpiredRequestDeadline(t *testing.T) {
	t.Parallel()
	service := newPreviewService(t, &fakeResourceSource{authority: "authority", client: newSearchClient()})
	request := previewRequest("object.metadata.name", "string", nil)
	request.Context.DeadlineUnixMs = time.Now().Add(-time.Second).UnixMilli()
	_, err := service.PreviewColumn(context.Background(), request)
	if err == nil {
		t.Fatal("expired preview deadline was accepted")
	}
}

func newPreviewService(t *testing.T, source ResourceSource) *GRPCService {
	t.Helper()
	runtime, err := NewRuntime(RuntimeConfig{Source: source})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(runtime.Close)
	service, err := NewGRPCService(runtime)
	if err != nil {
		t.Fatal(err)
	}
	return service
}

func previewRequest(
	expression, resultType string,
	selected *kmgrv1.ResourceIdentity,
) *kmgrv1.PreviewColumnRequest {
	return &kmgrv1.PreviewColumnRequest{
		Context: &kmgrv1.RequestContext{
			RequestId: "preview-request", ClusterSessionId: "session",
			DeadlineUnixMs: time.Now().Add(time.Minute).UnixMilli(),
		},
		Resource: &kmgrv1.ResourceType{
			Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true,
		},
		NamespaceScope: &kmgrv1.NamespaceScope{Namespaces: []string{"team"}},
		Column: &kmgrv1.CELColumnDefinition{
			Id: "preview", Title: "Preview", Expression: expression,
			ResultType: resultType, Missing: "—", ListJoiner: " · ",
		},
		SelectedObject: selected,
	}
}

var _ interface {
	Get(context.Context, string, metav1.GetOptions, ...string) (*unstructured.Unstructured, error)
} = (*searchClient)(nil)
