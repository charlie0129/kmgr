package object

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/metrics"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	metricsapi "k8s.io/metrics/pkg/apis/metrics/v1beta1"
	metricsclient "k8s.io/metrics/pkg/client/clientset/versioned/typed/metrics/v1beta1"
)

// DetailMetricsProvider is the optional enrichment seam for GetObject. The
// object is the same fresh, UID-validated object used to form the base detail;
// providers must never fetch a replacement object by namespace/name.
type DetailMetrics struct {
	Resources          []*kmgrv1.ResourceUsageValue
	ContainerResources map[string][]*kmgrv1.ResourceUsageValue
}

type DetailMetricsProvider interface {
	Metrics(
		ctx context.Context,
		identity Identity,
		object *unstructured.Unstructured,
	) (DetailMetrics, error)
}

type detailMetricsClientResolver interface {
	CachedMetricsAPIAvailability(sessionID string) (available, known bool, err error)
	MetricsClient(sessionID string) (metricsclient.MetricsV1beta1Interface, error)
}

// KubernetesDetailMetricsProvider reads the optional Metrics API through a
// client derived from the selected authoritative cluster session. It performs
// no I/O until Metrics is called for a Pod or Node detail request.
type KubernetesDetailMetricsProvider struct {
	clients detailMetricsClientResolver
}

func NewKubernetesDetailMetricsProvider(
	sessions *cluster.SessionRegistry,
) (*KubernetesDetailMetricsProvider, error) {
	if sessions == nil {
		return nil, errors.New("cluster session registry must not be nil")
	}
	return &KubernetesDetailMetricsProvider{
		clients: &sessionDetailMetricsClients{sessions: sessions},
	}, nil
}

type sessionDetailMetricsClients struct {
	sessions *cluster.SessionRegistry
}

func (r *sessionDetailMetricsClients) CachedMetricsAPIAvailability(
	sessionID string,
) (available, known bool, err error) {
	if r == nil || r.sessions == nil {
		return false, false, ErrSessionNotFound
	}
	session, ok := r.sessions.Get(sessionID)
	if !ok {
		return false, false, ErrSessionNotFound
	}
	available, known = session.CachedMetricsAPIAvailability()
	return available, known, nil
}

func (r *sessionDetailMetricsClients) MetricsClient(
	sessionID string,
) (metricsclient.MetricsV1beta1Interface, error) {
	if r == nil || r.sessions == nil {
		return nil, ErrSessionNotFound
	}
	session, ok := r.sessions.Get(sessionID)
	if !ok {
		return nil, ErrSessionNotFound
	}

	client := session.Metrics()
	if client == nil {
		return nil, errors.New("cluster Metrics API client is unavailable")
	}
	return client, nil
}

func (p *KubernetesDetailMetricsProvider) Metrics(
	ctx context.Context,
	identity Identity,
	object *unstructured.Unstructured,
) (DetailMetrics, error) {
	if p == nil || p.clients == nil {
		return DetailMetrics{}, errors.New("object detail metrics provider is unavailable")
	}
	if err := validateObjectUID(object, identity); err != nil {
		return DetailMetrics{}, err
	}

	kind := metricsKindForIdentity(identity)
	if kind == 0 {
		return DetailMetrics{}, nil
	}

	var (
		accounting DetailMetrics
		pod        corev1.Pod
		node       corev1.Node
	)
	switch kind {
	case metrics.PodMetrics:
		if err := runtime.DefaultUnstructuredConverter.FromUnstructured(object.Object, &pod); err != nil {
			return DetailMetrics{}, fmt.Errorf("decode Pod for resource accounting: %w", err)
		}
		accounting.Resources = podResourceUsage(&pod, nil)
		accounting.ContainerResources = podContainerResourceUsage(&pod, nil)
	case metrics.NodeMetrics:
		if err := runtime.DefaultUnstructuredConverter.FromUnstructured(object.Object, &node); err != nil {
			return DetailMetrics{}, fmt.Errorf("decode Node for resource accounting: %w", err)
		}
		accounting.Resources = nodeResourceUsage(&node, nil)
	}

	available, known, err := p.clients.CachedMetricsAPIAvailability(identity.SessionID)
	if err != nil {
		return accounting, err
	}
	if known && !available {
		// Discovery is an explicit workspace action. Consume only its cached
		// conclusion here; this detail path must never start discovery itself.
		// Requests, limits, and allocatable remain useful without measured usage.
		return accounting, nil
	}
	client, err := p.clients.MetricsClient(identity.SessionID)
	if err != nil {
		return accounting, err
	}

	switch kind {
	case metrics.PodMetrics:
		value, err := client.PodMetricses(identity.Namespace).Get(ctx, identity.Name, metav1.GetOptions{})
		if err != nil {
			return accounting, err
		}
		if err := validateMetricsUID(value.GetUID(), identity); err != nil {
			return accounting, err
		}
		return DetailMetrics{
			Resources:          podResourceUsage(&pod, value),
			ContainerResources: podContainerResourceUsage(&pod, value),
		}, nil
	case metrics.NodeMetrics:
		value, err := client.NodeMetricses().Get(ctx, identity.Name, metav1.GetOptions{})
		if err != nil {
			return accounting, err
		}
		if err := validateMetricsUID(value.GetUID(), identity); err != nil {
			return accounting, err
		}
		return DetailMetrics{Resources: nodeResourceUsage(&node, value)}, nil
	default:
		return DetailMetrics{}, nil
	}
}

