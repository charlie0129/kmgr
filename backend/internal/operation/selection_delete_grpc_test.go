package operation

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/view"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

func TestPrepareDeleteSelectionMapsExactBoundedConfirmation(t *testing.T) {
	provider := &operationSelectionProvider{description: view.SelectionDeleteDescription{
		State: view.SelectionState{
			Token: "selection", Generation: 4, IndexRevision: 8, SelectedCount: 3,
			ExpiresAt: time.Unix(2_000, 0),
		},
		Resource:      view.SelectionResource{Version: "v1", Resource: "pods"},
		Generation:    9,
		IndexRevision: 12,
		HiddenCount:   1,
		Preview: []view.SelectionDeletePreview{
			{Identity: view.SelectionIdentity{Version: "v1", Resource: "pods", Namespace: "ns", Name: "a", UID: "uid-a"}},
			{Identity: view.SelectionIdentity{Version: "v1", Resource: "pods", Namespace: "ns", Name: "b", UID: "uid-b"}, Hidden: true},
		},
	}}
	service := testOperationService(t, &fakeYAMLEditor{})
	if err := service.ConfigureSelectionDeletes(provider); err != nil {
		t.Fatal(err)
	}
	requestContext := operationContext("prepare-selection-delete")
	requestContext.DeadlineUnixMs = time.Now().Add(time.Minute).UnixMilli()
	response, err := service.PrepareDeleteSelection(context.Background(), &kmgrv1.PrepareDeleteSelectionRequest{
		Context: requestContext, ViewId: "view",
		SelectionToken: "selection", Generation: 9, IndexRevision: 12, PreviewLimit: 2,
	})
	if err != nil || response.GetError() != nil {
		t.Fatalf("prepare response = %#v, error = %v", response, err)
	}
	if response.GetRequestId() != "prepare-selection-delete" || response.GetSelectedCount() != 3 ||
		response.GetHiddenCount() != 1 || response.GetExpiresAtUnixMs() != 2_000_000 ||
		response.GetResource().GetResource() != "pods" || len(response.GetPreview()) != 2 ||
		response.GetPreview()[0].GetIdentity().GetUid() != "uid-a" ||
		response.GetPreview()[0].GetHiddenByFilter() ||
		!response.GetPreview()[1].GetHiddenByFilter() || !response.GetPreviewTruncated() {
		t.Fatalf("prepare response = %#v", response)
	}
	if provider.prepareCalls != 1 || provider.lastPreviewLimit != 2 {
		t.Fatalf("prepare calls = %d, limit = %d", provider.prepareCalls, provider.lastPreviewLimit)
	}
	deadline, ok := provider.lastPrepareContext.Deadline()
	if !ok || !deadline.Equal(time.UnixMilli(requestContext.GetDeadlineUnixMs())) {
		t.Fatalf("prepare context deadline = %v, %t", deadline, ok)
	}
}

func TestSelectionDeleteErrorMapsPreparationCancellation(t *testing.T) {
	service := testOperationService(t, &fakeYAMLEditor{})
	tests := []struct {
		name      string
		err       error
		category  kmgrv1.ErrorCategory
		reason    string
		retryable bool
	}{
		{
			name: "cancelled", err: context.Canceled,
			category: kmgrv1.ErrorCategory_ERROR_CATEGORY_CANCELLED,
			reason:   "SelectionPreparationCancelled",
		},
		{
			name: "deadline", err: context.DeadlineExceeded,
			category: kmgrv1.ErrorCategory_ERROR_CATEGORY_TIMEOUT,
			reason:   "SelectionPreparationTimedOut", retryable: true,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			mapped := service.selectionDeleteError(
				test.err, "prepare-delete-selection", "session",
			)
			if mapped.GetCategory() != test.category || mapped.GetReason() != test.reason ||
				mapped.GetRetryable() != test.retryable {
				t.Fatalf("mapped preparation error = %#v", mapped)
			}
		})
	}
}

