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
	manager := testManager(t, resolver, &fakeForwarder{ports: []uint16{40404}})
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
		&fakeForwarder{ports: []uint16{12345}},
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

func TestGRPCWatchOverflowResynchronizesEveryForward(t *testing.T) {
	t.Parallel()
	manager, err := NewManager(Config{
		Sessions:               staticSessionResolver{session: Session{}},
		SubscriberPendingLimit: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	service, err := NewGRPCService(manager)
	if err != nil {
		t.Fatal(err)
	}
	watchContext, cancel := context.WithCancel(context.Background())
	stream := newGatedPFStream(watchContext)
	done := make(chan error, 1)
	go func() {
		done <- service.Watch(&kmgrv1.WatchPortForwardsRequest{
			Context: pfContext("watch-resync"), StreamId: "stream", Generation: 9,
			IncludeStopped: true,
		}, stream)
	}()
	select {
	case <-stream.initialSent:
	case <-time.After(time.Second):
		t.Fatal("watch did not send initial snapshot")
	}

	manager.publish(managerUpdate{snapshot: Snapshot{ID: "superseded", State: StateStarting}})
	select {
	case <-stream.updateBlocked:
	case <-time.After(time.Second):
		t.Fatal("watch did not block on the first delta")
	}

	now := time.Now()
	for _, id := range []string{"one", "two", "three"} {
		runDone := make(chan struct{})
		close(runDone)
		snapshot := Snapshot{
			ID: id, State: StateListening, StartedAt: now, UpdatedAt: now,
			Target: Identity{SessionID: "session"},
		}
		manager.mu.Lock()
		manager.entries[id] = &entry{
			snapshot: snapshot, cancel: func() {}, runDone: runDone, revision: 1,
		}
		manager.mu.Unlock()
		manager.publish(managerUpdate{snapshot: snapshot})
	}
	close(stream.releaseUpdate)
	eventuallyForward(t, func() bool { return len(stream.Events()) >= 3 })

	events := stream.Events()
	resync := events[2]
	upserts := make(map[string]struct{}, len(resync.GetDelta().GetUpserts()))
	for _, value := range resync.GetDelta().GetUpserts() {
		upserts[value.GetPortForwardId()] = struct{}{}
	}
	if len(upserts) != 3 {
		t.Fatalf("resync upserts = %#v", resync.GetDelta().GetUpserts())
	}
	for _, id := range []string{"one", "two", "three"} {
		if _, exists := upserts[id]; !exists {
			t.Fatalf("resync omitted %q: %#v", id, resync.GetDelta())
		}
	}
	removed := resync.GetDelta().GetRemovedPortForwardIds()
	if len(removed) != 1 || removed[0] != "superseded" {
		t.Fatalf("resync removals = %v", removed)
	}
	if cursor := resync.GetCursor(); cursor.GetGeneration() != 9 || cursor.GetSequence() != 3 {
		t.Fatalf("resync cursor = %#v", cursor)
	}

	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("watch did not stop")
	}
}

type recordingPFStream struct {
	grpc.ServerStream
	ctx    context.Context
	mu     sync.Mutex
	events []*kmgrv1.PortForwardEvent
	sent   chan struct{}
}

type gatedPFStream struct {
	grpc.ServerStream
	ctx           context.Context
	mu            sync.Mutex
	events        []*kmgrv1.PortForwardEvent
	initialSent   chan struct{}
	updateBlocked chan struct{}
	releaseUpdate chan struct{}
}

func newGatedPFStream(ctx context.Context) *gatedPFStream {
	return &gatedPFStream{
		ctx: ctx, initialSent: make(chan struct{}), updateBlocked: make(chan struct{}),
		releaseUpdate: make(chan struct{}),
	}
}

func (s *gatedPFStream) Context() context.Context { return s.ctx }

func (s *gatedPFStream) Send(event *kmgrv1.PortForwardEvent) error {
	s.mu.Lock()
	s.events = append(s.events, event)
	count := len(s.events)
	s.mu.Unlock()
	switch count {
	case 1:
		close(s.initialSent)
	case 2:
		close(s.updateBlocked)
		select {
		case <-s.releaseUpdate:
		case <-s.ctx.Done():
			return s.ctx.Err()
		}
	}
	return nil
}

func (s *gatedPFStream) Events() []*kmgrv1.PortForwardEvent {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]*kmgrv1.PortForwardEvent(nil), s.events...)
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
