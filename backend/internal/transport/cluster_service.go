package transport

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync/atomic"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/kubeerrors"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const (
	DefaultConnectionProbeTimeout = 10 * time.Second
	MaximumConnectionProbeTimeout = 10 * time.Minute
)

const connectionActivitySampleInterval = 500 * time.Millisecond
const operationActivitySampleInterval = 500 * time.Millisecond

// SessionProber makes the explicit connection action independently testable.
// Implementations must honor the supplied context.
type SessionProber interface {
	Probe(context.Context, *cluster.Session) error
}

type versionProber struct{}

func (versionProber) Probe(ctx context.Context, session *cluster.Session) error {
	if session == nil || session.Discovery() == nil {
		return errors.New("Kubernetes discovery client is unavailable")
	}
	restClient := session.Discovery().RESTClient()
	if restClient == nil {
		return errors.New("Kubernetes discovery REST client is unavailable")
	}
	return restClient.Get().AbsPath("/version").Do(ctx).Error()
}

type ClusterService struct {
	kmgrv1.UnimplementedClusterServiceServer

	catalogs         *CatalogRegistry
	sessions         *cluster.SessionRegistry
	prober           SessionProber
	probeTimeout     time.Duration
	stopping         <-chan struct{}
	streamGeneration atomic.Uint64
}

type ClusterServiceOptions struct {
	Catalogs     *CatalogRegistry
	Sessions     *cluster.SessionRegistry
	Prober       SessionProber
	ProbeTimeout time.Duration
	Stopping     <-chan struct{}
}

func NewClusterService(options ClusterServiceOptions) *ClusterService {
	if options.Catalogs == nil {
		options.Catalogs = NewCatalogRegistry(nil)
	}
	if options.Sessions == nil {
		options.Sessions = cluster.NewSessionRegistry(nil)
	}
	if options.Prober == nil {
		options.Prober = versionProber{}
	}
	if options.ProbeTimeout <= 0 {
		options.ProbeTimeout = DefaultConnectionProbeTimeout
	}
	return &ClusterService{
		catalogs:     options.Catalogs,
		sessions:     options.Sessions,
		prober:       options.Prober,
		probeTimeout: options.ProbeTimeout,
		stopping:     options.Stopping,
	}
}

func (s *ClusterService) WatchConnection(
	request *kmgrv1.WatchConnectionRequest,
	stream grpc.ServerStreamingServer[kmgrv1.ConnectionEvent],
) error {
	if request == nil {
		return status.Error(codes.InvalidArgument, "request is required")
	}
	requestContext, cancel, err := validateRequestContext(stream.Context(), request.GetContext(), true)
	if err != nil {
		return err
	}
	defer cancel()
	if request.GetStreamId() == "" {
		return status.Error(codes.InvalidArgument, "stream ID is required")
	}
	session, lease, ok := s.sessions.Acquire(request.GetContext().GetClusterSessionId())
	if !ok {
		return status.Error(codes.NotFound, "cluster session was not found")
	}
	defer lease.Release()
	activity := session.APIActivity()
	generation := s.streamGeneration.Add(1)
	sequence := uint64(0)
	send := func() error {
		totals := activity.Snapshot()
		sequence++
		connectionState, connectionErrorMessage := connectionEventState(
			totals.ConnectionHealth, totals.ConnectionError,
		)
		if err := stream.Send(&kmgrv1.ConnectionEvent{
			Cursor: &kmgrv1.StreamCursor{
				StreamId: request.GetStreamId(), Generation: generation, Sequence: sequence,
			},
			State:              connectionState,
			ObservedAtUnixMs:   time.Now().UnixMilli(),
			ApiBytesReceived:   totals.BytesReceived,
			ApiBytesSent:       totals.BytesSent,
			AuthorityWarmCache: warmCacheUsageProto(totals.AuthorityWarmCache),
			GlobalWarmCache:    warmCacheUsageProto(totals.GlobalWarmCache),
			ErrorMessage:       connectionErrorMessage,
		}); err != nil {
			return err
		}
		return nil
	}
	if err := send(); err != nil {
		return err
	}
	ticker := time.NewTicker(connectionActivitySampleInterval)
	defer ticker.Stop()
	for {
		select {
		case <-requestContext.Done():
			return contextStatus(requestContext.Err())
		case <-s.stopping:
			return nil
		case <-ticker.C:
			if err := send(); err != nil {
				return err
			}
		}
	}
}

