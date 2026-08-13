package object

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
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

func TestWatchObjectRejectsSameNameRecreationInStream(t *testing.T) {
	t.Parallel()
	pod := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "uid")
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), pod)
	fakeWatch := watch.NewRaceFreeFake()
	client.PrependWatchReactor("pods", func(clienttesting.Action) (bool, watch.Interface, error) {
		return true, fakeWatch, nil
	})
	reader, _ := NewReader(fakeResolver{client: client})
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
		events[1].GetError().GetCategory() != kmgrv1.ErrorCategory_ERROR_CATEGORY_CONFLICT {
		t.Fatalf("recreation event = %#v", events)
	}
}

func TestGetEventsFiltersMapsSortsAndClampsLimit(t *testing.T) {
	t.Parallel()
	pod := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "pod-uid")
	early := eventObject("early", "event-early", "pod-uid", time.Unix(10, 0), time.Unix(20, 0))
	late := eventObject("late", "event-late", "pod-uid", time.Unix(11, 0), time.Unix(30, 0))
	other := eventObject("other", "event-other", "other-uid", time.Unix(12, 0), time.Unix(40, 0))
	scheme := runtime.NewScheme()
	if err := corev1.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	client := dynamicfake.NewSimpleDynamicClient(scheme, pod, early, late, other)
	var listRestrictions clienttesting.ListRestrictions
	client.PrependReactor("list", "events", func(action clienttesting.Action) (bool, runtime.Object, error) {
		listRestrictions = action.(clienttesting.ListAction).GetListRestrictions()
		// Let the fake tracker return all values to verify the defensive UID filter.
		return false, nil, nil
	})
	reader, _ := NewReader(fakeResolver{client: client})
	service, _ := NewGRPCService(reader)
	request := &kmgrv1.GetEventsRequest{
		Context: requestContext(), Identity: protoIdentity("pods", "pod", "pod-uid"), Limit: MaximumEventLimit + 1,
	}
	response, err := service.GetEvents(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if response.GetError() != nil || len(response.GetEvents()) != 2 {
		t.Fatalf("events response = %#v", response)
	}
	if listRestrictions.Fields.String() != "involvedObject.uid=pod-uid" {
		t.Fatalf("event selector = %q", listRestrictions.Fields.String())
	}
	if response.GetEvents()[0].GetIdentity().GetName() != "late" ||
		response.GetEvents()[0].GetLastObservedUnixMs() != 30_000 ||
		response.GetEvents()[0].GetCount() != 7 ||
		response.GetEvents()[0].GetReportingController() != "example/controller" ||
		response.GetEvents()[1].GetIdentity().GetName() != "early" {
		t.Fatalf("mapped events = %#v", response.GetEvents())
	}
	listActions := 0
	for _, action := range client.Actions() {
		if action.Matches("list", "events") {
			listActions++
			restrictions := action.(clienttesting.ListAction).GetListRestrictions()
			if restrictions.Fields.String() != "involvedObject.uid=pod-uid" {
				t.Errorf("recorded selector = %q", restrictions.Fields.String())
			}
		}
	}
	if listActions != 1 {
		t.Fatalf("list event actions = %d", listActions)
	}
}

func TestGetEventsRejectsRecreatedTargetBeforeListing(t *testing.T) {
	t.Parallel()
	pod := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "new-uid")
	reader := testReader(t, pod)
	service, _ := NewGRPCService(reader)
	response, err := service.GetEvents(context.Background(), &kmgrv1.GetEventsRequest{
		Context: requestContext(), Identity: protoIdentity("pods", "pod", "old-uid"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if response.GetError().GetReason() != "ObjectRecreated" {
		t.Fatalf("structured error = %#v", response.GetError())
	}
}

func eventObject(name, uid, involvedUID string, first, last time.Time) *corev1.Event {
	return &corev1.Event{
		TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Event"},
		ObjectMeta: metav1.ObjectMeta{
			Namespace: "ns", Name: name, UID: types.UID(uid), ResourceVersion: "rv-" + name,
		},
		InvolvedObject: corev1.ObjectReference{UID: types.UID(involvedUID)},
		Type:           "Warning", Reason: "Example", Message: "safe message",
		FirstTimestamp: metav1.NewTime(first), LastTimestamp: metav1.NewTime(last),
		Count: 3, Series: &corev1.EventSeries{Count: 7, LastObservedTime: metav1.NewMicroTime(last)},
		ReportingController: "example/controller",
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
	ctx    context.Context
	mu     sync.Mutex
	events []*kmgrv1.ObjectEvent
}

func newObjectTestStream(ctx context.Context) *objectTestStream {
	return &objectTestStream{ctx: ctx}
}

func (s *objectTestStream) Send(value *kmgrv1.ObjectEvent) error {
	s.mu.Lock()
	s.events = append(s.events, value)
	s.mu.Unlock()
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
