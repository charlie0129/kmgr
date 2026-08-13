package view

import (
	"context"
	"errors"
	"strings"
	"sync"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

var _ kmgrv1.ViewServiceServer = (*GRPCService)(nil)

// GRPCService is intentionally a thin protocol adapter. Runtime owns all
// consumer lifetimes, generation gating, warm caches, and bounded batching.
type GRPCService struct {
	kmgrv1.UnimplementedViewServiceServer
	runtime  *Runtime
	searchMu sync.Mutex
	searches map[searchStreamKey]context.CancelFunc
}

type searchStreamKey struct {
	sessionID  string
	searchID   string
	generation uint64
	revision   uint64
}

func NewGRPCService(runtime *Runtime) (*GRPCService, error) {
	if runtime == nil {
		return nil, errors.New("view runtime must not be nil")
	}
	return &GRPCService{runtime: runtime, searches: make(map[searchStreamKey]context.CancelFunc)}, nil
}

func (s *GRPCService) SearchCachedObjects(
	_ context.Context,
	request *kmgrv1.SearchCachedObjectsRequest,
) (*kmgrv1.SearchCachedObjectsResponse, error) {
	if request == nil || request.GetContext() == nil || request.GetContext().GetRequestId() == "" ||
		strings.TrimSpace(request.GetContext().GetClusterSessionId()) == "" ||
		strings.TrimSpace(request.GetQuery()) == "" {
		return nil, status.Error(codes.InvalidArgument, "request, session, and query are required")
	}
	scope := request.GetNamespaceScope()
	result, err := s.runtime.SearchCached(CachedSearchQuery{
		SessionID: request.GetContext().GetClusterSessionId(),
		NamespaceScope: NamespaceScope{
			All: scope.GetAllNamespaces(), Namespaces: append([]string(nil), scope.GetNamespaces()...),
		},
		Query: request.GetQuery(), ResultLimit: int(request.GetResultLimit()),
		ExaminationLimit: int(request.GetExaminationLimit()),
	})
	response := &kmgrv1.SearchCachedObjectsResponse{RequestId: request.GetContext().GetRequestId()}
	if err != nil {
		response.Error = structuredCachedSearchError(err)
		return response, nil
	}
	response.Results = result.Results
	response.ObjectsExamined = result.Examined
	response.ExaminationTruncated = result.Truncated
	return response, nil
}

func (s *GRPCService) SearchObjects(
	request *kmgrv1.SearchObjectsRequest,
	stream grpc.ServerStreamingServer[kmgrv1.SearchObjectsEvent],
) error {
	if request == nil || request.GetContext() == nil || request.GetContext().GetClusterSessionId() == "" ||
		request.GetSearchId() == "" || request.GetGeneration() == 0 || request.GetQueryRevision() == 0 || request.GetResource() == nil {
		return status.Error(codes.InvalidArgument, "session, search ID, generation, revision, and resource are required")
	}
	ctx, cancel := context.WithCancel(stream.Context())
	key := searchStreamKey{
		sessionID: request.GetContext().GetClusterSessionId(), searchID: request.GetSearchId(),
		generation: request.GetGeneration(), revision: request.GetQueryRevision(),
	}
	s.searchMu.Lock()
	for existing, existingCancel := range s.searches {
		if existing.sessionID == key.sessionID && existing.searchID == key.searchID &&
			(existing.generation < key.generation || existing.revision < key.revision) {
			existingCancel()
			delete(s.searches, existing)
		}
	}
	s.searches[key] = cancel
	s.searchMu.Unlock()
	defer func() {
		cancel()
		s.searchMu.Lock()
		delete(s.searches, key)
		s.searchMu.Unlock()
	}()

	resource := request.GetResource()
	scope := request.GetNamespaceScope()
	sequence := uint64(0)
	err := s.runtime.Search(ctx, SearchQuery{
		SessionID: key.sessionID,
		Resource: ResourceType{
			Group: resource.GetGroup(), Version: resource.GetVersion(), Resource: resource.GetResource(),
			Kind: resource.GetKind(), Namespaced: resource.GetNamespaced(),
		},
		NamespaceScope: NamespaceScope{All: scope.GetAllNamespaces(), Namespaces: append([]string(nil), scope.GetNamespaces()...)},
		Query:          request.GetQuery(), ResultLimit: int(request.GetResultLimit()),
		AllowPaginatedList: request.GetAllowPaginatedList(),
	}, func(batch SearchBatch) error {
		sequence++
		return stream.Send(&kmgrv1.SearchObjectsEvent{
			Cursor:        &kmgrv1.StreamCursor{StreamId: key.searchID, Generation: key.generation, Sequence: sequence},
			QueryRevision: key.revision,
			Results:       batch.Results,
			Progress: &kmgrv1.SearchProgress{
				QueryRevision: key.revision, ObjectsExamined: batch.Examined, Complete: batch.Complete,
				UsedDirectGet: batch.UsedDirectGet, ReusableSnapshotAvailable: batch.Reusable,
			},
		})
	})
	return viewStatusError(err)
}

func (s *GRPCService) CancelSearch(
	_ context.Context,
	request *kmgrv1.CancelSearchRequest,
) (*kmgrv1.Acknowledgement, error) {
	if request == nil || request.GetContext() == nil || request.GetContext().GetRequestId() == "" ||
		request.GetContext().GetClusterSessionId() == "" || request.GetSearchId() == "" ||
		request.GetGeneration() == 0 || request.GetQueryRevision() == 0 {
		return nil, status.Error(codes.InvalidArgument, "request, session, search ID, generation, and revision are required")
	}
	key := searchStreamKey{
		sessionID: request.GetContext().GetClusterSessionId(), searchID: request.GetSearchId(),
		generation: request.GetGeneration(), revision: request.GetQueryRevision(),
	}
	s.searchMu.Lock()
	cancel := s.searches[key]
	if cancel != nil {
		delete(s.searches, key)
	}
	s.searchMu.Unlock()
	if cancel != nil {
		cancel()
	}
	return &kmgrv1.Acknowledgement{RequestId: request.GetContext().GetRequestId(), Accepted: cancel != nil}, nil
}

func (s *GRPCService) StreamView(
	request *kmgrv1.OpenViewRequest,
	stream grpc.ServerStreamingServer[kmgrv1.ViewEvent],
) error {
	subscription, err := s.runtime.Open(request)
	if err != nil {
		return viewStatusError(err)
	}
	defer subscription.Close()
	for {
		events, err := subscription.Next(stream.Context())
		if err != nil {
			if errors.Is(err, ErrViewClosed) {
				return nil
			}
			return viewStatusError(err)
		}
		for _, event := range events {
			if err := stream.Send(event); err != nil {
				return err
			}
		}
	}
}

func (s *GRPCService) CancelView(
	_ context.Context,
	request *kmgrv1.CancelViewRequest,
) (*kmgrv1.Acknowledgement, error) {
	// A delayed RPC from an old generation cannot cancel its replacement.
	if request == nil || request.GetContext() == nil || request.GetContext().GetRequestId() == "" ||
		request.GetContext().GetClusterSessionId() == "" || request.GetViewId() == "" || request.GetGeneration() == 0 {
		return nil, status.Error(codes.InvalidArgument, "request context, session, view ID, and generation are required")
	}
	accepted := s.runtime.Cancel(
		request.GetContext().GetClusterSessionId(),
		request.GetViewId(),
		request.GetGeneration(),
	)
	return &kmgrv1.Acknowledgement{RequestId: request.GetContext().GetRequestId(), Accepted: accepted}, nil
}

func viewStatusError(err error) error {
	if err == nil {
		return nil
	}
	switch {
	case errors.Is(err, ErrSessionNotFound):
		return status.Error(codes.NotFound, "cluster session was not found")
	case errors.Is(err, ErrInvalidView):
		return status.Error(codes.InvalidArgument, err.Error())
	case errors.Is(err, ErrStaleViewOpen):
		return status.Error(codes.FailedPrecondition, err.Error())
	case errors.Is(err, ErrViewClosed):
		return status.Error(codes.Canceled, "resource view closed")
	default:
		return status.Error(codes.Internal, "resource view failed")
	}
}

func structuredCachedSearchError(err error) *kmgrv1.StructuredError {
	result := &kmgrv1.StructuredError{
		Category: kmgrv1.ErrorCategory_ERROR_CATEGORY_INTERNAL,
		Reason:   "CachedSearchFailed", Message: "The in-memory object search failed.",
		Operation: "search cached objects",
	}
	switch {
	case errors.Is(err, ErrSessionNotFound):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_NOT_FOUND
		result.Reason = "ClusterSessionNotFound"
		result.Message = "The cluster session was not found."
	case errors.Is(err, ErrInvalidView):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_VALIDATION
		result.Reason = "InvalidCachedSearch"
		result.Message = err.Error()
	case errors.Is(err, ErrViewClosed):
		result.Category = kmgrv1.ErrorCategory_ERROR_CATEGORY_UNAVAILABLE
		result.Reason = "ViewRuntimeClosed"
		result.Message = "The in-memory object cache is unavailable."
		result.Retryable = true
	}
	return result
}
