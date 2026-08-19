package operation

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/object"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/client-go/dynamic"
)

func TestPrepareYamlEditReturnsValidationAndSemanticDiff(t *testing.T) {
	t.Parallel()
	beforeSecret := []byte("old decoded value")
	afterSecret := []byte("new decoded value")
	editor := &fakeYAMLEditor{prepared: object.PreparedYAML{
		CurrentResourceVersion: "rv-1", NormalizedYAML: []byte("kind: ConfigMap\n"),
		UnifiedDiff: []byte("--- server\n+++ edited\n"), UnifiedDiffTruncated: true,
		Diff: []object.SemanticDiff{{
			Path: "data.mode", BeforeSummary: "<redacted>", AfterSummary: "<redacted>",
			BeforeDecodedSecretValue: beforeSecret, HasBeforeDecodedSecretValue: true,
			AfterDecodedSecretValue: afterSecret, HasAfterDecodedSecretValue: true,
		}},
	}}
	service := testOperationService(t, editor)
	response, err := service.PrepareYamlEdit(context.Background(), &kmgrv1.PrepareYamlEditRequest{
		Context: operationContext("prepare"), Identity: operationIdentity(), YamlUtf8: []byte("yaml"),
		ExpectedResourceVersion: "rv-1",
	})
	if err != nil || response.GetError() != nil || len(response.GetDiff()) != 1 {
		t.Fatalf("unexpected prepare response envelope: error = %v", err)
	}
	entry := response.GetDiff()[0]
	if entry.GetPath() != "data.mode" || response.GetCurrentResourceVersion() != "rv-1" ||
		!bytes.Equal(response.GetUnifiedDiffUtf8(), editor.prepared.UnifiedDiff) ||
		!response.GetUnifiedDiffTruncated() ||
		!entry.GetHasBeforeDecodedSecretValue() || !bytes.Equal(entry.GetBeforeDecodedSecretValue(), beforeSecret) ||
		!entry.GetHasAfterDecodedSecretValue() || !bytes.Equal(entry.GetAfterDecodedSecretValue(), afterSecret) {
		t.Fatal("prepare response did not preserve the transient YAML diff fields")
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

func TestDeleteManyStreamsLargeSelectionAndReplaysBoundedExactResults(t *testing.T) {
	const targetCount = 10_000
	provider := &recordingProvider{}
	editor := &fakeYAMLEditor{resource: &recordingResource{provider: provider, namespace: "ns"}}
	service := testOperationService(t, editor)
	requests := make([]*kmgrv1.DeleteManyRequest, 0, 2+targetCount/maxDeleteTargetChunkItems)
	requests = append(requests, &kmgrv1.DeleteManyRequest{
		Sequence: 1,
		Payload: &kmgrv1.DeleteManyRequest_Start{Start: &kmgrv1.DeleteManyStart{
			Context: operationContext("large-delete"), OperationId: "large-delete-operation",
			TotalTargets: targetCount, PropagationPolicy: kmgrv1.PropagationPolicy_PROPAGATION_POLICY_BACKGROUND,
			MaxConcurrency: MaxDeleteConcurrency,
		}},
	})
	for offset := 0; offset < targetCount; offset += maxDeleteTargetChunkItems {
		count := min(maxDeleteTargetChunkItems, targetCount-offset)
		targets := make([]*kmgrv1.DeleteTarget, count)
		for index := range targets {
			value := strconv.Itoa(offset + index)
			identity := operationIdentity()
			identity.Resource = "pods"
			identity.Name = "pod-" + value
			identity.Uid = "uid-" + value
			targets[index] = &kmgrv1.DeleteTarget{Identity: identity}
		}
		requests = append(requests, &kmgrv1.DeleteManyRequest{
			Sequence: uint64(len(requests) + 1),
			Payload: &kmgrv1.DeleteManyRequest_Targets{Targets: &kmgrv1.DeleteTargetChunk{
				StartIndex: uint32(offset), Targets: targets,
			}},
		})
	}
	stream := &recordingDeleteManyStream{ctx: context.Background(), requests: requests}
	if err := service.DeleteMany(stream); err != nil {
		t.Fatal(err)
	}
	if stream.response == nil || !stream.response.GetAccepted() {
		t.Fatalf("start response = %#v", stream.response)
	}
	operation, found := service.manager.Get("large-delete-operation")
	if !found {
		t.Fatal("large streamed delete was not tracked")
	}
	select {
	case <-operation.Done():
	case <-time.After(10 * time.Second):
		t.Fatal("large streamed delete did not complete")
	}

	eventStream := &recordingOperationStream{ctx: context.Background()}
	if err := service.WatchOperation(&kmgrv1.WatchOperationRequest{
		Context: operationContext("large-watch"), StreamId: "large-stream", Generation: 1,
		OperationId: "large-delete-operation",
	}, eventStream); err != nil {
		t.Fatal(err)
	}
	seen := make(map[string]struct{}, targetCount)
	for _, event := range eventStream.events {
		if size := proto.Size(event); size > maxOperationEventBytes {
			t.Fatalf("operation event encoded size = %d, maximum = %d", size, maxOperationEventBytes)
		}
		for _, result := range event.GetItemResults() {
			uid := result.GetIdentity().GetUid()
			if result.GetState() != kmgrv1.OperationItemState_OPERATION_ITEM_STATE_SUCCEEDED {
				t.Fatalf("result %q state = %v", uid, result.GetState())
			}
			if _, duplicate := seen[uid]; duplicate {
				t.Fatalf("result %q was streamed twice", uid)
			}
			seen[uid] = struct{}{}
		}
	}
	last := eventStream.events[len(eventStream.events)-1]
	if len(seen) != targetCount || last.GetCompletedItems() != targetCount ||
		last.GetTotalItems() != targetCount || last.GetState() != kmgrv1.OperationState_OPERATION_STATE_SUCCEEDED {
		t.Fatalf("results=%d last=%#v", len(seen), last)
	}
}

func TestDeleteManyRejectsIncompleteUploadWithoutExecutingPartialSelection(t *testing.T) {
	service := testOperationService(t, &fakeYAMLEditor{})
	identity := operationIdentity()
	identity.Resource = "pods"
	stream := &recordingDeleteManyStream{ctx: context.Background(), requests: []*kmgrv1.DeleteManyRequest{
		{
			Sequence: 1,
			Payload: &kmgrv1.DeleteManyRequest_Start{Start: &kmgrv1.DeleteManyStart{
				Context: operationContext("partial"), OperationId: "partial-delete", TotalTargets: 2,
				PropagationPolicy: kmgrv1.PropagationPolicy_PROPAGATION_POLICY_BACKGROUND,
			}},
		},
		{
			Sequence: 2,
			Payload: &kmgrv1.DeleteManyRequest_Targets{Targets: &kmgrv1.DeleteTargetChunk{
				Targets: []*kmgrv1.DeleteTarget{{Identity: identity}},
			}},
		},
	}}
	if err := service.DeleteMany(stream); err != nil {
		t.Fatal(err)
	}
	if stream.response.GetAccepted() || stream.response.GetError().GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION {
		t.Fatalf("partial response = %#v", stream.response)
	}
	if _, found := service.manager.Get("partial-delete"); found {
		t.Fatal("partial upload created an operation")
	}
}

func TestUnaryDeleteRejectsSelectionsThatRequireChunking(t *testing.T) {
	service := testOperationService(t, &fakeYAMLEditor{})
	targets := make([]*kmgrv1.DeleteTarget, maxUnaryDeleteTargets+1)
	response, err := service.Delete(context.Background(), &kmgrv1.DeleteRequest{
		Context: operationContext("oversized-unary"), OperationId: "oversized-unary",
		Targets: targets, PropagationPolicy: kmgrv1.PropagationPolicy_PROPAGATION_POLICY_BACKGROUND,
	})
	if err != nil || response.GetAccepted() || response.GetError().GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION {
		t.Fatalf("response = %#v, error = %v", response, err)
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
	contextName  string
}

func (e *fakeYAMLEditor) ContextName(string) (string, bool) {
	return e.contextName, e.contextName != ""
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
	e.mutations = cloneTestDataMutations(mutations)
	return e.dataResult, e.dataErr
}

func cloneTestDataMutations(values []object.DataMutation) []object.DataMutation {
	result := make([]object.DataMutation, len(values))
	for index, value := range values {
		result[index] = value
		result[index].Value = append([]byte(nil), value.Value...)
		result[index].ExpectedContentHash = append([]byte(nil), value.ExpectedContentHash...)
	}
	return result
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

type recordingDeleteManyStream struct {
	grpc.ServerStream
	ctx      context.Context
	requests []*kmgrv1.DeleteManyRequest
	next     int
	response *kmgrv1.StartOperationResponse
}

func (s *recordingDeleteManyStream) Context() context.Context { return s.ctx }
func (s *recordingDeleteManyStream) Recv() (*kmgrv1.DeleteManyRequest, error) {
	if s.next >= len(s.requests) {
		return nil, io.EOF
	}
	value := s.requests[s.next]
	s.next++
	return value, nil
}
func (s *recordingDeleteManyStream) SendAndClose(value *kmgrv1.StartOperationResponse) error {
	s.response = value
	return nil
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
	oversized := structuredOperationError(
		&ValidationError{Field: "payload", Message: strings.Repeat("x", maxStructuredOperationError*2)},
		operationIdentity(), "apply-yaml", "production-context",
	)
	if proto.Size(oversized) > maxStructuredOperationError ||
		oversized.GetReason() != "OperationErrorDetailsOmitted" ||
		oversized.GetContextName() != "production-context" || oversized.GetResource().GetUid() != "uid" {
		t.Fatalf("bounded structured error = %#v (size %d)", oversized, proto.Size(oversized))
	}
}

func TestStructuredOperationErrorRejectsYAMLForceOwnership(t *testing.T) {
	t.Parallel()
	value := structuredOperationError(
		fmt.Errorf("prepare YAML: %w", object.ErrYAMLForceOwnershipUnsupported),
		operationIdentity(),
		"prepare-yaml",
		"production-context",
	)
	if value.GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_UNSUPPORTED ||
		value.GetReason() != "YAMLForceOwnershipUnsupported" ||
		value.GetFieldPath() != "force_field_ownership" ||
		value.GetContextName() != "production-context" ||
		value.GetOperation() != "prepare-yaml" {
		t.Fatalf("force-ownership error = %#v", value)
	}
}

func TestOperationErrorsRetainHumanContextForValidationAndProgress(t *testing.T) {
	editor := &fakeYAMLEditor{contextName: "production-context", err: errors.New("backend failed")}
	service := testOperationService(t, editor)
	invalid, err := service.Scale(context.Background(), &kmgrv1.ScaleRequest{
		Context: operationContext("invalid-scale"), OperationId: "invalid-scale",
		Identity: operationIdentity(), Replicas: -1, ExpectedResourceVersion: "rv-1",
	})
	if err != nil || invalid.GetError().GetContextName() != "production-context" ||
		invalid.GetError().GetOperation() != "scale" {
		t.Fatalf("validation response = %#v, error = %v", invalid, err)
	}

	started, err := service.ApplyYaml(context.Background(), &kmgrv1.ApplyYamlRequest{
		Context: operationContext("failed-apply"), OperationId: "failed-apply",
		Identity: operationIdentity(), YamlUtf8: []byte("kind: ConfigMap"),
		ExpectedResourceVersion: "rv-1", FieldManager: object.YAMLFieldManager,
	})
	if err != nil || !started.GetAccepted() {
		t.Fatalf("start response = %#v, error = %v", started, err)
	}
	operation, found := service.manager.Get("failed-apply")
	if !found {
		t.Fatal("failed apply was not tracked")
	}
	<-operation.Done()
	events := &recordingOperationStream{ctx: context.Background()}
	if err := service.WatchOperation(&kmgrv1.WatchOperationRequest{
		Context: operationContext("failed-watch"), StreamId: "failed-stream", Generation: 1,
		OperationId: "failed-apply",
	}, events); err != nil {
		t.Fatal(err)
	}
	last := events.events[len(events.events)-1]
	if last.GetError().GetContextName() != "production-context" ||
		last.GetItemResults()[0].GetError().GetContextName() != "production-context" {
		t.Fatalf("terminal event = %#v", last)
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