func (s *ClusterService) WatchOperations(
	request *kmgrv1.WatchOperationsRequest,
	stream grpc.ServerStreamingServer[kmgrv1.ClusterOperationBatch],
) error {
	if request == nil {
		return status.Error(codes.InvalidArgument, "request is required")
	}
	requestContext, cancel, err := validateRequestContext(stream.Context(), request.GetContext(), true)
	if err != nil {
		return err
	}
	defer cancel()
	if request.GetStreamId() == "" {
		return status.Error(codes.InvalidArgument, "stream ID is required")
	}
	session, lease, ok := s.sessions.Acquire(request.GetContext().GetClusterSessionId())
	if !ok {
		return status.Error(codes.NotFound, "cluster session was not found")
	}
	defer lease.Release()
	activity := session.APIActivity()
	generation := s.streamGeneration.Add(1)
	sequence := uint64(0)
	completionCursor := uint64(0)
	send := func(force bool) error {
		snapshot := activity.OperationActivitySnapshot(completionCursor)
		if !force && len(snapshot.Active) == 0 && len(snapshot.Completed) == 0 {
			return nil
		}
		active := make([]*kmgrv1.KubernetesAPIOperation, 0, len(snapshot.Active))
		for _, operation := range snapshot.Active {
			active = append(active, apiOperationProto(operation))
		}
		completed := make([]*kmgrv1.KubernetesAPIOperation, 0, len(snapshot.Completed))
		for _, operation := range snapshot.Completed {
			completed = append(completed, apiOperationProto(operation))
		}
		sequence++
		if err := stream.Send(&kmgrv1.ClusterOperationBatch{
			Cursor: &kmgrv1.StreamCursor{
				StreamId: request.GetStreamId(), Generation: generation, Sequence: sequence,
			},
			Active:           active,
			Completed:        completed,
			DroppedCompleted: snapshot.DroppedCompleted,
		}); err != nil {
			return err
		}
		completionCursor = snapshot.CompletionCursor
		return nil
	}
	if err := send(true); err != nil {
		return err
	}
	ticker := time.NewTicker(operationActivitySampleInterval)
	defer ticker.Stop()
	for {
		select {
		case <-requestContext.Done():
			return contextStatus(requestContext.Err())
		case <-s.stopping:
			return nil
		case <-ticker.C:
			if err := send(false); err != nil {
				return err
			}
		}
	}
}

func apiOperationProto(operation cluster.APIOperationSnapshot) *kmgrv1.KubernetesAPIOperation {
	result := &kmgrv1.KubernetesAPIOperation{
		Id:                  operation.ID,
		State:               apiOperationStateProto(operation.State),
		Operation:           operation.Operation,
		Group:               operation.Group,
		Version:             operation.Version,
		Resource:            operation.Resource,
		Namespace:           operation.Namespace,
		Name:                operation.Name,
		Subresource:         operation.Subresource,
		HttpStatusCode:      operation.HTTPStatusCode,
		BytesReceived:       operation.BytesReceived,
		BytesSent:           operation.BytesSent,
		StartedAtUnixNanos:  operation.StartedAtUnixNanos,
		FinishedAtUnixNanos: operation.FinishedAtUnixNanos,
	}
	result.ErrorMessage = operation.ErrorMessage
	return result
}

