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
	memory := MeasurementFor(sample, corev1.ResourceMemory, "metrics.k8s.io", "Pod containers")
	if got := memory.Quantity.String(); got != "80Mi" {
		t.Fatalf("memory quantity = %q, want 80Mi", got)
	}
	extended := MeasurementFor(sample, "vendor.example/gpu-memory", "metrics.k8s.io", "Pod containers")
	if got := extended.Quantity.String(); got != "5" {
		t.Fatalf("extended-resource quantity = %q, want 5", got)
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
	memory := MeasurementFor(sample, corev1.ResourceMemory, "metrics.k8s.io", "Node")
	if got := memory.Quantity.String(); got != "1Gi" {
		t.Fatalf("memory quantity = %q, want 1Gi", got)
	}
}

func TestKubernetesMetricsFetcherPreservesSubMillicoreCPUPrecision(t *testing.T) {
	t.Parallel()
	metric := metricsapi.NodeMetrics{
		ObjectMeta: metav1.ObjectMeta{Name: "node-a"},
		Usage: corev1.ResourceList{
			corev1.ResourceCPU: resource.MustParse("1500n"),
		},
	}
	client := metricsfake.NewSimpleClientset()
	client.PrependReactor("list", "nodes", func(clienttesting.Action) (bool, runtime.Object, error) {
		return true, &metricsapi.NodeMetricsList{Items: []metricsapi.NodeMetrics{metric}}, nil
	})
	samples, err := (KubernetesFetcher{
		Client: client.MetricsV1beta1(), Kind: NodeMetrics,
	}).Fetch(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got := samples["node-a"].Resources[string(corev1.ResourceCPU)]; got != 1500 {
		t.Fatalf("CPU nanocores = %d, want 1500", got)
	}
	measurement := MeasurementFor(
		samples["node-a"], corev1.ResourceCPU, MetricsAPIGroupVersion, "node",
	)
	if got := measurement.Quantity.ScaledValue(resource.Nano); got != 1500 {
		t.Fatalf("round-tripped CPU nanocores = %d, want 1500", got)
	}
}

func TestKubernetesMetricsFetcherPaginatesPodsAndNodes(t *testing.T) {
	t.Parallel()
	client := metricsfake.NewSimpleClientset()
	optionsByResource := map[string][]metav1.ListOptions{}
	client.PrependReactor("list", "pods", func(action clienttesting.Action) (bool, runtime.Object, error) {
		options := metricsListOptions(t, action)
		optionsByResource["pods"] = append(optionsByResource["pods"], options)
		switch options.Continue {
		case "":
			return true, &metricsapi.PodMetricsList{
				ListMeta: metav1.ListMeta{Continue: "pods-next"},
				Items: []metricsapi.PodMetrics{{ObjectMeta: metav1.ObjectMeta{
					UID: "pod-one", Labels: map[string]string{
						"app": "api", "tier": "frontend",
					},
				}}},
			}, nil
		case "pods-next":
			return true, &metricsapi.PodMetricsList{
				Items: []metricsapi.PodMetrics{{ObjectMeta: metav1.ObjectMeta{
					UID: "pod-two", Labels: map[string]string{
						"app": "api", "tier": "frontend",
					},
				}}},
			}, nil
		default:
			t.Fatalf("unexpected Pod continuation %q", options.Continue)
			return true, nil, nil
		}
	})
	client.PrependReactor("list", "nodes", func(action clienttesting.Action) (bool, runtime.Object, error) {
		options := metricsListOptions(t, action)
		optionsByResource["nodes"] = append(optionsByResource["nodes"], options)
		switch options.Continue {
		case "":
			return true, &metricsapi.NodeMetricsList{
				ListMeta: metav1.ListMeta{Continue: "nodes-next"},
				Items:    []metricsapi.NodeMetrics{{ObjectMeta: metav1.ObjectMeta{UID: "node-one"}}},
			}, nil
		case "nodes-next":
			return true, &metricsapi.NodeMetricsList{
				Items: []metricsapi.NodeMetrics{{ObjectMeta: metav1.ObjectMeta{UID: "node-two"}}},
			}, nil
		default:
			t.Fatalf("unexpected Node continuation %q", options.Continue)
			return true, nil, nil
		}
	})
	for _, test := range []struct {
		kind          APIKind
		resource      string
		labelSelector string
		want          []string
	}{
		{
			kind: PodMetrics, resource: "pods",
			labelSelector: "app=api,tier=frontend",
			want:          []string{"pod-one", "pod-two"},
		},
		{kind: NodeMetrics, resource: "nodes", want: []string{"node-one", "node-two"}},
	} {
		samples, err := (KubernetesFetcher{
			Client: client.MetricsV1beta1(), Kind: test.kind,
			LabelSelector: test.labelSelector,
		}).Fetch(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		for _, identity := range test.want {
			if _, found := samples[identity]; !found {
				t.Fatalf("%s samples = %#v, missing %q", test.resource, samples, identity)
			}
		}
		options := optionsByResource[test.resource]
		if len(options) != 2 || options[0].Limit != metricsListPageSize || options[0].Continue != "" ||
			options[1].Limit != metricsListPageSize || options[1].Continue != test.resource+"-next" ||
			options[0].LabelSelector != test.labelSelector ||
			options[1].LabelSelector != test.labelSelector {
			t.Fatalf("%s list options = %#v", test.resource, options)
		}
	}
}

func TestKubernetesMetricsFetcherRejectsRepeatedContinuationToken(t *testing.T) {
	t.Parallel()
	client := metricsfake.NewSimpleClientset()
	calls := 0
	client.PrependReactor("list", "nodes", func(clienttesting.Action) (bool, runtime.Object, error) {
		calls++
		return true, &metricsapi.NodeMetricsList{ListMeta: metav1.ListMeta{Continue: "sensitive-token"}}, nil
	})
	_, err := (KubernetesFetcher{Client: client.MetricsV1beta1(), Kind: NodeMetrics}).Fetch(context.Background())
	if !errors.Is(err, ErrMetricsAPIUnavailable) || calls != 2 || strings.Contains(err.Error(), "sensitive-token") {
		t.Fatalf("error = %v, calls = %d", err, calls)
	}
}

func TestKubernetesMetricsFetcherStopsPaginationAfterCancellation(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	client := metricsfake.NewSimpleClientset()
	calls := 0
	client.PrependReactor("list", "pods", func(clienttesting.Action) (bool, runtime.Object, error) {
		calls++
		cancel()
		return true, &metricsapi.PodMetricsList{ListMeta: metav1.ListMeta{Continue: "next"}}, nil
	})
	_, err := (KubernetesFetcher{Client: client.MetricsV1beta1(), Kind: PodMetrics}).Fetch(ctx)
	if !errors.Is(err, context.Canceled) || calls != 1 {
		t.Fatalf("error = %v, calls = %d", err, calls)
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

func metricsListOptions(t *testing.T, action clienttesting.Action) metav1.ListOptions {
	t.Helper()
	withOptions, ok := action.(interface{ GetListOptions() metav1.ListOptions })
	if !ok {
		t.Fatalf("list action type = %T, want ListOptions", action)
	}
	return withOptions.GetListOptions()
}
