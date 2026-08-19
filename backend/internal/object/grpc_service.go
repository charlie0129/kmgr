package object

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sort"
	"sync"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/kubeerrors"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/watch"
)

var _ kmgrv1.ObjectServiceServer = (*GRPCService)(nil)

type GRPCService struct {
	kmgrv1.UnimplementedObjectServiceServer
	reader          *Reader
	metricsProvider DetailMetricsProvider
	watchRetryDelay func(int) time.Duration
	scanMu          sync.Mutex
	scans           map[relationshipScanKey]context.CancelFunc
}

type relationshipScanKey struct {
	sessionID  string
	scanID     string
	generation uint64
}

// objectWatchStreamSendError separates a failed gRPC delivery from failures
// opening or consuming the Kubernetes watch. A disconnected client must end
// this RPC; retrying the API watch would retain authority and work that no
// caller can observe.
type objectWatchStreamSendError struct {
	err error
}

func (e *objectWatchStreamSendError) Error() string { return e.err.Error() }
func (e *objectWatchStreamSendError) Unwrap() error { return e.err }

func NewGRPCService(reader *Reader, metricsProviders ...DetailMetricsProvider) (*GRPCService, error) {
	if reader == nil {
		return nil, errors.New("object reader must not be nil")
	}
	if len(metricsProviders) > 1 {
		return nil, errors.New("at most one object detail metrics provider may be configured")
	}
	service := &GRPCService{
		reader: reader, scans: make(map[relationshipScanKey]context.CancelFunc),
		watchRetryDelay: objectWatchRetryDelay,
	}
	if len(metricsProviders) == 1 {
		service.metricsProvider = metricsProviders[0]
	}
	return service, nil
}

func (s *GRPCService) GetObject(
	ctx context.Context,
	request *kmgrv1.GetObjectRequest,
) (*kmgrv1.GetObjectResponse, error) {
	requestID, operationContext, cancel, err := objectRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	identity, err := identityFromProto(request.GetIdentity(), request.GetContext().GetClusterSessionId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, err.Error())
	}
	detail, err := s.reader.Detail(operationContext, identity, request.GetIncludeYaml(), request.GetIncludeSummary())
	if err != nil {
		return &kmgrv1.GetObjectResponse{
			RequestId: requestID, Identity: request.GetIdentity(),
			Error: structuredObjectError(
				err, request.GetIdentity(), "get-object", s.contextName(request.GetContext()),
			),
		}, nil
	}
	response := detailResponse(requestID, request.GetIdentity(), detail)
	if request.GetIncludeMetrics() && s.metricsProvider != nil {
		// Metrics are optional enrichment. Authentication, discovery, or
		// Metrics API failures must not turn a successful authoritative object
		// read into a failed detail page. Providers may still return safe
		// scheduler accounting when measured usage is unavailable.
		values, _ := s.metricsProvider.Metrics(operationContext, identity, detail.object)
		response.Metrics = values.Resources
		for _, container := range response.Containers {
			container.Metrics = values.ContainerResources[container.GetName()]
		}
	}
	return response, nil
}

