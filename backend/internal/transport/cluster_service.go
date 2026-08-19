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

const DefaultConnectionProbeTimeout = 8 * time.Second

const connectionActivityCoalesceDelay = 100 * time.Millisecond

// SessionProber makes the explicit connection action independently testable.
// Implementations must honor the supplied context.
type SessionProber interface {
	Probe(context.Context, *cluster.Session) error
}

type SessionProbeFunc func(context.Context, *cluster.Session) error

func (f SessionProbeFunc) Probe(ctx context.Context, session *cluster.Session) error {
	return f(ctx, session)
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
	streamGeneration atomic.Uint64
}

type ClusterServiceOptions struct {
	Catalogs     *CatalogRegistry
	Sessions     *cluster.SessionRegistry
	Prober       SessionProber
	ProbeTimeout time.Duration
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
	updates, unsubscribe := activity.Subscribe()
	defer unsubscribe()
	generation := s.streamGeneration.Add(1)
	sequence := uint64(0)
	lastSent := cluster.APIActivitySnapshot{}
	send := func(force bool) error {
		totals := activity.Snapshot()
		if !force && totals == lastSent {
			return nil
		}
		sequence++
		connectionState, connectionError := connectionEventState(
			totals.ConnectionHealth, session.Context().Name,
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
			Error:              connectionError,
		}); err != nil {
			return err
		}
		lastSent = totals
		return nil
	}
	if err := send(true); err != nil {
		return err
	}
	var timer *time.Timer
	var timerChannel <-chan time.Time
	for {
		select {
		case <-requestContext.Done():
			if timer != nil {
				timer.Stop()
			}
			return contextStatus(requestContext.Err())
		case <-updates:
			if timerChannel == nil {
				timer = time.NewTimer(connectionActivityCoalesceDelay)
				timerChannel = timer.C
			}
		case <-timerChannel:
			timerChannel = nil
			timer = nil
			if err := send(false); err != nil {
				return err
			}
		}
	}
}

func warmCacheUsageProto(usage cluster.WarmCacheUsage) *kmgrv1.WarmCacheUsage {
	return &kmgrv1.WarmCacheUsage{
		RetainedViews:   usage.RetainedViews,
		RetainedObjects: usage.RetainedObjects,
		RetainedBytes:   usage.RetainedBytes,
		ViewLimit:       usage.ViewLimit,
		ObjectLimit:     usage.ObjectLimit,
		ByteLimit:       usage.ByteLimit,
		BudgetEvictions: usage.BudgetEvictions,
	}
}

func connectionEventState(
	health cluster.APIConnectionHealth,
	contextName string,
) (kmgrv1.ConnectionState, *kmgrv1.StructuredError) {
	switch health {
	case cluster.APIConnectionReconnecting:
		return kmgrv1.ConnectionState_CONNECTION_STATE_RECONNECTING, &kmgrv1.StructuredError{
			Category:    kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE,
			Reason:      "APITransportInterrupted",
			Message:     "The Kubernetes API transport was interrupted and may reconnect.",
			Retryable:   true,
			ContextName: contextName,
			Operation:   "watch-connection",
		}
	case cluster.APIConnectionAuthenticationFailed:
		return kmgrv1.ConnectionState_CONNECTION_STATE_FAILED, &kmgrv1.StructuredError{
			Category:    kmgrv1.ErrorCategory_ERROR_CATEGORY_AUTHENTICATION,
			Reason:      "AuthenticationRejected",
			Message:     "The Kubernetes API server rejected the configured credentials.",
			ContextName: contextName,
			Operation:   "watch-connection",
		}
	default:
		// OpenSession performs an authenticated probe before this stream can
		// start. A zero health value therefore means no post-probe request has
		// completed yet, not that the session is unauthenticated.
		return kmgrv1.ConnectionState_CONNECTION_STATE_CONNECTED, nil
	}
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

	catalog, err := s.catalogs.Load(request.GetKubeconfigPaths(), request.GetReload())
	if err != nil {
		response.Error = kubeconfigError(err, "list-contexts")
		return response, nil
	}
	if err := requestContext.Err(); err != nil {
		return nil, contextStatus(err)
	}

	contexts := catalog.Contexts()
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

	catalog, err := s.catalogs.Load(request.GetKubeconfigPaths(), false)
	if err != nil {
		response.Error = kubeconfigError(err, "open-session")
		return response, nil
	}
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
