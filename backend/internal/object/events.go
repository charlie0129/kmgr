package object

import (
	"context"
	"sort"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

const (
	DefaultEventLimit        uint32 = 100
	MaximumEventLimit        uint32 = 500
	maximumEventReasonBytes         = 128
	maximumEventMessageBytes        = 4 * 1024
)

type KubernetesEvent struct {
	Identity            Identity
	Type                string
	Reason              string
	Message             string
	FirstObserved       time.Time
	LastObserved        time.Time
	Count               int32
	ReportingController string
}

func NormalizeEventLimit(limit uint32) uint32 {
	if limit == 0 {
		return DefaultEventLimit
	}
	if limit > MaximumEventLimit {
		return MaximumEventLimit
	}
	return limit
}

// Events performs a fresh target GET before reading core/v1 Events. This keeps
// a stale detail page from silently loading data for a same-name recreation.
func (r *Reader) Events(ctx context.Context, identity Identity, limit uint32) ([]KubernetesEvent, error) {
	if _, err := r.Get(ctx, identity); err != nil {
		return nil, err
	}
	resource, err := r.resolver.Resource(
		identity.SessionID,
		schema.GroupVersionResource{Version: "v1", Resource: "events"},
		identity.Namespace,
	)
	if err != nil {
		return nil, err
	}
	limit = NormalizeEventLimit(limit)
	list, err := resource.List(ctx, metav1.ListOptions{
		FieldSelector: fields.OneTermEqualSelector("involvedObject.uid", identity.UID).String(),
		Limit:         int64(limit),
	})
	if err != nil {
		return nil, err
	}
	result := make([]KubernetesEvent, 0, min(len(list.Items), int(limit)))
	for index := range list.Items {
		var event corev1.Event
		if err := runtime.DefaultUnstructuredConverter.FromUnstructured(list.Items[index].Object, &event); err != nil {
			return nil, err
		}
		// Fake clients and unusual API proxies may not enforce the field
		// selector. Never return an event belonging to another object.
		if string(event.InvolvedObject.UID) != identity.UID {
			continue
		}
		result = append(result, kubernetesEvent(identity.SessionID, event))
	}
	sort.Slice(result, func(i, j int) bool {
		left, right := result[i], result[j]
		if !left.LastObserved.Equal(right.LastObserved) {
			return left.LastObserved.After(right.LastObserved)
		}
		if !left.FirstObserved.Equal(right.FirstObserved) {
			return left.FirstObserved.After(right.FirstObserved)
		}
		if left.Identity.Namespace != right.Identity.Namespace {
			return left.Identity.Namespace < right.Identity.Namespace
		}
		if left.Identity.Name != right.Identity.Name {
			return left.Identity.Name < right.Identity.Name
		}
		return left.Identity.UID < right.Identity.UID
	})
	if len(result) > int(limit) {
		result = result[:limit]
	}
	return result, nil
}

func kubernetesEvent(sessionID string, value corev1.Event) KubernetesEvent {
	first := value.FirstTimestamp.Time
	if first.IsZero() {
		first = value.EventTime.Time
	}
	if first.IsZero() {
		first = value.CreationTimestamp.Time
	}
	last := time.Time{}
	if value.Series != nil {
		last = value.Series.LastObservedTime.Time
	}
	if last.IsZero() {
		last = value.LastTimestamp.Time
	}
	if last.IsZero() {
		last = value.EventTime.Time
	}
	if last.IsZero() {
		last = first
	}
	count := value.Count
	if value.Series != nil && value.Series.Count > count {
		count = value.Series.Count
	}
	reporter := value.ReportingController
	if reporter == "" {
		reporter = value.Source.Component
	}
	return KubernetesEvent{
		Identity: Identity{
			SessionID: sessionID, Version: "v1", Resource: "events",
			Namespace: value.Namespace, Name: value.Name, UID: string(value.UID),
		},
		Type: value.Type,
		// Legacy core/v1 Events do not consistently enforce the newer Events
		// API's display-string limits. Normalize and byte-bound untrusted text
		// before it reaches protobuf or AppKit table/tool-tip storage.
		Reason:        boundedNormalizedText(value.Reason, maximumEventReasonBytes),
		Message:       boundedNormalizedText(value.Message, maximumEventMessageBytes),
		FirstObserved: first, LastObserved: last, Count: count,
		ReportingController: reporter,
	}
}