func (s *GRPCService) WatchObject(
	request *kmgrv1.WatchObjectRequest,
	stream kmgrv1.ObjectService_WatchObjectServer,
) error {
	if request == nil || stream == nil || request.GetContext() == nil ||
		request.GetObjectStreamId() == "" || request.GetGeneration() == 0 {
		return status.Error(codes.InvalidArgument, "request context, object stream ID, and generation are required")
	}
	requestID, operationContext, cancel, err := objectRequestContext(stream.Context(), request.GetContext())
	if err != nil {
		return err
	}
	defer cancel()
	identity, err := identityFromProto(request.GetIdentity(), request.GetContext().GetClusterSessionId())
	if err != nil {
		return status.Error(codes.InvalidArgument, err.Error())
	}

	// Verify the UID before opening the watch. When the caller has no resource
	// version, anchor the watch at this authoritative GET so updates cannot fall
	// into a GET/WATCH gap.
	current, err := s.reader.Get(operationContext, identity)
	if err != nil {
		return s.sendObjectFailure(stream, request, 1, err, "watch-object")
	}
	resourceVersion := request.GetResourceVersion()
	if resourceVersion == "" {
		resourceVersion = current.GetResourceVersion()
	}
	var sequence uint64 = 1
	if err := stream.Send(&kmgrv1.ObjectEvent{
		Cursor: objectCursor(request, sequence),
		Type:   kmgrv1.ObjectEventType_OBJECT_EVENT_TYPE_STATUS,
		Object: &kmgrv1.GetObjectResponse{
			RequestId: requestID, Identity: request.GetIdentity(), ResourceVersion: resourceVersion,
		},
	}); err != nil {
		return err
	}
	retryAttempt := 0
	needsReanchor := false
	for {
		if needsReanchor {
			current, getErr := s.reader.Get(operationContext, identity)
			if getErr != nil {
				if !retryableObjectWatchError(getErr) {
					sequence++
					return s.sendObjectFailure(stream, request, sequence, getErr, "watch-object")
				}
				if err := waitForObjectWatchRetry(operationContext, s.watchRetryDelay(retryAttempt)); err != nil {
					return objectStatusError(err)
				}
				retryAttempt++
				continue
			}
			resourceVersion = current.GetResourceVersion()
			detail, detailErr := detailFromObject(current, identity, true, true)
			if detailErr != nil {
				sequence++
				return s.sendObjectFailure(stream, request, sequence, detailErr, "watch-object")
			}
			sequence++
			if err := stream.Send(&kmgrv1.ObjectEvent{
				Cursor: objectCursor(request, sequence), Type: kmgrv1.ObjectEventType_OBJECT_EVENT_TYPE_UPDATED,
				Object: detailResponse(requestID, request.GetIdentity(), detail),
			}); err != nil {
				return err
			}
			needsReanchor = false
			retryAttempt = 0
		}
		objectWatch, watchErr := s.reader.Watch(operationContext, identity, resourceVersion)
		if watchErr == nil && objectWatch == nil {
			watchErr = ErrObjectWatchClosed
		}
		if watchErr == nil {
			watchErr = func() error {
				defer objectWatch.Stop()
				for {
					select {
					case <-operationContext.Done():
						return operationContext.Err()
					case event, open := <-objectWatch.ResultChan():
						if !open {
							return ErrObjectWatchClosed
						}
						if event.Type == watch.Error {
							result := apierrors.FromObject(event.Object)
							if result == nil {
								result = errors.New("Kubernetes object watch failed")
							}
							return result
						}
						value, conversionErr := unstructuredObject(event.Object)
						if conversionErr != nil {
							return fmt.Errorf("%w: %v", ErrInvalidObjectWatchEvent, conversionErr)
						}
						if value.GetResourceVersion() != "" {
							resourceVersion = value.GetResourceVersion()
						}
						sequence++
						if event.Type == watch.Bookmark {
							if err := stream.Send(&kmgrv1.ObjectEvent{
								Cursor: objectCursor(request, sequence),
								Type:   kmgrv1.ObjectEventType_OBJECT_EVENT_TYPE_STATUS,
								Object: &kmgrv1.GetObjectResponse{
									RequestId: requestID, Identity: request.GetIdentity(),
									ResourceVersion: resourceVersion,
								},
							}); err != nil {
								return &objectWatchStreamSendError{err: err}
							}
							retryAttempt = 0
							continue
						}
						if event.Type != watch.Added && event.Type != watch.Modified && event.Type != watch.Deleted {
							return fmt.Errorf("%w: unsupported event type %q", ErrInvalidObjectWatchEvent, event.Type)
						}
						detail, detailErr := detailFromObject(value, identity, true, true)
						if detailErr != nil {
							var changed *IdentityChangedError
							if errors.As(detailErr, &changed) {
								return detailErr
							}
							return fmt.Errorf("%w: %v", ErrInvalidObjectWatchEvent, detailErr)
						}
						eventType := kmgrv1.ObjectEventType_OBJECT_EVENT_TYPE_UPDATED
						if event.Type == watch.Deleted {
							eventType = kmgrv1.ObjectEventType_OBJECT_EVENT_TYPE_DELETED
						}
						if err := stream.Send(&kmgrv1.ObjectEvent{
							Cursor: objectCursor(request, sequence), Type: eventType,
							Object: detailResponse(requestID, request.GetIdentity(), detail),
						}); err != nil {
							return &objectWatchStreamSendError{err: err}
						}
						retryAttempt = 0
					}
				}
			}()
		}
		var streamSendErr *objectWatchStreamSendError
		if errors.As(watchErr, &streamSendErr) {
			return streamSendErr.err
		}
		if operationContext.Err() != nil {
			return objectStatusError(operationContext.Err())
		}
		if apierrors.IsGone(watchErr) || apierrors.IsResourceExpired(watchErr) {
			needsReanchor = true
			continue
		} else if !retryableObjectWatchError(watchErr) {
			sequence++
			return s.sendObjectFailure(stream, request, sequence, watchErr, "watch-object")
		}
		if err := waitForObjectWatchRetry(operationContext, s.watchRetryDelay(retryAttempt)); err != nil {
			return objectStatusError(err)
		}
		retryAttempt++
	}
}

