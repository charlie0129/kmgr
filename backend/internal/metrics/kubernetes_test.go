package metrics

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	clienttesting "k8s.io/client-go/testing"
	metricsapi "k8s.io/metrics/pkg/apis/metrics/v1beta1"
	metricsfake "k8s.io/metrics/pkg/client/clientset/versioned/fake"
)

func TestKubernetesPodMetricsFetcherAggregatesContainersAndPreservesExactKeys(t *testing.T) {
	t.Parallel()
	measuredAt := time.Date(2026, 8, 13, 12, 0, 0, 0, time.UTC)
	podMetric := metricsapi.PodMetrics{
		ObjectMeta: metav1.ObjectMeta{Namespace: "team-a", Name: "api", UID: types.UID("pod-uid")},
		Timestamp:  metav1.NewTime(measuredAt),
		Containers: []metricsapi.ContainerMetrics{
			{Name: "app", Usage: corev1.ResourceList{
				corev1.ResourceCPU:                               resource.MustParse("125m"),
				corev1.ResourceMemory:                            resource.MustParse("64Mi"),
				corev1.ResourceName("vendor.example/gpu-memory"): resource.MustParse("3"),
			}},
			{Name: "sidecar", Usage: corev1.ResourceList{
				corev1.ResourceCPU:                               resource.MustParse("25m"),
				corev1.ResourceMemory:                            resource.MustParse("16Mi"),
				corev1.ResourceName("vendor.example/gpu-memory"): resource.MustParse("2"),
			}},
		},
	}
	client := metricsfake.NewSimpleClientset()
	client.PrependReactor("list", "pods", func(clienttesting.Action) (bool, runtime.Object, error) {
		return true, &metricsapi.PodMetricsList{Items: []metricsapi.PodMetrics{podMetric}}, nil
	})
	fetcher := KubernetesFetcher{Client: client.MetricsV1beta1(), Kind: PodMetrics, Namespace: "team-a"}
	samples, err := fetcher.Fetch(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	sample := samples["pod-uid"]
	if sample.MeasuredAt != measuredAt || sample.Resources[string(corev1.ResourceCPU)] != 150_000_000 ||
		sample.Resources[string(corev1.ResourceMemory)] != 80*1024*1024 ||
		sample.Resources["vendor.example/gpu-memory"] != 5 {
		t.Fatalf("sample = %#v", sample)
	}
	measurement := MeasurementFor(sample, corev1.ResourceCPU, "metrics.k8s.io", "Pod containers")
	if !measurement.HasValue() || measurement.Quantity.MilliValue() != 150 || measurement.Provider != "metrics.k8s.io" {
		t.Fatalf("measurement = %#v", measurement)
	}
}

func TestKubernetesNodeMetricsFetcherAndRealZero(t *testing.T) {
	t.Parallel()
	nodeMetric := metricsapi.NodeMetrics{
		ObjectMeta: metav1.ObjectMeta{Name: "node-a"},
		Timestamp:  metav1.NewTime(time.Unix(100, 0)),
		Usage: corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("0"),
			corev1.ResourceMemory: resource.MustParse("1Gi"),
		},
	}
	client := metricsfake.NewSimpleClientset()
	client.PrependReactor("list", "nodes", func(clienttesting.Action) (bool, runtime.Object, error) {
		return true, &metricsapi.NodeMetricsList{Items: []metricsapi.NodeMetrics{nodeMetric}}, nil
	})
	samples, err := (KubernetesFetcher{Client: client.MetricsV1beta1(), Kind: NodeMetrics}).Fetch(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	sample := samples["node-a"]
	zero := MeasurementFor(sample, corev1.ResourceCPU, "metrics.k8s.io", "Node")
	missing := MeasurementFor(sample, corev1.ResourceEphemeralStorage, "metrics.k8s.io", "Node")
	if !zero.HasValue() || zero.Quantity.MilliValue() != 0 || missing.HasValue() {
		t.Fatalf("zero=%#v missing=%#v", zero, missing)
	}
}

func TestKubernetesMetricsFetcherClassifiesForbiddenWithoutRemotePayload(t *testing.T) {
	t.Parallel()
	client := metricsfake.NewSimpleClientset()
	client.PrependReactor("list", "pods", func(clienttesting.Action) (bool, runtime.Object, error) {
		return true, nil, apierrors.NewForbidden(
			schema.GroupResource{Group: "metrics.k8s.io", Resource: "pods"},
			"redacted", errors.New("sensitive upstream response"),
		)
	})
	_, err := (KubernetesFetcher{Client: client.MetricsV1beta1(), Kind: PodMetrics}).Fetch(context.Background())
	if !errors.Is(err, ErrMetricsAPIForbidden) || strings.Contains(err.Error(), "sensitive upstream response") {
		t.Fatalf("error = %v", err)
	}
}
