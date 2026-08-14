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
	"k8s.io/client-go/rest"
	metricsfake "k8s.io/metrics/pkg/client/clientset/versioned/fake"
	metricsclient "k8s.io/metrics/pkg/client/clientset/versioned/typed/metrics/v1beta1"
)

func TestKubernetesMetricSourceConstructsProvidersWithoutFetching(t *testing.T) {
	t.Parallel()
	catalog := metricTestCatalog(t)
	registry := cluster.NewSessionRegistry(metricClientFactory{
		metrics: metricsfake.NewSimpleClientset().MetricsV1beta1(),
	})
	t.Cleanup(registry.CloseAll)
	first, err := registry.Open(catalog, "metrics")
	if err != nil {
		t.Fatal(err)
	}
	second, err := registry.Open(catalog, "metrics")
	if err != nil {
		t.Fatal(err)
	}
	authority := first.Context().ID + "/shared"
	source := &KubernetesMetricSource{Sessions: registry, RefreshInterval: time.Hour}
	firstProvider, err := source.OpenMetrics(first.ID(), authority, metrics.PodMetrics, "team-a")
	if err != nil {
		t.Fatal(err)
	}
	secondProvider, err := source.OpenMetrics(second.ID(), authority, metrics.PodMetrics, "team-a")
	if err != nil {
		t.Fatal(err)
	}
	if firstProvider != secondProvider {
		t.Fatal("same authority/kind/namespace did not share metrics provider")
	}
	if firstProvider.ConsumerCount() != 0 {
		t.Fatal("constructing a provider created a network consumer")
	}
	nodeProvider, err := source.OpenMetrics(first.ID(), authority, metrics.NodeMetrics, "")
	if err != nil {
		t.Fatal(err)
	}
	if nodeProvider == firstProvider {
		t.Fatal("Pod and Node metrics were cross-wired")
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
	session, err := registry.Open(metricCatalogForServer(t, server.URL), "metrics")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := session.DiscoverResourcesCached(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	provider, err := (&KubernetesMetricSource{
		Sessions: registry, RefreshInterval: time.Hour,
	}).OpenMetrics(session.ID(), "authority", metrics.PodMetrics, "team-a")
	if provider != nil || !errors.Is(err, metrics.ErrMetricsAPIUnavailable) {
		t.Fatalf("known-absent Metrics API result = (%#v, %v)", provider, err)
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
