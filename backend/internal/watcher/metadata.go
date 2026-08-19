package watcher

import (
	"context"
	"errors"
	"fmt"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/metadata"
	clientwatchlist "k8s.io/client-go/util/watchlist"
)

// partialMetadataListerWatcher adapts client-go's typed metadata client to the
// unstructured read-only stream consumed by Pipeline. The conversion preserves
// ObjectMeta while ensuring fallback objects can never retain spec or status.
type partialMetadataListerWatcher struct {
	client metadata.ResourceInterface
}

var _ ListerWatcher = partialMetadataListerWatcher{}
var _ WatchListSemantics = partialMetadataListerWatcher{}

func (l partialMetadataListerWatcher) SupportsWatchListSemantics() bool {
	return l.client != nil && !clientwatchlist.DoesClientNotSupportWatchListSemantics(l.client)
}

// IsWatchListSemanticsUnSupported preserves client-go's negative capability
// marker through this adapter for callers that inspect it directly.
func (l partialMetadataListerWatcher) IsWatchListSemanticsUnSupported() bool {
	return !l.SupportsWatchListSemantics()
}

func (l partialMetadataListerWatcher) List(
	ctx context.Context,
	options metav1.ListOptions,
) (*unstructured.UnstructuredList, error) {
	if l.client == nil {
		return nil, errors.New("metadata fallback client is unavailable")
	}
	page, err := l.client.List(ctx, options)
	if err != nil {
		return nil, err
	}
	if page == nil {
		return nil, errors.New("server returned a nil metadata fallback list")
	}
	result := &unstructured.UnstructuredList{
		Items: make([]unstructured.Unstructured, len(page.Items)),
	}
	result.SetResourceVersion(page.GetResourceVersion())
	result.SetContinue(page.GetContinue())
	result.SetRemainingItemCount(page.GetRemainingItemCount())
	for index := range page.Items {
		object, err := partialMetadataObject(&page.Items[index])
		if err != nil {
			return nil, fmt.Errorf("convert metadata fallback list item %d: %w", index, err)
		}
		result.Items[index] = *object
	}
	return result, nil
}

func (l partialMetadataListerWatcher) Watch(
	ctx context.Context,
	options metav1.ListOptions,
) (watch.Interface, error) {
	if l.client == nil {
		return nil, errors.New("metadata fallback client is unavailable")
	}
	stream, err := l.client.Watch(ctx, options)
	if err != nil {
		return nil, err
	}
	if stream == nil {
		return nil, errors.New("server returned a nil metadata fallback watch")
	}
	return watch.Filter(stream, func(event watch.Event) (watch.Event, bool) {
		if event.Type == watch.Error {
			return event, true
		}
		value, ok := event.Object.(*metav1.PartialObjectMetadata)
		if !ok || value == nil {
			return metadataConversionError(event.Type, event.Object), true
		}
		object, err := partialMetadataObject(value)
		if err != nil {
			return metadataConversionError(event.Type, err), true
		}
		event.Object = object
		return event, true
	}), nil
}

func partialMetadataObject(value *metav1.PartialObjectMetadata) (*unstructured.Unstructured, error) {
	if value == nil {
		return nil, errors.New("nil PartialObjectMetadata")
	}
	content, err := runtime.DefaultUnstructuredConverter.ToUnstructured(value)
	if err != nil {
		return nil, err
	}
	// The typed source is the boundary that guarantees no full-object fields
	// can enter this fallback even if a caller later adds an object projection.
	delete(content, "spec")
	delete(content, "status")
	return &unstructured.Unstructured{Object: content}, nil
}

func metadataConversionError(eventType watch.EventType, value any) watch.Event {
	return watch.Event{Type: watch.Error, Object: &metav1.Status{
		Status: metav1.StatusFailure,
		Reason: metav1.StatusReasonInternalError,
		Code:   500,
		Message: fmt.Sprintf(
			"convert metadata fallback %s event object of type %T", eventType, value,
		),
	}}
}