func TestDeleteSelectionLeasesPastExpiryAndStreamsAggregateProgress(t *testing.T) {
	lease := operationSelectionLeaseForTest(20*time.Millisecond, 600)
	state := lease.state
	provider := &operationSelectionProvider{lease: lease}
	recording := &recordingProvider{started: make(chan struct{}, 1), block: make(chan struct{})}
	service := testOperationService(t, &fakeYAMLEditor{
		resource: &recordingResource{provider: recording},
	})
	if err := service.ConfigureSelectionDeletes(provider); err != nil {
		t.Fatal(err)
	}
	response, err := service.DeleteSelection(context.Background(), &kmgrv1.DeleteSelectionRequest{
		Context: operationContext("delete-selection"), OperationId: "selection-delete-operation",
		ViewId: "view", SelectionToken: state.Token, SelectedCount: state.SelectedCount,
		Resource:          &kmgrv1.ResourceType{Version: "v1", Resource: "pods"},
		PropagationPolicy: kmgrv1.PropagationPolicy_PROPAGATION_POLICY_BACKGROUND,
		MaxConcurrency:    1,
	})
	if err != nil || !response.GetAccepted() || response.GetError() != nil {
		t.Fatalf("delete response = %#v, error = %v", response, err)
	}
	select {
	case <-recording.started:
	case <-time.After(time.Second):
		t.Fatal("selection delete did not reach Kubernetes")
	}
	time.Sleep(time.Until(state.ExpiresAt) + 5*time.Millisecond)
	if lease.released.Load() {
		t.Fatal("running selection lease was released at token expiry")
	}
	close(recording.block)
	operation, found := service.manager.Get("selection-delete-operation")
	if !found {
		t.Fatal("selection delete operation was not tracked")
	}
	select {
	case <-operation.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("selection delete operation did not finish")
	}
	if !lease.released.Load() {
		t.Fatal("terminal selection operation did not release its lease")
	}

	stream := &recordingOperationStream{ctx: context.Background()}
	if err := service.WatchOperation(&kmgrv1.WatchOperationRequest{
		Context: operationContext("watch-selection-delete"), StreamId: "selection-delete-stream",
		Generation: 1, OperationId: "selection-delete-operation",
	}, stream); err != nil {
		t.Fatal(err)
	}
	last := stream.events[len(stream.events)-1]
	if !last.GetAggregateOnly() || last.GetCompletedItems() != 600 || last.GetTotalItems() != 600 ||
		last.GetState() != kmgrv1.OperationState_OPERATION_STATE_SUCCEEDED ||
		len(last.GetItemResults()) != 0 || last.GetOmittedItemResults() != 0 {
		t.Fatalf("aggregate terminal event = %#v", last)
	}
	recording.mu.Lock()
	defer recording.mu.Unlock()
	if len(recording.calls) != 600 {
		t.Fatalf("Kubernetes delete calls = %d", len(recording.calls))
	}
	for _, call := range recording.calls {
		if call.options.Preconditions == nil || call.options.Preconditions.UID == nil {
			t.Fatalf("selection delete omitted UID precondition: %#v", call)
		}
	}
}

func TestDeleteSelectionRejectsConfirmationMismatchBeforeMutation(t *testing.T) {
	lease := operationSelectionLeaseForTest(time.Minute, 2)
	state := lease.state
	recording := &recordingProvider{}
	service := testOperationService(t, &fakeYAMLEditor{
		resource: &recordingResource{provider: recording},
	})
	if err := service.ConfigureSelectionDeletes(&operationSelectionProvider{lease: lease}); err != nil {
		t.Fatal(err)
	}
	response, err := service.DeleteSelection(context.Background(), &kmgrv1.DeleteSelectionRequest{
		Context: operationContext("mismatched-selection"), OperationId: "mismatched-selection",
		ViewId: "view", SelectionToken: state.Token, SelectedCount: state.SelectedCount + 1,
		Resource:          &kmgrv1.ResourceType{Version: "v1", Resource: "pods"},
		PropagationPolicy: kmgrv1.PropagationPolicy_PROPAGATION_POLICY_BACKGROUND,
	})
	if err != nil || response.GetAccepted() ||
		response.GetError().GetReason() != "SelectionConfirmationMismatch" {
		t.Fatalf("mismatch response = %#v, error = %v", response, err)
	}
	if _, found := service.manager.Get("mismatched-selection"); found {
		t.Fatal("mismatched selection started an operation")
	}
	if !lease.released.Load() {
		t.Fatal("rejected selection confirmation retained its lease")
	}
	recording.mu.Lock()
	defer recording.mu.Unlock()
	if len(recording.calls) != 0 {
		t.Fatal("mismatched selection reached Kubernetes")
	}
}

