package transport

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"sync"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	appconfig "github.com/charlie0129/kmgr/backend/internal/config"
	"github.com/charlie0129/kmgr/backend/internal/object"
	"github.com/charlie0129/kmgr/backend/internal/operation"
	"github.com/charlie0129/kmgr/backend/internal/portforward"
	execstream "github.com/charlie0129/kmgr/backend/internal/stream/exec"
	streamlogs "github.com/charlie0129/kmgr/backend/internal/stream/logs"
	"github.com/charlie0129/kmgr/backend/internal/view"
	viewcolumns "github.com/charlie0129/kmgr/backend/internal/view/columns"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
)

const DefaultGracefulStopTimeout = 5 * time.Second

type ServerOptions struct {
	Version                string
	Logger                 *slog.Logger
	CatalogLoader          CatalogLoader
	ClientFactory          cluster.ClientFactory
	SessionProber          SessionProber
	ProbeTimeout           time.Duration
	ColumnsPath            string
	MetricsRefreshInterval time.Duration
	KubernetesQPS          float32
	KubernetesBurst        int
	GRPCOptions            []grpc.ServerOption
}

// Server wires authentication, safe RPC logging, engine lifecycle, catalogs,
// and cluster sessions. Additional protocol services may be registered through
// GRPC before Serve starts.
type Server struct {
	grpc       *grpc.Server
	engine     *EngineService
	cluster    *ClusterService
	catalogs   *CatalogRegistry
	sessions   *cluster.SessionRegistry
	views      *view.Runtime
	operations *operation.Manager
	logs       *streamlogs.Manager
	exec       *execstream.Manager
	forwards   *portforward.Manager
	logger     *slog.Logger
	closeOnce  sync.Once
}

