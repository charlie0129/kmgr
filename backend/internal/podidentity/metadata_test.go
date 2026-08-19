package podidentity

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/metadata"
	"k8s.io/client-go/rest"
)

func TestMetadataGetterRequestsOnlyPartialObjectMetadata(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet || request.URL.Path != "/api/v1/namespaces/team-a/pods/api-0" {
			t.Errorf("metadata request = %s %s", request.Method, request.URL.Path)
		}
		if accept := request.Header.Get("Accept"); !strings.Contains(accept, "as=PartialObjectMetadata") {
			t.Errorf("metadata Accept = %q", accept)
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(writer, `{
			"apiVersion":"meta.k8s.io/v1","kind":"PartialObjectMetadata",
			"metadata":{"namespace":"team-a","name":"api-0","uid":"pod-uid"}
		}`)
	}))
	defer server.Close()
	client, err := metadata.NewForConfig(&rest.Config{Host: server.URL})
	if err != nil {
		t.Fatalf("NewForConfig: %v", err)
	}
	uid, err := (MetadataGetter{Client: client}).PodUID(
		context.Background(), "team-a", "api-0",
	)
	if err != nil {
		t.Fatalf("PodUID: %v", err)
	}
	if uid != types.UID("pod-uid") {
		t.Fatalf("Pod UID = %q, want pod-uid", uid)
	}
}