func TestDeleteSelectionWatchBoundsFailureDetailsAndReportsOmissions(t *testing.T) {
	const total = DefaultMaxAggregateResults + 44
	lease := operationSelectionLeaseForTest(time.Minute, total)
	failures := make(map[string]error, total)
	for _, identity := range lease.identities {
		failures[identity.Name] = errors.New("delete failed")
	}
	service := testOperationService(t, &fakeYAMLEditor{
		resource: &recordingResource{provider: &recordingProvider{errors: failures}},
	})
	if err := service.ConfigureSelectionDeletes(&operationSelectionProvider{lease: lease}); err != nil {
		t.Fatal(err)
	}
	response, err := service.DeleteSelection(context.Background(), &kmgrv1.DeleteSelectionRequest{
		Context:     operationContext("bounded-selection-failures"),
		OperationId: "bounded-selection-failures", ViewId: "view",
		SelectionToken: lease.state.Token, SelectedCount: lease.state.SelectedCount,
		Resource:          &kmgrv1.ResourceType{Version: "v1", Resource: "pods"},
		PropagationPolicy: kmgrv1.PropagationPolicy_PROPAGATION_POLICY_BACKGROUND,
		MaxConcurrency:    MaxDeleteConcurrency,
	})
	if err != nil || !response.GetAccepted() || response.GetError() != nil {
		t.Fatalf("delete response = %#v, error = %v", response, err)
	}
	operation, found := service.manager.Get("bounded-selection-failures")
	if !found {
		t.Fatal("selection delete operation was not tracked")
	}
	select {
	case <-operation.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("selection delete operation did not finish")
	}

	stream := &recordingOperationStream{ctx: context.Background()}
	if err := service.WatchOperation(&kmgrv1.WatchOperationRequest{
		Context:  operationContext("watch-bounded-selection-failures"),
		StreamId: "bounded-selection-failure-stream", Generation: 1,
		OperationId: "bounded-selection-failures",
	}, stream); err != nil {
		t.Fatal(err)
	}
	retained := 0
	for _, event := range stream.events {
		if !event.GetAggregateOnly() {
			t.Fatalf("non-aggregate event = %#v", event)
		}
		retained += len(event.GetItemResults())
	}
	last := stream.events[len(stream.events)-1]
	if retained != DefaultMaxAggregateResults ||
		last.GetOmittedItemResults() != total-DefaultMaxAggregateResults ||
		last.GetCompletedItems() != total || last.GetTotalItems() != total ||
		last.GetState() != kmgrv1.OperationState_OPERATION_STATE_FAILED {
		t.Fatalf(
			"retained=%d terminal state=%v completed=%d/%d omitted=%d",
			retained, last.GetState(), last.GetCompletedItems(), last.GetTotalItems(),
			last.GetOmittedItemResults(),
		)
	}
}

