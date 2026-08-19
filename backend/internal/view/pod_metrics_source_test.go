package view

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/metrics"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/rest"
	clienttesting "k8s.io/client-go/testing"
	metricsapi "k8s.io/metrics/pkg/apis/metrics/v1beta1"
	metricsfake "k8s.io/metrics/pkg/client/clientset/versioned/fake"
	metricsclient "k8s.io/metrics/pkg/client/clientset/versioned/typed/metrics/v1beta1"
)

func TestKubernetesMetricSourceReusesExactPodCacheAcrossAuthoritySessions(t *testing.T) {
	t.Parallel()
	client := metricsfake.NewSimpleClientset()
	var calls atomic.Int32
	client.PrependReactor("get", "pods", func(action clienttesting.Action) (bool, runtime.Object, error) {
		get := action.(clienttesting.GetAction)
		calls.Add(1)
		return true, &metricsapi.PodMetrics{ObjectMeta: metav1.ObjectMeta{
			Namespace: action.GetNamespace(), Name: get.GetName(), UID: "pod-uid",
		}}, nil
	})
	registry := cluster.NewSessionRegistry(metricClientFactory{metrics: client.MetricsV1beta1()})
	t.Cleanup(registry.CloseAll)
	catalog := metricTestCatalog(t)
	first, err := registry.Open(catalog, metricContextID(t, catalog))
	if err != nil {
		t.Fatal(err)
	}
	second, err := registry.Open(catalog, metricContextID(t, catalog))
	if err != nil {
		t.Fatal(err)
	}
	if first.AuthorityID() == "" || first.AuthorityID() != second.AuthorityID() {
		t.Fatalf("session authorities = %q / %q", first.AuthorityID(), second.AuthorityID())
	}
	source := &KubernetesMetricSource{Sessions: registry, RefreshInterval: time.Hour}
	reference := metrics.PodReference{Namespace: "team", Name: "api", UID: "pod-uid"}

	firstSnapshot, err := source.ResolvePodMetrics(
		context.Background(), first.ID(), first.AuthorityID(), []metrics.PodReference{reference},
	)
	if err != nil {
		t.Fatal(err)
	}
	secondSnapshot, err := source.ResolvePodMetrics(
		context.Background(), second.ID(), second.AuthorityID(), []metrics.PodReference{reference},
	)
	if err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 || firstSnapshot.State != metrics.MeasurementCurrent ||
		secondSnapshot.State != metrics.MeasurementCurrent || firstSnapshot.Samples["pod-uid"].Resources == nil ||
		secondSnapshot.Samples["pod-uid"].Resources == nil {
		t.Fatalf("first = %#v, second = %#v, GET calls = %d", firstSnapshot, secondSnapshot, calls.Load())
	}
	source.mu.Lock()
	entry := source.podCaches[first.AuthorityID()]
	if len(source.podCaches) != 1 || entry == nil || entry.active != 0 {
		t.Fatalf("Pod caches = %#v", source.podCaches)
	}
	source.mu.Unlock()
	if actions := client.Actions(); len(actions) != 1 || actions[0].GetVerb() != "get" ||
		actions[0].GetNamespace() != "team" {
		t.Fatalf("Metrics client actions = %#v", actions)
	}
	if released := source.ReleaseIdleProviders(); released != 1 {
		t.Fatalf("released exact caches = %d, want 1", released)
	}
}

