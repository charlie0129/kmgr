package object

import (
	"context"
	"errors"
	"math"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	clienttesting "k8s.io/client-go/testing"
	metricsapi "k8s.io/metrics/pkg/apis/metrics/v1beta1"
	metricsfake "k8s.io/metrics/pkg/client/clientset/versioned/fake"
	metricsclient "k8s.io/metrics/pkg/client/clientset/versioned/typed/metrics/v1beta1"
)

func TestGRPCGetObjectRequestsOptionalMetricsOnlyWhenIncluded(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Pod", "pods", "team-a", "api", "pod-uid")
	value.Object["spec"] = map[string]any{"containers": []any{
		map[string]any{"name": "app"},
	}}
	provider := &recordingDetailMetricsProvider{values: DetailMetrics{
		Resources: []*kmgrv1.ResourceUsageValue{{
			ResourceName: string(corev1.ResourceCPU), UsageAvailable: true, Used: 0.25,
		}},
		ContainerResources: map[string][]*kmgrv1.ResourceUsageValue{
			"app": {{
				ResourceName: string(corev1.ResourceCPU), UsageAvailable: true, Used: 0.2,
			}},
		},
	}}
	service, err := NewGRPCService(testReader(t, value), provider)
	if err != nil {
		t.Fatal(err)
	}

	withoutMetrics, err := service.GetObject(context.Background(), detailMetricsRequest(false))
	if err != nil {
		t.Fatal(err)
	}
	if provider.calls != 0 || len(withoutMetrics.GetMetrics()) != 0 {
		t.Fatalf("excluded metrics: calls=%d values=%#v", provider.calls, withoutMetrics.GetMetrics())
	}
	if len(withoutMetrics.GetContainers()) != 1 ||
		len(withoutMetrics.GetContainers()[0].GetMetrics()) != 0 {
		t.Fatalf("base container detail = %#v", withoutMetrics.GetContainers())
	}

	withMetrics, err := service.GetObject(context.Background(), detailMetricsRequest(true))
	if err != nil {
		t.Fatal(err)
	}
	if provider.calls != 1 || len(withMetrics.GetMetrics()) != 1 ||
		withMetrics.GetMetrics()[0].GetUsed() != 0.25 {
		t.Fatalf("included metrics: calls=%d values=%#v", provider.calls, withMetrics.GetMetrics())
	}
	if len(withMetrics.GetContainers()) != 1 ||
		withMetrics.GetContainers()[0].GetName() != "app" ||
		withMetrics.GetContainers()[0].GetMetrics()[0].GetUsed() != 0.2 {
		t.Fatalf("container metrics = %#v", withMetrics.GetContainers())
	}
	if provider.object == nil || string(provider.object.GetUID()) != "pod-uid" {
		t.Fatalf("provider object = %#v", provider.object)
	}
}

func TestGRPCGetObjectMetricsFailureKeepsAuthoritativeBaseDetail(t *testing.T) {
	resource := schema.GroupResource{Group: "metrics.k8s.io", Resource: "pods"}
	for name, metricsErr := range map[string]error{
		"forbidden": apierrors.NewForbidden(
			resource, "api", errors.New("sensitive upstream response"),
		),
		"missing": apierrors.NewNotFound(resource, "api"),
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			value := kubernetesObject("v1", "Pod", "pods", "team-a", "api", "pod-uid")
			provider := &recordingDetailMetricsProvider{err: metricsErr}
			service, err := NewGRPCService(testReader(t, value), provider)
			if err != nil {
				t.Fatal(err)
			}

			response, err := service.GetObject(context.Background(), detailMetricsRequest(true))
			if err != nil {
				t.Fatal(err)
			}
			if provider.calls != 1 || response.GetError() != nil || len(response.GetYamlUtf8()) == 0 ||
				len(response.GetSummaryFields()) == 0 || len(response.GetMetrics()) != 0 {
				t.Fatalf("degraded detail response = %#v (calls=%d)", response, provider.calls)
			}
		})
	}
}

