package portforward

import (
	"context"
	"sync"
	"testing"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
)

func TestGRPCStartListStopAndNonLoopbackWarning(t *testing.T) {
	t.Parallel()
	resolver := &sequenceResolver{results: []resolveResult{{target: podIdentity("pod", "uid")}}}
	manager := testManager(t, resolver, &fakeForwarder{ports: []uint16{40404}}, 1)
	defer manager.Close()
	service, err := NewGRPCService(manager)
	if err != nil {
		t.Fatal(err)
	}
	request := &kmgrv1.StartPortForwardRequest{
		Context: pfContext("start"), PortForwardId: "forward", Target: pfPodIdentity(),
		RemotePort: 8080, BindAddress: "0.0.0.0",
	}
	rejected, err := service.Start(context.Background(), request)
	if err != nil || rejected.GetAccepted() || rejected.GetError().GetReason() != "NonLoopbackApprovalRequired" {
		t.Fatalf("rejected = %#v, error = %v", rejected, err)
	}
	request.AllowNonLoopback = true
	accepted, err := service.Start(context.Background(), request)
	if err != nil || !accepted.GetAccepted() {
		t.Fatalf("accepted = %#v, error = %v", accepted, err)
	}
	eventuallyForward(t, func() bool { return manager.List("", false)[0].State == StateListening })
	listed, err := service.List(context.Background(), &kmgrv1.ListPortForwardsRequest{Context: pfContext("list")})
	if err != nil || len(listed.GetPortForwards()) != 1 {
		t.Fatalf("listed = %#v, error = %v", listed, err)
	}
	value := listed.GetPortForwards()[0]
	if value.GetLocalPort() != 40404 || value.GetResolvedPod().GetUid() != "uid" ||
		value.GetLastError().GetSafeDetails()["exposure_warning"] != "non_loopback_bind" {
		t.Fatalf("listed forward = %#v", value)
	}
	ack, err := service.Stop(context.Background(), &kmgrv1.StopPortForwardRequest{
		Context: pfContext("stop"), PortForwardId: "forward",
	})
	if err != nil || !ack.GetAccepted() {
		t.Fatalf("stop = %#v, error = %v", ack, err)
	}
}

func TestGRPCWatchStartsWithSnapshotAndEmitsStoppedRemoval(t *testing.T) {
	t.Parallel()
	manager := testManager(t,
		&sequenceResolver{results: []resolveResult{{target: podIdentity("pod", "uid")}}},
		&fakeForwarder{ports: []uint16{12345}}, 1,
	)
	defer manager.Close()
	service, _ := NewGRPCService(manager)
	_, err := service.Start(context.Background(), &kmgrv1.StartPortForwardRequest{
		Context: pfContext("start"), PortForwardId: "forward", Target: pfPodIdentity(), RemotePort: 8080,
	})
	if err != nil {
		t.Fatal(err)
	}
	watchContext, cancel := context.WithCancel(context.Background())
	stream := &recordingPFStream{ctx: watchContext, sent: make(chan struct{}, 4)}
	done := make(chan error, 1)
	go func() {
		done <- service.Watch(&kmgrv1.WatchPortForwardsRequest{
			Context: pfContext("watch"), StreamId: "stream", Generation: 7,
		}, stream)
	}()
	select {
	case <-stream.sent:
	case <-time.After(time.Second):
		t.Fatal("watch did not send initial snapshot")
	}
	_, _ = service.Stop(context.Background(), &kmgrv1.StopPortForwardRequest{
		Context: pfContext("stop"), PortForwardId: "forward",
	})
	eventuallyForward(t, func() bool {
		stream.mu.Lock()
		defer stream.mu.Unlock()
		for _, event := range stream.events {
			if len(event.GetDelta().GetRemovedPortForwardIds()) == 1 {
				return true
			}
		}
		return false
	})
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("watch did not stop")
	}
	stream.mu.Lock()
	defer stream.mu.Unlock()
	for index, event := range stream.events {
		if event.GetCursor().GetGeneration() != 7 || event.GetCursor().GetSequence() != uint64(index+1) {
			t.Fatalf("cursor %d = %#v", index, event.GetCursor())
		}
	}
}

type recordingPFStream struct {
	grpc.ServerStream
	ctx    context.Context
	mu     sync.Mutex
	events []*kmgrv1.PortForwardEvent
	sent   chan struct{}
}

func (s *recordingPFStream) Context() context.Context { return s.ctx }
func (s *recordingPFStream) Send(event *kmgrv1.PortForwardEvent) error {
	s.mu.Lock()
	s.events = append(s.events, event)
	s.mu.Unlock()
	select {
	case s.sent <- struct{}{}:
	default:
	}
	return nil
}

func pfContext(id string) *kmgrv1.RequestContext {
	return &kmgrv1.RequestContext{RequestId: id, ClusterSessionId: "session"}
}

func pfPodIdentity() *kmgrv1.ResourceIdentity {
	return &kmgrv1.ResourceIdentity{
		ClusterSessionId: "session", Version: "v1", Resource: "pods",
		Namespace: "ns", Name: "pod", Uid: "uid",
	}
}