func TestDeleteSelectionPreservesSanitizedForbiddenDiagnostics(t *testing.T) {
	const (
		rawStatusSecret = "raw-status-secret"
		rawCauseSecret  = "raw-cause-secret"
	)
	lease := operationSelectionLeaseForTest(time.Minute, 1)
	failure := &aggregateHiddenAPIStatusError{
		status: metav1.Status{
			Status: metav1.StatusFailure, Reason: metav1.StatusReasonForbidden,
			Code: 403, Message: strings.Repeat(rawStatusSecret, 8<<10),
			Details: &metav1.StatusDetails{
				Name: "pod-000000", Group: "apps", Kind: "Pod",
				UID: types.UID("uid-000000"),
				Causes: []metav1.StatusCause{{
					Type: metav1.CauseTypeForbidden, Field: "spec.serviceAccountName",
					Message: strings.Repeat(rawCauseSecret, 8<<10),
				}},
			},
		},
		payload: make([]byte, DefaultMaxAggregateBytes*2),
	}
	service := testOperationService(t, &fakeYAMLEditor{
		resource: &recordingResource{provider: &recordingProvider{errors: map[string]error{
			lease.identities[0].Name: failure,
		}}},
	})
	if err := service.ConfigureSelectionDeletes(&operationSelectionProvider{lease: lease}); err != nil {
		t.Fatal(err)
	}
	response, err := service.DeleteSelection(context.Background(), &kmgrv1.DeleteSelectionRequest{
		Context: operationContext("forbidden-selection"), OperationId: "forbidden-selection",
		ViewId: "view", SelectionToken: lease.state.Token,
		SelectedCount:     lease.state.SelectedCount,
		Resource:          &kmgrv1.ResourceType{Version: "v1", Resource: "pods"},
		PropagationPolicy: kmgrv1.PropagationPolicy_PROPAGATION_POLICY_BACKGROUND,
		MaxConcurrency:    1,
	})
	if err != nil || !response.GetAccepted() || response.GetError() != nil {
		t.Fatalf("delete response = %#v, error = %v", response, err)
	}
	operation, found := service.manager.Get("forbidden-selection")
	if !found {
		t.Fatal("selection delete operation was not tracked")
	}
	select {
	case <-operation.Done():
	case <-time.After(time.Second):
		t.Fatal("selection delete operation did not finish")
	}
	status := operation.Status()
	if len(status.Items) != 1 || status.Items[0].Err == nil ||
		status.retainedItemBytes > DefaultMaxAggregateBytes {
		t.Fatalf("aggregate forbidden status = %#v", status)
	}
	var retainedOriginal *aggregateHiddenAPIStatusError
	if errors.As(status.Items[0].Err, &retainedOriginal) ||
		errors.As(status.Err, &retainedOriginal) {
		t.Fatal("aggregate status retained the original Kubernetes error payload")
	}
	var retainedStatus interface{ Status() metav1.Status }
	if !errors.As(status.Items[0].Err, &retainedStatus) {
		t.Fatalf("retained error lost APIStatus: %T", status.Items[0].Err)
	}
	safeStatus := retainedStatus.Status()
	if safeStatus.Message != "" || safeStatus.Details == nil ||
		len(safeStatus.Details.Causes) != 1 ||
		safeStatus.Details.Causes[0].Message != "" {
		t.Fatalf("retained unsafe Kubernetes status = %#v", safeStatus)
	}

	stream := &recordingOperationStream{ctx: context.Background()}
	if err := service.WatchOperation(&kmgrv1.WatchOperationRequest{
		Context:  operationContext("watch-forbidden-selection"),
		StreamId: "forbidden-selection-stream", Generation: 1,
		OperationId: "forbidden-selection",
	}, stream); err != nil {
		t.Fatal(err)
	}
	last := stream.events[len(stream.events)-1]
	if len(last.GetItemResults()) != 1 {
		t.Fatalf("forbidden terminal event = %#v", last)
	}
	structured := last.GetItemResults()[0].GetError()
	details := structured.GetKubernetesStatus()
	if structured.GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHORIZATION ||
		structured.GetReason() != "Forbidden" || structured.GetHttpStatusCode() != 403 ||
		structured.GetRetryable() || details.GetName() != "pod-000000" ||
		details.GetGroup() != "apps" || details.GetKind() != "Pod" ||
		details.GetUid() != "uid-000000" || len(details.GetCauses()) != 1 ||
		details.GetCauses()[0].GetReason() != "FieldValueForbidden" ||
		details.GetCauses()[0].GetField() != "spec.serviceAccountName" {
		t.Fatalf("sanitized forbidden error = %#v", structured)
	}
	if terminal := last.GetError(); terminal.GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHORIZATION ||
		terminal.GetReason() != "Forbidden" || terminal.GetHttpStatusCode() != 403 {
		t.Fatalf("sanitized terminal forbidden error = %#v", terminal)
	}
	if encoded := last.String(); strings.Contains(encoded, rawStatusSecret) ||
		strings.Contains(encoded, rawCauseSecret) {
		t.Fatal("forbidden progress exposed raw Kubernetes status messages")
	}
}

