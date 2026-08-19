package object

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/dynamic"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	clienttesting "k8s.io/client-go/testing"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

func TestWatchObjectPinsUIDMapsUpdatesAndBookmarks(t *testing.T) {
	t.Parallel()
	pod := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "uid")
	scheme := runtime.NewScheme()
	client := dynamicfake.NewSimpleDynamicClient(scheme, pod)
	fakeWatch := watch.NewRaceFreeFake()
	client.PrependWatchReactor("pods", func(action clienttesting.Action) (bool, watch.Interface, error) {
		restrictions := action.(clienttesting.WatchAction).GetWatchRestrictions()
		if got := restrictions.Fields.String(); got != "metadata.name=pod" {
			t.Errorf("field selector = %q", got)
		}
		if restrictions.ResourceVersion != "rv-start" {
			t.Errorf("resource version = %q", restrictions.ResourceVersion)
		}
		return true, fakeWatch, nil
	})
	reader, err := NewReader(fakeResolver{client: client})
	if err != nil {
		t.Fatal(err)
	}
	service, err := NewGRPCService(reader)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	stream := newObjectTestStream(ctx)
	done := make(chan error, 1)
	go func() {
		done <- service.WatchObject(watchRequest("rv-start"), stream)
	}()
	stream.waitForCount(t, 1)

	updated := pod.DeepCopy()
	updated.SetResourceVersion("rv-2")
	updated.Object["status"] = map[string]any{"phase": "Running"}
	fakeWatch.Modify(updated)
	bookmark := &unstructured.Unstructured{}
	bookmark.SetResourceVersion("rv-3")
	fakeWatch.Action(watch.Bookmark, bookmark)
	stream.waitForCount(t, 3)
	cancel()
	if err := <-done; status.Code(err) != codes.Canceled {
		t.Fatalf("watch returned %v, want cancelled", err)
	}

	events := stream.snapshot()
	if len(events) != 3 {
		t.Fatalf("events = %d", len(events))
	}
	if events[0].GetType() != kmgrv1.ObjectEventType_OBJECT_EVENT_TYPE_STATUS ||
		events[0].GetObject().GetResourceVersion() != "rv-start" {
		t.Fatalf("initial status = %#v", events[0])
	}
	if events[1].GetType() != kmgrv1.ObjectEventType_OBJECT_EVENT_TYPE_UPDATED ||
		events[1].GetObject().GetResourceVersion() != "rv-2" ||
		len(events[1].GetObject().GetYamlUtf8()) == 0 {
		t.Fatalf("update = %#v", events[1])
	}
	if events[2].GetType() != kmgrv1.ObjectEventType_OBJECT_EVENT_TYPE_STATUS ||
		events[2].GetObject().GetResourceVersion() != "rv-3" {
		t.Fatalf("bookmark = %#v", events[2])
	}
	for index, event := range events {
		if event.GetCursor().GetStreamId() != "object-stream" ||
			event.GetCursor().GetGeneration() != 7 || event.GetCursor().GetSequence() != uint64(index+1) {
			t.Fatalf("cursor %d = %#v", index, event.GetCursor())
		}
	}
	if !fakeWatch.IsStopped() {
		t.Fatal("Kubernetes watch was not stopped on cancellation")
	}
}

func TestWatchObjectDoesNotRepeatAuthoritativeGetWhenResourceVersionIsSupplied(t *testing.T) {
	t.Parallel()
	pod := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "uid")
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), pod)
	fakeWatch := watch.NewRaceFreeFake()
	var getCalls int
	client.PrependReactor("get", "pods", func(clienttesting.Action) (bool, runtime.Object, error) {
		getCalls++
		return false, nil, nil
	})
	client.PrependWatchReactor("pods", func(action clienttesting.Action) (bool, watch.Interface, error) {
		if got := action.(clienttesting.WatchAction).GetWatchRestrictions().ResourceVersion; got != "rv-authoritative" {
			t.Errorf("watch resource version = %q", got)
		}
		return true, fakeWatch, nil
	})
	reader, _ := NewReader(fakeResolver{client: client})
	service, _ := NewGRPCService(reader)
	ctx, cancel := context.WithCancel(context.Background())
	stream := newObjectTestStream(ctx)
	done := make(chan error, 1)
	request := watchRequest("rv-authoritative")
	go func() { done <- service.WatchObject(request, stream) }()
	stream.waitForCount(t, 1)
	cancel()
	if err := <-done; status.Code(err) != codes.Canceled {
		t.Fatalf("watch returned %v, want cancelled", err)
	}
	if getCalls != 0 {
		t.Fatalf("duplicate initial GET calls = %d, want 0", getCalls)
	}
}