func TestKubernetesMetricSourceSharesDetailedPodCacheAcrossAuthoritySessions(t *testing.T) {
	t.Parallel()
	client := metricsfake.NewSimpleClientset()
	var calls atomic.Int32
	client.PrependReactor("get", "pods", func(action clienttesting.Action) (bool, runtime.Object, error) {
		calls.Add(1)
		return true, &metricsapi.PodMetrics{
			ObjectMeta: metav1.ObjectMeta{
				Namespace: action.GetNamespace(), Name: "api", UID: "pod-uid",
			},
			Containers: []metricsapi.ContainerMetrics{
				{Name: "app", Usage: corev1.ResourceList{
					corev1.ResourceCPU: resource.MustParse("125m"),
				}},
				{Name: "sidecar", Usage: corev1.ResourceList{
					corev1.ResourceCPU: resource.MustParse("25m"),
				}},
			},
		}, nil
	})
	registry := cluster.NewSessionRegistry(metricClientFactory{metrics: client.MetricsV1beta1()})
	t.Cleanup(registry.CloseAll)
	catalog := metricTestCatalog(t)
	first, err := registry.Open(catalog, metricContextID(t, catalog))
	if err != nil {
		t.Fatal(err)
	}
	second, err := registry.Open(catalog, metricContextID(t, catalog))
	if err != nil {
		t.Fatal(err)
	}
	source := &KubernetesMetricSource{Sessions: registry, RefreshInterval: time.Hour}
	reference := metrics.PodReference{Namespace: "team", Name: "api", UID: "pod-uid"}
	detail, err := source.ResolvePodMetricsDetail(context.Background(), first.ID(), reference)
	if err != nil || len(detail.Containers) != 2 {
		t.Fatalf("first detail = %#v, error = %v", detail, err)
	}
	detail.Containers[0].Name = "mutated"
	secondDetail, err := source.ResolvePodMetricsDetail(context.Background(), second.ID(), reference)
	if err != nil || secondDetail.Containers[0].Name != "app" {
		t.Fatalf("second detail = %#v, error = %v", secondDetail, err)
	}
	snapshot, err := source.ResolvePodMetrics(
		context.Background(), second.ID(), second.AuthorityID(), []metrics.PodReference{reference},
	)
	if err != nil || snapshot.Samples["pod-uid"].Resources["cpu"] != 150_000_000 || calls.Load() != 1 {
		t.Fatalf("compact snapshot = %#v, error = %v, calls = %d", snapshot, err, calls.Load())
	}
	if released := source.ReleaseIdleProviders(); released != 1 {
		t.Fatalf("released exact caches = %d, want 1", released)
	}
}

func TestKubernetesMetricSourceValidatesSessionAuthorityForBothMetricPaths(t *testing.T) {
	t.Parallel()
	client := metricsfake.NewSimpleClientset()
	registry := cluster.NewSessionRegistry(metricClientFactory{metrics: client.MetricsV1beta1()})
	t.Cleanup(registry.CloseAll)
	catalog := metricTestCatalog(t)
	session, err := registry.Open(catalog, metricContextID(t, catalog))
	if err != nil {
		t.Fatal(err)
	}
	source := &KubernetesMetricSource{Sessions: registry, RefreshInterval: time.Hour}
	reference := []metrics.PodReference{{Namespace: "team", Name: "api", UID: "uid"}}

	if snapshot, err := source.ResolvePodMetrics(
		context.Background(), session.ID(), "wrong-authority", reference,
	); !errors.Is(err, ErrMetricAuthorityMismatch) || snapshot.Samples != nil {
		t.Fatalf("mismatched exact result = (%#v, %v)", snapshot, err)
	}
	if lease, err := source.OpenMetrics(
		session.ID(), "wrong-authority", metrics.PodMetrics, "team", "",
	); !errors.Is(err, ErrMetricAuthorityMismatch) || lease != nil {
		t.Fatalf("mismatched provider result = (%#v, %v)", lease, err)
	}
	if _, err := source.ResolvePodMetrics(
		context.Background(), "missing-session", session.AuthorityID(), reference,
	); !errors.Is(err, ErrSessionNotFound) {
		t.Fatalf("missing-session error = %v", err)
	}
	if _, err := source.ResolvePodMetrics(
		context.Background(), session.ID(), "", reference,
	); err == nil {
		t.Fatal("empty authority was accepted")
	}
	if len(source.podCaches) != 0 || len(source.providers) != 0 || len(client.Actions()) != 0 {
		t.Fatalf("rejected calls retained state: caches=%d providers=%d actions=%v",
			len(source.podCaches), len(source.providers), client.Actions())
	}
}

func TestKubernetesMetricSourceExactCacheUsesShorterDerivedNegativeTTL(t *testing.T) {
	t.Parallel()
	client := metricsfake.NewSimpleClientset(&metricsapi.PodMetrics{ObjectMeta: metav1.ObjectMeta{
		Namespace: "team", Name: "api", UID: "uid",
	}})
	registry := cluster.NewSessionRegistry(metricClientFactory{metrics: client.MetricsV1beta1()})
	t.Cleanup(registry.CloseAll)
	catalog := metricTestCatalog(t)
	session, err := registry.Open(catalog, metricContextID(t, catalog))
	if err != nil {
		t.Fatal(err)
	}
	source := &KubernetesMetricSource{Sessions: registry, RefreshInterval: time.Second}
	_, err = source.ResolvePodMetrics(
		context.Background(), session.ID(), session.AuthorityID(),
		[]metrics.PodReference{{Namespace: "team", Name: "api", UID: "uid"}},
	)
	if err != nil {
		t.Fatalf("one-second refresh with derived negative TTL: %v", err)
	}
	source.mu.Lock()
	entry := source.podCaches[session.AuthorityID()]
	source.mu.Unlock()
	if entry == nil {
		t.Fatal("exact cache was not retained")
	}
	if released := source.ReleaseIdleProviders(); released != 1 {
		t.Fatalf("released caches = %d, want 1", released)
	}
}

