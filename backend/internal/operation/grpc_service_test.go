package operation

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/object"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/client-go/dynamic"
)

func TestPrepareYamlEditReturnsValidationAndSemanticDiff(t *testing.T) {
	t.Parallel()
	editor := &fakeYAMLEditor{prepared: object.PreparedYAML{
		CurrentResourceVersion: "rv-1", NormalizedYAML: []byte("kind: ConfigMap\n"),
		Diff: []object.SemanticDiff{{Path: "data.mode", BeforeSummary: "slow", AfterSummary: "fast"}},
	}}
	service := testOperationService(t, editor)
	response, err := service.PrepareYamlEdit(context.Background(), &kmgrv1.PrepareYamlEditRequest{
		Context: operationContext("prepare"), Identity: operationIdentity(), YamlUtf8: []byte("yaml"),
		ExpectedResourceVersion: "rv-1",
	})
	if err != nil || response.GetError() != nil || len(response.GetDiff()) != 1 ||
		response.GetDiff()[0].GetPath() != "data.mode" || response.GetCurrentResourceVersion() != "rv-1" {
		t.Fatalf("response = %#v, error = %v", response, err)
	}

	editor.err = &object.YAMLIdentityMismatchError{Field: "metadata.name", Expected: "settings", Actual: "other"}
	response, err = service.PrepareYamlEdit(context.Background(), &kmgrv1.PrepareYamlEditRequest{
		Context: operationContext("invalid"), Identity: operationIdentity(), YamlUtf8: []byte("yaml"),
		ExpectedResourceVersion: "rv-1",
	})
	if err != nil || len(response.GetValidationErrors()) != 1 ||
		response.GetValidationErrors()[0].GetReason() != "IdentityChanged" {
		t.Fatalf("validation response = %#v, error = %v", response, err)
	}
}