func TestWatchObjectAnchorsWithGetWhenResourceVersionIsAbsent(t *testing.T) {
	t.Parallel()
	pod := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "uid")
	pod.SetResourceVersion("rv-current")
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), pod)
	fakeWatch := watch.NewRaceFreeFake()
	var getCalls int
	client.PrependReactor("get", "pods", func(clienttesting.Action) (bool, runtime.Object, error) {
		getCalls++
		return false, nil, nil
	})
	client.PrependWatchReactor("pods", func(action clienttesting.Action) (bool, watch.Interface, error) {
		if got := action.(clienttesting.WatchAction).GetWatchRestrictions().ResourceVersion; got != "rv-current" {
			t.Errorf("watch resource version = %q", got)
		}
		return true, fakeWatch, nil
	})
	reader, _ := NewReader(fakeResolver{client: client})
	service, _ := NewGRPCService(reader)
	ctx, cancel := context.WithCancel(context.Background())
	stream := newObjectTestStream(ctx)
	done := make(chan error, 1)
	go func() { done <- service.WatchObject(watchRequest(""), stream) }()
	stream.waitForCount(t, 1)
	cancel()
	if err := <-done; status.Code(err) != codes.Canceled {
		t.Fatalf("watch returned %v, want cancelled", err)
	}
	if getCalls != 1 {
		t.Fatalf("anchor GET calls = %d, want 1", getCalls)
	}
}