func apiOperationStateProto(
	state cluster.APIOperationState,
) kmgrv1.KubernetesAPIOperationState {
	switch state {
	case cluster.APIOperationStateActive:
		return kmgrv1.KubernetesAPIOperationState_KUBERNETES_API_OPERATION_STATE_ACTIVE
	case cluster.APIOperationStateFinished:
		return kmgrv1.KubernetesAPIOperationState_KUBERNETES_API_OPERATION_STATE_FINISHED
	case cluster.APIOperationStateFailed:
		return kmgrv1.KubernetesAPIOperationState_KUBERNETES_API_OPERATION_STATE_FAILED
	case cluster.APIOperationStateCancelled:
		return kmgrv1.KubernetesAPIOperationState_KUBERNETES_API_OPERATION_STATE_CANCELLED
	case cluster.APIOperationStateTimedOut:
		return kmgrv1.KubernetesAPIOperationState_KUBERNETES_API_OPERATION_STATE_TIMED_OUT
	default:
		return kmgrv1.KubernetesAPIOperationState_KUBERNETES_API_OPERATION_STATE_UNSPECIFIED
	}
}

func warmCacheUsageProto(usage cluster.WarmCacheUsage) *kmgrv1.WarmCacheUsage {
	return &kmgrv1.WarmCacheUsage{
		RetainedViews:    usage.RetainedViews,
		RetainedObjects:  usage.RetainedObjects,
		RetainedBytes:    usage.RetainedBytes,
		EvictableViews:   usage.EvictableViews,
		EvictableObjects: usage.EvictableObjects,
		EvictableBytes:   usage.EvictableBytes,
		ViewLimit:        usage.ViewLimit,
		ObjectLimit:      usage.ObjectLimit,
		ByteLimit:        usage.ByteLimit,
		BudgetEvictions:  usage.BudgetEvictions,
	}
}

func connectionEventState(
	health cluster.APIConnectionHealth,
	errorMessage string,
) (kmgrv1.ConnectionState, string) {
	switch health {
	case cluster.APIConnectionReconnecting:
		return kmgrv1.ConnectionState_CONNECTION_STATE_RECONNECTING,
			fallbackAPIErrorMessage(errorMessage)
	case cluster.APIConnectionAuthenticationFailed:
		return kmgrv1.ConnectionState_CONNECTION_STATE_FAILED,
			fallbackAPIErrorMessage(errorMessage)
	default:
		// OpenSession performs an authenticated probe before this stream can
		// start. A zero health value therefore means no post-probe request has
		// completed yet, not that the session is unauthenticated.
		return kmgrv1.ConnectionState_CONNECTION_STATE_CONNECTED, ""
	}
}

func fallbackAPIErrorMessage(message string) string {
	if message != "" {
		return message
	}
	return "Kubernetes API request failed"
}

func (s *ClusterService) ListContexts(
	ctx context.Context,
	request *kmgrv1.ListContextsRequest,
) (*kmgrv1.ListContextsResponse, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestContext, cancel, err := validateRequestContext(ctx, request.GetContext(), false)
	if err != nil {
		return nil, err
	}
	defer cancel()
	response := &kmgrv1.ListContextsResponse{RequestId: request.GetContext().GetRequestId()}

	discovery, err := s.catalogs.Load(
		request.GetAddedKubeconfigPaths(),
		request.GetReload(),
	)
	if err != nil {
		response.Error = kubeconfigError(err, "list-contexts")
		return response, nil
	}
	if err := requestContext.Err(); err != nil {
		return nil, contextStatus(err)
	}

	contexts := discovery.Catalog.Contexts()
	response.Contexts = make([]*kmgrv1.KubeconfigContext, 0, len(contexts))
	for _, info := range contexts {
		supported := len(info.UnsupportedAuthentications) == 0
		entry := &kmgrv1.KubeconfigContext{
			ContextId:               info.ID,
			Name:                    info.Name,
			ClusterName:             info.ClusterName,
			ServerHostname:          info.ServerHostname,
			DefaultNamespace:        info.DefaultNamespace,
			SourcePaths:             append([]string(nil), info.SourcePaths...),
			Current:                 info.Current,
			AuthenticationHint:      info.AuthenticationHint,
			AuthenticationSupported: supported,
		}
		if !supported {
			entry.UnsupportedAuthenticationError = unsupportedAuthenticationError(info)
		}
		response.Contexts = append(response.Contexts, entry)
	}
	response.AddedKubeconfigSources = make(
		[]*kmgrv1.AddedKubeconfigSource,
		0,
		len(discovery.AddedSources),
	)
	for _, source := range discovery.AddedSources {
		entry := &kmgrv1.AddedKubeconfigSource{
			Path:         source.Path,
			ContextCount: uint32(source.ContextCount),
		}
		if source.Err != nil {
			entry.Error = addedKubeconfigSourceError(source.Err)
		}
		response.AddedKubeconfigSources = append(response.AddedKubeconfigSources, entry)
	}
	return response, nil
}

