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
	metricsapi "k8s.io/metrics/pkg/apis/metrics/v1beta1"
)

func TestGRPCGetObjectRequestsOptionalContainerMetricsOnlyWhenIncluded(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Pod", "pods", "team-a", "api", "pod-uid")
	value.Object["spec"] = map[string]any{"containers": []any{
		map[string]any{"name": "app"},
	}}
	provider := &recordingPodContainerMetricsProvider{values: map[string][]*kmgrv1.ResourceUsageValue{
		"app": {{
			ResourceName: string(corev1.ResourceCPU), UsageAvailable: true, Used: 0.2,
		}},
	}}
	service, err := NewGRPCService(testReader(t, value), provider)
	if err != nil {
		t.Fatal(err)
	}

	withoutMetrics, err := service.GetObject(context.Background(), detailMetricsRequest(false))
	if err != nil {
		t.Fatal(err)
	}
	if provider.calls != 0 || len(withoutMetrics.GetContainers()) != 1 ||
		len(withoutMetrics.GetContainers()[0].GetMetrics()) != 0 {
		t.Fatalf("excluded container metrics: calls=%d containers=%#v", provider.calls, withoutMetrics.GetContainers())
	}

	withMetrics, err := service.GetObject(context.Background(), detailMetricsRequest(true))
	if err != nil {
		t.Fatal(err)
	}
	if provider.calls != 1 || len(withMetrics.GetContainers()) != 1 ||
		withMetrics.GetContainers()[0].GetName() != "app" ||
		len(withMetrics.GetContainers()[0].GetMetrics()) != 1 ||
		withMetrics.GetContainers()[0].GetMetrics()[0].GetUsed() != 0.2 {
		t.Fatalf("included container metrics: calls=%d containers=%#v", provider.calls, withMetrics.GetContainers())
	}
	if provider.object == nil || string(provider.object.GetUID()) != "pod-uid" {
		t.Fatalf("provider object = %#v", provider.object)
	}
}

func TestGRPCGetObjectContainerMetricsFailureKeepsAuthoritativeBaseDetail(t *testing.T) {
	resource := schema.GroupResource{Group: "metrics.k8s.io", Resource: "pods"}
	for name, metricsErr := range map[string]error{
		"forbidden": apierrors.NewForbidden(resource, "api", errors.New("sensitive upstream response")),
		"missing":   apierrors.NewNotFound(resource, "api"),
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			value := kubernetesObject("v1", "Pod", "pods", "team-a", "api", "pod-uid")
			provider := &recordingPodContainerMetricsProvider{err: metricsErr}
			service, err := NewGRPCService(testReader(t, value), provider)
			if err != nil {
				t.Fatal(err)
			}

			response, err := service.GetObject(context.Background(), detailMetricsRequest(true))
			if err != nil {
				t.Fatal(err)
			}
			if provider.calls != 1 || response.GetError() != nil || len(response.GetYamlUtf8()) == 0 ||
				len(response.GetSummaryFields()) == 0 {
				t.Fatalf("degraded detail response = %#v (calls=%d)", response, provider.calls)
			}
		})
	}
}

func TestKubernetesPodContainerMetricsProviderUsesSharedCacheAndExactResources(t *testing.T) {
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
	cache := &fakePodMetricsDetailResolver{value: &metricsapi.PodMetrics{
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
	}}
	provider, err := NewKubernetesPodContainerMetricsProvider(cache)
	if err != nil {
		t.Fatal(err)
	}
	values, err := provider.ContainerMetrics(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "team-a",
		Name: "api", UID: "pod-uid",
	}, unstructuredForDetailMetrics(t, pod))
	if err != nil {
		t.Fatal(err)
	}
	if cache.calls != 1 || cache.sessionID != "session" ||
		cache.reference != (metrics.PodReference{Namespace: "team-a", Name: "api", UID: "pod-uid"}) {
		t.Fatalf("cache call = %#v", cache)
	}
	cpu := detailUsageByName(t, values["app"], corev1.ResourceCPU)
	if !cpu.GetUsageAvailable() || !nearlyEqual(cpu.GetUsed(), 0.0000015) ||
		cpu.GetRequested() != 0.25 || cpu.GetLimit() != 1 || cpu.GetUnit() != "cores" ||
		!nearlyEqual(cpu.GetSortValue(), 0.0000015) ||
		cpu.GetMeasuredAtUnixMs() != measuredAt.UnixMilli() ||
		cpu.GetProvider() != metrics.MetricsAPIGroupVersion || cpu.GetMeasurementScope() != "container app" {
		t.Fatalf("container CPU metric = %#v", cpu)
	}
	memory := detailUsageByName(t, values["app"], corev1.ResourceMemory)
	if memory.GetUsed() != 5*1024*1024 || memory.GetRequested() != 64*1024*1024 ||
		memory.GetLimit() != 128*1024*1024 || memory.GetUnit() != "bytes" {
		t.Fatalf("container memory metric = %#v", memory)
	}
	hugePages := detailUsageByName(t, values["app"], "hugepages-2Mi")
	if hugePages.GetUsageAvailable() || hugePages.GetRequested() != 1024*1024*1024 ||
		hugePages.GetLimit() != 2*1024*1024*1024 || hugePages.GetUnit() != "bytes" {
		t.Fatalf("container huge-page metric = %#v", hugePages)
	}
	accelerator := detailUsageByName(t, values["app"], "aliyun.com/ppu")
	if accelerator.GetUsageAvailable() || accelerator.GetRequested() != 1 ||
		accelerator.GetLimit() != 2 || accelerator.GetUnit() != "count" {
		t.Fatalf("container accelerator metric = %#v", accelerator)
	}
	if _, found := values["sidecar"]; found {
		t.Fatalf("metrics-only container entered authoritative detail: %#v", values)
	}
}

