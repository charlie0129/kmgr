package view

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/metrics"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sruntime "k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/rest"
	clienttesting "k8s.io/client-go/testing"
	metricsapi "k8s.io/metrics/pkg/apis/metrics/v1beta1"
	metricsfake "k8s.io/metrics/pkg/client/clientset/versioned/fake"
	metricsclient "k8s.io/metrics/pkg/client/clientset/versioned/typed/metrics/v1beta1"
)

func TestKubernetesMetricSourceConstructsProvidersWithoutFetching(t *testing.T) {
	t.Parallel()
	catalog := metricTestCatalog(t)
	contextID := metricContextID(t, catalog)
	registry := cluster.NewSessionRegistry(metricClientFactory{
		metrics: metricsfake.NewSimpleClientset().MetricsV1beta1(),
	})
	t.Cleanup(registry.CloseAll)
	first, err := registry.Open(catalog, contextID)
	if err != nil {
		t.Fatal(err)
	}
	second, err := registry.Open(catalog, contextID)
	if err != nil {
		t.Fatal(err)
	}
	authority := first.AuthorityID()
	source := &KubernetesMetricSource{Sessions: registry, RefreshInterval: time.Hour}
	firstLease, err := source.OpenMetrics(
		first.ID(), authority, metrics.PodMetrics, "team-a", "app=api",
	)
	if err != nil {
		t.Fatal(err)
	}
	defer firstLease.Close()
	secondLease, err := source.OpenMetrics(
		second.ID(), authority, metrics.PodMetrics, "team-a", "app=api",
	)
	if err != nil {
		t.Fatal(err)
	}
	defer secondLease.Close()
	key := metricProviderKey{
		authorityID: authority, kind: metrics.PodMetrics,
		namespace: "team-a", labels: "app=api",
	}
	entry := source.providers[key]
	if entry == nil || len(source.providers) != 1 {
		t.Fatal("same authority/kind/namespace did not share one metrics provider")
	}
	if entry.provider.ConsumerCount() != 0 {
		t.Fatal("constructing a provider created a network consumer")
	}
	differentLease, err := source.OpenMetrics(
		first.ID(), authority, metrics.PodMetrics, "team-a", "app=worker",
	)
	if err != nil {
		t.Fatal(err)
	}
	defer differentLease.Close()
	differentKey := metricProviderKey{
		authorityID: authority, kind: metrics.PodMetrics,
		namespace: "team-a", labels: "app=worker",
	}
	if source.providers[differentKey] == nil || source.providers[differentKey] == entry ||
		len(source.providers) != 2 {
		t.Fatal("different Pod label selectors shared one metrics provider")
	}
	nodeLease, err := source.OpenMetrics(
		first.ID(), authority, metrics.NodeMetrics, "", "ignored=selector",
	)
	if err != nil {
		t.Fatal(err)
	}
	defer nodeLease.Close()
	if source.providers[metricProviderKey{authorityID: authority, kind: metrics.NodeMetrics}] == entry {
		t.Fatal("Pod and Node metrics were cross-wired")
	}
}

