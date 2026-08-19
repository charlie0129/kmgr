package view

import (
	"context"
	"errors"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func (s *GRPCService) ApplySelectionGesture(
	ctx context.Context,
	request *kmgrv1.ApplySelectionGestureRequest,
) (*kmgrv1.ApplySelectionGestureResponse, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestID, operationContext, cancel, err := viewRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	if err := operationContext.Err(); err != nil {
		return nil, selectionStatusError(err)
	}
	gesture, err := selectionGestureFromMessage(request.GetGesture())
	if err != nil {
		return nil, selectionStatusError(err)
	}
	selection, err := s.runtime.ApplySelectionGesture(
		request.GetContext().GetClusterSessionId(),
		request.GetViewId(),
		request.GetGeneration(),
		request.GetIndexRevision(),
		request.GetPreviousToken(),
		gesture,
	)
	if err != nil {
		return nil, selectionStatusError(err)
	}
	return &kmgrv1.ApplySelectionGestureResponse{
		RequestId: requestID,
		Selection: selectionStateMessage(selection),
	}, nil
}

func (s *GRPCService) ProjectSelectionRange(
	ctx context.Context,
	request *kmgrv1.ProjectSelectionRangeRequest,
) (*kmgrv1.ProjectSelectionRangeResponse, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestID, operationContext, cancel, err := viewRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	if err := operationContext.Err(); err != nil {
		return nil, selectionStatusError(err)
	}
	projection, err := s.runtime.ProjectSelectionRange(
		request.GetContext().GetClusterSessionId(),
		request.GetViewId(),
		request.GetGeneration(),
		request.GetIndexRevision(),
		request.GetStartIndex(),
		request.GetLength(),
		request.GetToken(),
	)
	if err != nil {
		return nil, selectionStatusError(err)
	}
	return &kmgrv1.ProjectSelectionRangeResponse{
		RequestId:     requestID,
		ViewId:        request.GetViewId(),
		Generation:    projection.Generation,
		IndexRevision: projection.IndexRevision,
		StartIndex:    projection.StartIndex,
		RowsVisible:   projection.RowsVisible,
		Selection:     selectionStateMessage(projection.Membership.State),
		Selected:      projection.Membership.Selected,
		AnchorOffset:  projection.Membership.AnchorOffset,
	}, nil
}

func (s *GRPCService) FetchSelectionPage(
	ctx context.Context,
	request *kmgrv1.FetchSelectionPageRequest,
) (*kmgrv1.FetchSelectionPageResponse, error) {
	if request == nil {
		return nil, status.Error(codes.InvalidArgument, "request is required")
	}
	requestID, operationContext, cancel, err := viewRequestContext(ctx, request.GetContext())
	if err != nil {
		return nil, err
	}
	defer cancel()
	if err := operationContext.Err(); err != nil {
		return nil, selectionStatusError(err)
	}
	page, err := s.runtime.FetchSelectionPage(
		request.GetContext().GetClusterSessionId(),
		request.GetViewId(),
		request.GetToken(),
		request.GetOffset(),
		request.GetLimit(),
	)
	if err != nil {
		return nil, selectionStatusError(err)
	}
	items := make([]*kmgrv1.SelectionPageItem, 0, len(page.Items))
	for _, item := range page.Items {
		items = append(items, &kmgrv1.SelectionPageItem{
			PinnedIndex: item.Index,
			Identity: selectionIdentityMessage(
				request.GetContext().GetClusterSessionId(),
				item.Identity,
			),
		})
	}
	return &kmgrv1.FetchSelectionPageResponse{
		RequestId:  requestID,
		Selection:  selectionStateMessage(page.State),
		Offset:     page.Offset,
		Items:      items,
		NextOffset: page.NextOffset,
		Done:       page.Done,
	}, nil
}

func selectionGestureFromMessage(message *kmgrv1.SelectionGesture) (SelectionGesture, error) {
	if message == nil {
		return SelectionGesture{}, ErrInvalidSelectionGesture
	}
	var kind SelectionGestureKind
	switch message.GetKind() {
	case kmgrv1.SelectionGestureKind_SELECTION_GESTURE_KIND_REPLACE:
		kind = SelectionGestureReplace
	case kmgrv1.SelectionGestureKind_SELECTION_GESTURE_KIND_COMMAND_TOGGLE:
		kind = SelectionGestureCommandToggle
	case kmgrv1.SelectionGestureKind_SELECTION_GESTURE_KIND_SHIFT_EXTEND:
		kind = SelectionGestureShiftExtend
	case kmgrv1.SelectionGestureKind_SELECTION_GESTURE_KIND_COMMAND_ALL:
		kind = SelectionGestureCommandAll
	case kmgrv1.SelectionGestureKind_SELECTION_GESTURE_KIND_CLEAR:
		kind = SelectionGestureClear
	default:
		return SelectionGesture{}, ErrInvalidSelectionGesture
	}
	return SelectionGesture{
		Kind: kind, Index: message.GetIndex(), Additive: message.GetAdditive(),
	}, nil
}

func selectionStateMessage(state SelectionState) *kmgrv1.SelectionState {
	result := &kmgrv1.SelectionState{
		Token:         state.Token,
		Generation:    state.Generation,
		IndexRevision: state.IndexRevision,
		SelectedCount: state.SelectedCount,
	}
	if !state.ExpiresAt.IsZero() {
		result.ExpiresAtUnixMs = state.ExpiresAt.UnixMilli()
	}
	if state.Anchor != nil {
		result.Anchor = &kmgrv1.SelectionAnchor{
			Index: state.Anchor.Index,
			Uid:   state.Anchor.UID,
		}
	}
	return result
}

func selectionIdentityMessage(sessionID string, identity SelectionIdentity) *kmgrv1.ResourceIdentity {
	return &kmgrv1.ResourceIdentity{
		ClusterSessionId: sessionID,
		Group:            identity.Group,
		Version:          identity.Version,
		Resource:         identity.Resource,
		Namespace:        identity.Namespace,
		Name:             identity.Name,
		Uid:              identity.UID,
	}
}

func selectionStatusError(err error) error {
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return status.Error(codes.DeadlineExceeded, "request deadline exceeded")
	case errors.Is(err, context.Canceled):
		return status.Error(codes.Canceled, "request cancelled")
	case errors.Is(err, ErrViewNotFound),
		errors.Is(err, ErrSelectionTokenNotFound),
		errors.Is(err, ErrSelectionScopeMismatch):
		return status.Error(codes.NotFound, "selection or resource view was not found")
	case errors.Is(err, ErrStaleViewGeneration),
		errors.Is(err, ErrStaleViewRevision),
		errors.Is(err, ErrSelectionTokenExpired):
		return status.Error(codes.FailedPrecondition, err.Error())
	case errors.Is(err, ErrInvalidSelectionScope),
		errors.Is(err, ErrInvalidSelectionGesture),
		errors.Is(err, ErrInvalidSelectionPage),
		errors.Is(err, ErrInvalidViewRange):
		return status.Error(codes.InvalidArgument, err.Error())
	case errors.Is(err, ErrSelectionCapacityExhausted):
		return status.Error(codes.ResourceExhausted, err.Error())
	case errors.Is(err, ErrViewClosed):
		return status.Error(codes.Canceled, "resource view closed")
	case errors.Is(err, ErrInvalidSelectionSnapshot),
		errors.Is(err, ErrSelectionSnapshotConflict),
		errors.Is(err, ErrSelectionStoreUnavailable):
		return status.Error(codes.Internal, "selection state is unavailable")
	default:
		return status.Error(codes.Internal, "selection request failed")
	}
}
