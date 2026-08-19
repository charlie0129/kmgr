package object

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	metricsapi "k8s.io/metrics/pkg/apis/metrics/v1beta1"
)

// PodContainerMetricsProvider is the optional enrichment seam for the
// explicit Pod container table. The object is the same fresh, UID-validated
// Pod used to form the base detail; providers must never fetch a replacement
// object by namespace/name.
type PodContainerMetricsProvider interface {
	ContainerMetrics(
		ctx context.Context,
		identity Identity,
		object *unstructured.Unstructured,
	) (map[string][]*kmgrv1.ResourceUsageValue, error)
}

// PodMetricsDetailResolver is the shared authority cache seam used by the
// explicit Pod container table. Implementations must pin the lookup to the
// supplied base-Pod UID and coalesce it with viewport metric requests.
type PodMetricsDetailResolver interface {
	ResolvePodMetricsDetail(
		ctx context.Context,
		sessionID string,
		reference metrics.PodReference,
	) (*metricsapi.PodMetrics, error)
}

// KubernetesPodContainerMetricsProvider resolves exact Pod samples through
// the authority-owned cache shared with viewport metrics. It performs no I/O
// until the explicit Pod container table requests enrichment.
type KubernetesPodContainerMetricsProvider struct {
	podMetrics PodMetricsDetailResolver
}

func NewKubernetesPodContainerMetricsProvider(
	podMetrics PodMetricsDetailResolver,
) (*KubernetesPodContainerMetricsProvider, error) {
	if podMetrics == nil {
		return nil, errors.New("Pod metrics detail resolver must not be nil")
	}
	return &KubernetesPodContainerMetricsProvider{podMetrics: podMetrics}, nil
}

func (p *KubernetesPodContainerMetricsProvider) ContainerMetrics(
	ctx context.Context,
	identity Identity,
	object *unstructured.Unstructured,
) (map[string][]*kmgrv1.ResourceUsageValue, error) {
	if p == nil || p.podMetrics == nil {
		return nil, errors.New("Pod container metrics provider is unavailable")
	}
	if err := validateObjectUID(object, identity); err != nil {
		return nil, err
	}
	if identity.Group != "" || identity.Version != "v1" || identity.Resource != "pods" {
		return nil, nil
	}

	var pod corev1.Pod
	if err := runtime.DefaultUnstructuredConverter.FromUnstructured(object.Object, &pod); err != nil {
		return nil, fmt.Errorf("decode Pod for container resource accounting: %w", err)
	}
	accounting := podContainerResourceUsage(&pod, nil)

	value, err := p.podMetrics.ResolvePodMetricsDetail(ctx, identity.SessionID, metrics.PodReference{
		Namespace: identity.Namespace, Name: identity.Name, UID: types.UID(identity.UID),
	})
	if err != nil {
		return accounting, err
	}
	if value == nil {
		return accounting, nil
	}
	if err := validateMetricsUID(value.GetUID(), identity); err != nil {
		return accounting, err
	}
	return podContainerResourceUsage(&pod, value), nil
}

func validateMetricsUID(actual types.UID, identity Identity) error {
	// Some Metrics API implementations omit UID. If supplied, it must remain
	// pinned to the same object as the authoritative core API GET.
	if actual == "" || string(actual) == identity.UID {
		return nil
	}
	return &IdentityChangedError{
		ExpectedUID: identity.UID, ActualUID: string(actual),
		Namespace: identity.Namespace, Name: identity.Name,
	}
}

