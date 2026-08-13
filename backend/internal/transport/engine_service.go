package transport

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"sync"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const (
	ProtocolMajor uint32 = 1
	ProtocolMinor uint32 = 0
)

var engineCapabilities = []*kmgrv1.Capability{
	{Name: "engine.health", Version: 1},
	{Name: "cluster.contexts", Version: 1},
	{Name: "cluster.sessions", Version: 1},
	{Name: "cluster.discovery", Version: 1},
	{Name: "view.resources", Version: 1},
	{Name: "object.details", Version: 1},
	{Name: "object.data", Version: 1},
}

type EngineService struct {
	kmgrv1.UnimplementedEngineServiceServer

	version          string
	instanceID       string
	startedAt        time.Time
	stopping         chan struct{}
	stopOnce         sync.Once
	streamMu         sync.Mutex
	streamGeneration map[string]uint64
}

func NewEngineService(version string, startedAt time.Time) (*EngineService, error) {
	if version == "" {
		version = "dev"
	}
	if startedAt.IsZero() {
		startedAt = time.Now()
	}
	instanceID, err := newEngineInstanceID()
	if err != nil {
		return nil, err
	}
	return &EngineService{
		version:          version,
		instanceID:       instanceID,
		startedAt:        startedAt,
		stopping:         make(chan struct{}),
		streamGeneration: make(map[string]uint64),
	}, nil
}

func (s *EngineService) Handshake(
	ctx context.Context,
	request *kmgrv1.HandshakeRequest,
) (*kmgrv1.HandshakeResponse, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestContext, cancel, err := validateRequestContext(ctx, request.GetContext(), false)
	if err != nil {
		return nil, err
	}
	defer cancel()
	if err := requestContext.Err(); err != nil {
		return nil, contextStatus(err)
	}

	response := &kmgrv1.HandshakeResponse{
		RequestId:        request.GetContext().GetRequestId(),
		EngineVersion:    s.version,
		EngineInstanceId: s.instanceID,
	}
	protocol := request.GetClientProtocol()
	if protocol == nil || protocol.GetMajor() != ProtocolMajor {
		clientMajor := uint32(0)
		if protocol != nil {
			clientMajor = protocol.GetMajor()
		}
		response.Error = &kmgrv1.StructuredError{
			Category:  kmgrv1.ErrorCategory_ERROR_CATEGORY_UNSUPPORTED,
			Reason:    "ProtocolVersionMismatch",
			Message:   fmt.Sprintf("The GUI protocol major version %d is not compatible with engine protocol major version %d.", clientMajor, ProtocolMajor),
			Operation: "handshake",
			SafeDetails: map[string]string{
				"client_protocol_major": fmt.Sprint(clientMajor),
				"engine_protocol_major": fmt.Sprint(ProtocolMajor),
			},
		}
		return response, nil
	}

	minor := min(protocol.GetMinor(), ProtocolMinor)
	response.NegotiatedProtocol = &kmgrv1.ProtocolVersion{Major: ProtocolMajor, Minor: minor}
	response.Capabilities = cloneCapabilities(engineCapabilities)
	return response, nil
}

func (s *EngineService) Health(
	ctx context.Context,
	request *kmgrv1.HealthRequest,
) (*kmgrv1.HealthResponse, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestContext, cancel, err := validateRequestContext(ctx, request.GetContext(), false)
	if err != nil {
		return nil, err
	}
	defer cancel()
	if err := requestContext.Err(); err != nil {
		return nil, contextStatus(err)
	}
	return &kmgrv1.HealthResponse{
		RequestId:       request.GetContext().GetRequestId(),
		State:           s.State(),
		StartedAtUnixMs: s.startedAt.UnixMilli(),
	}, nil
}

func (s *EngineService) WatchHealth(
	request *kmgrv1.WatchHealthRequest,
	stream grpc.ServerStreamingServer[kmgrv1.HealthEvent],
) error {
	if request == nil {
		return status.Error(codes.InvalidArgument, "request is required")
	}
	requestContext, cancel, err := validateRequestContext(stream.Context(), request.GetContext(), false)
	if err != nil {
		return err
	}
	defer cancel()
	if request.GetStreamId() == "" {
		return status.Error(codes.InvalidArgument, "stream ID is required")
	}

	s.streamMu.Lock()
	s.streamGeneration[request.GetStreamId()]++
	generation := s.streamGeneration[request.GetStreamId()]
	s.streamMu.Unlock()
	state := s.State()
	if err := stream.Send(&kmgrv1.HealthEvent{
		Cursor: &kmgrv1.StreamCursor{
			StreamId:   request.GetStreamId(),
			Generation: generation,
			Sequence:   1,
		},
		State: state,
	}); err != nil {
		return err
	}
	if state == kmgrv1.HealthState_HEALTH_STATE_STOPPING {
		return nil
	}

	select {
	case <-requestContext.Done():
		return contextStatus(requestContext.Err())
	case <-s.stopping:
		return stream.Send(&kmgrv1.HealthEvent{
			Cursor: &kmgrv1.StreamCursor{
				StreamId:   request.GetStreamId(),
				Generation: generation,
				Sequence:   2,
			},
			State: kmgrv1.HealthState_HEALTH_STATE_STOPPING,
		})
	}
}

func (s *EngineService) Shutdown(
	ctx context.Context,
	request *kmgrv1.ShutdownRequest,
) (*kmgrv1.Acknowledgement, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestContext, cancel, err := validateRequestContext(ctx, request.GetContext(), false)
	if err != nil {
		return nil, err
	}
	defer cancel()
	if err := requestContext.Err(); err != nil {
		return nil, contextStatus(err)
	}
	s.RequestStop()
	return &kmgrv1.Acknowledgement{
		RequestId: request.GetContext().GetRequestId(),
		Accepted:  true,
	}, nil
}

func (s *EngineService) RequestStop() {
	s.stopOnce.Do(func() {
		close(s.stopping)
		s.streamMu.Lock()
		clear(s.streamGeneration)
		s.streamMu.Unlock()
	})
}

func (s *EngineService) Done() <-chan struct{} { return s.stopping }

func (s *EngineService) State() kmgrv1.HealthState {
	select {
	case <-s.stopping:
		return kmgrv1.HealthState_HEALTH_STATE_STOPPING
	default:
		return kmgrv1.HealthState_HEALTH_STATE_READY
	}
}

func (s *EngineService) InstanceID() string { return s.instanceID }

func newEngineInstanceID() (string, error) {
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", fmt.Errorf("generate engine instance ID: %w", err)
	}
	return "engine_" + hex.EncodeToString(random[:]), nil
}

func cloneCapabilities(capabilities []*kmgrv1.Capability) []*kmgrv1.Capability {
	result := make([]*kmgrv1.Capability, len(capabilities))
	for index, capability := range capabilities {
		result[index] = &kmgrv1.Capability{Name: capability.GetName(), Version: capability.GetVersion()}
	}
	return result
}
