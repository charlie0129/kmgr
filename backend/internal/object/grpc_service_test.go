package object

import (
	"context"
	"encoding/base64"
	"errors"
	"sync"
	"testing"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	metadatafake "k8s.io/client-go/metadata/fake"
	clienttesting "k8s.io/client-go/testing"
)

func TestGRPCGetDataCarriesDecodedSecretBytes(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Secret", "secrets", "ns", "secret", "uid")
	value.Object["data"] = map[string]any{"token": base64.StdEncoding.EncodeToString([]byte("raw-token"))}
	reader := testReader(t, value)
	service, err := NewGRPCService(reader)
	if err != nil {
		t.Fatal(err)
	}
	response, err := service.GetData(context.Background(), &kmgrv1.GetDataRequest{
		Context: &kmgrv1.RequestContext{
			RequestId: "request", ClusterSessionId: "session", DeadlineUnixMs: time.Now().Add(time.Second).UnixMilli(),
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

func TestRelationshipToProtoCarriesControllerFlag(t *testing.T) {
	t.Parallel()
	value := relationshipToProto(Relationship{
		Kind:       RelationshipOwner,
		Identity:   Identity{SessionID: "session", Version: "v1", Resource: "pods", Namespace: "ns", Name: "api", UID: "uid"},
		Label:      "Pod",
		Controller: true,
	})
	if value.GetKind() != kmgrv1.RelationshipKind_RELATIONSHIP_KIND_OWNER ||
		!value.GetController() {
		t.Fatalf("relationship proto = %#v", value)
	}
}

func TestGRPCRelationshipScanCursorAndExplicitCancellation(t *testing.T) {
	target := kubernetesObject("apps/v1", "Deployment", "deployments", "ns", "api", "owner-uid")
	metadataScheme := metadatafake.NewTestScheme()
	metav1.AddMetaToScheme(metadataScheme)
	metadataClient := metadatafake.NewSimpleMetadataClient(
		metadataScheme, relationshipPartialMetadata(target),
	)
	block := make(chan struct{})
	metadataClient.PrependReactor("list", "replicasets", func(clienttesting.Action) (bool, runtime.Object, error) {
		<-block
		return true, nil, context.Canceled
	})
	discovery := newRelationshipDiscoveryClient(t, relationshipDiscoveryHandler(t, []*metav1.APIResourceList{{
		GroupVersion: "apps/v1", APIResources: []metav1.APIResource{{
			Name: "replicasets", Kind: "ReplicaSet", Namespaced: true,
			Verbs: metav1.Verbs{"list"},
		}},
	}}))
	reader, err := NewReader(scanTestResolver{
		dynamic:   dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), target),
		discovery: discovery, metadata: metadataClient,
	})
	if err != nil {
		t.Fatal(err)
	}
	service, _ := NewGRPCService(reader)
	stream := &relationshipScanTestStream{ctx: context.Background()}
	done := make(chan error, 1)
	go func() { done <- service.ScanRelationships(relationshipScanRequest(2), stream) }()
	waitForRelationshipScan(t, service, relationshipScanKey{sessionID: "session", scanID: "scan", generation: 2})

	ack, err := service.CancelRelationshipScan(context.Background(), &kmgrv1.CancelRelationshipScanRequest{
		Context: relationshipRequestContext(), ScanId: "scan", Generation: 2,
	})
	if err != nil || !ack.GetAccepted() {
		t.Fatalf("cancel acknowledgement = %#v, error = %v", ack, err)
	}
	close(block)
	if err := <-done; status.Code(err) != codes.Canceled {
		t.Fatalf("scan cancellation error = %v", err)
	}
	events := stream.snapshot()
	for index, event := range events {
		if event.GetCursor().GetStreamId() != "scan" || event.GetCursor().GetGeneration() != 2 ||
			event.GetCursor().GetSequence() != uint64(index+1) {
			t.Fatalf("event %d cursor = %#v", index, event.GetCursor())
		}
	}
}

func TestGRPCCancelRelationshipScanHonorsTransportAndRequestDeadlines(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name       string
		callCtx    func() context.Context
		requestCtx func() *kmgrv1.RequestContext
		wantCode   codes.Code
	}{
		{
			name: "transport canceled",
			callCtx: func() context.Context {
				ctx, cancel := context.WithCancel(context.Background())
				cancel()
				return ctx
			},
			requestCtx: relationshipRequestContext,
			wantCode:   codes.Canceled,
		},
		{
			name:    "application deadline expired",
			callCtx: context.Background,
			requestCtx: func() *kmgrv1.RequestContext {
				value := relationshipRequestContext()
				value.DeadlineUnixMs = time.Now().Add(-time.Second).UnixMilli()
				return value
			},
			wantCode: codes.DeadlineExceeded,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reader := testReader(t, kubernetesObject("v1", "Pod", "pods", "ns", "api", "owner-uid"))
			service, err := NewGRPCService(reader)
			if err != nil {
				t.Fatal(err)
			}
			key := relationshipScanKey{sessionID: "session", scanID: "scan", generation: 2}
			cancelled := false
			service.scans[key] = func() { cancelled = true }

			ack, err := service.CancelRelationshipScan(test.callCtx(), &kmgrv1.CancelRelationshipScanRequest{
				Context: test.requestCtx(), ScanId: "scan", Generation: 2,
			})
			if status.Code(err) != test.wantCode || ack != nil {
				t.Fatalf("cancel response = %#v, error = %v; want nil/%v", ack, err, test.wantCode)
			}
			if cancelled {
				t.Fatal("invalid cancellation request canceled the active relationship scan")
			}
			if service.scans[key] == nil {
				t.Fatal("invalid cancellation request removed the active relationship scan")
			}
		})
	}
}

