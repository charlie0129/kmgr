package object

import (
	"context"
	"encoding/base64"
	"testing"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"k8s.io/apimachinery/pkg/runtime"
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

func TestGRPCGetDataCarriesDecodedSecretBytes(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Secret", "secrets", "ns", "secret", "uid")
	value.Object["data"] = map[string]any{"token": base64.StdEncoding.EncodeToString([]byte("raw-token"))}
	service, err := NewGRPCService(testReader(t, value))
	if err != nil {
		t.Fatal(err)
	}
	response, err := service.GetData(context.Background(), &kmgrv1.GetDataRequest{
		Context: &kmgrv1.RequestContext{
			RequestId: "request", ClusterSessionId: "session",
			DeadlineUnixMs: time.Now().Add(time.Second).UnixMilli(),
		},
		Identity: &kmgrv1.ResourceIdentity{
			ClusterSessionId: "session", Version: "v1", Resource: "secrets",
			Namespace: "ns", Name: "secret", Uid: "uid",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if response.GetError() != nil || !response.GetSecret() || len(response.GetEntries()) != 1 {
		t.Fatalf("response metadata = %#v", response)
	}
	if got := string(response.GetEntries()[0].GetValue()); got != "raw-token" {
		t.Fatalf("decoded value = %q", got)
	}
	if response.GetEntries()[0].GetByteSize() != 9 || len(response.GetEntries()[0].GetContentHash()) != 32 {
		t.Fatalf("entry metadata = %#v", response.GetEntries()[0])
	}
}

func TestGRPCGetObjectReturnsStructuredRecreationConflict(t *testing.T) {
	t.Parallel()
	client := dynamicfake.NewSimpleDynamicClient(
		runtime.NewScheme(), kubernetesObject("v1", "Pod", "pods", "ns", "pod", "new-uid"),
	)
	reader, err := NewReader(fakeResolver{client: client, contextName: "production"})
	if err != nil {
		t.Fatal(err)
	}
	service, err := NewGRPCService(reader)
	if err != nil {
		t.Fatal(err)
	}
	response, err := service.GetObject(context.Background(), &kmgrv1.GetObjectRequest{
		Context: &kmgrv1.RequestContext{RequestId: "request", ClusterSessionId: "session"},
		Identity: &kmgrv1.ResourceIdentity{
			ClusterSessionId: "session", Version: "v1", Resource: "pods",
			Namespace: "ns", Name: "pod", Uid: "old-uid",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if response.GetError().GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT ||
		response.GetError().GetReason() != "ObjectRecreated" ||
		response.GetError().GetContextName() != "production" ||
		response.GetError().GetOperation() != "get-object" {
		t.Fatalf("structured error = %#v", response.GetError())
	}
}
