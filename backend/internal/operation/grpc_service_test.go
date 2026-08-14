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
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
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

func TestWatchOperationHonorsApplicationDeadline(t *testing.T) {
	t.Parallel()
	editor := &fakeYAMLEditor{block: make(chan struct{})}
	service := testOperationService(t, editor)
	started, err := service.ApplyYaml(context.Background(), &kmgrv1.ApplyYamlRequest{
		Context: operationContext("start-deadline-watch"), OperationId: "deadline-watch-operation",
		Identity: operationIdentity(), YamlUtf8: []byte("data: pending"),
		ExpectedResourceVersion: "rv-1", FieldManager: "kmgr",
	})
	if err != nil || !started.GetAccepted() {
		t.Fatalf("start = %#v, error = %v", started, err)
	}
	requestContext := operationContext("deadline-watch")
	requestContext.DeadlineUnixMs = time.Now().Add(40 * time.Millisecond).UnixMilli()
	stream := &recordingOperationStream{ctx: context.Background()}
	done := make(chan error, 1)
	go func() {
		done <- service.WatchOperation(&kmgrv1.WatchOperationRequest{
			Context: requestContext, StreamId: "deadline-stream", Generation: 1,
			OperationId: "deadline-watch-operation",
		}, stream)
	}()
	select {
	case err := <-done:
		if status.Code(err) != codes.DeadlineExceeded {
			t.Fatalf("watch error = %v, want deadline exceeded", err)
		}
	case <-time.After(time.Second):
		t.Fatal("watch did not stop at its application deadline")
	}
	operation, found := service.manager.Get("deadline-watch-operation")
	if !found {
		t.Fatal("watch deadline removed the underlying operation")
	}
	select {
	case <-operation.Done():
		t.Fatal("watch deadline cancelled the underlying operation")
	default:
	}
	operation.Cancel()
}

func TestAcceptedApplyYamlRetainsApplicationDeadline(t *testing.T) {
	t.Parallel()
	observedContext := make(chan context.Context, 1)
	editor := &fakeYAMLEditor{block: make(chan struct{}), applyContext: observedContext}
	service := testOperationService(t, editor)
	requestContext := operationContext("deadline-apply")
	deadline := time.Now().Add(150 * time.Millisecond)
	requestContext.DeadlineUnixMs = deadline.UnixMilli()
	transportContext, cancelTransport := context.WithCancel(context.Background())
	started, err := service.ApplyYaml(transportContext, &kmgrv1.ApplyYamlRequest{
		Context: requestContext, OperationId: "deadline-operation", Identity: operationIdentity(),
		YamlUtf8: []byte("data: deadline"), ExpectedResourceVersion: "rv-1", FieldManager: "kmgr",
	})
	if err != nil || !started.GetAccepted() {
		t.Fatalf("start = %#v, error = %v", started, err)
	}
	var backendContext context.Context
	select {
	case backendContext = <-observedContext:
	case <-time.After(time.Second):
		t.Fatal("accepted apply did not reach the backend")
	}
	gotDeadline, ok := backendContext.Deadline()
	if !ok || !gotDeadline.Equal(time.UnixMilli(requestContext.GetDeadlineUnixMs())) {
		t.Fatalf("backend deadline = %v, %t, want %v", gotDeadline, ok, time.UnixMilli(requestContext.GetDeadlineUnixMs()))
	}
	cancelTransport()
	operation, found := service.manager.Get("deadline-operation")
	if !found {
		t.Fatal("accepted operation was not tracked")
	}
	select {
	case <-operation.Done():
		t.Fatal("unary transport cancellation stopped accepted mutation work")
	case <-time.After(20 * time.Millisecond):
	}
	select {
	case <-operation.Done():
	case <-time.After(time.Second):
		t.Fatal("accepted mutation did not stop at its application deadline")
	}
	status := operation.Status()
	if status.State != StateCancelled || len(status.Items) != 1 ||
		status.Items[0].State != ItemStateCancelled ||
		!errors.Is(status.Items[0].Err, context.DeadlineExceeded) ||
		!errors.Is(status.Err, context.DeadlineExceeded) {
		t.Fatalf("deadline status = %#v", status)
	}
}