func TestKubernetesMetricSourceBoundsIdleProvidersWithoutDisruptingActiveSharing(t *testing.T) {
	t.Parallel()
	catalog := metricTestCatalog(t)
	contextID := metricContextID(t, catalog)
	registry := cluster.NewSessionRegistry(metricClientFactory{
		metrics: metricsfake.NewSimpleClientset().MetricsV1beta1(),
	})
	t.Cleanup(registry.CloseAll)
	session, err := registry.Open(catalog, contextID)
	if err != nil {
		t.Fatal(err)
	}
	authority := session.AuthorityID()
	source := &KubernetesMetricSource{
		Sessions: registry, RefreshInterval: time.Hour,
		IdleProviderLimit: 1, IdleSampleLimit: 100,
	}

	activeLease, err := source.OpenMetrics(
		session.ID(), authority, metrics.PodMetrics, "active", "",
	)
	if err != nil {
		t.Fatal(err)
	}
	activeKey := metricProviderKey{authorityID: authority, kind: metrics.PodMetrics, namespace: "active"}
	activeProvider := source.providers[activeKey].provider
	active := activeLease.Subscribe()
	select {
	case <-active.Updates():
	case <-time.After(time.Second):
		t.Fatal("active provider did not fetch")
	}

	firstIdleLease, err := source.OpenMetrics(
		session.ID(), authority, metrics.PodMetrics, "idle-a", "",
	)
	if err != nil {
		t.Fatal(err)
	}
	firstIdleKey := metricProviderKey{authorityID: authority, kind: metrics.PodMetrics, namespace: "idle-a"}
	firstIdleProvider := source.providers[firstIdleKey].provider
	firstIdleLease.Close()
	secondIdleLease, err := source.OpenMetrics(
		session.ID(), authority, metrics.PodMetrics, "idle-b", "",
	)
	if err != nil {
		t.Fatal(err)
	}
	secondIdleKey := metricProviderKey{authorityID: authority, kind: metrics.PodMetrics, namespace: "idle-b"}
	secondIdleLease.Close()

	if len(source.providers) != 2 || source.providers[activeKey] == nil || source.providers[secondIdleKey] == nil ||
		source.providers[firstIdleKey] != nil || source.idle.Len() != 1 {
		t.Fatalf("bounded providers=%d idle=%d entries=%#v", len(source.providers), source.idle.Len(), source.providers)
	}
	if _, err := firstIdleProvider.Acquire(); err == nil {
		t.Fatal("least-recent idle provider remained acquirable after eviction")
	}
	if released := source.ReleaseIdleProviders(); released != 1 {
		t.Fatalf("released idle providers = %d, want 1", released)
	}
	if len(source.providers) != 1 || source.providers[activeKey] == nil || activeProvider.ConsumerCount() != 1 {
		t.Fatal("idle cleanup disrupted the active provider")
	}
	if released := source.ReleaseIdleAuthority(authority); released != 0 {
		t.Fatalf("authority cleanup released %d active providers", released)
	}

	sharedLease, err := source.OpenMetrics(
		session.ID(), authority, metrics.PodMetrics, "active", "",
	)
	if err != nil {
		t.Fatal(err)
	}
	shared := sharedLease.Subscribe()
	if source.providers[activeKey].provider != activeProvider || activeProvider.ConsumerCount() != 2 {
		t.Fatal("active provider was replaced instead of shared")
	}
	shared.Close()
	active.Close()
	if released := source.ReleaseIdleAuthority(authority); released != 1 {
		t.Fatalf("released authority providers = %d, want 1", released)
	}
	if len(source.providers) != 0 || activeProvider.RetainedSampleCount() != 0 {
		t.Fatal("authority cleanup retained the idle provider or its snapshot")
	}
}

func TestKubernetesMetricSourceRejectsIdleSnapshotOverSampleBudget(t *testing.T) {
	t.Parallel()
	client := metricsfake.NewSimpleClientset()
	client.PrependReactor("list", "pods", func(clienttesting.Action) (bool, k8sruntime.Object, error) {
		return true, &metricsapi.PodMetricsList{Items: []metricsapi.PodMetrics{
			{ObjectMeta: metav1.ObjectMeta{Namespace: "oversized", Name: "one"}},
			{ObjectMeta: metav1.ObjectMeta{Namespace: "oversized", Name: "two"}},
		}}, nil
	})
	registry := cluster.NewSessionRegistry(metricClientFactory{metrics: client.MetricsV1beta1()})
	t.Cleanup(registry.CloseAll)
	catalog := metricTestCatalog(t)
	session, err := registry.Open(catalog, metricContextID(t, catalog))
	if err != nil {
		t.Fatal(err)
	}
	authority := session.AuthorityID()
	source := &KubernetesMetricSource{
		Sessions: registry, RefreshInterval: time.Hour,
		IdleProviderLimit: 8, IdleSampleLimit: 1,
	}
	lease, err := source.OpenMetrics(
		session.ID(), authority, metrics.PodMetrics, "oversized", "",
	)
	if err != nil {
		t.Fatal(err)
	}
	key := metricProviderKey{authorityID: authority, kind: metrics.PodMetrics, namespace: "oversized"}
	provider := source.providers[key].provider
	subscription := lease.Subscribe()
	select {
	case snapshot := <-subscription.Updates():
		if len(snapshot.Samples) != 2 {
			t.Fatalf("samples = %d, want 2", len(snapshot.Samples))
		}
	case <-time.After(time.Second):
		t.Fatal("metrics snapshot did not arrive")
	}
	subscription.Close()
	if len(source.providers) != 0 || source.idle.Len() != 0 || source.idleSamples != 0 {
		t.Fatalf("oversized idle snapshot retained: providers=%d idle=%d samples=%d",
			len(source.providers), source.idle.Len(), source.idleSamples)
	}
	if provider.RetainedSampleCount() != 0 {
		t.Fatal("evicted provider retained oversized sample map")
	}
}