func TestWatchObjectReconnectsFromLastDeliveredResourceVersion(t *testing.T) {
	t.Parallel()
	pod := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "uid")
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), pod)
	firstWatch := watch.NewRaceFreeFake()
	secondWatch := watch.NewRaceFreeFake()
	opened := make(chan string, 2)
	var watchMu sync.Mutex
	watchCalls := 0
	client.PrependWatchReactor("pods", func(action clienttesting.Action) (bool, watch.Interface, error) {
		watchMu.Lock()
		defer watchMu.Unlock()
		watchCalls++
		resourceVersion := action.(clienttesting.WatchAction).GetWatchRestrictions().ResourceVersion
		opened <- resourceVersion
		if watchCalls == 1 {
			return true, firstWatch, nil
		}
		return true, secondWatch, nil
	})
	reader, _ := NewReader(fakeResolver{client: client})
	service, _ := NewGRPCService(reader)
	service.watchRetryDelay = func(int) time.Duration { return 0 }
	ctx, cancel := context.WithCancel(context.Background())
	stream := newObjectTestStream(ctx)
	done := make(chan error, 1)
	go func() { done <- service.WatchObject(watchRequest("rv-start"), stream) }()
	stream.waitForCount(t, 1)
	if got := <-opened; got != "rv-start" {
		t.Fatalf("initial watch resource version = %q", got)
	}

	updated := pod.DeepCopy()
	updated.SetResourceVersion("rv-2")
	firstWatch.Modify(updated)
	stream.waitForCount(t, 2)
	firstWatch.Stop()
	select {
	case got := <-opened:
		if got != "rv-2" {
			t.Fatalf("resumed watch resource version = %q, want rv-2", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("object watch did not reconnect")
	}

	updatedAgain := pod.DeepCopy()
	updatedAgain.SetResourceVersion("rv-3")
	secondWatch.Modify(updatedAgain)
	stream.waitForCount(t, 3)
	cancel()
	if err := <-done; status.Code(err) != codes.Canceled {
		t.Fatalf("watch returned %v, want cancelled", err)
	}
	events := stream.snapshot()
	if len(events) != 3 || events[1].GetError() != nil || events[2].GetError() != nil ||
		events[2].GetObject().GetResourceVersion() != "rv-3" {
		t.Fatalf("reconnected events = %#v", events)
	}
}

func TestWatchObjectReanchorsWithFreshGetAfterGone(t *testing.T) {
	t.Parallel()
	pod := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "uid")
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), pod)
	firstWatch := watch.NewRaceFreeFake()
	secondWatch := watch.NewRaceFreeFake()
	opened := make(chan string, 2)
	var getMu sync.Mutex
	getCalls := 0
	client.PrependReactor("get", "pods", func(clienttesting.Action) (bool, runtime.Object, error) {
		getMu.Lock()
		defer getMu.Unlock()
		getCalls++
		if getCalls == 1 {
			return true, nil, apierrors.NewInternalError(errors.New("temporary GET failure"))
		}
		return false, nil, nil
	})
	var watchMu sync.Mutex
	watchCalls := 0
	client.PrependWatchReactor("pods", func(action clienttesting.Action) (bool, watch.Interface, error) {
		watchMu.Lock()
		defer watchMu.Unlock()
		watchCalls++
		opened <- action.(clienttesting.WatchAction).GetWatchRestrictions().ResourceVersion
		if watchCalls == 1 {
			return true, firstWatch, nil
		}
		return true, secondWatch, nil
	})
	reader, _ := NewReader(fakeResolver{client: client})
	service, _ := NewGRPCService(reader)
	service.watchRetryDelay = func(int) time.Duration { return 0 }
	ctx, cancel := context.WithCancel(context.Background())
	stream := newObjectTestStream(ctx)
	done := make(chan error, 1)
	go func() { done <- service.WatchObject(watchRequest("rv-old"), stream) }()
	stream.waitForCount(t, 1)
	if got := <-opened; got != "rv-old" {
		t.Fatalf("initial watch resource version = %q", got)
	}

	current := pod.DeepCopy()
	current.SetResourceVersion("rv-2")
	current.Object["status"] = map[string]any{"phase": "Running"}
	if _, err := client.Resource(schema.GroupVersionResource{
		Version: "v1", Resource: "pods",
	}).Namespace("ns").Update(ctx, current, metav1.UpdateOptions{}); err != nil {
		t.Fatal(err)
	}
	firstWatch.Error(&metav1.Status{
		Status: metav1.StatusFailure, Reason: metav1.StatusReasonExpired, Code: 410,
	})
	stream.waitForCount(t, 2)
	select {
	case got := <-opened:
		if got != "rv-2" {
			t.Fatalf("reanchored watch resource version = %q, want rv-2", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("object watch did not reanchor after 410 Gone")
	}
	events := stream.snapshot()
	if events[1].GetType() != kmgrv1.ObjectEventType_OBJECT_EVENT_TYPE_UPDATED ||
		events[1].GetObject().GetResourceVersion() != "rv-2" || events[1].GetError() != nil {
		t.Fatalf("410 reanchor event = %#v", events[1])
	}
	getMu.Lock()
	if getCalls != 2 {
		t.Fatalf("GET calls after transient reanchor failure = %d, want 2", getCalls)
	}
	getMu.Unlock()
	cancel()
	if err := <-done; status.Code(err) != codes.Canceled {
		t.Fatalf("watch returned %v, want cancelled", err)
	}
}

func TestWatchObjectStopsRetryingWhenSessionDisappears(t *testing.T) {
	t.Parallel()
	pod := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "uid")
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), pod)
	fakeWatch := watch.NewRaceFreeFake()
	client.PrependWatchReactor("pods", func(clienttesting.Action) (bool, watch.Interface, error) {
		return true, fakeWatch, nil
	})
	resolver := &disappearingObjectResolver{client: client, allowedCalls: 2}
	reader, _ := NewReader(resolver)
	service, _ := NewGRPCService(reader)
	service.watchRetryDelay = func(int) time.Duration { return 0 }
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	stream := newObjectTestStream(ctx)
	done := make(chan error, 1)
	go func() { done <- service.WatchObject(watchRequest("rv-1"), stream) }()
	stream.waitForCount(t, 1)
	fakeWatch.Stop()
	stream.waitForCount(t, 2)
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("watch returned transport error: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("watch kept retrying after its cluster session disappeared")
	}
	events := stream.snapshot()
	if events[1].GetError().GetReason() != "SessionNotFound" {
		t.Fatalf("session-loss event = %#v", events[1])
	}
	resolver.mu.Lock()
	defer resolver.mu.Unlock()
	if resolver.calls != 3 {
		t.Fatalf("resolver calls after session loss = %d, want 3", resolver.calls)
	}
}

func TestWatchObjectReturnsStreamSendFailureWithoutReopeningWatch(t *testing.T) {
	t.Parallel()
	pod := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "uid")
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), pod)
	fakeWatch := watch.NewRaceFreeFake()
	var watchMu sync.Mutex
	watchCalls := 0
	client.PrependWatchReactor("pods", func(clienttesting.Action) (bool, watch.Interface, error) {
		watchMu.Lock()
		watchCalls++
		watchMu.Unlock()
		return true, fakeWatch, nil
	})
	reader, _ := NewReader(fakeResolver{client: client})
	service, _ := NewGRPCService(reader)
	service.watchRetryDelay = func(int) time.Duration { return 0 }
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	streamFailure := errors.New("stream delivery failed")
	stream := newObjectTestStream(ctx)
	stream.sendErrorAt = 2
	stream.sendError = streamFailure
	done := make(chan error, 1)
	go func() { done <- service.WatchObject(watchRequest("rv-1"), stream) }()
	stream.waitForCount(t, 1)
	updated := pod.DeepCopy()
	updated.SetResourceVersion("rv-2")
	fakeWatch.Modify(updated)
	select {
	case err := <-done:
		if !errors.Is(err, streamFailure) {
			t.Fatalf("watch returned %v, want stream send failure", err)
		}
	case <-ctx.Done():
		t.Fatal("watch retried after its gRPC stream failed")
	}
	watchMu.Lock()
	defer watchMu.Unlock()
	if watchCalls != 1 {
		t.Fatalf("Kubernetes watch opened %d times after stream failure, want 1", watchCalls)
	}
}

