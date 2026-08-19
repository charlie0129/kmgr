package view

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	k8swatch "k8s.io/apimachinery/pkg/watch"
)

func TestRuntimeColdEmptyPodStreamHintsUseRevisionStableInvalidation(t *testing.T) {
	tests := []struct {
		name   string
		filter string
	}{
		{name: "visible Pod"},
		{name: "filter-hidden Pod", filter: "name:no-match"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			client := newScriptedResource()
			client.listPages = []*unstructured.UnstructuredList{listPage("rv-1", "")}
			runtime, err := NewRuntime(RuntimeConfig{
				Source:       &fakeResourceSource{authority: "cluster-a", client: client},
				ReleaseDelay: time.Hour, BatchDelay: time.Millisecond, PipelineTimeout: time.Second,
			})
			if err != nil {
				t.Fatal(err)
			}
			defer runtime.Close()

			request := openView("session", "view", 1)
			request.Spec.FilterExpression = test.filter
			subscription, err := runtime.Open(request)
			if err != nil {
				t.Fatal(err)
			}
			defer subscription.Close()
			initial := drainSubscription(t, subscription)
			invalidation := firstInvalidation(initial)
			if invalidation == nil || invalidation.GetRowsVisible() != 0 ||
				invalidation.GetPresentationRevision() == 0 || invalidation.GetIndexRevision() == 0 {
				t.Fatalf("initial delivery omitted nonzero empty invalidation: %#v", initial)
			}
			if len(invalidation.GetObservedOptionalResourceKeys()) != 0 ||
				invalidation.GetObservedOptionalResourceKeysTruncated() {
				t.Fatalf("cold-empty invalidation invented optional hints: %#v", invalidation)
			}
			eventually(t, time.Second, func() bool { return client.watchCalls.Load() == 1 })

			live := pod("uid-live", "ns", "live", "Running", 0, nil, time.Time{})
			live.SetResourceVersion("2")
			if err := unstructured.SetNestedSlice(live.Object, []any{map[string]any{
				"name": "main",
				"resources": map[string]any{
					"requests": map[string]any{"hugepages-2Mi": "4Mi"},
				},
			}}, "spec", "containers"); err != nil {
				t.Fatal(err)
			}
			client.lastWatch().channel <- k8swatch.Event{Type: k8swatch.Added, Object: live}
			first := waitForOptionalResourceHint(t, subscription, "hugepages-2Mi")
			firstRevision := first.GetPresentationRevision()
			firstIndexRevision := first.GetIndexRevision()
			if test.filter == "" {
				if first.GetRowsVisible() != 1 || firstRevision <= invalidation.GetPresentationRevision() ||
					firstIndexRevision <= invalidation.GetIndexRevision() {
					t.Fatalf("visible Pod did not advance expected revisions: %#v", first)
				}
			} else if firstRevision != invalidation.GetPresentationRevision() ||
				firstIndexRevision != invalidation.GetIndexRevision() {
				t.Fatalf("filter-hidden hint changed presentation revisions: %#v", first)
			}

			// A later raw update repeats the advisory key. An identical projected
			// row is a hint-only invalidation and preserves both revisions.
			updated := live.DeepCopy()
			updated.SetResourceVersion("3")
			client.lastWatch().channel <- k8swatch.Event{Type: k8swatch.Modified, Object: updated}
			second := waitForOptionalResourceHint(t, subscription, "hugepages-2Mi")
			if second.GetPresentationRevision() != firstRevision || second.GetIndexRevision() != firstIndexRevision {
				t.Fatalf("hint-only invalidation advanced revisions: first=%#v second=%#v", first, second)
			}
		})
	}
}

func waitForOptionalResourceHint(
	t *testing.T,
	subscription *Subscription,
	key string,
) *kmgrv1.ViewInvalidation {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		events, err := subscription.Next(ctx)
		cancel()
		if err != nil {
			if errors.Is(err, context.DeadlineExceeded) {
				continue
			}
			t.Fatal(err)
		}
		if err := subscription.AcknowledgeDelivery(events); err != nil {
			t.Fatal(err)
		}
		for _, event := range events {
			invalidation := event.GetInvalidation()
			if invalidation == nil {
				continue
			}
			keys := invalidation.GetObservedOptionalResourceKeys()
			if slices.Contains(keys, key) {
				if !slices.IsSorted(keys) {
					t.Fatalf("optional resource hints are not sorted: %q", keys)
				}
				return invalidation
			}
		}
	}
	t.Fatalf("never observed optional resource hint %q", key)
	return nil
}

func firstInvalidation(events []*kmgrv1.ViewEvent) *kmgrv1.ViewInvalidation {
	for _, event := range events {
		if invalidation := event.GetInvalidation(); invalidation != nil {
			return invalidation
		}
	}
	return nil
}