func (s *ClusterService) OpenSession(
	ctx context.Context,
	request *kmgrv1.OpenSessionRequest,
) (*kmgrv1.OpenSessionResponse, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestContext, cancel, err := validateRequestContext(ctx, request.GetContext(), false)
	if err != nil {
		return nil, err
	}
	defer cancel()
	response := &kmgrv1.OpenSessionResponse{RequestId: request.GetContext().GetRequestId()}
	if request.GetContextName() == "" {
		return nil, status.Error(codes.InvalidArgument, "context reference is required")
	}

	discovery, err := s.catalogs.Load(request.GetAddedKubeconfigPaths(), false)
	if err != nil {
		response.Error = kubeconfigError(err, "open-session")
		return response, nil
	}
	catalog := discovery.Catalog
	info, ok := catalog.Context(request.GetContextName())
	if !ok {
		response.Error = kubeconfigError(
			&cluster.ContextNotFoundError{Reference: request.GetContextName()},
			"open-session",
		)
		return response, nil
	}

	session, err := s.sessions.Open(catalog, request.GetContextName())
	if err != nil {
		response.Error = kubeconfigError(err, "open-session")
		response.Error.ContextName = info.Name
		return response, nil
	}
	accepted := false
	defer func() {
		if !accepted {
			s.sessions.Close(session.ID())
		}
	}()

	probeContext, probeCancel := context.WithTimeout(requestContext, s.probeTimeout)
	err = s.prober.Probe(probeContext, session)
	probeCancel()
	if err != nil {
		response.Error = connectionError(err, info.Name, info.ServerHostname)
		return response, nil
	}
	if err := requestContext.Err(); err != nil {
		return nil, contextStatus(err)
	}

	accepted = true
	response.ClusterSessionId = session.ID()
	response.ContextName = info.Name
	response.ClusterName = info.ClusterName
	response.ServerHostname = info.ServerHostname
	response.DefaultNamespace = info.DefaultNamespace
	return response, nil
}

func (s *ClusterService) CloseSession(
	ctx context.Context,
	request *kmgrv1.CloseSessionRequest,
) (*kmgrv1.Acknowledgement, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestContext, cancel, err := validateRequestContext(ctx, request.GetContext(), true)
	if err != nil {
		return nil, err
	}
	defer cancel()
	if err := requestContext.Err(); err != nil {
		return nil, contextStatus(err)
	}
	sessionID := request.GetContext().GetClusterSessionId()
	closed := false
	if request.GetKeepIndependentStreams() {
		closed = s.sessions.CloseWorkspace(sessionID)
	} else {
		closed = s.sessions.Close(sessionID)
	}
	if !closed {
		return nil, status.Error(codes.NotFound, "cluster session was not found")
	}
	return &kmgrv1.Acknowledgement{
		RequestId: request.GetContext().GetRequestId(),
		Accepted:  true,
	}, nil
}

