package cluster

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const apiOperationCompletionCapacity = 8_192

type APIOperationState uint32

const (
	APIOperationStateUnspecified APIOperationState = iota
	APIOperationStateActive
	APIOperationStateFinished
	APIOperationStateFailed
	APIOperationStateCancelled
	APIOperationStateTimedOut
)

// APIOperationSnapshot contains request metadata plus exact decoded Kubernetes
// watch Status details and original Go error text for failed operations. It
// never contains query values, selectors, headers, bodies, credentials, or
// raw URLs.
type APIOperationSnapshot struct {
	ID                  uint64
	State               APIOperationState
	Operation           string
	Group               string
	Version             string
	Resource            string
	Namespace           string
	Name                string
	Subresource         string
	HTTPStatusCode      int32
	BytesReceived       uint64
	BytesSent           uint64
	StartedAtUnixNanos  int64
	FinishedAtUnixNanos int64
	ErrorMessage        string
}

type APIOperationActivitySnapshot struct {
	Active           []APIOperationSnapshot
	Completed        []APIOperationSnapshot
	CompletionCursor uint64
	DroppedCompleted uint64
}

type apiOperationDescriptor struct {
	operation   string
	group       string
	version     string
	resource    string
	namespace   string
	name        string
	subresource string
}

type trackedAPIOperation struct {
	activity           *APIActivity
	id                 uint64
	detail             apiOperationDescriptor
	ctx                context.Context
	started            int64
	received           atomic.Uint64
	sent               atomic.Uint64
	status             atomic.Int32
	finish             sync.Once
	terminalMu         sync.Mutex
	serverErrorMessage string
	goErrorMessage     string
	completedSnapshot  APIOperationSnapshot
	completed          bool
}

type completedAPIOperation struct {
	sequence uint64
	snapshot APIOperationSnapshot
}

type apiOperationCompletionRing struct {
	entries []completedAPIOperation
	head    int
}

func (a *APIActivity) beginOperation(request *http.Request) *trackedAPIOperation {
	if a == nil || request == nil {
		return nil
	}
	operation := &trackedAPIOperation{
		activity: a,
		id:       a.operationSequence.Add(1),
		detail:   describeAPIOperation(request),
		ctx:      request.Context(),
		started:  time.Now().UnixNano(),
	}
	a.operationsMu.Lock()
	if a.activeOperations == nil {
		a.activeOperations = make(map[uint64]*trackedAPIOperation)
	}
	a.activeOperations[operation.id] = operation
	a.operationsMu.Unlock()
	return operation
}

// OperationActivitySnapshot returns a replacement active snapshot and only
// completions or corrected completions newer than afterCompletion. The fixed
// backend ring bridges the 500 ms IPC sampling interval; long-lived GUI
// retention is maintained by the client and is not retransmitted on every
// sample.
func (a *APIActivity) OperationActivitySnapshot(
	afterCompletion uint64,
) APIOperationActivitySnapshot {
	if a == nil {
		return APIOperationActivitySnapshot{}
	}
	a.operationsMu.RLock()
	active := make([]APIOperationSnapshot, 0, len(a.activeOperations))
	for _, operation := range a.activeOperations {
		active = append(active, operation.snapshot(APIOperationStateActive, 0))
	}
	completed, dropped := a.completedOperations.recordsAfter(afterCompletion)
	cursor := a.completionSequence
	a.operationsMu.RUnlock()

	sort.Slice(active, func(i, j int) bool {
		if active[i].StartedAtUnixNanos != active[j].StartedAtUnixNanos {
			return active[i].StartedAtUnixNanos < active[j].StartedAtUnixNanos
		}
		return active[i].ID < active[j].ID
	})
	return APIOperationActivitySnapshot{
		Active:           active,
		Completed:        completed,
		CompletionCursor: cursor,
		DroppedCompleted: dropped,
	}
}

func (o *trackedAPIOperation) setHTTPStatus(statusCode int) {
	if o != nil {
		o.status.Store(int32(statusCode))
	}
}

func (o *trackedAPIOperation) addReceived(count uint64) {
	if o != nil && count != 0 {
		o.received.Add(count)
	}
}

func (o *trackedAPIOperation) addSent(count uint64) {
	if o != nil && count != 0 {
		o.sent.Add(count)
	}
}