func metricsKindForIdentity(identity Identity) metrics.APIKind {
	if identity.Group != "" || identity.Version != "v1" {
		return 0
	}
	switch identity.Resource {
	case "pods":
		return metrics.PodMetrics
	case "nodes":
		return metrics.NodeMetrics
	default:
		return 0
	}
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

func podResourceUsage(pod *corev1.Pod, value *metricsapi.PodMetrics) []*kmgrv1.ResourceUsageValue {
	requests, limits := metrics.EffectivePodResources(pod)
	usage := make(corev1.ResourceList)
	if value != nil {
		for _, container := range value.Containers {
			addQuantities(usage, container.Usage)
		}
	}
	return resourceUsageValues(
		usage, requests, limits, nil,
		metrics.MetricsAPIGroupVersion, "pod containers", metricsTimestamp(value),
	)
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
			nil,
			metrics.MetricsAPIGroupVersion,
			"container "+container.name,
			metricsTimestamp(value),
		)
	}
	return result
}

func nodeResourceUsage(node *corev1.Node, value *metricsapi.NodeMetrics) []*kmgrv1.ResourceUsageValue {
	usage := corev1.ResourceList(nil)
	if value != nil {
		usage = value.Usage
	}
	allocatable := corev1.ResourceList(nil)
	physicalCapacity := corev1.ResourceList(nil)
	if node != nil {
		allocatable = node.Status.Allocatable
		physicalCapacity = node.Status.Capacity
	}
	// ResourceUsageValue has one denominator slot. Consistent with Node table
	// cells and the product rules, that slot carries allocatable. Physical
	// capacity still participates in exact-key discovery, but cannot be sent as
	// a second quantity without changing the protocol.
	return resourceUsageValuesWithNames(
		usage, nil, nil, allocatable, physicalCapacity,
		metrics.MetricsAPIGroupVersion, "node", metricsTimestamp(value),
	)
}

func metricsTimestamp(value any) int64 {
	switch current := value.(type) {
	case *metricsapi.PodMetrics:
		if current != nil && !current.Timestamp.IsZero() {
			return current.Timestamp.UnixMilli()
		}
	case *metricsapi.NodeMetrics:
		if current != nil && !current.Timestamp.IsZero() {
			return current.Timestamp.UnixMilli()
		}
	}
	return 0
}

func resourceUsageValues(
	usage, requests, limits, capacity corev1.ResourceList,
	provider, scope string,
	measuredAt int64,
) []*kmgrv1.ResourceUsageValue {
	return resourceUsageValuesWithNames(
		usage, requests, limits, capacity, nil, provider, scope, measuredAt,
	)
}

func resourceUsageValuesWithNames(
	usage, requests, limits, capacity, additionalNames corev1.ResourceList,
	provider, scope string,
	measuredAt int64,
) []*kmgrv1.ResourceUsageValue {
	names := map[corev1.ResourceName]struct{}{
		corev1.ResourceCPU:    {},
		corev1.ResourceMemory: {},
	}
	for _, values := range []corev1.ResourceList{usage, requests, limits, capacity, additionalNames} {
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
		if quantity, found := capacity[name]; found {
			item.Capacity = detailNumberPointer(detailQuantityNumeric(quantity))
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
	case value.Capacity != nil:
		value.SortValue = detailNumberPointer(value.GetCapacity())
	}
}