func TestKubernetesMetricSourceRequiresSharedMetricsClient(t *testing.T) {
	t.Parallel()
	registry := cluster.NewSessionRegistry(metricClientFactory{})
	t.Cleanup(registry.CloseAll)
	catalog := metricTestCatalog(t)
	session, err := registry.Open(catalog, metricContextID(t, catalog))
	if err != nil {
		t.Fatal(err)
	}
	source := &KubernetesMetricSource{Sessions: registry, RefreshInterval: time.Hour}
	snapshot, err := source.ResolvePodMetrics(
		context.Background(), session.ID(), session.AuthorityID(),
		[]metrics.PodReference{{Namespace: "team", Name: "api", UID: "uid"}},
	)
	if err == nil || snapshot.Samples != nil || len(source.podCaches) != 0 {
		t.Fatalf("missing client result = (%#v, %v), caches = %d", snapshot, err, len(source.podCaches))
	}
}

func TestKubernetesMetricSourcePinsSessionAndSkipsActiveExactCacheRelease(t *testing.T) {
	t.Parallel()
	started := make(chan struct{}, 1)
	release := make(chan struct{})
	client := metricsfake.NewSimpleClientset()
	client.PrependReactor("get", "pods", func(action clienttesting.Action) (bool, runtime.Object, error) {
		started <- struct{}{}
		<-release
		return true, &metricsapi.PodMetrics{ObjectMeta: metav1.ObjectMeta{
			Namespace: action.GetNamespace(), Name: "api", UID: "uid",
		}}, nil
	})
	registry := cluster.NewSessionRegistry(metricClientFactory{metrics: client.MetricsV1beta1()})
	t.Cleanup(registry.CloseAll)
	catalog := metricTestCatalog(t)
	session, err := registry.Open(catalog, metricContextID(t, catalog))
	if err != nil {
		t.Fatal(err)
	}
	authorityID := session.AuthorityID()
	source := &KubernetesMetricSource{Sessions: registry, RefreshInterval: time.Hour}
	done := make(chan error, 1)
	go func() {
		_, resolveErr := source.ResolvePodMetrics(
			context.Background(), session.ID(), authorityID,
			[]metrics.PodReference{{Namespace: "team", Name: "api", UID: "uid"}},
		)
		done <- resolveErr
	}()
	receiveMetricSourceSignal(t, started, "exact PodMetrics GET")
	if !registry.CloseWorkspace(session.ID()) || !registry.AuthorityActive(authorityID) {
		t.Fatal("active exact resolve did not pin the session backend")
	}
	if released := source.ReleaseIdleAuthority(authorityID); released != 0 {
		t.Fatalf("released active exact cache = %d, want 0", released)
	}
	close(release)
	select {
	case resolveErr := <-done:
		if resolveErr != nil {
			t.Fatal(resolveErr)
		}
	case <-time.After(time.Second):
		t.Fatal("exact resolve did not finish")
	}
	eventuallyMetricSource(t, func() bool { return !registry.AuthorityActive(authorityID) })
	if released := source.ReleaseIdleAuthority(authorityID); released != 1 {
		t.Fatalf("released completed exact cache = %d, want 1", released)
	}
}

