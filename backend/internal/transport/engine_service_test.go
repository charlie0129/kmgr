package transport

import (
	"context"
	"reflect"
	"slices"
	"testing"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestEngineServiceHandshakeAndHealth(t *testing.T) {
	t.Parallel()
	startedAt := time.Unix(1_700_000_000, 123_000_000)
	service, err := NewEngineService("test-version", startedAt)
	if err != nil {
		t.Fatal(err)
	}
	response, err := service.Handshake(context.Background(), &kmgrv1.HandshakeRequest{
		Context:        requestContext("handshake"),
		ClientProtocol: &kmgrv1.ProtocolVersion{Major: ProtocolMajor, Minor: ProtocolMinor + 10},
		ClientVersion:  "gui-test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if response.GetError() != nil || response.GetRequestId() != "handshake" {
		t.Fatalf("handshake response = %#v", response)
	}
	if response.GetNegotiatedProtocol().GetMajor() != ProtocolMajor ||
		response.GetNegotiatedProtocol().GetMinor() != ProtocolMinor {
		t.Fatalf("negotiated protocol = %#v", response.GetNegotiatedProtocol())
	}
	if response.GetEngineVersion() != "test-version" || response.GetEngineInstanceId() == "" {
		t.Fatalf("engine identity/capabilities = %#v", response)
	}
	gotCapabilities := make([]string, 0, len(response.GetCapabilities()))
	for _, capability := range response.GetCapabilities() {
		if capability.GetVersion() != 1 {
			t.Fatalf("capability %q version = %d, want 1", capability.GetName(), capability.GetVersion())
		}
		gotCapabilities = append(gotCapabilities, capability.GetName())
	}
	slices.Sort(gotCapabilities)
	wantCapabilities := []string{
		"cluster.contexts",
		"cluster.discovery",
		"cluster.sessions",
		"engine.health",
		"exec.stream",
		"logs.stream",
		"object.data",
		"object.details",
		"object.events",
		"object.relationships",
		"operation.mutations",
		"port-forward.manager",
		"view.column-preview",
		"view.optional-resources",
		"view.resources",
		"view.search",
	}
	if !reflect.DeepEqual(gotCapabilities, wantCapabilities) {
		t.Fatalf("capabilities = %q, want %q", gotCapabilities, wantCapabilities)
	}

	health, err := service.Health(context.Background(), &kmgrv1.HealthRequest{Context: requestContext("health")})
	if err != nil {
		t.Fatal(err)
	}
	if health.GetState() != kmgrv1.HealthState_HEALTH_STATE_READY || health.GetStartedAtUnixMs() != startedAt.UnixMilli() {
		t.Fatalf("health = %#v", health)
	}
	service.RequestStop()
	health, err = service.Health(context.Background(), &kmgrv1.HealthRequest{Context: requestContext("stopping")})
	if err != nil {
		t.Fatal(err)
	}
	if health.GetState() != kmgrv1.HealthState_HEALTH_STATE_STOPPING {
		t.Fatalf("stopping health = %#v", health)
	}
}

func TestEngineServiceHandshakeProtocolMismatchIsStructured(t *testing.T) {
	t.Parallel()
	service, err := NewEngineService("test", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	response, err := service.Handshake(context.Background(), &kmgrv1.HandshakeRequest{
		Context:        requestContext("mismatch"),
		ClientProtocol: &kmgrv1.ProtocolVersion{Major: ProtocolMajor + 1},
	})
	if err != nil {
		t.Fatal(err)
	}
	if response.GetNegotiatedProtocol() != nil ||
		response.GetError().GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_UNSUPPORTED ||
		response.GetError().GetReason() != "ProtocolVersionMismatch" {
		t.Fatalf("mismatch response = %#v", response)
	}
}

func TestEngineServiceRejectsNilAndInvalidRequest(t *testing.T) {
	t.Parallel()
	service, err := NewEngineService("test", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.Handshake(context.Background(), nil); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("nil handshake code = %v", status.Code(err))
	}
	if _, err := service.Health(context.Background(), &kmgrv1.HealthRequest{}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("missing context code = %v", status.Code(err))
	}
}

func requestContext(requestID string) *kmgrv1.RequestContext {
	return &kmgrv1.RequestContext{RequestId: requestID}
}
