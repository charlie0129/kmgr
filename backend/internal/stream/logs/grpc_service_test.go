package logs

import (
	"errors"
	"testing"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestStartFromProtoPreservesIdentityAndOptionalLogOptions(t *testing.T) {
	t.Parallel()
	sinceUnixMS := time.Now().Add(-time.Hour).UnixMilli()
	sinceSeconds := int64(60)
	tail := int64(100)
	limit := int64(1 << 20)
	convertedInvalid, err := startFromProto(&kmgrv1.StartLogsRequest{
		Context:     &kmgrv1.RequestContext{RequestId: "request", ClusterSessionId: "session-1"},
		LogStreamId: "logs", Generation: 8,
		Sources: []*kmgrv1.LogSource{{
			Identity: &kmgrv1.ResourceIdentity{
				ClusterSessionId: "session-1", Version: "v1", Resource: "pods",
				Namespace: "default", Name: "api-0", Uid: "uid-0",
			},
			SourceId: "source", SourceLabel: "default/api-0", Container: "main",
		}},
		Options: &kmgrv1.LogOptions{
			Follow: true, Previous: true, Timestamps: true,
			SinceUnixMs: &sinceUnixMS, SinceSeconds: &sinceSeconds,
			TailLines: &tail, ByteLimit: &limit,
		},
	})
	if err == nil {
		err = validateStart(convertedInvalid, DefaultMaxSourcesPerStream)
	}
	if !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("mutually exclusive since options error = %v", err)
	}

	request := &kmgrv1.StartLogsRequest{
		Context:     &kmgrv1.RequestContext{RequestId: "request", ClusterSessionId: "session-1"},
		LogStreamId: "logs", Generation: 8,
		Sources: []*kmgrv1.LogSource{{
			Identity: &kmgrv1.ResourceIdentity{
				ClusterSessionId: "session-1", Version: "v1", Resource: "pods",
				Namespace: "default", Name: "api-0", Uid: "uid-0",
			},
			SourceId: "source", SourceLabel: "default/api-0", Container: "main",
		}},
		Options: &kmgrv1.LogOptions{
			Follow: true, Previous: true, Timestamps: true,
			SinceSeconds: &sinceSeconds, TailLines: &tail, ByteLimit: &limit,
		},
	}
	converted, err := startFromProto(request)
	if err != nil {
		t.Fatalf("startFromProto: %v", err)
	}
	if converted.SessionID != "session-1" || converted.StreamID != "logs" || converted.Generation != 8 || len(converted.Sources) != 1 {
		t.Fatalf("converted request = %#v", converted)
	}
	if converted.Sources[0].Identity.UID != "uid-0" || converted.Sources[0].Container != "main" ||
		converted.Options.SinceSeconds == nil || *converted.Options.SinceSeconds != sinceSeconds ||
		converted.Options.TailLines == nil || *converted.Options.TailLines != tail ||
		converted.Options.ByteLimit == nil || *converted.Options.ByteLimit != limit {
		t.Fatalf("converted source/options = %#v / %#v", converted.Sources[0], converted.Options)
	}
}

func TestStartFromProtoRejectsDynamicWorkloadMembershipExplicitly(t *testing.T) {
	t.Parallel()
	_, err := startFromProto(&kmgrv1.StartLogsRequest{
		Options: &kmgrv1.LogOptions{FollowWorkloadMembership: true},
	})
	if status.Code(err) != codes.Unimplemented {
		t.Fatalf("error code = %v, want Unimplemented: %v", status.Code(err), err)
	}
}

func TestStructuredLogErrorRedactsPayloadAndPreservesIdentity(t *testing.T) {
	t.Parallel()
	secretPayload := "sensitive log payload"
	source := testSource("api")
	result := structuredLogError(errors.New(secretPayload), &source, "production")
	if result.GetMessage() == secretPayload || result.GetReason() == secretPayload {
		t.Fatal("raw log failure entered the structured error")
	}
	if result.GetContextName() != "production" || result.GetResource().GetUid() != "uid-api" {
		t.Fatalf("safe error context = %#v", result)
	}
}
