package operation

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/object"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/dynamic"
)

func TestDeleteManyAppliesExactUIDPreconditionsAndReturnsPartialFailures(t *testing.T) {
	t.Parallel()
	client := &recordingProvider{errors: map[string]error{"forbidden": fmt.Errorf("forbidden")}}
	gvr := schema.GroupVersionResource{Group: "apps", Version: "v1", Resource: "deployments"}
	targets := []DeleteTarget{
		{Identity: deleteIdentity(gvr, "team-a", "ok", "uid-ok")},
		{Identity: deleteIdentity(gvr, "team-b", "forbidden", "uid-forbidden")},
	}
	grace := int64(5)
	results := DeleteMany(context.Background(), client, targets, DeleteOptions{
		PropagationPolicy:  metav1.DeletePropagationForeground,
		GracePeriodSeconds: &grace,
		MaxConcurrency:     2,
	})
	if len(results) != 2 || results[0].Err != nil || results[1].Err == nil {
		t.Fatalf("results = %#v", results)
	}
	client.mu.Lock()
	defer client.mu.Unlock()
	if len(client.calls) != 2 {
		t.Fatalf("delete calls = %#v", client.calls)
	}
	for _, call := range client.calls {
		if call.options.Preconditions == nil || call.options.Preconditions.UID == nil {
			t.Fatalf("call has no UID precondition: %#v", call)
		}
		wantUID := types.UID("uid-" + call.name)
		if *call.options.Preconditions.UID != wantUID {
			t.Fatalf("precondition = %q, want %q", *call.options.Preconditions.UID, wantUID)
		}
		if call.options.PropagationPolicy == nil || *call.options.PropagationPolicy != metav1.DeletePropagationForeground {
			t.Fatalf("propagation = %#v", call.options.PropagationPolicy)
		}
		if call.options.GracePeriodSeconds == nil || *call.options.GracePeriodSeconds != 5 {
			t.Fatalf("grace period = %#v", call.options.GracePeriodSeconds)
		}
	}
}

func TestDeleteManyRejectsMissingUIDWithoutCallingAPI(t *testing.T) {
	t.Parallel()
	client := &recordingProvider{}
	results := DeleteMany(context.Background(), client, []DeleteTarget{{
		Identity: deleteIdentity(schema.GroupVersionResource{Version: "v1", Resource: "pods"}, "", "replacement-risk", ""),
	}}, DeleteOptions{PropagationPolicy: metav1.DeletePropagationBackground})
	if len(results) != 1 || results[0].Err == nil {
		t.Fatalf("results = %#v", results)
	}
	if len(client.calls) != 0 {
		t.Fatal("API was called without UID precondition")
	}
}

func TestDeleteManyBoundsConcurrency(t *testing.T) {
	t.Parallel()
	client := &recordingProvider{block: make(chan struct{})}
	gvr := schema.GroupVersionResource{Version: "v1", Resource: "pods"}
	targets := make([]DeleteTarget, 10)
	for index := range targets {
		targets[index] = DeleteTarget{Identity: deleteIdentity(gvr, "", fmt.Sprintf("pod-%d", index), fmt.Sprintf("uid-%d", index))}
	}
	done := make(chan []DeleteResult, 1)
	go func() {
		done <- DeleteMany(context.Background(), client, targets, DeleteOptions{
			PropagationPolicy: metav1.DeletePropagationBackground, MaxConcurrency: 3,
		})
	}()
	eventuallyDelete(t, func() bool { return client.peak.Load() == 3 }, "three concurrent delete calls")
	if peak := client.peak.Load(); peak > 3 {
		t.Fatalf("peak concurrency = %d", peak)
	}
	close(client.block)
	<-done
}

func TestDeleteManyCancellationSkipsPendingTargets(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	client := &recordingProvider{started: make(chan struct{}, 1), block: make(chan struct{})}
	gvr := schema.GroupVersionResource{Version: "v1", Resource: "pods"}
	targets := []DeleteTarget{
		{Identity: deleteIdentity(gvr, "", "first", "one")},
		{Identity: deleteIdentity(gvr, "", "second", "two")},
		{Identity: deleteIdentity(gvr, "", "third", "three")},
	}
	done := make(chan []DeleteResult, 1)
	go func() {
		done <- DeleteMany(ctx, client, targets, DeleteOptions{
			PropagationPolicy: metav1.DeletePropagationBackground, MaxConcurrency: 1,
		})
	}()
	<-client.started
	cancel()
	close(client.block)
	results := <-done
	if results[1].Err == nil || results[2].Err == nil {
		t.Fatalf("pending results were not cancelled: %#v", results)
	}
	client.mu.Lock()
	defer client.mu.Unlock()
	if len(client.calls) != 1 {
		t.Fatalf("calls = %d, want 1 already-started request", len(client.calls))
	}
}

func TestDeleteManyRejectedRunningClaimSkipsKubernetesRequest(t *testing.T) {
	t.Parallel()
	client := &recordingProvider{}
	gvr := schema.GroupVersionResource{Version: "v1", Resource: "pods"}
	targets := []DeleteTarget{
		{Identity: deleteIdentity(gvr, "", "first", "one")},
		{Identity: deleteIdentity(gvr, "", "queued", "two")},
	}
	results := DeleteManyWithProgress(
		context.Background(), client, targets,
		DeleteOptions{PropagationPolicy: metav1.DeletePropagationBackground, MaxConcurrency: 1},
		func(index int, state ItemState, _ DeleteResult) bool {
			return state != ItemStateRunning || index == 0
		},
	)
	if results[0].Err != nil || !errors.Is(results[1].Err, context.Canceled) {
		t.Fatalf("results = %#v", results)
	}
	client.mu.Lock()
	defer client.mu.Unlock()
	if len(client.calls) != 1 || client.calls[0].name != "first" {
		t.Fatalf("calls = %#v, want only first", client.calls)
	}
}