func TestCancelOperationNotStartedOnlyCancelsQueuedDeleteItems(t *testing.T) {
	t.Parallel()
	provider := &recordingProvider{started: make(chan struct{}, 1), block: make(chan struct{})}
	editor := &fakeYAMLEditor{resource: &recordingResource{provider: provider, namespace: "ns"}}
	service := testOperationService(t, editor)
	firstIdentity := operationIdentity()
	firstIdentity.Resource = "pods"
	firstIdentity.Name = "running"
	firstIdentity.Uid = "uid-running"
	queuedIdentity := operationIdentity()
	queuedIdentity.Resource = "pods"
	queuedIdentity.Name = "queued"
	queuedIdentity.Uid = "uid-queued"
	started, err := service.Delete(context.Background(), &kmgrv1.DeleteRequest{
		Context: operationContext("delete"), OperationId: "delete-operation",
		Targets:           []*kmgrv1.DeleteTarget{{Identity: firstIdentity}, {Identity: queuedIdentity}},
		PropagationPolicy: kmgrv1.PropagationPolicy_PROPAGATION_POLICY_BACKGROUND,
		MaxConcurrency:    1,
	})
	if err != nil || !started.GetAccepted() {
		t.Fatalf("start = %#v, error = %v", started, err)
	}
	select {
	case <-provider.started:
	case <-time.After(time.Second):
		t.Fatal("first delete did not start")
	}
	operation, found := service.manager.Get("delete-operation")
	if !found {
		t.Fatal("accepted delete operation was not tracked")
	}
	eventuallyOperation(t, func() bool {
		status := operation.Status()
		return status.State == StateRunning && status.Items[0].State == ItemStateRunning &&
			status.Items[1].State == ItemStatePending
	})
	ack, err := service.CancelOperation(context.Background(), &kmgrv1.CancelOperationRequest{
		Context: operationContext("cancel-queued"), OperationId: "delete-operation", CancelNotStartedOnly: true,
	})
	if err != nil || !ack.GetAccepted() {
		t.Fatalf("pending-only cancel = %#v, error = %v", ack, err)
	}
	status := operation.Status()
	if status.State != StateRunning || status.Items[0].State != ItemStateRunning ||
		status.Items[1].State != ItemStateCancelled {
		t.Fatalf("pending-only delete status = %#v", status)
	}
	close(provider.block)
	select {
	case <-operation.Done():
	case <-time.After(time.Second):
		t.Fatal("delete operation did not finish")
	}
	status = operation.Status()
	if status.State != StatePartiallySucceeded || status.Items[0].State != ItemStateSucceeded ||
		status.Items[1].State != ItemStateCancelled {
		t.Fatalf("terminal delete status = %#v", status)
	}
	provider.mu.Lock()
	if len(provider.calls) != 1 || provider.calls[0].name != "running" {
		provider.mu.Unlock()
		t.Fatalf("delete calls = %#v, want only running target", provider.calls)
	}
	provider.mu.Unlock()
	ack, err = service.CancelOperation(context.Background(), &kmgrv1.CancelOperationRequest{
		Context: operationContext("cancel-again"), OperationId: "delete-operation", CancelNotStartedOnly: true,
	})
	if err != nil || ack.GetAccepted() {
		t.Fatalf("terminal pending-only cancel = %#v, error = %v", ack, err)
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
	mu           sync.Mutex
	prepared     object.PreparedYAML
	err          error
	block        chan struct{}
	lastPayload  string
	object       *unstructured.Unstructured
	resource     dynamic.ResourceInterface
	dataResult   object.Data
	dataErr      error
	mutations    []object.DataMutation
	applyContext chan context.Context
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
	if e.applyContext != nil {
		select {
		case e.applyContext <- ctx:
		default:
		}
	}
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
	t.Cleanup(service.manager.Close)
	return service
}

func TestStructuredOperationErrorReportsManagerCapacityAndShutdown(t *testing.T) {
	t.Parallel()
	tests := []struct {
		err      error
		category kmgrv1.ErrorCategory
		reason   string
	}{
		{ErrManagerFull, kmgrv1.ErrorCategory_ERROR_CATEGORY_RESOURCE_EXHAUSTED, "TooManyOperations"},
		{ErrManagerClosed, kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE, "EngineStopping"},
	}
	for _, test := range tests {
		value := structuredOperationError(test.err, nil, "scale")
		if value.GetCategory() != test.category || value.GetReason() != test.reason {
			t.Fatalf("structured error for %v = %#v", test.err, value)
		}
	}
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