func podContainerResourceUsage(
	pod *corev1.Pod,
	value *metricsapi.PodMetrics,
) map[string][]*kmgrv1.ResourceUsageValue {
	if pod == nil {
		return nil
	}
	usageByName := make(map[string]corev1.ResourceList)
	if value != nil {
		for _, container := range value.Containers {
			usage := usageByName[container.Name]
			if usage == nil {
				usage = make(corev1.ResourceList)
				usageByName[container.Name] = usage
			}
			addQuantities(usage, container.Usage)
		}
	}

	type declaredResources struct {
		name      string
		resources corev1.ResourceRequirements
	}
	declared := make([]declaredResources, 0,
		len(pod.Spec.Containers)+len(pod.Spec.InitContainers)+len(pod.Spec.EphemeralContainers))
	for _, container := range pod.Spec.Containers {
		declared = append(declared, declaredResources{container.Name, container.Resources})
	}
	for _, container := range pod.Spec.InitContainers {
		declared = append(declared, declaredResources{container.Name, container.Resources})
	}
	for _, container := range pod.Spec.EphemeralContainers {
		declared = append(declared, declaredResources{container.Name, container.Resources})
	}

	result := make(map[string][]*kmgrv1.ResourceUsageValue, len(declared))
	for _, container := range declared {
		if _, duplicate := result[container.name]; duplicate {
			continue
		}
		result[container.name] = resourceUsageValues(
			usageByName[container.name],
			container.resources.Requests,
			container.resources.Limits,
			metrics.MetricsAPIGroupVersion,
			"container "+container.name,
			metricsTimestamp(value),
		)
	}
	return result
}

func metricsTimestamp(value *metricsapi.PodMetrics) int64 {
	if value != nil && !value.Timestamp.IsZero() {
		return value.Timestamp.UnixMilli()
	}
	return 0
}

func resourceUsageValues(
	usage, requests, limits corev1.ResourceList,
	provider, scope string,
	measuredAt int64,
) []*kmgrv1.ResourceUsageValue {
	names := map[corev1.ResourceName]struct{}{
		corev1.ResourceCPU:    {},
		corev1.ResourceMemory: {},
	}
	for _, values := range []corev1.ResourceList{usage, requests, limits} {
		for name := range values {
			names[name] = struct{}{}
		}
	}
	ordered := make([]corev1.ResourceName, 0, len(names))
	for name := range names {
		ordered = append(ordered, name)
	}
	slices.SortFunc(ordered, func(left, right corev1.ResourceName) int {
		return strings.Compare(string(left), string(right))
	})

	result := make([]*kmgrv1.ResourceUsageValue, 0, len(ordered))
	for _, name := range ordered {
		item := &kmgrv1.ResourceUsageValue{
			ResourceName: string(name), Unit: detailResourceUnit(name),
		}
		if quantity, found := usage[name]; found {
			item.Used = detailQuantityNumeric(quantity)
			item.UsageAvailable = true
			item.MeasuredAtUnixMs = measuredAt
			item.Provider = provider
			item.MeasurementScope = scope
		}
		if quantity, found := requests[name]; found {
			item.Requested = detailNumberPointer(detailQuantityNumeric(quantity))
		}
		if quantity, found := limits[name]; found {
			item.Limit = detailNumberPointer(detailQuantityNumeric(quantity))
		}
		setDetailUsageSortValue(item)
		result = append(result, item)
	}
	return result
}

func addQuantities(total, values corev1.ResourceList) {
	for name, quantity := range values {
		current, found := total[name]
		if !found {
			total[name] = quantity.DeepCopy()
			continue
		}
		current.Add(quantity)
		total[name] = current
	}
}

func detailResourceUnit(name corev1.ResourceName) string {
	if name == corev1.ResourceCPU {
		return "cores"
	}
	if name == corev1.ResourceMemory || name == corev1.ResourceEphemeralStorage ||
		strings.HasPrefix(string(name), corev1.ResourceHugePagesPrefix) {
		return "bytes"
	}
	return "count"
}

func detailQuantityNumeric(quantity resource.Quantity) float64 {
	if quantity.IsZero() {
		return 0
	}
	return quantity.AsApproximateFloat64()
}

func detailNumberPointer(value float64) *float64 { return &value }

func setDetailUsageSortValue(value *kmgrv1.ResourceUsageValue) {
	if value == nil {
		return
	}
	value.SortValue = nil
	switch {
	case value.GetUsageAvailable():
		value.SortValue = detailNumberPointer(value.GetUsed())
	case value.Requested != nil:
		value.SortValue = detailNumberPointer(value.GetRequested())
	case value.Limit != nil:
		value.SortValue = detailNumberPointer(value.GetLimit())
	}
}
