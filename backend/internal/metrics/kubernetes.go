package metrics

import (
	"context"
	"errors"
	"fmt"
	"strings"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	metricsapi "k8s.io/metrics/pkg/apis/metrics/v1beta1"
	metricsclient "k8s.io/metrics/pkg/client/clientset/versioned/typed/metrics/v1beta1"
)

const MetricsAPIGroupVersion = "metrics.k8s.io/v1beta1"

var (
	ErrMetricsAPIUnavailable = errors.New("Kubernetes Metrics API is unavailable")
	ErrMetricsAPIForbidden   = errors.New("Kubernetes Metrics API access is forbidden")
)

type APIKind uint8

const (
	PodMetrics APIKind = iota + 1
	NodeMetrics
)

// KubernetesFetcher converts Metrics API values to provider-neutral samples.
// Sample keys are UID when the API supplies one, otherwise namespace/name for
// Pods and name for Nodes. Exact Kubernetes resource names remain separate.
type KubernetesFetcher struct {
	Client    metricsclient.MetricsV1beta1Interface
	Kind      APIKind
	Namespace string
}

func (f KubernetesFetcher) Fetch(ctx context.Context) (map[string]Sample, error) {
	if f.Client == nil {
		return nil, ErrMetricsAPIUnavailable
	}
	switch f.Kind {
	case PodMetrics:
		list, err := f.Client.PodMetricses(f.Namespace).List(ctx, metav1.ListOptions{})
		if err != nil {
			return nil, classifyMetricsError(err)
		}
		return podSamples(list.Items), nil
	case NodeMetrics:
		list, err := f.Client.NodeMetricses().List(ctx, metav1.ListOptions{})
		if err != nil {
			return nil, classifyMetricsError(err)
		}
		return nodeSamples(list.Items), nil
	default:
		return nil, fmt.Errorf("unsupported metrics kind %d", f.Kind)
	}
}

func podSamples(values []metricsapi.PodMetrics) map[string]Sample {
	result := make(map[string]Sample, len(values))
	for index := range values {
		value := &values[index]
		resources := make(map[string]int64)
		for _, container := range value.Containers {
			addUsage(resources, container.Usage)
		}
		identity := string(value.UID)
		if identity == "" {
			identity = value.Namespace + "/" + value.Name
		}
		result[identity] = Sample{
			MeasuredAt: value.Timestamp.Time, Resources: resources,
		}
	}
	return result
}

func nodeSamples(values []metricsapi.NodeMetrics) map[string]Sample {
	result := make(map[string]Sample, len(values))
	for index := range values {
		value := &values[index]
		identity := string(value.UID)
		if identity == "" {
			identity = value.Name
		}
		resources := make(map[string]int64, len(value.Usage))
		addUsage(resources, value.Usage)
		result[identity] = Sample{MeasuredAt: value.Timestamp.Time, Resources: resources}
	}
	return result
}

// CPU is stored as nanocores and byte-addressed resources as bytes. Generic
// integer/extended resources retain their integral quantity. Values that
// cannot fit int64 use the quantity's saturating conversion.
func addUsage(result map[string]int64, usage corev1.ResourceList) {
	for name, quantity := range usage {
		var value int64
		if name == corev1.ResourceCPU {
			value = quantity.MilliValue() * 1_000_000
		} else {
			value = quantity.Value()
		}
		result[string(name)] += value
	}
}

func classifyMetricsError(err error) error {
	switch {
	case apierrors.IsForbidden(err), apierrors.IsUnauthorized(err):
		return fmt.Errorf("%w: %T", ErrMetricsAPIForbidden, err)
	case apierrors.IsNotFound(err), apierrors.IsServiceUnavailable(err):
		return fmt.Errorf("%w: %T", ErrMetricsAPIUnavailable, err)
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return err
	default:
		return fmt.Errorf("%w: %T", ErrMetricsAPIUnavailable, err)
	}
}

// MeasurementFor converts one provider sample without confusing absent data
// with a real zero. CPU nanocores and byte values are converted back into
// Kubernetes quantities for accounting/tooltips.
func MeasurementFor(sample Sample, resourceName corev1.ResourceName, provider, scope string) Measurement {
	value, found := sample.Resources[string(resourceName)]
	if !found {
		return UnavailableMeasurement("metrics sample did not contain this resource")
	}
	quantity := *resourceQuantity(resourceName, value)
	return CurrentMeasurement(quantity, provider, scope, sample.MeasuredAt)
}

func resourceQuantity(name corev1.ResourceName, value int64) *resource.Quantity {
	if name == corev1.ResourceCPU {
		return resource.NewScaledQuantity(value, resource.Nano)
	}
	if name == corev1.ResourceMemory || name == corev1.ResourceEphemeralStorage ||
		strings.HasPrefix(string(name), corev1.ResourceHugePagesPrefix) {
		return resource.NewQuantity(value, resource.BinarySI)
	}
	return resource.NewQuantity(value, resource.DecimalSI)
}