func objectWatchRetryDelay(attempt int) time.Duration {
	delay := 100 * time.Millisecond
	for range min(max(attempt, 0), 6) {
		delay *= 2
	}
	return min(delay, 5*time.Second)
}

func waitForObjectWatchRetry(ctx context.Context, delay time.Duration) error {
	if delay <= 0 {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
			return nil
		}
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func retryableObjectWatchError(err error) bool {
	if err == nil || errors.Is(err, ErrInvalidObjectWatchEvent) {
		return false
	}
	var changed *IdentityChangedError
	if errors.As(err, &changed) || errors.Is(err, ErrInvalidIdentity) ||
		errors.Is(err, ErrSessionNotFound) || apierrors.IsNotFound(err) ||
		apierrors.IsUnauthorized(err) || apierrors.IsForbidden(err) {
		return false
	}
	if errors.Is(err, ErrObjectWatchClosed) {
		return true
	}
	var apiStatus apierrors.APIStatus
	if errors.As(err, &apiStatus) {
		code := apiStatus.Status().Code
		return code == 0 || code == 408 || code == 429 || code >= 500
	}
	// Transport and decoding-layer watch failures often arrive without a
	// Kubernetes Status. Keep the last authoritative detail visible and retry;
	// malformed object events are wrapped above and fail closed instead.
	return true
}

func (s *GRPCService) GetRelationships(
	ctx context.Context,
	request *kmgrv1.GetRelationshipsRequest,
) (*kmgrv1.GetRelationshipsResponse, error) {
	requestID, operationContext, cancel, err := objectRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	identity, err := identityFromProto(request.GetIdentity(), request.GetContext().GetClusterSessionId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, err.Error())
	}
	values, childrenIncomplete, err := s.reader.Relationships(
		operationContext, identity, request.GetIncludeOwners(), request.GetIncludeChildren(),
	)
	response := &kmgrv1.GetRelationshipsResponse{
		RequestId: requestID, ChildrenPotentiallyIncomplete: childrenIncomplete,
	}
	if err != nil {
		response.Error = structuredObjectError(
			err, request.GetIdentity(), "get-relationships", s.contextName(request.GetContext()),
		)
		return response, nil
	}
	response.Relationships = make([]*kmgrv1.ResourceRelationship, 0, len(values))
	for _, value := range values {
		response.Relationships = append(response.Relationships, relationshipToProto(value))
	}
	return response, nil
}