func (o *trackedAPIOperation) complete(terminalError error) {
	if o == nil || o.activity == nil {
		return
	}
	o.finish.Do(func() {
		finished := time.Now().UnixNano()
		contextError := o.ctx.Err()
		statusCode := int(o.status.Load())
		state := completedAPIOperationState(
			contextError, terminalError, statusCode,
		)
		snapshot := o.snapshot(state, finished)
		goErrorMessage := apiOperationErrorMessage(
			contextError, terminalError, statusCode,
		)
		o.terminalMu.Lock()
		o.goErrorMessage = goErrorMessage
		if o.serverErrorMessage != "" {
			snapshot.State = APIOperationStateFailed
		}
		snapshot.ErrorMessage = combinedAPIOperationErrorMessage(
			o.serverErrorMessage,
			o.goErrorMessage,
		)
		o.completedSnapshot = snapshot
		o.completed = true
		a := o.activity
		a.operationsMu.Lock()
		if a.activeOperations[o.id] == o {
			delete(a.activeOperations, o.id)
		}
		a.completionSequence++
		a.completedOperations.append(completedAPIOperation{
			sequence: a.completionSequence,
			snapshot: snapshot,
		})
		a.operationsMu.Unlock()
		o.terminalMu.Unlock()
	})
}

// recordWatchError attaches an embedded Kubernetes watch.Error to the same
// HTTP operation as the response stream. If the Go body error completed first,
// append a corrected completion with the same operation ID and a newer cursor
// so already-running history consumers receive the full two-layer failure.
func (o *trackedAPIOperation) recordWatchError(err error) {
	if o == nil || o.activity == nil || err == nil {
		return
	}
	message := kubernetesWatchErrorMessage(err)
	if message == "" {
		return
	}

	o.terminalMu.Lock()
	if o.serverErrorMessage == message {
		o.terminalMu.Unlock()
		return
	}
	o.serverErrorMessage = message
	if !o.completed {
		o.terminalMu.Unlock()
		return
	}

	snapshot := o.completedSnapshot
	snapshot.State = APIOperationStateFailed
	snapshot.ErrorMessage = combinedAPIOperationErrorMessage(
		o.serverErrorMessage,
		o.goErrorMessage,
	)
	o.completedSnapshot = snapshot
	a := o.activity
	a.operationsMu.Lock()
	a.completionSequence++
	a.completedOperations.append(completedAPIOperation{
		sequence: a.completionSequence,
		snapshot: snapshot,
	})
	a.operationsMu.Unlock()
	o.terminalMu.Unlock()
}

func (o *trackedAPIOperation) snapshot(
	state APIOperationState,
	finished int64,
) APIOperationSnapshot {
	return APIOperationSnapshot{
		ID:                  o.id,
		State:               state,
		Operation:           o.detail.operation,
		Group:               o.detail.group,
		Version:             o.detail.version,
		Resource:            o.detail.resource,
		Namespace:           o.detail.namespace,
		Name:                o.detail.name,
		Subresource:         o.detail.subresource,
		HTTPStatusCode:      o.status.Load(),
		BytesReceived:       o.received.Load(),
		BytesSent:           o.sent.Load(),
		StartedAtUnixNanos:  o.started,
		FinishedAtUnixNanos: finished,
	}
}

func completedAPIOperationState(
	contextError, terminalError error,
	statusCode int,
) APIOperationState {
	switch {
	case errors.Is(contextError, context.DeadlineExceeded):
		return APIOperationStateTimedOut
	case errors.Is(contextError, context.Canceled):
		return APIOperationStateCancelled
	case terminalError != nil && !errors.Is(terminalError, io.EOF):
		if errors.Is(terminalError, context.DeadlineExceeded) {
			return APIOperationStateTimedOut
		}
		if errors.Is(terminalError, context.Canceled) {
			return APIOperationStateCancelled
		}
		return APIOperationStateFailed
	case statusCode >= http.StatusBadRequest || statusCode == 0:
		return APIOperationStateFailed
	default:
		return APIOperationStateFinished
	}
}

func (r *apiOperationCompletionRing) append(operation completedAPIOperation) {
	if len(r.entries) < apiOperationCompletionCapacity {
		r.entries = append(r.entries, operation)
		return
	}
	r.entries[r.head] = operation
	r.head = (r.head + 1) % len(r.entries)
}