func TestKubernetesDetailMetricsProviderAccountsPodAndPreservesExactResources(t *testing.T) {
	t.Parallel()
	measuredAt := time.Date(2026, 8, 14, 9, 30, 0, 0, time.UTC)
	pod := &corev1.Pod{
		TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Pod"},
		ObjectMeta: metav1.ObjectMeta{
			Namespace: "team-a", Name: "api", UID: types.UID("pod-uid"), ResourceVersion: "42",
		},
		Spec: corev1.PodSpec{Containers: []corev1.Container{{
			Name: "app",
			Resources: corev1.ResourceRequirements{
				Requests: corev1.ResourceList{
					corev1.ResourceCPU:                    resource.MustParse("250m"),
					corev1.ResourceMemory:                 resource.MustParse("64Mi"),
					corev1.ResourceName("hugepages-2Mi"):  resource.MustParse("1Gi"),
					corev1.ResourceName("aliyun.com/ppu"): resource.MustParse("1"),
				},
				Limits: corev1.ResourceList{
					corev1.ResourceCPU:                    resource.MustParse("1"),
					corev1.ResourceMemory:                 resource.MustParse("128Mi"),
					corev1.ResourceName("hugepages-2Mi"):  resource.MustParse("2Gi"),
					corev1.ResourceName("aliyun.com/ppu"): resource.MustParse("2"),
				},
			},
		}}},
	}
	metric := &metricsapi.PodMetrics{
		ObjectMeta: metav1.ObjectMeta{Namespace: "team-a", Name: "api", UID: types.UID("pod-uid")},
		Timestamp:  metav1.NewTime(measuredAt),
		Containers: []metricsapi.ContainerMetrics{
			{Name: "app", Usage: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse("1500n"),
				corev1.ResourceMemory: resource.MustParse("5Mi"),
			}},
			{Name: "sidecar", Usage: corev1.ResourceList{
				corev1.ResourceCPU: resource.MustParse("2500n"),
			}},
		},
	}
	client := metricsfake.NewSimpleClientset()
	client.PrependReactor("get", "pods", func(clienttesting.Action) (bool, runtime.Object, error) {
		return true, metric.DeepCopy(), nil
	})
	provider := &KubernetesDetailMetricsProvider{clients: &fakeDetailMetricsClientResolver{
		client: client.MetricsV1beta1(),
	}}
	identity := Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "team-a",
		Name: "api", UID: "pod-uid",
	}

	values, err := provider.Metrics(context.Background(), identity, unstructuredForDetailMetrics(t, pod))
	if err != nil {
		t.Fatal(err)
	}
	cpu := detailUsageByName(t, values.Resources, corev1.ResourceCPU)
	if !cpu.GetUsageAvailable() || !nearlyEqual(cpu.GetUsed(), 0.000004) ||
		cpu.GetRequested() != 0.25 || cpu.GetLimit() != 1 || cpu.GetUnit() != "cores" ||
		!nearlyEqual(cpu.GetSortValue(), 0.000004) ||
		cpu.GetMeasuredAtUnixMs() != measuredAt.UnixMilli() ||
		cpu.GetProvider() != metrics.MetricsAPIGroupVersion || cpu.GetMeasurementScope() != "pod containers" {
		t.Fatalf("CPU detail metric = %#v", cpu)
	}
	memory := detailUsageByName(t, values.Resources, corev1.ResourceMemory)
	if memory.GetUsed() != 5*1024*1024 || memory.GetRequested() != 64*1024*1024 ||
		memory.GetLimit() != 128*1024*1024 || memory.GetUnit() != "bytes" ||
		memory.GetSortValue() != 5*1024*1024 {
		t.Fatalf("memory detail metric = %#v", memory)
	}
	hugePages := detailUsageByName(t, values.Resources, "hugepages-2Mi")
	if hugePages.GetUsageAvailable() || hugePages.GetRequested() != 1024*1024*1024 ||
		hugePages.GetLimit() != 2*1024*1024*1024 || hugePages.GetUnit() != "bytes" ||
		hugePages.GetSortValue() != 1024*1024*1024 {
		t.Fatalf("huge-page detail metric = %#v", hugePages)
	}
	accelerator := detailUsageByName(t, values.Resources, "aliyun.com/ppu")
	if accelerator.GetUsageAvailable() || accelerator.GetRequested() != 1 ||
		accelerator.GetLimit() != 2 || accelerator.GetUnit() != "count" ||
		accelerator.GetSortValue() != 1 {
		t.Fatalf("accelerator detail metric = %#v", accelerator)
	}
	containerCPU := detailUsageByName(t, values.ContainerResources["app"], corev1.ResourceCPU)
	if !containerCPU.GetUsageAvailable() || !nearlyEqual(containerCPU.GetUsed(), 0.0000015) ||
		containerCPU.GetRequested() != 0.25 || containerCPU.GetLimit() != 1 ||
		containerCPU.GetMeasurementScope() != "container app" {
		t.Fatalf("container CPU detail metric = %#v", containerCPU)
	}
	containerMemory := detailUsageByName(
		t, values.ContainerResources["app"], corev1.ResourceMemory,
	)
	if containerMemory.GetUsed() != 5*1024*1024 ||
		containerMemory.GetRequested() != 64*1024*1024 ||
		containerMemory.GetLimit() != 128*1024*1024 {
		t.Fatalf("container memory detail metric = %#v", containerMemory)
	}
	if _, found := values.ContainerResources["sidecar"]; found {
		t.Fatalf("metrics-only container entered authoritative detail: %#v", values.ContainerResources)
	}
}