func TestDeleteSelectionClampsPagesToLeaseLimit(t *testing.T) {
	lease := operationSelectionLeaseForTest(time.Minute, 19)
	lease.maxPageSize = 7
	recording := &recordingProvider{}
	service := testOperationService(t, &fakeYAMLEditor{
		resource: &recordingResource{provider: recording},
	})
	if err := service.ConfigureSelectionDeletes(&operationSelectionProvider{lease: lease}); err != nil {
		t.Fatal(err)
	}
	response, err := service.DeleteSelection(context.Background(), &kmgrv1.DeleteSelectionRequest{
		Context: operationContext("small-selection-pages"), OperationId: "small-selection-pages",
		ViewId: "view", SelectionToken: lease.state.Token,
		SelectedCount:     lease.state.SelectedCount,
		Resource:          &kmgrv1.ResourceType{Version: "v1", Resource: "pods"},
		PropagationPolicy: kmgrv1.PropagationPolicy_PROPAGATION_POLICY_BACKGROUND,
		MaxConcurrency:    1,
	})
	if err != nil || !response.GetAccepted() || response.GetError() != nil {
		t.Fatalf("delete response = %#v, error = %v", response, err)
	}
	operation, found := service.manager.Get("small-selection-pages")
	if !found {
		t.Fatal("selection delete operation was not tracked")
	}
	select {
	case <-operation.Done():
	case <-time.After(time.Second):
		t.Fatal("selection delete operation did not finish")
	}
	if got, want := lease.pageLimits, []uint32{7, 7, 5}; !slices.Equal(got, want) {
		t.Fatalf("selection lease page limits = %v, want %v", got, want)
	}
	recording.mu.Lock()
	defer recording.mu.Unlock()
	if len(recording.calls) != 19 {
		t.Fatalf("Kubernetes delete calls = %d, want 19", len(recording.calls))
	}
}