func (r *apiOperationCompletionRing) recordsAfter(
	sequence uint64,
) ([]APIOperationSnapshot, uint64) {
	if len(r.entries) == 0 {
		return nil, 0
	}
	oldest := r.entries[r.head].sequence
	dropped := uint64(0)
	if oldest > 0 && sequence < oldest-1 {
		dropped = oldest - 1 - sequence
		sequence = oldest - 1
	}
	records := make([]APIOperationSnapshot, 0, len(r.entries))
	for offset := range len(r.entries) {
		entry := r.entries[(r.head+offset)%len(r.entries)]
		if entry.sequence > sequence {
			records = append(records, entry.snapshot)
		}
	}
	return records, dropped
}

func describeAPIOperation(request *http.Request) apiOperationDescriptor {
	detail := apiOperationDescriptor{operation: operationForMethod(request.Method, false)}
	if request.URL == nil {
		detail.resource = "Kubernetes API"
		return detail
	}
	segments := safeAPIPathSegments(request.URL.Path)
	if len(segments) == 0 {
		detail.resource = "Kubernetes API"
		return detail
	}

	resourceIndex := -1
	switch {
	case segments[0] == "api" && len(segments) >= 2:
		detail.version = segments[1]
		resourceIndex = 2
	case segments[0] == "apis" && len(segments) >= 3:
		detail.group = segments[1]
		detail.version = segments[2]
		resourceIndex = 3
	case segments[0] == "api" || segments[0] == "apis":
		detail.operation = "DISCOVER"
		detail.resource = "API discovery"
		return detail
	case segments[0] == "version":
		detail.resource = "Version"
		return detail
	default:
		detail.resource = "Kubernetes API"
		return detail
	}
	if resourceIndex >= len(segments) {
		detail.operation = "DISCOVER"
		detail.resource = "API discovery"
		return detail
	}

	// A namespaced path is .../namespaces/{namespace}/{resource}. The shorter
	// .../namespaces/{name} form addresses the Namespace resource itself.
	if segments[resourceIndex] == "namespaces" && len(segments) >= resourceIndex+3 &&
		!(len(segments) == resourceIndex+3 &&
			(segments[resourceIndex+2] == "status" || segments[resourceIndex+2] == "finalize")) {
		detail.namespace = segments[resourceIndex+1]
		resourceIndex += 2
	}
	detail.resource = segments[resourceIndex]
	if len(segments) > resourceIndex+1 {
		detail.name = segments[resourceIndex+1]
	}
	if len(segments) > resourceIndex+2 {
		detail.subresource = segments[resourceIndex+2]
	}

	isCollection := detail.name == ""
	detail.operation = operationForMethod(request.Method, isCollection)
	if request.Method == http.MethodGet && request.URL.Query().Get("watch") == "true" {
		detail.operation = "WATCH"
	} else if isConnectSubresource(detail.subresource) {
		detail.operation = "CONNECT"
	}
	return detail
}

func operationForMethod(method string, collection bool) string {
	switch strings.ToUpper(method) {
	case http.MethodGet:
		if collection {
			return "LIST"
		}
		return "GET"
	case http.MethodPost:
		if collection {
			return "CREATE"
		}
		return "POST"
	case http.MethodPut:
		return "UPDATE"
	case http.MethodPatch:
		return "PATCH"
	case http.MethodDelete:
		return "DELETE"
	default:
		method = safeAPIPathSegment(strings.ToUpper(method))
		if method == "" {
			return "REQUEST"
		}
		return method
	}
}

func isConnectSubresource(value string) bool {
	switch value {
	case "attach", "exec", "portforward", "proxy":
		return true
	default:
		return false
	}
}

func safeAPIPathSegments(path string) []string {
	raw := strings.Split(strings.Trim(path, "/"), "/")
	segments := make([]string, 0, len(raw))
	for _, value := range raw {
		if value == "" {
			continue
		}
		segments = append(segments, safeAPIPathSegment(value))
	}
	return segments
}

func safeAPIPathSegment(value string) string {
	if unescaped, err := url.PathUnescape(value); err == nil {
		value = unescaped
	}
	if len(value) == 0 || len(value) > 253 {
		return ""
	}
	for _, character := range value {
		if (character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') ||
			character == '.' || character == '-' || character == '_' {
			continue
		}
		return ""
	}
	return value
}