func TestDeleteManyDeadlineCancelsKubernetesAndQueuedTargets(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	client := &recordingProvider{started: make(chan struct{}, 1), block: make(chan struct{})}
	defer close(client.block)
	gvr := schema.GroupVersionResource{Version: "v1", Resource: "pods"}
	targets := []DeleteTarget{
		{Identity: deleteIdentity(gvr, "", "running", "one")},
		{Identity: deleteIdentity(gvr, "", "queued", "two")},
		{Identity: deleteIdentity(gvr, "", "also-queued", "three")},
	}
	done := make(chan []DeleteResult, 1)
	go func() {
		done <- DeleteMany(ctx, client, targets, DeleteOptions{
			PropagationPolicy: metav1.DeletePropagationBackground, MaxConcurrency: 1,
		})
	}()
	<-client.started
	var results []DeleteResult
	select {
	case results = <-done:
	case <-time.After(time.Second):
		t.Fatal("delete did not stop at its deadline")
	}
	for index, result := range results {
		if !errors.Is(result.Err, context.DeadlineExceeded) {
			t.Fatalf("result %d error = %v, want deadline exceeded", index, result.Err)
		}
	}
	client.mu.Lock()
	defer client.mu.Unlock()
	if len(client.calls) != 1 || client.calls[0].name != "running" {
		t.Fatalf("calls = %#v, want only running target", client.calls)
	}
}

type deleteCall struct {
	namespace string
	name      string
	options   metav1.DeleteOptions
}

type recordingProvider struct {
	mu      sync.Mutex
	calls   []deleteCall
	errors  map[string]error
	block   chan struct{}
	started chan struct{}
	active  atomic.Int32
	peak    atomic.Int32
}

func (p *recordingProvider) Resource(identity object.Identity) (dynamic.ResourceInterface, error) {
	return &recordingResource{provider: p, namespace: identity.Namespace}, nil
}

type recordingResource struct {
	provider  *recordingProvider
	namespace string
}

func (r *recordingResource) Namespace(namespace string) dynamic.ResourceInterface {
	return &recordingResource{provider: r.provider, namespace: namespace}
}

func (r *recordingResource) Delete(ctx context.Context, name string, options metav1.DeleteOptions, subresources ...string) error {
	active := r.provider.active.Add(1)
	defer r.provider.active.Add(-1)
	for {
		peak := r.provider.peak.Load()
		if active <= peak || r.provider.peak.CompareAndSwap(peak, active) {
			break
		}
	}
	r.provider.mu.Lock()
	r.provider.calls = append(r.provider.calls, deleteCall{namespace: r.namespace, name: name, options: options})
	err := r.provider.errors[name]
	r.provider.mu.Unlock()
	if r.provider.started != nil {
		select {
		case r.provider.started <- struct{}{}:
		default:
		}
	}
	if r.provider.block != nil {
		select {
		case <-r.provider.block:
		case <-ctx.Done():
			return context.Cause(ctx)
		}
	}
	return err
}

func (*recordingResource) Create(context.Context, *unstructured.Unstructured, metav1.CreateOptions, ...string) (*unstructured.Unstructured, error) {
	panic("unexpected Create")
}
func (*recordingResource) Update(context.Context, *unstructured.Unstructured, metav1.UpdateOptions, ...string) (*unstructured.Unstructured, error) {
	panic("unexpected Update")
}
func (*recordingResource) UpdateStatus(context.Context, *unstructured.Unstructured, metav1.UpdateOptions) (*unstructured.Unstructured, error) {
	panic("unexpected UpdateStatus")
}
func (*recordingResource) DeleteCollection(context.Context, metav1.DeleteOptions, metav1.ListOptions) error {
	panic("unexpected DeleteCollection")
}
func (*recordingResource) Get(context.Context, string, metav1.GetOptions, ...string) (*unstructured.Unstructured, error) {
	panic("unexpected Get")
}
func (*recordingResource) List(context.Context, metav1.ListOptions) (*unstructured.UnstructuredList, error) {
	panic("unexpected List")
}
func (*recordingResource) Watch(context.Context, metav1.ListOptions) (watch.Interface, error) {
	panic("unexpected Watch")
}
func (*recordingResource) Patch(context.Context, string, types.PatchType, []byte, metav1.PatchOptions, ...string) (*unstructured.Unstructured, error) {
	panic("unexpected Patch")
}
func (*recordingResource) Apply(context.Context, string, *unstructured.Unstructured, metav1.ApplyOptions, ...string) (*unstructured.Unstructured, error) {
	panic("unexpected Apply")
}
func (*recordingResource) ApplyStatus(context.Context, string, *unstructured.Unstructured, metav1.ApplyOptions) (*unstructured.Unstructured, error) {
	panic("unexpected ApplyStatus")
}

func eventuallyDelete(t *testing.T, condition func() bool, description string) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", description)
		}
		time.Sleep(time.Millisecond)
	}
}

var _ dynamic.NamespaceableResourceInterface = (*recordingResource)(nil)

func deleteIdentity(gvr schema.GroupVersionResource, namespace, name, uid string) object.Identity {
	return object.Identity{
		SessionID: "session", Group: gvr.Group, Version: gvr.Version, Resource: gvr.Resource,
		Namespace: namespace, Name: name, UID: uid,
	}
}