func (s *ClusterService) Discover(
	ctx context.Context,
	request *kmgrv1.DiscoverRequest,
) (*kmgrv1.DiscoverResponse, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestContext, cancel, err := validateRequestContext(ctx, request.GetContext(), true)
	if err != nil {
		return nil, err
	}
	defer cancel()
	response := &kmgrv1.DiscoverResponse{RequestId: request.GetContext().GetRequestId()}
	session, ok := s.sessions.Get(request.GetContext().GetClusterSessionId())
	if !ok {
		return nil, status.Error(codes.NotFound, "cluster session was not found")
	}
	discoveryResult, err := session.DiscoverResourcesCached(requestContext, request.GetRefresh())
	if err != nil {
		response.Error = connectionError(err, session.Context().Name, session.Context().ServerHostname)
		response.Error.Operation = "discover-resources"
		return response, nil
	}
	response.DiscoveryRevision = discoveryResult.Revision
	response.PotentiallyIncomplete = discoveryResult.PotentiallyIncomplete
	if discoveryResult.PotentiallyIncomplete {
		response.Warning = discoveryWarning(discoveryResult.Failures, session.Context().Name)
	}
	response.Resources = make([]*kmgrv1.ApiResource, 0, len(discoveryResult.Resources))
	for _, resource := range discoveryResult.Resources {
		response.Resources = append(response.Resources, &kmgrv1.ApiResource{
			Type: &kmgrv1.ResourceType{
				Group:      resource.Group,
				Version:    resource.Version,
				Resource:   resource.Resource,
				Kind:       resource.Kind,
				Namespaced: resource.Namespaced,
			},
			Verbs:            append([]string(nil), resource.Verbs...),
			ShortNames:       append([]string(nil), resource.ShortNames...),
			Categories:       append([]string(nil), resource.Categories...),
			PreferredVersion: resource.PreferredVersion,
		})
	}
	return response, nil
}

func discoveryWarning(failures []cluster.DiscoveryFailure, contextName string) *kmgrv1.StructuredError {
	result := &kmgrv1.StructuredError{
		Category:    kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE,
		Reason:      "DiscoveryPartiallyFailed",
		Message:     "Some Kubernetes API groups could not be discovered. The available resource list may be incomplete.",
		Retryable:   true,
		ContextName: contextName,
		Operation:   "discover-resources",
	}
	targets := make([]string, 0, len(failures))
	for _, failure := range failures {
		if failure.Target != "" {
			targets = append(targets, failure.Target)
		}
		// Preserve only Kubernetes status structure. kubeerrors.Enrich never
		// copies Status.Message, cause messages, raw bodies, or headers.
		kubeerrors.Enrich(result, failure.Err)
	}
	// The status reason describes one failed endpoint; the warning itself has
	// stable semantics even when several endpoints failed differently.
	result.Reason = "DiscoveryPartiallyFailed"
	sort.Strings(targets)
	targets = slicesCompact(targets)
	result.SafeDetails = map[string]string{
		"failed_group_version_count": fmt.Sprintf("%d", len(failures)),
	}
	if len(targets) != 0 {
		result.SafeDetails["failed_group_versions"] = strings.Join(targets, ",")
	}
	return result
}

func slicesCompact(values []string) []string {
	if len(values) < 2 {
		return values
	}
	result := values[:1]
	for _, value := range values[1:] {
		if value != result[len(result)-1] {
			result = append(result, value)
		}
	}
	return result
}

func (s *ClusterService) ListNamespaces(
	ctx context.Context,
	request *kmgrv1.ListNamespacesRequest,
) (*kmgrv1.ListNamespacesResponse, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestContext, cancel, err := validateRequestContext(ctx, request.GetContext(), true)
	if err != nil {
		return nil, err
	}
	defer cancel()
	response := &kmgrv1.ListNamespacesResponse{RequestId: request.GetContext().GetRequestId()}
	session, ok := s.sessions.Get(request.GetContext().GetClusterSessionId())
	if !ok {
		return nil, status.Error(codes.NotFound, "cluster session was not found")
	}
	namespaces, err := session.ListNamespacesCached(requestContext)
	if err != nil {
		response.Error = connectionError(err, session.Context().Name, session.Context().ServerHostname)
		response.Error.Operation = "list-namespaces"
		return response, nil
	}
	response.Namespaces = namespaces
	return response, nil
}