func TestGRPCRelationshipScanRejectsStaleGeneration(t *testing.T) {
	reader := testReader(t, kubernetesObject("v1", "Pod", "pods", "ns", "api", "owner-uid"))
	service, _ := NewGRPCService(reader)
	service.scans[relationshipScanKey{sessionID: "session", scanID: "scan", generation: 3}] = func() {}
	err := service.ScanRelationships(relationshipScanRequest(2), &relationshipScanTestStream{ctx: context.Background()})
	if status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("stale generation error = %v", err)
	}
}

func relationshipScanRequest(generation uint64) *kmgrv1.ScanRelationshipsRequest {
	return &kmgrv1.ScanRelationshipsRequest{
		Context: relationshipRequestContext(), ScanId: "scan", Generation: generation,
		Identity: &kmgrv1.ResourceIdentity{
			ClusterSessionId: "session", Group: "apps", Version: "v1", Resource: "deployments",
			Namespace: "ns", Name: "api", Uid: "owner-uid",
		},
	}
}

func relationshipRequestContext() *kmgrv1.RequestContext {
	return &kmgrv1.RequestContext{RequestId: "request", ClusterSessionId: "session"}
}

func waitForRelationshipScan(t *testing.T, service *GRPCService, key relationshipScanKey) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		service.scanMu.Lock()
		_, active := service.scans[key]
		service.scanMu.Unlock()
		if active {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("relationship scan did not become active")
}

type relationshipScanTestStream struct {
	grpc.ServerStream
	ctx    context.Context
	mu     sync.Mutex
	events []*kmgrv1.RelationshipScanEvent
}

func (s *relationshipScanTestStream) Context() context.Context { return s.ctx }
func (s *relationshipScanTestStream) Send(value *kmgrv1.RelationshipScanEvent) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, value)
	return nil
}
func (s *relationshipScanTestStream) SetHeader(metadata.MD) error  { return nil }
func (s *relationshipScanTestStream) SendHeader(metadata.MD) error { return nil }
func (s *relationshipScanTestStream) SetTrailer(metadata.MD)       {}
func (s *relationshipScanTestStream) SendMsg(any) error            { return errors.New("unexpected SendMsg") }
func (s *relationshipScanTestStream) RecvMsg(any) error            { return errors.New("unexpected RecvMsg") }
func (s *relationshipScanTestStream) snapshot() []*kmgrv1.RelationshipScanEvent {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]*kmgrv1.RelationshipScanEvent(nil), s.events...)
}
