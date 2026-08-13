package view

import (
	"os"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/metrics"
	"k8s.io/client-go/rest"
)

func TestKubernetesMetricSourceConstructsProvidersWithoutFetching(t *testing.T) {
	t.Parallel()
	catalog := metricTestCatalog(t)
	registry := cluster.NewSessionRegistry(metricClientFactory{})
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

type metricClientFactory struct{}

func (metricClientFactory) New(*rest.Config) (cluster.BackendClients, error) {
	return cluster.BackendClients{}, nil
}

func metricTestCatalog(t *testing.T) *cluster.Catalog {
	t.Helper()
	// Kubeconfig catalog construction is tested in cluster. Use its public
	// loader here to verify the view adapter only relies on the session API.
	path := t.TempDir() + "/config"
	contents := []byte(`apiVersion: v1
kind: Config
clusters:
- name: target
  cluster: {server: https://metrics.example.test}
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