func TestKubernetesDetailMetricsProviderUsesNodeAllocatableAsCapacity(t *testing.T) {
	t.Parallel()
	node := &corev1.Node{
		TypeMeta:   metav1.TypeMeta{APIVersion: "v1", Kind: "Node"},
		ObjectMeta: metav1.ObjectMeta{Name: "node-a", UID: types.UID("node-uid"), ResourceVersion: "10"},
		Status: corev1.NodeStatus{
			Allocatable: corev1.ResourceList{
				corev1.ResourceCPU:                   resource.MustParse("3900m"),
				corev1.ResourceMemory:                resource.MustParse("7Gi"),
				corev1.ResourceName("hugepages-1Gi"): resource.MustParse("2Gi"),
			},
			Capacity: corev1.ResourceList{
				corev1.ResourceCPU:                   resource.MustParse("4"),
				corev1.ResourceMemory:                resource.MustParse("8Gi"),
				corev1.ResourceName("hugepages-1Gi"): resource.MustParse("4Gi"),
			},
		},
	}
	metric := &metricsapi.NodeMetrics{
		ObjectMeta: metav1.ObjectMeta{Name: "node-a", UID: types.UID("node-uid")},
		Timestamp:  metav1.NewTime(time.Unix(100, 0)),
		Usage: corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("1500n"),
			corev1.ResourceMemory: resource.MustParse("1Gi"),
		},
	}
	client := metricsfake.NewSimpleClientset()
	client.PrependReactor("get", "nodes", func(clienttesting.Action) (bool, runtime.Object, error) {
		return true, metric.DeepCopy(), nil
	})
	provider := &KubernetesDetailMetricsProvider{clients: &fakeDetailMetricsClientResolver{
		client: client.MetricsV1beta1(),
	}}
	values, err := provider.Metrics(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "nodes", Name: "node-a", UID: "node-uid",
	}, unstructuredForDetailMetrics(t, node))
	if err != nil {
		t.Fatal(err)
	}
	cpu := detailUsageByName(t, values.Resources, corev1.ResourceCPU)
	if !nearlyEqual(cpu.GetUsed(), 0.0000015) || !nearlyEqual(cpu.GetCapacity(), 3.9) ||
		cpu.GetRequested() != 0 || cpu.Requested != nil || !nearlyEqual(cpu.GetSortValue(), 0.0000015) {
		t.Fatalf("Node CPU detail metric = %#v", cpu)
	}
	hugePages := detailUsageByName(t, values.Resources, "hugepages-1Gi")
	if hugePages.GetUsageAvailable() || hugePages.GetCapacity() != 2*1024*1024*1024 ||
		hugePages.GetUnit() != "bytes" || hugePages.GetSortValue() != 2*1024*1024*1024 {
		t.Fatalf("Node huge-page detail metric = %#v", hugePages)
	}
}

