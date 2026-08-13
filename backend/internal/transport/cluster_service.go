package transport

import (
	"context"
	"errors"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const DefaultConnectionProbeTimeout = 8 * time.Second

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

	catalogs     *CatalogRegistry
	sessions     *cluster.SessionRegistry
	prober       SessionProber
	probeTimeout time.Duration
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
		return nil, status.Error(codes.InvalidArgument, "context name is required")
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
	if request.GetRefresh() {
		if mapper, ok := session.Mapper().(interface{ Reset() }); ok {
			mapper.Reset()
		}
	}
	resources, revision, err := cluster.DiscoverResources(requestContext, session)
	if err != nil {
		response.Error = connectionError(err, session.Context().Name, session.Context().ServerHostname)
		response.Error.Operation = "discover-resources"
		return response, nil
	}
	response.DiscoveryRevision = revision
	response.Resources = make([]*kmgrv1.ApiResource, 0, len(resources))
	for _, resource := range resources {
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
	namespaces, err := cluster.ListNamespaces(requestContext, session)
	if err != nil {
		response.Error = connectionError(err, session.Context().Name, session.Context().ServerHostname)
		response.Error.Operation = "list-namespaces"
		return response, nil
	}
	response.Namespaces = namespaces
	return response, nil
}

func (s *ClusterService) Catalogs() *CatalogRegistry         { return s.catalogs }
func (s *ClusterService) Sessions() *cluster.SessionRegistry { return s.sessions }
