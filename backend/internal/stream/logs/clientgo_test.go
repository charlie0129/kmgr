package logs

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"testing"

	"github.com/charlie0129/kmgr/backend/internal/podidentity"
	corev1 "k8s.io/api/core/v1"
	coreclient "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/client-go/metadata"
	"k8s.io/client-go/rest"
)

func TestClientGoSourceVerifiesUIDAndUsesPodLogSubresource(t *testing.T) {
	t.Parallel()
	var logRequests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api/v1/namespaces/team-a/pods/api-0":
			writer.Header().Set("Content-Type", "application/json")
			_, _ = fmt.Fprint(writer, `{"apiVersion":"meta.k8s.io/v1","kind":"PartialObjectMetadata","metadata":{"namespace":"team-a","name":"api-0","uid":"pod-uid"}}`)
		case "/api/v1/namespaces/team-a/pods/api-0/log":
			logRequests.Add(1)
			assertLogQuery(t, request.URL.Query())
			writer.WriteHeader(http.StatusOK)
			_, _ = writer.Write([]byte("payload\n"))
		default:
			http.NotFound(writer, request)
		}
	}))
	defer server.Close()

	config := &rest.Config{Host: server.URL}
	client, err := coreclient.NewForConfig(config)
	if err != nil {
		t.Fatalf("NewForConfig: %v", err)
	}
	metadataClient, err := metadata.NewForConfig(config)
	if err != nil {
		t.Fatalf("metadata NewForConfig: %v", err)
	}
	opener := ClientGoSource{
		Core: client, PodUIDs: podidentity.MetadataGetter{Client: metadataClient},
	}
	since := int64(120)
	tail := int64(40)
	limit := int64(8192)
	reader, err := opener.Open(context.Background(), Source{
		Identity: Identity{Namespace: "team-a", Name: "api-0", UID: "pod-uid"}, Container: "sidecar",
	}, corev1.PodLogOptions{
		Container: "sidecar", Follow: true, Previous: true, Timestamps: true,
		SinceSeconds: &since, TailLines: &tail, LimitBytes: &limit,
	})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	payload, err := io.ReadAll(reader)
	_ = reader.Close()
	if err != nil || string(payload) != "payload\n" {
		t.Fatalf("ReadAll = %q, %v", payload, err)
	}
	if logRequests.Load() != 1 {
		t.Fatalf("log requests = %d, want 1", logRequests.Load())
	}

	_, err = opener.Open(context.Background(), Source{
		Identity: Identity{Namespace: "team-a", Name: "api-0", UID: "replacement-uid"}, Container: "sidecar",
	}, corev1.PodLogOptions{})
	var mismatch *UIDMismatchError
	if !errors.As(err, &mismatch) {
		t.Fatalf("UID mismatch error = %v", err)
	}
	if logRequests.Load() != 1 {
		t.Fatalf("UID mismatch reached log subresource; requests = %d", logRequests.Load())
	}
}

func assertLogQuery(t *testing.T, query url.Values) {
	t.Helper()
	want := map[string]string{
		"container": "sidecar", "follow": "true", "previous": "true", "timestamps": "true",
		"sinceSeconds": "120", "tailLines": "40", "limitBytes": "8192",
	}
	for key, value := range want {
		if query.Get(key) != value {
			t.Errorf("query %s = %q, want %q (all: %v)", key, query.Get(key), value, query)
		}
	}
}