func TestKubernetesDetailMetricsProviderRejectsRecreatedMetricsObject(t *testing.T) {
	t.Parallel()
	pod := &corev1.Pod{
		TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Pod"},
		ObjectMeta: metav1.ObjectMeta{
			Namespace: "team-a", Name: "api", UID: types.UID("old-uid"),
		},
	}
	metric := &metricsapi.PodMetrics{
		ObjectMeta: metav1.ObjectMeta{Namespace: "team-a", Name: "api", UID: types.UID("new-uid")},
	}
	client := metricsfake.NewSimpleClientset()
	client.PrependReactor("get", "pods", func(clienttesting.Action) (bool, runtime.Object, error) {
		return true, metric.DeepCopy(), nil
	})
	provider := &KubernetesDetailMetricsProvider{clients: &fakeDetailMetricsClientResolver{
		client: client.MetricsV1beta1(),
	}}
	_, err := provider.Metrics(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "team-a",
		Name: "api", UID: "old-uid",
	}, unstructuredForDetailMetrics(t, pod))
	var changed *IdentityChangedError
	if !errors.As(err, &changed) || changed.ActualUID != "new-uid" {
		t.Fatalf("metrics identity error = %v", err)
	}
}

func TestKubernetesDetailMetricsProviderSkipsGetForKnownMetricsAPIAbsence(t *testing.T) {
	t.Parallel()
	pod := &corev1.Pod{
		TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Pod"},
		ObjectMeta: metav1.ObjectMeta{
			Namespace: "team-a", Name: "api", UID: types.UID("pod-uid"),
		},
	}
	resolver := &fakeDetailMetricsClientResolver{availabilityKnown: true}
	provider := &KubernetesDetailMetricsProvider{clients: resolver}
	values, err := provider.Metrics(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "team-a",
		Name: "api", UID: "pod-uid",
	}, unstructuredForDetailMetrics(t, pod))
	if err != nil {
		t.Fatal(err)
	}
	if len(values.Resources) != 2 || resolver.availabilityCalls != 1 || resolver.clientCalls != 0 {
		t.Fatalf(
			"known-absent result: values=%#v availability calls=%d client calls=%d",
			values, resolver.availabilityCalls, resolver.clientCalls,
		)
	}
	for _, value := range values.Resources {
		if value.GetUsageAvailable() || value.Requested != nil || value.Limit != nil {
			t.Fatalf("known-absent accounting should not invent quantities: %#v", value)
		}
	}
}