func TestKubernetesPodContainerMetricsProviderDoesNotFetchForNonPod(t *testing.T) {
	t.Parallel()
	cache := &fakePodMetricsDetailResolver{}
	provider, err := NewKubernetesPodContainerMetricsProvider(cache)
	if err != nil {
		t.Fatal(err)
	}
	values, err := provider.ContainerMetrics(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "nodes", Name: "node-a", UID: "node-uid",
	}, unstructuredForDetailMetrics(t, &corev1.Node{ObjectMeta: metav1.ObjectMeta{
		Name: "node-a", UID: "node-uid",
	}}))
	if err != nil || len(values) != 0 || cache.calls != 0 {
		t.Fatalf("non-Pod result=%#v err=%v cache calls=%d", values, err, cache.calls)
	}
}

func TestKubernetesPodContainerMetricsProviderRejectsRecreatedMetricsObject(t *testing.T) {
	t.Parallel()
	pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{
		Namespace: "team-a", Name: "api", UID: types.UID("old-uid"),
	}}
	provider, err := NewKubernetesPodContainerMetricsProvider(&fakePodMetricsDetailResolver{
		value: &metricsapi.PodMetrics{ObjectMeta: metav1.ObjectMeta{
			Namespace: "team-a", Name: "api", UID: types.UID("new-uid"),
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = provider.ContainerMetrics(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "team-a",
		Name: "api", UID: "old-uid",
	}, unstructuredForDetailMetrics(t, pod))
	var changed *IdentityChangedError
	if !errors.As(err, &changed) || changed.ActualUID != "new-uid" {
		t.Fatalf("metrics identity error = %v", err)
	}
}

func TestGRPCGetObjectKeepsContainerAccountingWhenMeasuredUsageFails(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Pod", "pods", "team-a", "api", "pod-uid")
	value.Object["spec"] = map[string]any{"containers": []any{map[string]any{
		"name": "app",
		"resources": map[string]any{"requests": map[string]any{
			"cpu": "250m", "memory": "64Mi", "hugepages-2Mi": "1Gi",
		}},
	}}}
	provider, err := NewKubernetesPodContainerMetricsProvider(&fakePodMetricsDetailResolver{err: apierrors.NewForbidden(
		schema.GroupResource{Group: "metrics.k8s.io", Resource: "pods"},
		"api", errors.New("metrics access denied"),
	)})
	if err != nil {
		t.Fatal(err)
	}
	service, err := NewGRPCService(testReader(t, value), provider)
	if err != nil {
		t.Fatal(err)
	}

	response, err := service.GetObject(context.Background(), detailMetricsRequest(true))
	if err != nil {
		t.Fatal(err)
	}
	if response.GetError() != nil || len(response.GetContainers()) != 1 {
		t.Fatalf("degraded container detail = %#v", response)
	}
	containerMetrics := response.GetContainers()[0].GetMetrics()
	cpu := detailUsageByName(t, containerMetrics, corev1.ResourceCPU)
	memory := detailUsageByName(t, containerMetrics, corev1.ResourceMemory)
	hugePages := detailUsageByName(t, containerMetrics, "hugepages-2Mi")
	if cpu.GetUsageAvailable() || cpu.GetRequested() != 0.25 || cpu.GetSortValue() != 0.25 ||
		memory.GetUsageAvailable() || memory.GetRequested() != 64*1024*1024 ||
		memory.GetSortValue() != 64*1024*1024 || hugePages.GetUsageAvailable() ||
		hugePages.GetRequested() != 1024*1024*1024 ||
		hugePages.GetSortValue() != 1024*1024*1024 {
		t.Fatalf("degraded container accounting = %#v", containerMetrics)
	}
}

func TestNewKubernetesPodContainerMetricsProviderRejectsNilResolver(t *testing.T) {
	t.Parallel()
	if _, err := NewKubernetesPodContainerMetricsProvider(nil); err == nil {
		t.Fatal("nil Pod metrics resolver was accepted")
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

type recordingPodContainerMetricsProvider struct {
	calls  int
	object *unstructured.Unstructured
	values map[string][]*kmgrv1.ResourceUsageValue
	err    error
}

func (p *recordingPodContainerMetricsProvider) ContainerMetrics(
	_ context.Context,
	_ Identity,
	object *unstructured.Unstructured,
) (map[string][]*kmgrv1.ResourceUsageValue, error) {
	p.calls++
	p.object = object
	return p.values, p.err
}

type fakePodMetricsDetailResolver struct {
	calls     int
	sessionID string
	reference metrics.PodReference
	value     *metricsapi.PodMetrics
	err       error
}

func (r *fakePodMetricsDetailResolver) ResolvePodMetricsDetail(
	_ context.Context,
	sessionID string,
	reference metrics.PodReference,
) (*metricsapi.PodMetrics, error) {
	r.calls++
	r.sessionID = sessionID
	r.reference = reference
	if r.value == nil {
		return nil, r.err
	}
	return r.value.DeepCopy(), r.err
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