func NewServer(launchToken string, options ServerOptions) (*Server, error) {
	authenticator, err := NewTokenAuthenticator(launchToken)
	if err != nil {
		return nil, err
	}
	engine, err := NewEngineService(options.Version, time.Now())
	if err != nil {
		return nil, err
	}
	catalogs := NewCatalogRegistry(options.CatalogLoader)
	sessions := cluster.NewSessionRegistry(options.ClientFactory)
	if options.KubernetesQPS != 0 || options.KubernetesBurst != 0 {
		if err := sessions.SetRateLimit(options.KubernetesQPS, options.KubernetesBurst); err != nil {
			return nil, fmt.Errorf("configure Kubernetes client rate limit: %w", err)
		}
	}
	clusterService := NewClusterService(ClusterServiceOptions{
		Catalogs:     catalogs,
		Sessions:     sessions,
		Prober:       options.SessionProber,
		ProbeTimeout: options.ProbeTimeout,
	})
	columnsCompiler, err := viewcolumns.NewCompiler(viewcolumns.DefaultCostLimit)
	if err != nil {
		return nil, err
	}
	columnsPath := options.ColumnsPath
	if columnsPath == "" {
		columnsPath, err = appconfig.DefaultColumnsPath()
		if err != nil {
			return nil, err
		}
	}
	columnManager, err := appconfig.NewColumnManager(columnsPath, columnsCompiler)
	if err != nil {
		return nil, fmt.Errorf("load columns configuration: %w", err)
	}
	viewRuntime, err := view.NewRuntime(view.RuntimeConfig{
		Source: view.ClusterResourceSource{Sessions: sessions},
		Metrics: &view.KubernetesMetricSource{
			Sessions: sessions, RefreshInterval: options.MetricsRefreshInterval,
		},
		Columns: columnManager,
	})
	if err != nil {
		return nil, err
	}
	viewService, err := view.NewGRPCService(viewRuntime, columnsCompiler)
	if err != nil {
		viewRuntime.Close()
		return nil, err
	}
	objectReader, err := object.NewReader(object.ClusterResolver{Sessions: sessions})
	if err != nil {
		viewRuntime.Close()
		return nil, err
	}
	objectReader.SetCachedChildSource(relationshipCacheAdapter{runtime: viewRuntime})
	detailMetrics, err := object.NewKubernetesDetailMetricsProvider(sessions)
	if err != nil {
		viewRuntime.Close()
		return nil, err
	}
	objectService, err := object.NewGRPCService(objectReader, detailMetrics)
	if err != nil {
		viewRuntime.Close()
		return nil, err
	}
	operationManager := operation.NewManager()
	operationService, err := operation.NewGRPCService(
		objectReader,
		operationManager,
		operation.ClusterMutationBackendAcquirer{Sessions: sessions},
	)
	if err != nil {
		operationManager.Close()
		viewRuntime.Close()
		return nil, err
	}
	logManager, err := streamlogs.NewManager(streamlogs.Config{
		Resolver: streamlogs.ClusterResolver{Sessions: sessions},
	})
	if err != nil {
		operationManager.Close()
		viewRuntime.Close()
		return nil, err
	}
	logService, err := streamlogs.NewGRPCService(
		logManager,
		streamlogs.ClusterWorkloadSourceResolver{Sessions: sessions},
	)
	if err != nil {
		logManager.Close()
		operationManager.Close()
		viewRuntime.Close()
		return nil, err
	}
	execManager, err := execstream.NewManager(execstream.Config{
		Resolver: execstream.ClusterResolver{Sessions: sessions},
	})
	if err != nil {
		logManager.Close()
		operationManager.Close()
		viewRuntime.Close()
		return nil, err
	}
	execService, err := execstream.NewGRPCService(execManager)
	if err != nil {
		execManager.Close()
		logManager.Close()
		operationManager.Close()
		viewRuntime.Close()
		return nil, err
	}
	forwardManager, err := portforward.NewManager(portforward.Config{
		Sessions: portforward.ClusterSessions{Sessions: sessions},
	})
	if err != nil {
		execManager.Close()
		logManager.Close()
		operationManager.Close()
		viewRuntime.Close()
		return nil, err
	}
	forwardService, err := portforward.NewGRPCService(forwardManager)
	if err != nil {
		forwardManager.Close()
		execManager.Close()
		logManager.Close()
		operationManager.Close()
		viewRuntime.Close()
		return nil, err
	}
	serverOptions := []grpc.ServerOption{
		grpc.ChainUnaryInterceptor(
			authenticator.UnaryServerInterceptor,
			unaryLoggingInterceptor(options.Logger),
		),
		grpc.ChainStreamInterceptor(
			authenticator.StreamServerInterceptor,
			streamLoggingInterceptor(options.Logger),
		),
	}
	serverOptions = append(serverOptions, options.GRPCOptions...)
	grpcServer := grpc.NewServer(serverOptions...)
	kmgrv1.RegisterEngineServiceServer(grpcServer, engine)
	kmgrv1.RegisterClusterServiceServer(grpcServer, clusterService)
	kmgrv1.RegisterViewServiceServer(grpcServer, viewService)
	kmgrv1.RegisterObjectServiceServer(grpcServer, objectService)
	kmgrv1.RegisterOperationServiceServer(grpcServer, operationService)
	kmgrv1.RegisterLogServiceServer(grpcServer, logService)
	kmgrv1.RegisterExecServiceServer(grpcServer, execService)
	kmgrv1.RegisterPortForwardServiceServer(grpcServer, forwardService)

	return &Server{
		grpc:       grpcServer,
		engine:     engine,
		cluster:    clusterService,
		catalogs:   catalogs,
		sessions:   sessions,
		views:      viewRuntime,
		operations: operationManager,
		logs:       logManager,
		exec:       execManager,
		forwards:   forwardManager,
		logger:     options.Logger,
	}, nil
}

func (s *Server) Serve(listener net.Listener) error {
	if listener == nil {
		return errors.New("gRPC listener must not be nil")
	}
	err := s.grpc.Serve(listener)
	if errors.Is(err, grpc.ErrServerStopped) {
		return nil
	}
	return err
}

func (s *Server) RequestStop()          { s.engine.RequestStop() }
func (s *Server) Done() <-chan struct{} { return s.engine.Done() }

func (s *Server) Shutdown(timeout time.Duration) {
	s.closeOnce.Do(func() {
		s.engine.RequestStop()
		if timeout <= 0 {
			timeout = DefaultGracefulStopTimeout
		}
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()
		s.views.Close()
		s.logs.Close()
		s.exec.Close()
		s.forwards.RequestClose()
		s.operations.RequestClose()
		_ = s.forwards.CloseContext(ctx)
		_ = s.operations.CloseContext(ctx)
		stopped := make(chan struct{})
		go func() {
			s.grpc.GracefulStop()
			close(stopped)
		}()
		select {
		case <-stopped:
		case <-ctx.Done():
			if s.logger != nil {
				s.logger.Warn("forcing server stop after shutdown timeout")
			}
			s.grpc.Stop()
			<-stopped
		}
		s.sessions.CloseAll()
	})
}