func TestGRPCGetObjectKeepsSchedulerAccountingWhenMeasuredUsageFails(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Pod", "pods", "team-a", "api", "pod-uid")
	value.Object["spec"] = map[string]any{"containers": []any{map[string]any{
		"name": "app",
		"resources": map[string]any{"requests": map[string]any{
			"cpu": "250m", "memory": "64Mi", "hugepages-2Mi": "1Gi",
		}},
	}}}
	client := metricsfake.NewSimpleClientset()
	client.PrependReactor("get", "pods", func(clienttesting.Action) (bool, runtime.Object, error) {
		return true, nil, apierrors.NewForbidden(
			schema.GroupResource{Group: "metrics.k8s.io", Resource: "pods"},
			"api", errors.New("metrics access denied"),
		)
	})
	provider := &KubernetesDetailMetricsProvider{clients: &fakeDetailMetricsClientResolver{
		client: client.MetricsV1beta1(),
	}}
	service, err := NewGRPCService(testReader(t, value), provider)
	if err != nil {
		t.Fatal(err)
	}

	response, err := service.GetObject(context.Background(), detailMetricsRequest(true))
	if err != nil {
		t.Fatal(err)
	}
	if response.GetError() != nil {
		t.Fatalf("detail failed with optional Metrics API: %#v", response.GetError())
	}
	cpu := detailUsageByName(t, response.GetMetrics(), corev1.ResourceCPU)
	memory := detailUsageByName(t, response.GetMetrics(), corev1.ResourceMemory)
	hugePages := detailUsageByName(t, response.GetMetrics(), "hugepages-2Mi")
	if cpu.GetUsageAvailable() || cpu.GetRequested() != 0.25 || cpu.GetSortValue() != 0.25 ||
		memory.GetUsageAvailable() || memory.GetRequested() != 64*1024*1024 ||
		memory.GetSortValue() != 64*1024*1024 || hugePages.GetUsageAvailable() ||
		hugePages.GetRequested() != 1024*1024*1024 ||
		hugePages.GetSortValue() != 1024*1024*1024 {
		t.Fatalf("degraded scheduler accounting = %#v", response.GetMetrics())
	}
	if len(response.GetContainers()) != 1 {
		t.Fatalf("degraded container detail = %#v", response.GetContainers())
	}
	containerCPU := detailUsageByName(
		t, response.GetContainers()[0].GetMetrics(), corev1.ResourceCPU,
	)
	if containerCPU.GetUsageAvailable() || containerCPU.GetRequested() != 0.25 ||
		containerCPU.GetSortValue() != 0.25 {
		t.Fatalf("degraded container CPU = %#v", containerCPU)
	}
}

func detailMetricsRequest(include bool) *kmgrv1.GetObjectRequest {
	return &kmgrv1.GetObjectRequest{
		Context: &kmgrv1.RequestContext{RequestId: "request", ClusterSessionId: "session"},
		Identity: &kmgrv1.ResourceIdentity{
			ClusterSessionId: "session", Version: "v1", Resource: "pods",
			Namespace: "team-a", Name: "api", Uid: "pod-uid",
		},
		IncludeYaml: true, IncludeSummary: true, IncludeMetrics: include,
	}
}

type recordingDetailMetricsProvider struct {
	calls  int
	object *unstructured.Unstructured
	values DetailMetrics
	err    error
}

func (p *recordingDetailMetricsProvider) Metrics(
	_ context.Context,
	_ Identity,
	object *unstructured.Unstructured,
) (DetailMetrics, error) {
	p.calls++
	p.object = object
	return p.values, p.err
}

type fakeDetailMetricsClientResolver struct {
	client            metricsclient.MetricsV1beta1Interface
	availability      bool
	availabilityKnown bool
	availabilityErr   error
	availabilityCalls int
	clientCalls       int
}

func (r *fakeDetailMetricsClientResolver) CachedMetricsAPIAvailability(
	string,
) (available, known bool, err error) {
	r.availabilityCalls++
	return r.availability, r.availabilityKnown, r.availabilityErr
}

func (r *fakeDetailMetricsClientResolver) MetricsClient(string) (metricsclient.MetricsV1beta1Interface, error) {
	r.clientCalls++
	return r.client, nil
}

func unstructuredForDetailMetrics(t *testing.T, value runtime.Object) *unstructured.Unstructured {
	t.Helper()
	object, err := runtime.DefaultUnstructuredConverter.ToUnstructured(value)
	if err != nil {
		t.Fatal(err)
	}
	return &unstructured.Unstructured{Object: object}
}

func detailUsageByName(
	t *testing.T,
	values []*kmgrv1.ResourceUsageValue,
	name corev1.ResourceName,
) *kmgrv1.ResourceUsageValue {
	t.Helper()
	for _, value := range values {
		if value.GetResourceName() == string(name) {
			return value
		}
	}
	t.Fatalf("resource %q not present in %#v", name, values)
	return nil
}

func nearlyEqual(left, right float64) bool {
	return math.Abs(left-right) < 1e-12
}