func (s *GRPCService) ScanRelationships(
	request *kmgrv1.ScanRelationshipsRequest,
	stream kmgrv1.ObjectService_ScanRelationshipsServer,
) error {
	if request == nil || stream == nil || request.GetContext() == nil ||
		request.GetScanId() == "" || request.GetGeneration() == 0 {
		return status.Error(codes.InvalidArgument, "request context, scan ID, and generation are required")
	}
	_, operationContext, deadlineCancel, err := objectRequestContext(stream.Context(), request.GetContext())
	if err != nil {
		return err
	}
	defer deadlineCancel()
	identity, err := identityFromProto(request.GetIdentity(), request.GetContext().GetClusterSessionId())
	if err != nil {
		return status.Error(codes.InvalidArgument, err.Error())
	}
	contextName := s.contextName(request.GetContext())
	ctx, cancel := context.WithCancel(operationContext)
	key := relationshipScanKey{
		sessionID: request.GetContext().GetClusterSessionId(), scanID: request.GetScanId(),
		generation: request.GetGeneration(),
	}
	s.scanMu.Lock()
	for existing, existingCancel := range s.scans {
		if existing.sessionID != key.sessionID || existing.scanID != key.scanID {
			continue
		}
		switch {
		case existing.generation > key.generation:
			s.scanMu.Unlock()
			cancel()
			return status.Error(codes.FailedPrecondition, "relationship scan generation is stale")
		case existing.generation < key.generation:
			existingCancel()
			delete(s.scans, existing)
		}
	}
	if existing := s.scans[key]; existing != nil {
		s.scanMu.Unlock()
		cancel()
		return status.Error(codes.AlreadyExists, "relationship scan generation is already active")
	}
	s.scans[key] = cancel
	s.scanMu.Unlock()
	defer func() {
		cancel()
		s.scanMu.Lock()
		if current := s.scans[key]; current != nil {
			delete(s.scans, key)
		}
		s.scanMu.Unlock()
	}()

	sequence := uint64(0)
	err = s.reader.ScanRelationships(ctx, identity, func(update RelationshipScanUpdate) error {
		sequence++
		event := &kmgrv1.RelationshipScanEvent{
			Cursor: &kmgrv1.StreamCursor{
				StreamId: request.GetScanId(), Generation: request.GetGeneration(), Sequence: sequence,
			},
			Progress: relationshipScanProgressToProto(update.Progress),
		}
		for _, relationship := range update.Relationships {
			event.Relationships = append(event.Relationships, relationshipToProto(relationship))
		}
		if update.Warning != nil {
			event.Warning = structuredObjectError(
				update.Warning, request.GetIdentity(), "scan-relationships", contextName,
			)
		}
		return stream.Send(event)
	})
	if err == nil {
		return nil
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return objectStatusError(err)
	}
	sequence++
	if sendErr := stream.Send(&kmgrv1.RelationshipScanEvent{
		Cursor: &kmgrv1.StreamCursor{
			StreamId: request.GetScanId(), Generation: request.GetGeneration(), Sequence: sequence,
		},
		Error: structuredObjectError(
			err, request.GetIdentity(), "scan-relationships", contextName,
		),
	}); sendErr != nil {
		return sendErr
	}
	return nil
}

func (s *GRPCService) CancelRelationshipScan(
	ctx context.Context,
	request *kmgrv1.CancelRelationshipScanRequest,
) (*kmgrv1.Acknowledgement, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestID, operationContext, cancelContext, err := objectRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancelContext()
	if err := operationContext.Err(); err != nil {
		return nil, objectStatusError(err)
	}
	if request.GetScanId() == "" || request.GetGeneration() == 0 {
		return nil, status.Error(codes.InvalidArgument, "request, session, scan ID, and generation are required")
	}
	key := relationshipScanKey{
		sessionID: request.GetContext().GetClusterSessionId(), scanID: request.GetScanId(),
		generation: request.GetGeneration(),
	}
	s.scanMu.Lock()
	cancel := s.scans[key]
	if cancel != nil {
		delete(s.scans, key)
	}
	s.scanMu.Unlock()
	if cancel != nil {
		cancel()
	}
	return &kmgrv1.Acknowledgement{
		RequestId: requestID, Accepted: cancel != nil,
	}, nil
}