func TestWatchOperationStreamsRunningAggregateCounterProgress(t *testing.T) {
	service := testOperationService(t, &fakeYAMLEditor{})
	advance := make(chan struct{})
	finish := make(chan struct{})
	started := make(chan struct{})
	reported := make(chan struct{})
	operation, err := service.manager.StartAggregate(
		context.Background(), "counter-progress", "delete", "session", 2,
		func(ctx context.Context, report AggregateReporter) error {
			close(started)
			select {
			case <-advance:
			case <-ctx.Done():
				return context.Cause(ctx)
			}
			if !report(
				operationTestIdentity("pod-a", "uid-a"),
				ItemUpdate{State: ItemStateSucceeded},
			) {
				return errors.New("aggregate success report was rejected")
			}
			close(reported)
			select {
			case <-finish:
			case <-ctx.Done():
				return context.Cause(ctx)
			}
			if !report(
				operationTestIdentity("pod-b", "uid-b"),
				ItemUpdate{State: ItemStateSucceeded},
			) {
				return errors.New("aggregate success report was rejected")
			}
			return nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	<-started
	stream := &recordingOperationStream{ctx: context.Background()}
	watchDone := make(chan error, 1)
	go func() {
		watchDone <- service.WatchOperation(&kmgrv1.WatchOperationRequest{
			Context:  operationContext("watch-counter-progress"),
			StreamId: "counter-progress-stream", Generation: 1,
			OperationId: "counter-progress",
		}, stream)
	}()
	eventuallyOperation(t, func() bool {
		stream.mu.Lock()
		defer stream.mu.Unlock()
		return len(stream.events) == 1 && stream.events[0].GetCompletedItems() == 0
	})
	close(advance)
	<-reported
	eventuallyOperation(t, func() bool {
		stream.mu.Lock()
		defer stream.mu.Unlock()
		return len(stream.events) >= 2
	})
	stream.mu.Lock()
	progress := stream.events[1]
	stream.mu.Unlock()
	if !progress.GetAggregateOnly() || progress.GetCompletedItems() != 1 ||
		progress.GetTotalItems() != 2 || len(progress.GetItemResults()) != 0 ||
		progress.GetState() != kmgrv1.OperationState_OPERATION_STATE_RUNNING {
		t.Fatalf("running aggregate counter event = %#v", progress)
	}
	close(finish)
	select {
	case err := <-watchDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		operation.Cancel()
		t.Fatal("aggregate counter watch did not finish")
	}
}

func TestWatchOperationStreamsRunningAggregateOmissionProgress(t *testing.T) {
	service := testOperationService(t, &fakeYAMLEditor{})
	omitNext := make(chan struct{})
	finish := make(chan struct{})
	seeded := make(chan struct{})
	omitted := make(chan struct{})
	total := uint32(DefaultMaxAggregateResults + 2)
	operation, err := service.manager.StartAggregate(
		context.Background(), "omission-progress", "delete", "session", total,
		func(ctx context.Context, report AggregateReporter) error {
			for index := range DefaultMaxAggregateResults {
				if !report(
					operationTestIdentity(
						fmt.Sprintf("pod-%d", index), fmt.Sprintf("uid-%d", index),
					),
					ItemUpdate{State: ItemStateFailed, Err: errors.New("delete failed")},
				) {
					return errors.New("aggregate failure report was rejected")
				}
			}
			close(seeded)
			select {
			case <-omitNext:
			case <-ctx.Done():
				return context.Cause(ctx)
			}
			if !report(
				operationTestIdentity("pod-omitted", "uid-omitted"),
				ItemUpdate{State: ItemStateFailed, Err: errors.New("delete failed")},
			) {
				return errors.New("aggregate omitted failure report was rejected")
			}
			close(omitted)
			select {
			case <-finish:
			case <-ctx.Done():
				return context.Cause(ctx)
			}
			if !report(
				operationTestIdentity("pod-success", "uid-success"),
				ItemUpdate{State: ItemStateSucceeded},
			) {
				return errors.New("aggregate success report was rejected")
			}
			return nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	<-seeded
	stream := &recordingOperationStream{ctx: context.Background()}
	watchDone := make(chan error, 1)
	go func() {
		watchDone <- service.WatchOperation(&kmgrv1.WatchOperationRequest{
			Context:  operationContext("watch-omission-progress"),
			StreamId: "omission-progress-stream", Generation: 1,
			OperationId: "omission-progress",
		}, stream)
	}()
	eventuallyOperation(t, func() bool {
		stream.mu.Lock()
		defer stream.mu.Unlock()
		return len(stream.events) == 1 &&
			len(stream.events[0].GetItemResults()) == DefaultMaxAggregateResults
	})
	close(omitNext)
	<-omitted
	eventuallyOperation(t, func() bool {
		stream.mu.Lock()
		defer stream.mu.Unlock()
		return len(stream.events) >= 2
	})
	stream.mu.Lock()
	progress := stream.events[1]
	stream.mu.Unlock()
	if !progress.GetAggregateOnly() || progress.GetCompletedItems() != total-1 ||
		progress.GetOmittedItemResults() != 1 || len(progress.GetItemResults()) != 0 ||
		progress.GetState() != kmgrv1.OperationState_OPERATION_STATE_RUNNING {
		t.Fatalf("running aggregate omission event = %#v", progress)
	}
	close(finish)
	select {
	case err := <-watchDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		operation.Cancel()
		t.Fatal("aggregate omission watch did not finish")
	}
}

type operationSelectionProvider struct {
	lease              SelectionDeleteLease
	description        view.SelectionDeleteDescription
	prepareErr         error
	prepareCalls       int
	lastPreviewLimit   uint32
	lastPrepareContext context.Context
}

func (p *operationSelectionProvider) PrepareSelectionDelete(
	ctx context.Context, _, _, _ string, _, _ uint64, previewLimit uint32,
) (view.SelectionDeleteDescription, error) {
	p.prepareCalls++
	p.lastPreviewLimit = previewLimit
	p.lastPrepareContext = ctx
	return p.description, p.prepareErr
}

func (p *operationSelectionProvider) AcquireSelectionLease(
	sessionID, viewID, token string,
) (SelectionDeleteLease, error) {
	if p.lease == nil {
		return nil, errors.New("selection store is unavailable")
	}
	state := p.lease.State()
	if sessionID != "session" || viewID != "view" || token != state.Token {
		return nil, view.ErrSelectionScopeMismatch
	}
	return p.lease, nil
}

type operationSelectionLease struct {
	state       view.SelectionState
	resource    view.SelectionResource
	identities  []view.SelectionIdentity
	maxPageSize uint32
	pageLimits  []uint32
	released    atomic.Bool
}

type aggregateHiddenAPIStatusError struct {
	status  metav1.Status
	payload []byte
}

func (e *aggregateHiddenAPIStatusError) Error() string { return e.status.Message }

func (e *aggregateHiddenAPIStatusError) Status() metav1.Status { return e.status }

func operationSelectionLeaseForTest(
	ttl time.Duration,
	count int,
) *operationSelectionLease {
	identities := make([]view.SelectionIdentity, count)
	for index := range identities {
		identities[index] = view.SelectionIdentity{
			Version: "v1", Resource: "pods", Namespace: "ns",
			Name: "pod-" + formatSelectionIndex(index), UID: "uid-" + formatSelectionIndex(index),
		}
	}
	return &operationSelectionLease{
		state: view.SelectionState{
			Token: "selection", Generation: 1, IndexRevision: 1,
			SelectedCount: uint64(count), ExpiresAt: time.Now().Add(ttl),
		},
		resource:    view.SelectionResource{Version: "v1", Resource: "pods"},
		identities:  identities,
		maxPageSize: view.DefaultMaxSelectionPageSize,
	}
}

func (l *operationSelectionLease) State() view.SelectionState { return l.state }

func (l *operationSelectionLease) Resource() (view.SelectionResource, bool) {
	return l.resource, len(l.identities) > 0
}

func (l *operationSelectionLease) MaxPageSize() uint32 { return l.maxPageSize }

func (l *operationSelectionLease) Page(offset uint64, limit uint32) (view.SelectionPage, error) {
	l.pageLimits = append(l.pageLimits, limit)
	if offset > uint64(len(l.identities)) || limit == 0 || limit > l.maxPageSize {
		return view.SelectionPage{}, view.ErrInvalidSelectionPage
	}
	end := min(offset+uint64(limit), uint64(len(l.identities)))
	items := make([]view.SelectionPageItem, 0, end-offset)
	for index := offset; index < end; index++ {
		items = append(items, view.SelectionPageItem{
			Index: index, Identity: l.identities[index],
		})
	}
	return view.SelectionPage{
		State: l.state, Offset: offset, Items: items, NextOffset: end,
		Done: end == uint64(len(l.identities)),
	}, nil
}

func (l *operationSelectionLease) Release() { l.released.Store(true) }

func formatSelectionIndex(index int) string {
	return fmt.Sprintf("%06d", index)
}