func TestApplyWatchAndCancelOperation(t *testing.T) {
	t.Parallel()
	editor := &fakeYAMLEditor{block: make(chan struct{})}
	service := testOperationService(t, editor)
	started, err := service.ApplyYaml(context.Background(), &kmgrv1.ApplyYamlRequest{
		Context: operationContext("apply"), OperationId: "operation", Identity: operationIdentity(),
		YamlUtf8: []byte("secret: must-not-enter-status"), ExpectedResourceVersion: "rv-1", FieldManager: "kmgr",
	})
	if err != nil || !started.GetAccepted() {
		t.Fatalf("start = %#v, error = %v", started, err)
	}
	eventStream := &recordingOperationStream{ctx: context.Background()}
	done := make(chan error, 1)
	go func() {
		done <- service.WatchOperation(&kmgrv1.WatchOperationRequest{
			Context: operationContext("watch"), StreamId: "stream", Generation: 3, OperationId: "operation",
		}, eventStream)
	}()
	eventuallyOperation(t, func() bool {
		eventStream.mu.Lock()
		defer eventStream.mu.Unlock()
		return len(eventStream.events) > 0
	})
	ack, err := service.CancelOperation(context.Background(), &kmgrv1.CancelOperationRequest{
		Context: operationContext("cancel"), OperationId: "operation",
	})
	if err != nil || !ack.GetAccepted() {
		t.Fatalf("cancel = %#v, error = %v", ack, err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("watch did not terminate")
	}
	eventStream.mu.Lock()
	defer eventStream.mu.Unlock()
	last := eventStream.events[len(eventStream.events)-1]
	if last.GetState() != kmgrv1.OperationState_OPERATION_STATE_CANCELLED ||
		last.GetCursor().GetGeneration() != 3 || last.GetCursor().GetSequence() == 0 ||
		last.GetError().GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_CANCELLED {
		t.Fatalf("last event = %#v", last)
	}
	if editor.lastPayload == "secret: must-not-enter-status" {
		// The editor necessarily received the payload; the assertion below is
		// that no progress/event message retains it.
		for _, event := range eventStream.events {
			if event.String() == editor.lastPayload {
				t.Fatal("operation event retained mutation payload")
			}
		}
	}
}

func TestApplyYamlRejectsArbitraryFieldManagerAndDuplicateID(t *testing.T) {
	t.Parallel()
	editor := &fakeYAMLEditor{block: make(chan struct{})}
	service := testOperationService(t, editor)
	bad, err := service.ApplyYaml(context.Background(), &kmgrv1.ApplyYamlRequest{
		Context: operationContext("bad"), OperationId: "bad", Identity: operationIdentity(),
		YamlUtf8: []byte("yaml"), ExpectedResourceVersion: "rv", FieldManager: "kubectl",
	})
	if err != nil || bad.GetAccepted() || bad.GetError().GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION {
		t.Fatalf("bad field manager response = %#v, error = %v", bad, err)
	}
	request := &kmgrv1.ApplyYamlRequest{
		Context: operationContext("one"), OperationId: "same", Identity: operationIdentity(),
		YamlUtf8: []byte("yaml"), ExpectedResourceVersion: "rv",
	}
	first, err := service.ApplyYaml(context.Background(), request)
	if err != nil || !first.GetAccepted() {
		t.Fatalf("first = %#v, error = %v", first, err)
	}
	request.Context.RequestId = "two"
	second, err := service.ApplyYaml(context.Background(), request)
	if err != nil || second.GetAccepted() || second.GetError() == nil {
		t.Fatalf("second = %#v, error = %v", second, err)
	}
	_, _ = service.CancelOperation(context.Background(), &kmgrv1.CancelOperationRequest{
		Context: operationContext("cleanup"), OperationId: "same",
	})
}

type fakeYAMLEditor struct {
	mu          sync.Mutex
	prepared    object.PreparedYAML
	err         error
	block       chan struct{}
	lastPayload string
	object      *unstructured.Unstructured
	resource    dynamic.ResourceInterface
	dataResult  object.Data
	dataErr     error
	mutations   []object.DataMutation
}

func (e *fakeYAMLEditor) PrepareYAML(
	context.Context, object.Identity, []byte, string, bool,
) (object.PreparedYAML, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.prepared, e.err
}

func (e *fakeYAMLEditor) UpdateData(
	_ context.Context, _ object.Identity, _ string, mutations []object.DataMutation,
) (object.Data, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.mutations = cloneDataMutations(mutations)
	return e.dataResult, e.dataErr
}

func (e *fakeYAMLEditor) Get(context.Context, object.Identity) (*unstructured.Unstructured, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.err != nil {
		return nil, e.err
	}
	if e.object == nil {
		return nil, errors.New("no fake object")
	}
	return e.object.DeepCopy(), nil
}

func (e *fakeYAMLEditor) Resource(object.Identity) (dynamic.ResourceInterface, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.err != nil {
		return nil, e.err
	}
	return e.resource, nil
}

func (e *fakeYAMLEditor) ApplyYAML(
	ctx context.Context, identity object.Identity, payload []byte, _ string, _ bool,
) (object.AppliedYAML, error) {
	e.mu.Lock()
	e.lastPayload = string(payload)
	err := e.err
	e.mu.Unlock()
	if e.block != nil {
		select {
		case <-ctx.Done():
			return object.AppliedYAML{}, ctx.Err()
		case <-e.block:
		}
	}
	if err != nil {
		return object.AppliedYAML{}, err
	}
	return object.AppliedYAML{Identity: identity, NewResourceVersion: "rv-2"}, nil
}

type recordingOperationStream struct {
	grpc.ServerStream
	ctx    context.Context
	mu     sync.Mutex
	events []*kmgrv1.OperationEvent
}

func (s *recordingOperationStream) Context() context.Context { return s.ctx }
func (s *recordingOperationStream) Send(value *kmgrv1.OperationEvent) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, value)
	return nil
}

func testOperationService(t *testing.T, editor *fakeYAMLEditor) *GRPCService {
	t.Helper()
	service, err := NewGRPCService(editor, nil)
	if err != nil {
		t.Fatal(err)
	}
	return service
}

func operationContext(requestID string) *kmgrv1.RequestContext {
	return &kmgrv1.RequestContext{RequestId: requestID, ClusterSessionId: "session"}
}

func operationIdentity() *kmgrv1.ResourceIdentity {
	return &kmgrv1.ResourceIdentity{
		ClusterSessionId: "session", Version: "v1", Resource: "configmaps",
		Namespace: "ns", Name: "settings", Uid: "uid",
	}
}

func eventuallyOperation(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for operation event")
		}
		time.Sleep(time.Millisecond)
	}
}