func (s *GRPCService) GetData(
	ctx context.Context,
	request *kmgrv1.GetDataRequest,
) (*kmgrv1.GetDataResponse, error) {
	requestID, operationContext, cancel, err := objectRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	identity, err := identityFromProto(request.GetIdentity(), request.GetContext().GetClusterSessionId())
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, err.Error())
	}
	data, err := s.reader.GetData(operationContext, identity)
	if err != nil {
		return &kmgrv1.GetDataResponse{
			RequestId: requestID, Identity: request.GetIdentity(),
			Error: structuredObjectError(
				err, request.GetIdentity(), "get-data", s.contextName(request.GetContext()),
			),
		}, nil
	}
	response := &kmgrv1.GetDataResponse{
		RequestId: requestID, Identity: request.GetIdentity(),
		ResourceVersion: data.ResourceVersion, Secret: data.Secret,
		Entries: make([]*kmgrv1.DataEntry, 0, len(data.Entries)),
	}
	for _, entry := range data.Entries {
		kind := kmgrv1.DataEntryKind_DATA_ENTRY_KIND_TEXT
		if entry.Kind == DataBinary {
			kind = kmgrv1.DataEntryKind_DATA_ENTRY_KIND_BINARY
		}
		response.Entries = append(response.Entries, &kmgrv1.DataEntry{
			Key: entry.Key, Kind: kind, Value: slices.Clone(entry.Value),
			ByteSize: uint64(len(entry.Value)), ContentHash: slices.Clone(entry.ContentHash[:]),
		})
	}
	return response, nil
}

func identityFromProto(value *kmgrv1.ResourceIdentity, sessionID string) (Identity, error) {
	if value == nil {
		return Identity{}, ErrInvalidIdentity
	}
	if value.GetClusterSessionId() != "" && value.GetClusterSessionId() != sessionID {
		return Identity{}, errors.New("resource identity belongs to another cluster session")
	}
	identity := Identity{
		SessionID: sessionID, Group: value.GetGroup(), Version: value.GetVersion(),
		Resource: value.GetResource(), Namespace: value.GetNamespace(), Name: value.GetName(), UID: value.GetUid(),
	}
	return identity, identity.Validate()
}

func objectRequestContext(
	ctx context.Context,
	request *kmgrv1.RequestContext,
) (string, context.Context, context.CancelFunc, error) {
	if request == nil || request.GetRequestId() == "" || request.GetClusterSessionId() == "" {
		return "", nil, nil, status.Error(codes.InvalidArgument, "request ID and cluster session ID are required")
	}
	if request.GetDeadlineUnixMs() == 0 {
		derived, cancel := context.WithCancel(ctx)
		return request.GetRequestId(), derived, cancel, nil
	}
	deadline := time.UnixMilli(request.GetDeadlineUnixMs())
	if !deadline.After(time.Now()) {
		return "", nil, nil, status.Error(codes.DeadlineExceeded, "request deadline exceeded")
	}
	derived, cancel := context.WithDeadline(ctx, deadline)
	return request.GetRequestId(), derived, cancel, nil
}

func stringEntries(values map[string]string) []*kmgrv1.StringMapEntry {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	result := make([]*kmgrv1.StringMapEntry, 0, len(keys))
	for _, key := range keys {
		result = append(result, &kmgrv1.StringMapEntry{Key: key, Value: values[key]})
	}
	return result
}

func detailResponse(requestID string, identity *kmgrv1.ResourceIdentity, detail Detail) *kmgrv1.GetObjectResponse {
	response := &kmgrv1.GetObjectResponse{
		RequestId: requestID, Identity: identity, ResourceVersion: detail.ResourceVersion,
		YamlUtf8: slices.Clone(detail.YAML), Labels: stringEntries(detail.Labels),
		Annotations: stringEntries(detail.Annotations),
	}
	for _, field := range detail.Summary {
		response.SummaryFields = append(response.SummaryFields, &kmgrv1.ObjectSummaryField{
			SectionId: field.Section, FieldId: field.ID, Label: field.Label,
			DisplayText: field.Value, Severity: kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL,
		})
	}
	for _, container := range detail.Containers {
		response.Containers = append(response.Containers, &kmgrv1.PodContainerDetail{
			Name: container.Name, Kind: containerKindToProto(container.Kind),
			Status: container.Status, StatusTooltip: container.StatusTooltip,
			StatusSeverity: containerStatusSeverityToProto(container.StatusSeverity),
			Ready:          container.Ready, RestartCount: container.RestartCount,
			Ports: slices.Clone(container.Ports),
		})
	}
	return response
}