func TestKubernetesMetricSourceReleasesExactCacheWithoutDisruptingActiveListProvider(t *testing.T) {
	t.Parallel()
	client := metricsfake.NewSimpleClientset(&metricsapi.PodMetrics{ObjectMeta: metav1.ObjectMeta{
		Namespace: "team", Name: "api", UID: "uid",
	}})
	registry := cluster.NewSessionRegistry(metricClientFactory{metrics: client.MetricsV1beta1()})
	t.Cleanup(registry.CloseAll)
	catalog := metricTestCatalog(t)
	session, err := registry.Open(catalog, metricContextID(t, catalog))
	if err != nil {
		t.Fatal(err)
	}
	authorityID := session.AuthorityID()
	source := &KubernetesMetricSource{Sessions: registry, RefreshInterval: time.Hour}
	lease, err := source.OpenMetrics(session.ID(), authorityID, metrics.PodMetrics, "team", "")
	if err != nil {
		t.Fatal(err)
	}
	providerSubscription := lease.Subscribe()
	select {
	case <-providerSubscription.Updates():
	case <-time.After(time.Second):
		t.Fatal("LIST provider did not fetch")
	}
	_, err = source.ResolvePodMetrics(
		context.Background(), session.ID(), authorityID,
		[]metrics.PodReference{{Namespace: "team", Name: "api", UID: "uid"}},
	)
	if err != nil {
		t.Fatal(err)
	}
	providerKey := metricProviderKey{
		authorityID: authorityID, kind: metrics.PodMetrics, namespace: "team",
	}
	provider := source.providers[providerKey].provider
	if released := source.ReleaseIdleAuthority(authorityID); released != 1 {
		t.Fatalf("released entries = %d, want exact cache only", released)
	}
	if source.providers[providerKey] == nil || provider.ConsumerCount() != 1 {
		t.Fatal("exact cache release disrupted active LIST provider")
	}
	providerSubscription.Close()
	if released := source.ReleaseIdleAuthority(authorityID); released != 1 {
		t.Fatalf("released idle LIST provider = %d, want 1", released)
	}
	if len(source.providers) != 0 || len(source.podCaches) != 0 {
		t.Fatalf("source retained providers=%d caches=%d", len(source.providers), len(source.podCaches))
	}
}

func TestKubernetesMetricSourceShutdownCancelsActiveExactResolve(t *testing.T) {
	t.Parallel()
	client := &cancelableMetricClient{
		started: make(chan struct{}, 1), canceled: make(chan struct{}, 1),
	}
	registry := cluster.NewSessionRegistry(metricClientFactory{metrics: client})
	t.Cleanup(registry.CloseAll)
	catalog := metricTestCatalog(t)
	session, err := registry.Open(catalog, metricContextID(t, catalog))
	if err != nil {
		t.Fatal(err)
	}
	source := &KubernetesMetricSource{Sessions: registry, RefreshInterval: time.Hour}
	resolveDone := make(chan error, 1)
	go func() {
		_, resolveErr := source.ResolvePodMetrics(
			context.Background(), session.ID(), session.AuthorityID(),
			[]metrics.PodReference{{Namespace: "team", Name: "api", UID: "uid"}},
		)
		resolveDone <- resolveErr
	}()
	receiveMetricSourceSignal(t, client.started, "active exact resolve")
	released := source.ReleaseIdleProviders()
	if released != 1 {
		t.Fatalf("shutdown released entries = %d, want 1 exact cache", released)
	}
	receiveMetricSourceSignal(t, client.canceled, "exact GET cancellation")
	select {
	case resolveErr := <-resolveDone:
		if !errors.Is(resolveErr, metrics.ErrPodSampleCacheClosed) {
			t.Fatalf("Resolve error = %v", resolveErr)
		}
	case <-time.After(time.Second):
		t.Fatal("active exact Resolve was not woken by shutdown")
	}
	if len(source.podCaches) != 0 {
		t.Fatalf("shutdown retained %d exact caches", len(source.podCaches))
	}
}

type cancelableMetricClient struct {
	started  chan struct{}
	canceled chan struct{}
}

func (*cancelableMetricClient) RESTClient() rest.Interface { return nil }

func (*cancelableMetricClient) NodeMetricses() metricsclient.NodeMetricsInterface { return nil }

func (c *cancelableMetricClient) PodMetricses(namespace string) metricsclient.PodMetricsInterface {
	return &cancelablePodMetrics{client: c, namespace: namespace}
}

type cancelablePodMetrics struct {
	client    *cancelableMetricClient
	namespace string
}

func (c *cancelablePodMetrics) Get(
	ctx context.Context,
	name string,
	_ metav1.GetOptions,
) (*metricsapi.PodMetrics, error) {
	c.client.started <- struct{}{}
	<-ctx.Done()
	c.client.canceled <- struct{}{}
	return nil, ctx.Err()
}

func (*cancelablePodMetrics) List(
	context.Context,
	metav1.ListOptions,
) (*metricsapi.PodMetricsList, error) {
	return nil, errors.New("unexpected PodMetrics LIST")
}

func (*cancelablePodMetrics) Watch(context.Context, metav1.ListOptions) (watch.Interface, error) {
	return nil, errors.New("unexpected PodMetrics WATCH")
}

func receiveMetricSourceSignal(t *testing.T, signal <-chan struct{}, description string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(time.Second):
		t.Fatalf("timed out waiting for %s", description)
	}
}

func eventuallyMetricSource(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("condition was not met")
}