func TestWatchObjectRejectsSameNameRecreationInStream(t *testing.T) {
	t.Parallel()
	pod := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "uid")
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), pod)
	fakeWatch := watch.NewRaceFreeFake()
	client.PrependWatchReactor("pods", func(clienttesting.Action) (bool, watch.Interface, error) {
		return true, fakeWatch, nil
	})
	reader, _ := NewReader(fakeResolver{client: client, contextName: "production"})
	service, _ := NewGRPCService(reader)
	stream := newObjectTestStream(context.Background())
	done := make(chan error, 1)
	go func() { done <- service.WatchObject(watchRequest("rv-1"), stream) }()
	stream.waitForCount(t, 1)
	recreated := pod.DeepCopy()
	recreated.SetUID("new-uid")
	fakeWatch.Modify(recreated)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	events := stream.snapshot()
	if len(events) != 2 || events[1].GetError().GetReason() != "ObjectRecreated" ||
		events[1].GetError().GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT ||
		events[1].GetError().GetContextName() != "production" {
		t.Fatalf("recreation event = %#v", events)
	}
}

func watchRequest(resourceVersion string) *kmgrv1.WatchObjectRequest {
	return &kmgrv1.WatchObjectRequest{
		Context: requestContext(), ObjectStreamId: "object-stream", Generation: 7,
		Identity: protoIdentity("pods", "pod", "uid"), ResourceVersion: resourceVersion,
	}
}

func requestContext() *kmgrv1.RequestContext {
	return &kmgrv1.RequestContext{RequestId: "request", ClusterSessionId: "session"}
}

func protoIdentity(resource, name, uid string) *kmgrv1.ResourceIdentity {
	return &kmgrv1.ResourceIdentity{
		ClusterSessionId: "session", Version: "v1", Resource: resource,
		Namespace: "ns", Name: name, Uid: uid,
	}
}

type objectTestStream struct {
	ctx         context.Context
	mu          sync.Mutex
	events      []*kmgrv1.ObjectEvent
	sendCount   int
	sendErrorAt int
	sendError   error
}

func newObjectTestStream(ctx context.Context) *objectTestStream {
	return &objectTestStream{ctx: ctx}
}

func (s *objectTestStream) Send(value *kmgrv1.ObjectEvent) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sendCount++
	if s.sendErrorAt != 0 && s.sendCount == s.sendErrorAt {
		return s.sendError
	}
	s.events = append(s.events, value)
	return nil
}

func (s *objectTestStream) SetHeader(metadata.MD) error  { return nil }
func (s *objectTestStream) SendHeader(metadata.MD) error { return nil }
func (s *objectTestStream) SetTrailer(metadata.MD)       {}
func (s *objectTestStream) Context() context.Context     { return s.ctx }
func (s *objectTestStream) SendMsg(any) error            { return errors.New("unexpected SendMsg") }
func (s *objectTestStream) RecvMsg(any) error            { return errors.New("unexpected RecvMsg") }

func (s *objectTestStream) snapshot() []*kmgrv1.ObjectEvent {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]*kmgrv1.ObjectEvent(nil), s.events...)
}

func (s *objectTestStream) waitForCount(t *testing.T, count int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if len(s.snapshot()) >= count {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("stream received %d events, want at least %d", len(s.snapshot()), count)
}

var _ grpc.ServerStreamingServer[kmgrv1.ObjectEvent] = (*objectTestStream)(nil)
var _ = apierrors.IsGone
var _ = schema.GroupVersionResource{}

type disappearingObjectResolver struct {
	mu           sync.Mutex
	client       dynamic.Interface
	calls        int
	allowedCalls int
}

func (r *disappearingObjectResolver) Resource(
	_ string,
	gvr schema.GroupVersionResource,
	namespace string,
) (dynamic.ResourceInterface, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls++
	if r.calls > r.allowedCalls {
		return nil, ErrSessionNotFound
	}
	resource := r.client.Resource(gvr)
	if namespace != "" {
		return resource.Namespace(namespace), nil
	}
	return resource, nil
}