func containerKindToProto(value ContainerKind) kmgrv1.PodContainerKind {
	switch value {
	case ContainerRegular:
		return kmgrv1.PodContainerKind_POD_CONTAINER_KIND_REGULAR
	case ContainerInit:
		return kmgrv1.PodContainerKind_POD_CONTAINER_KIND_INIT
	case ContainerEphemeral:
		return kmgrv1.PodContainerKind_POD_CONTAINER_KIND_EPHEMERAL
	default:
		return kmgrv1.PodContainerKind_POD_CONTAINER_KIND_UNSPECIFIED
	}
}

func containerStatusSeverityToProto(value ContainerStatusSeverity) kmgrv1.CellSeverity {
	switch value {
	case ContainerStatusWarning:
		return kmgrv1.CellSeverity_CELL_SEVERITY_WARNING
	case ContainerStatusCritical:
		return kmgrv1.CellSeverity_CELL_SEVERITY_ERROR
	case ContainerStatusMuted:
		return kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
	default:
		return kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL
	}
}

func identityToProto(identity Identity) *kmgrv1.ResourceIdentity {
	return &kmgrv1.ResourceIdentity{
		ClusterSessionId: identity.SessionID, Group: identity.Group, Version: identity.Version,
		Resource: identity.Resource, Namespace: identity.Namespace, Name: identity.Name, Uid: identity.UID,
	}
}

func relationshipToProto(value Relationship) *kmgrv1.ResourceRelationship {
	kind := kmgrv1.RelationshipKind_RELATIONSHIP_KIND_RELATED
	switch value.Kind {
	case RelationshipOwner:
		kind = kmgrv1.RelationshipKind_RELATIONSHIP_KIND_OWNER
	case RelationshipChild:
		kind = kmgrv1.RelationshipKind_RELATIONSHIP_KIND_CHILD
	}
	return &kmgrv1.ResourceRelationship{
		Kind: kind, Identity: identityToProto(value.Identity), Label: value.Label,
		Stale: value.Stale, PotentiallyIncomplete: value.PotentiallyIncomplete,
	}
}

func relationshipScanProgressToProto(value RelationshipScanProgress) *kmgrv1.RelationshipScanProgress {
	result := &kmgrv1.RelationshipScanProgress{
		ResourcesTotal: uint32(value.ResourcesTotal), ResourcesScanned: uint32(value.ResourcesScanned),
		ObjectsExamined: value.ObjectsExamined, ResourcesFailed: uint32(value.ResourcesFailed),
		Complete: value.Complete, PotentiallyIncomplete: value.PotentiallyIncomplete,
	}
	if value.Current.Resource != "" {
		result.CurrentResource = &kmgrv1.ResourceType{
			Group: value.Current.Group, Version: value.Current.Version,
			Resource: value.Current.Resource, Kind: value.Current.Kind,
			Namespaced: value.Current.Namespaced,
		}
	}
	return result
}

func objectCursor(request *kmgrv1.WatchObjectRequest, sequence uint64) *kmgrv1.StreamCursor {
	return &kmgrv1.StreamCursor{
		StreamId: request.GetObjectStreamId(), Generation: request.GetGeneration(), Sequence: sequence,
	}
}

func (s *GRPCService) sendObjectFailure(
	stream kmgrv1.ObjectService_WatchObjectServer,
	request *kmgrv1.WatchObjectRequest,
	sequence uint64,
	err error,
	operation string,
) error {
	return stream.Send(&kmgrv1.ObjectEvent{
		Cursor: objectCursor(request, sequence), Type: kmgrv1.ObjectEventType_OBJECT_EVENT_TYPE_STATUS,
		Error: structuredObjectError(
			err, request.GetIdentity(), operation, s.contextName(request.GetContext()),
		),
	})
}