func TestKubernetesMetricSourceUsesKnownDiscoveryAbsence(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		switch request.URL.Path {
		case "/api":
			_ = json.NewEncoder(writer).Encode(&metav1.APIVersions{Versions: []string{"v1"}})
		case "/apis":
			_ = json.NewEncoder(writer).Encode(&metav1.APIGroupList{})
		case "/api/v1":
			_ = json.NewEncoder(writer).Encode(&metav1.APIResourceList{
				GroupVersion: "v1",
				APIResources: []metav1.APIResource{{
					Name: "pods", Kind: "Pod", Namespaced: true,
					Verbs: metav1.Verbs{"list", "watch"},
				}},
			})
		default:
			http.NotFound(writer, request)
		}
	}))
	defer server.Close()

	registry := cluster.NewSessionRegistry(nil)
	t.Cleanup(registry.CloseAll)
	catalog := metricCatalogForServer(t, server.URL)
	session, err := registry.Open(catalog, metricContextID(t, catalog))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := session.DiscoverResourcesCached(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	source := &KubernetesMetricSource{
		Sessions: registry, RefreshInterval: time.Hour,
	}
	provider, err := source.OpenMetrics(
		session.ID(), session.AuthorityID(), metrics.PodMetrics, "team-a", "",
	)
	if provider != nil || !errors.Is(err, metrics.ErrMetricsAPIUnavailable) {
		t.Fatalf("known-absent Metrics API result = (%#v, %v)", provider, err)
	}
	snapshot, err := source.ResolvePodMetrics(
		context.Background(), session.ID(), session.AuthorityID(),
		[]metrics.PodReference{{Namespace: "team-a", Name: "api", UID: "uid"}},
	)
	if snapshot.Samples != nil || !errors.Is(err, metrics.ErrMetricsAPIUnavailable) ||
		len(source.podCaches) != 0 {
		t.Fatalf("known-absent exact Metrics API result = (%#v, %v)", snapshot, err)
	}
}

type metricClientFactory struct {
	metrics metricsclient.MetricsV1beta1Interface
}

func (f metricClientFactory) New(*rest.Config) (cluster.BackendClients, error) {
	return cluster.BackendClients{Metrics: f.metrics}, nil
}

func metricTestCatalog(t *testing.T) *cluster.Catalog {
	return metricCatalogForServer(t, "https://metrics.example.test")
}

func metricCatalogForServer(t *testing.T, server string) *cluster.Catalog {
	t.Helper()
	// Kubeconfig catalog construction is tested in cluster. Use its public
	// loader here to verify the view adapter only relies on the session API.
	path := t.TempDir() + "/config"
	contents := []byte(`apiVersion: v1
kind: Config
clusters:
- name: target
  cluster: {server: ` + server + `}
users:
- name: static
  user: {token: token}
contexts:
- name: metrics
  context: {cluster: target, user: static}
`)
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	catalog, err := cluster.DiscoverPaths([]string{path})
	if err != nil {
		t.Fatal(err)
	}
	return catalog
}

func metricContextID(t *testing.T, catalog *cluster.Catalog) string {
	t.Helper()
	for _, info := range catalog.Contexts() {
		if info.Name == "metrics" {
			return info.ID
		}
	}
	t.Fatal("metrics context was not found")
	return ""
}
