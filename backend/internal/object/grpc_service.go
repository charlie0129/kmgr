package object

import (
	"context"
	"errors"
	"slices"
	"sort"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
)

var _ kmgrv1.ObjectServiceServer = (*GRPCService)(nil)

type GRPCService struct {
	kmgrv1.UnimplementedObjectServiceServer
	reader *Reader
}

func NewGRPCService(reader *Reader) (*GRPCService, error) {
	if reader == nil {
		return nil, errors.New("object reader must not be nil")
	}
	return &GRPCService{reader: reader}, nil
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
			Error: structuredObjectError(err, request.GetIdentity(), "get-object"),
		}, nil
	}
	response := &kmgrv1.GetObjectResponse{
		RequestId:       requestID,
		Identity:        request.GetIdentity(),
		ResourceVersion: detail.ResourceVersion,
		YamlUtf8:        slices.Clone(detail.YAML),
		Labels:          stringEntries(detail.Labels),
		Annotations:     stringEntries(detail.Annotations),
	}
	for _, field := range detail.Summary {
		response.SummaryFields = append(response.SummaryFields, &kmgrv1.ObjectSummaryField{
			SectionId: field.Section, FieldId: field.ID, Label: field.Label,
			DisplayText: field.Value, Severity: kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL,
		})
	}
	return response, nil
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
			Error: structuredObjectError(err, request.GetIdentity(), "get-data"),
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

func structuredObjectError(err error, identity *kmgrv1.ResourceIdentity, operation string) *kmgrv1.StructuredError {
	result := &kmgrv1.StructuredError{
		Category: kmgrv1.ErrorCategory_ERROR_CATEGORY_INTERNAL,
		Reason:   "ObjectRequestFailed", Message: "The Kubernetes object request failed.",
		Operation: operation, Resource: identity,
	}
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