func (s *GRPCService) contextName(request *kmgrv1.RequestContext) string {
	if s == nil || s.reader == nil || request == nil {
		return ""
	}
	value, _ := s.reader.ContextName(request.GetClusterSessionId())
	return value
}

func unstructuredObject(value runtime.Object) (*unstructured.Unstructured, error) {
	if current, ok := value.(*unstructured.Unstructured); ok {
		return current, nil
	}
	if value == nil {
		return nil, errors.New("Kubernetes watch event has no object")
	}
	converted, err := runtime.DefaultUnstructuredConverter.ToUnstructured(value)
	if err != nil {
		return nil, fmt.Errorf("decode Kubernetes watch object: %w", err)
	}
	return &unstructured.Unstructured{Object: converted}, nil
}

func objectStatusError(err error) error {
	switch {
	case errors.Is(err, context.Canceled):
		return status.Error(codes.Canceled, "object watch cancelled")
	case errors.Is(err, context.DeadlineExceeded):
		return status.Error(codes.DeadlineExceeded, "object watch deadline exceeded")
	default:
		return err
	}
}

func structuredObjectError(
	err error,
	identity *kmgrv1.ResourceIdentity,
	operation, contextName string,
) *kmgrv1.StructuredError {
	result := &kmgrv1.StructuredError{
		Category: kmgrv1.ErrorCategory_ERROR_CATEGORY_INTERNAL,
		Reason:   "ObjectRequestFailed", Message: "The Kubernetes object request failed.",
		ContextName: contextName, Operation: operation, Resource: identity,
	}
	kubeerrors.Enrich(result, err)
	var changed *IdentityChangedError
	var apiStatus apierrors.APIStatus
	switch {
	case errors.As(err, &changed):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT
		result.Reason = "ObjectRecreated"
		result.Message = changed.Error()
		result.SafeDetails = map[string]string{"expected_uid": changed.ExpectedUID, "current_uid": changed.ActualUID}
	case errors.Is(err, ErrInvalidIdentity):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION
		result.Reason = "InvalidIdentity"
		result.Message = "The Kubernetes resource identity is incomplete."
	case errors.Is(err, ErrUnsupportedDataObject):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_UNSUPPORTED
		result.Reason = "DataEditorUnsupported"
		result.Message = "Key/value data editing is available only for ConfigMaps and Secrets."
	case errors.Is(err, ErrRelationshipResolutionUnavailable):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE
		result.Reason = "RelationshipResolutionUnavailable"
		result.Message = "Kubernetes API relationship mapping is unavailable."
		result.Retryable = true
	case errors.Is(err, ErrRelationshipScanLimit):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_RESOURCE_EXHAUSTED
		result.Reason = "RelationshipScanLimitReached"
		result.Message = err.Error()
	case errors.Is(err, ErrObjectWatchClosed):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE
		result.Reason = "ObjectWatchClosed"
		result.Message = "The Kubernetes object watch closed and can be reopened."
		result.Retryable = true
	case errors.Is(err, ErrSessionNotFound):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND
		result.Reason = "SessionNotFound"
		result.Message = "The cluster session is no longer open."
	case errors.Is(err, context.Canceled):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_CANCELLED
		result.Reason = "RequestCancelled"
		result.Message = "The object request was cancelled."
	case errors.Is(err, context.DeadlineExceeded):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_TIMEOUT
		result.Reason = "RequestTimedOut"
		result.Message = "The object request timed out."
		result.Retryable = true
	case apierrors.IsNotFound(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND
		result.Reason = "NotFound"
		result.Message = "The Kubernetes object no longer exists."
	case apierrors.IsUnauthorized(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHENTICATION
		result.Reason = "AuthenticationRejected"
		result.Message = "The Kubernetes API server rejected the configured credentials."
	case apierrors.IsForbidden(err):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHORIZATION
		result.Reason = "Forbidden"
		result.Message = "The configured identity is not authorized for this object request."
	case errors.As(err, &apiStatus):
		value := apiStatus.Status()
		result.HttpStatusCode = value.Code
		result.Reason = string(value.Reason)
		result.Retryable = value.Code == 408 || value.Code == 429 || value.Code >= 500
	}
	return result
}
