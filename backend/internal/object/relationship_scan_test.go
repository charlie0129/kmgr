package object

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/dynamic"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	"k8s.io/client-go/metadata"
	metadatafake "k8s.io/client-go/metadata/fake"
	"k8s.io/client-go/rest"
)

type scanTestResolver struct {
	dynamic   dynamic.Interface
	discovery discovery.DiscoveryInterface
	metadata  *metadatafake.FakeMetadataClient
}

func (r scanTestResolver) Resource(
	_ string, gvr schema.GroupVersionResource, namespace string,
) (dynamic.ResourceInterface, error) {
	client := r.dynamic.Resource(gvr)
	if namespace != "" {
		return client.Namespace(namespace), nil
	}
	return client, nil
}

func (r scanTestResolver) RelationshipScanSession(string) (RelationshipScanSession, error) {
	return scanTestSession{discovery: r.discovery, metadataClient: r.metadata}, nil
}

type scanTestSession struct {
	discovery      discovery.DiscoveryInterface
	metadataClient metadata.Interface
}

func (s scanTestSession) DiscoverResources(ctx context.Context) (cluster.ResourceDiscovery, error) {
	return cluster.DiscoverResourcesWithClient(ctx, s.discovery)
}

func (s scanTestSession) Metadata() metadata.Interface {
	return s.metadataClient
}

func TestScanRelationshipsUsesExactOwnerUIDPreferredVersionsAndNamespace(t *testing.T) {
	t.Parallel()
	target := kubernetesObject("apps/v1", "Deployment", "deployments", "ns", "api", "owner-uid")
	dynamicClient := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), target)
	metadataScheme := metadatafake.NewTestScheme()
	metav1.AddMetaToScheme(metadataScheme)
	child := partialMetadata("apps/v1", "ReplicaSet", "ns", "api-rs", "child-uid", "owner-uid")
	wrongUID := partialMetadata("v1", "Pod", "ns", "same-name-owner", "wrong-child", "replacement-owner-uid")
	otherNamespace := partialMetadata("v1", "Pod", "other", "other", "other-child", "owner-uid")
	metadataClient := metadatafake.NewSimpleMetadataClient(
		metadataScheme, relationshipPartialMetadata(target), child, wrongUID, otherNamespace,
	)
	discovery := newRelationshipDiscoveryClient(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api":
			writeRelationshipDiscoveryJSON(t, writer, &metav1.APIVersions{Versions: []string{"v1"}})
		case "/apis":
			writeRelationshipDiscoveryJSON(t, writer, &metav1.APIGroupList{Groups: []metav1.APIGroup{{
				Name: "apps",
				Versions: []metav1.GroupVersionForDiscovery{
					{GroupVersion: "apps/v1", Version: "v1"},
					{GroupVersion: "apps/v1beta1", Version: "v1beta1"},
				},
				PreferredVersion: metav1.GroupVersionForDiscovery{GroupVersion: "apps/v1", Version: "v1"},
			}}})
		case "/api/v1":
			writeRelationshipDiscoveryJSON(t, writer, &metav1.APIResourceList{
				GroupVersion: "v1", APIResources: []metav1.APIResource{
					{Name: "pods", Kind: "Pod", Namespaced: true, Verbs: metav1.Verbs{"list"}},
					{Name: "nodes", Kind: "Node", Namespaced: false, Verbs: metav1.Verbs{"list"}},
				},
			})
		case "/apis/apps/v1", "/apis/apps/v1beta1":
			writeRelationshipDiscoveryJSON(t, writer, &metav1.APIResourceList{
				GroupVersion: request.URL.Path[len("/apis/"):],
				APIResources: []metav1.APIResource{{
					Name: "replicasets", Kind: "ReplicaSet", Namespaced: true,
					Verbs: metav1.Verbs{"list"},
				}},
			})
		default:
			http.NotFound(writer, request)
		}
	}))
	reader, err := NewReader(scanTestResolver{dynamic: dynamicClient, discovery: discovery, metadata: metadataClient})
	if err != nil {
		t.Fatal(err)
	}
	var updates []RelationshipScanUpdate
	err = reader.ScanRelationships(context.Background(), Identity{
		SessionID: "session", Group: "apps", Version: "v1", Resource: "deployments",
		Namespace: "ns", Name: "api", UID: "owner-uid",
	}, func(update RelationshipScanUpdate) error {
		updates = append(updates, update)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	var children []Relationship
	for _, update := range updates {
		children = append(children, update.Relationships...)
	}
	if len(children) != 1 || children[0].Identity.UID != "child-uid" ||
		children[0].Identity.Resource != "replicasets" {
		t.Fatalf("children = %#v", children)
	}
	final := updates[len(updates)-1].Progress
	if !final.Complete || final.PotentiallyIncomplete || final.ResourcesTotal != 2 || final.ObjectsExamined != 2 {
		t.Fatalf("final progress = %#v", final)
	}
	for _, action := range metadataClient.Actions() {
		if action.GetResource().Resource == "nodes" || action.GetNamespace() != "ns" {
			t.Fatalf("unexpected metadata action = %#v", action)
		}
		if action.GetResource().Version == "v1beta1" {
			t.Fatalf("non-preferred version scanned = %#v", action)
		}
	}
}

func TestClusterRelationshipScansReuseSharedDiscoveryCatalog(t *testing.T) {
	t.Parallel()
	var discoveryCycles atomic.Int64
	var anchorGets atomic.Int64
	var metadataLists atomic.Int64
	reader, sessionID := newClusterRelationshipReader(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api":
			discoveryCycles.Add(1)
			writeRelationshipDiscoveryJSON(t, writer, &metav1.APIVersions{Versions: []string{"v1"}})
		case "/apis":
			writeRelationshipDiscoveryJSON(t, writer, &metav1.APIGroupList{})
		case "/api/v1":
			writeRelationshipDiscoveryJSON(t, writer, &metav1.APIResourceList{
				GroupVersion: "v1",
				APIResources: []metav1.APIResource{{
					Name: "pods", Kind: "Pod", Namespaced: true, Verbs: metav1.Verbs{"list"},
				}},
			})
		case "/apis/apps/v1/namespaces/ns/deployments/api":
			anchorGets.Add(1)
			if accept := request.Header.Get("Accept"); !strings.Contains(accept, "as=PartialObjectMetadata") {
				t.Errorf("metadata anchor Accept = %q", accept)
			}
			writeRelationshipDiscoveryJSON(t, writer, map[string]any{
				"apiVersion": "meta.k8s.io/v1",
				"kind":       "PartialObjectMetadata",
				"metadata": map[string]any{
					"namespace": "ns", "name": "api", "uid": "owner-uid",
				},
			})
		case "/api/v1/namespaces/ns/pods":
			metadataLists.Add(1)
			if request.URL.Query().Get("limit") != "500" {
				t.Errorf("metadata list limit = %q, want 500", request.URL.Query().Get("limit"))
			}
			writeRelationshipDiscoveryJSON(t, writer, map[string]any{
				"apiVersion": "meta.k8s.io/v1",
				"kind":       "PartialObjectMetadataList",
				"metadata":   map[string]any{"resourceVersion": "1"},
				"items":      []any{},
			})
		default:
			http.NotFound(writer, request)
		}
	}))
	identity := Identity{
		SessionID: sessionID, Group: "apps", Version: "v1", Resource: "deployments",
		Namespace: "ns", Name: "api", UID: "owner-uid",
	}
	scan := func() error {
		var final RelationshipScanProgress
		err := reader.ScanRelationships(context.Background(), identity, func(update RelationshipScanUpdate) error {
			final = update.Progress
			return nil
		})
		if err != nil {
			return err
		}
		if !final.Complete || final.ResourcesScanned != 1 {
			return fmt.Errorf("final progress = %#v", final)
		}
		return nil
	}

	start := make(chan struct{})
	resultErrors := make(chan error, 2)
	for range 2 {
		go func() {
			<-start
			resultErrors <- scan()
		}()
	}
	close(start)
	for range 2 {
		if err := <-resultErrors; err != nil {
			t.Fatal(err)
		}
	}
	if err := scan(); err != nil {
		t.Fatal(err)
	}
	if got := discoveryCycles.Load(); got != 1 {
		t.Fatalf("concurrent and repeated relationship scans caused %d discovery cycles, want 1", got)
	}
	if got := anchorGets.Load(); got != 3 {
		t.Fatalf("metadata anchor GETs = %d, want one authoritative GET per scan", got)
	}
	if got := metadataLists.Load(); got != 3 {
		t.Fatalf("metadata LISTs = %d, want one explicit object scan per invocation", got)
	}
}

func TestScanRelationshipsRejectsRecreatedTargetBeforeBulkLists(t *testing.T) {
	t.Parallel()
	target := kubernetesObject("apps/v1", "Deployment", "deployments", "ns", "api", "new-uid")
	metadataScheme := metadatafake.NewTestScheme()
	metav1.AddMetaToScheme(metadataScheme)
	metadataClient := metadatafake.NewSimpleMetadataClient(
		metadataScheme, relationshipPartialMetadata(target),
	)
	var discoveryRequests atomic.Int64
	discovery := newRelationshipDiscoveryClient(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		discoveryRequests.Add(1)
		http.NotFound(writer, request)
	}))
	reader, _ := NewReader(scanTestResolver{
		dynamic:   dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), target),
		discovery: discovery, metadata: metadataClient,
	})
	err := reader.ScanRelationships(context.Background(), Identity{
		SessionID: "session", Group: "apps", Version: "v1", Resource: "deployments",
		Namespace: "ns", Name: "api", UID: "old-uid",
	}, func(RelationshipScanUpdate) error { return nil })
	var changed *IdentityChangedError
	if !errors.As(err, &changed) || changed.ActualUID != "new-uid" {
		t.Fatalf("scan error = %#v", err)
	}
	actions := metadataClient.Actions()
	if len(actions) != 1 || actions[0].GetVerb() != "get" ||
		actions[0].GetResource() != (schema.GroupVersionResource{
			Group: "apps", Version: "v1", Resource: "deployments",
		}) {
		t.Fatalf("metadata actions before rejected scan = %v, want one exact anchor GET", actions)
	}
	if discoveryRequests.Load() != 0 {
		t.Fatalf("discovery requests before UID guard = %d", discoveryRequests.Load())
	}
}

func TestDiscoverRelationshipResourcesSelectsStablePreferredVersion(t *testing.T) {
	t.Parallel()
	discovery := newRelationshipDiscoveryClient(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api":
			writeRelationshipDiscoveryJSON(t, writer, &metav1.APIVersions{})
		case "/apis":
			writeRelationshipDiscoveryJSON(t, writer, &metav1.APIGroupList{Groups: []metav1.APIGroup{{
				Name: "apps",
				Versions: []metav1.GroupVersionForDiscovery{
					{GroupVersion: "apps/v1beta1", Version: "v1beta1"},
					{GroupVersion: "apps/v1", Version: "v1"},
				},
				PreferredVersion: metav1.GroupVersionForDiscovery{
					GroupVersion: "apps/v1beta1", Version: "v1beta1",
				},
			}}})
		case "/apis/apps/v1beta1", "/apis/apps/v1":
			writeRelationshipDiscoveryJSON(t, writer, &metav1.APIResourceList{
				GroupVersion: request.URL.Path[len("/apis/"):],
				APIResources: []metav1.APIResource{{
					Name: "deployments", Kind: "Deployment", Verbs: metav1.Verbs{"list"},
				}},
			})
		default:
			http.NotFound(writer, request)
		}
	}))
	metadataScheme := metadatafake.NewTestScheme()
	metav1.AddMetaToScheme(metadataScheme)
	resources, incomplete, err := discoverRelationshipResources(context.Background(), scanTestSession{
		discovery: discovery, metadataClient: metadatafake.NewSimpleMetadataClient(metadataScheme),
	})
	if err != nil || incomplete || len(resources) != 1 || resources[0].Version != "v1beta1" {
		// Honor the server-declared preferred version rather than guessing from
		// lexical or discovery response order.
		t.Fatalf("resources=%#v incomplete=%t err=%v", resources, incomplete, err)
	}
	if !slices.Equal([]string{resources[0].Group, resources[0].Resource}, []string{"apps", "deployments"}) {
		t.Fatalf("resource = %#v", resources[0])
	}
}

func TestDiscoverRelationshipResourcesKeepsPartialResults(t *testing.T) {
	t.Parallel()
	discovery := newRelationshipDiscoveryClient(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api":
			writeRelationshipDiscoveryJSON(t, writer, &metav1.APIVersions{Versions: []string{"v1"}})
		case "/apis":
			writeRelationshipDiscoveryJSON(t, writer, &metav1.APIGroupList{Groups: []metav1.APIGroup{{
				Name: "broken.example.io",
				Versions: []metav1.GroupVersionForDiscovery{{
					GroupVersion: "broken.example.io/v1", Version: "v1",
				}},
				PreferredVersion: metav1.GroupVersionForDiscovery{
					GroupVersion: "broken.example.io/v1", Version: "v1",
				},
			}}})
		case "/api/v1":
			writeRelationshipDiscoveryJSON(t, writer, &metav1.APIResourceList{
				GroupVersion: "v1", APIResources: []metav1.APIResource{{
					Name: "pods", Kind: "Pod", Namespaced: true, Verbs: metav1.Verbs{"list"},
				}},
			})
		case "/apis/broken.example.io/v1":
			http.Error(writer, "unavailable", http.StatusServiceUnavailable)
		default:
			http.NotFound(writer, request)
		}
	}))
	metadataScheme := metadatafake.NewTestScheme()
	metav1.AddMetaToScheme(metadataScheme)
	resources, incomplete, err := discoverRelationshipResources(context.Background(), scanTestSession{
		discovery: discovery, metadataClient: metadatafake.NewSimpleMetadataClient(metadataScheme),
	})
	if err != nil {
		t.Fatal(err)
	}
	if !incomplete || len(resources) != 1 || resources[0].Resource != "pods" {
		t.Fatalf("resources=%#v incomplete=%t", resources, incomplete)
	}
}

func TestScanRelationshipsCancelsStalledDiscoveryRequest(t *testing.T) {
	t.Parallel()
	requestStarted := make(chan struct{})
	requestCanceled := make(chan struct{})
	releaseHandler := make(chan struct{})
	defer close(releaseHandler)
	var startOnce sync.Once
	var cancelOnce sync.Once
	discovery := newRelationshipDiscoveryClient(t, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api":
			writeRelationshipDiscoveryJSON(t, writer, &metav1.APIVersions{Versions: []string{"v1"}})
		case "/apis":
			writeRelationshipDiscoveryJSON(t, writer, &metav1.APIGroupList{})
		case "/api/v1":
			startOnce.Do(func() { close(requestStarted) })
			select {
			case <-request.Context().Done():
				cancelOnce.Do(func() { close(requestCanceled) })
			case <-releaseHandler:
			}
		default:
			http.NotFound(writer, request)
		}
	}))
	target := kubernetesObject("apps/v1", "Deployment", "deployments", "ns", "api", "owner-uid")
	metadataScheme := metadatafake.NewTestScheme()
	metav1.AddMetaToScheme(metadataScheme)
	metadataClient := metadatafake.NewSimpleMetadataClient(
		metadataScheme, relationshipPartialMetadata(target),
	)
	reader, err := NewReader(scanTestResolver{
		dynamic:   dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), target),
		discovery: discovery, metadata: metadataClient,
	})
	if err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- reader.ScanRelationships(ctx, Identity{
			SessionID: "session", Group: "apps", Version: "v1", Resource: "deployments",
			Namespace: "ns", Name: "api", UID: "owner-uid",
		}, func(RelationshipScanUpdate) error { return nil })
	}()
	select {
	case <-requestStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("relationship discovery request did not start")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("ScanRelationships error = %v, want context.Canceled", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("relationship scan did not return after cancellation")
	}
	select {
	case <-requestCanceled:
	case <-time.After(2 * time.Second):
		t.Fatal("discovery HTTP handler did not observe request cancellation")
	}
	for _, action := range metadataClient.Actions() {
		if action.GetVerb() == "list" {
			t.Fatalf("metadata LIST began before discovery completed: %v", metadataClient.Actions())
		}
	}
}

func newClusterRelationshipReader(t *testing.T, handler http.Handler) (*Reader, string) {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)

	kubeconfigPath := filepath.Join(t.TempDir(), "config")
	kubeconfig := fmt.Sprintf(`apiVersion: v1
kind: Config
clusters:
- name: target
  cluster:
    server: %q
contexts:
- name: target
  context:
    cluster: target
current-context: target
`, server.URL)
	if err := os.WriteFile(kubeconfigPath, []byte(kubeconfig), 0o600); err != nil {
		t.Fatal(err)
	}
	catalog, err := cluster.DiscoverPaths([]string{kubeconfigPath})
	if err != nil {
		t.Fatal(err)
	}
	contexts := catalog.Contexts()
	if len(contexts) != 1 {
		t.Fatalf("kubeconfig contexts = %#v", contexts)
	}
	registry := cluster.NewSessionRegistry(nil)
	t.Cleanup(registry.CloseAll)
	session, err := registry.Open(catalog, contexts[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	reader, err := NewReader(ClusterResolver{Sessions: registry})
	if err != nil {
		t.Fatal(err)
	}
	return reader, session.ID()
}

func newRelationshipDiscoveryClient(t *testing.T, handler http.Handler) discovery.DiscoveryInterface {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if authorization := request.Header.Get("Authorization"); authorization != "Bearer relationship-test-token" {
			t.Errorf("Authorization header = %q, want discovery client bearer token", authorization)
			http.Error(writer, "unauthorized", http.StatusUnauthorized)
			return
		}
		handler.ServeHTTP(writer, request)
	}))
	t.Cleanup(server.Close)
	client, err := discovery.NewDiscoveryClientForConfig(&rest.Config{
		Host: server.URL, BearerToken: "relationship-test-token",
	})
	if err != nil {
		server.Close()
		t.Fatal(err)
	}
	return client
}

func writeRelationshipDiscoveryJSON(t *testing.T, writer http.ResponseWriter, value any) {
	t.Helper()
	writer.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(writer).Encode(value); err != nil {
		t.Errorf("encode relationship discovery response: %v", err)
	}
}

func relationshipDiscoveryHandler(
	t *testing.T,
	lists []*metav1.APIResourceList,
) http.Handler {
	t.Helper()
	coreVersions := make([]string, 0)
	groupsByName := make(map[string]*metav1.APIGroup)
	listsByPath := make(map[string]*metav1.APIResourceList, len(lists))
	for _, list := range lists {
		if list == nil {
			continue
		}
		groupVersion, err := schema.ParseGroupVersion(list.GroupVersion)
		if err != nil {
			t.Fatalf("invalid test discovery group version %q: %v", list.GroupVersion, err)
		}
		path := "/api/" + groupVersion.Version
		if groupVersion.Group == "" {
			coreVersions = append(coreVersions, groupVersion.Version)
		} else {
			path = "/apis/" + list.GroupVersion
			group := groupsByName[groupVersion.Group]
			if group == nil {
				group = &metav1.APIGroup{Name: groupVersion.Group}
				groupsByName[groupVersion.Group] = group
			}
			version := metav1.GroupVersionForDiscovery{
				GroupVersion: list.GroupVersion, Version: groupVersion.Version,
			}
			group.Versions = append(group.Versions, version)
			if group.PreferredVersion.Version == "" {
				group.PreferredVersion = version
			}
		}
		listsByPath[path] = list
	}
	groups := make([]metav1.APIGroup, 0, len(groupsByName))
	for _, group := range groupsByName {
		groups = append(groups, *group)
	}
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api":
			writeRelationshipDiscoveryJSON(t, writer, &metav1.APIVersions{Versions: coreVersions})
		case "/apis":
			writeRelationshipDiscoveryJSON(t, writer, &metav1.APIGroupList{Groups: groups})
		default:
			if list := listsByPath[request.URL.Path]; list != nil {
				writeRelationshipDiscoveryJSON(t, writer, list)
				return
			}
			http.NotFound(writer, request)
		}
	})
}

func partialMetadata(
	apiVersion, kind, namespace, name string,
	uid, ownerUID types.UID,
) *metav1.PartialObjectMetadata {
	value := &metav1.PartialObjectMetadata{
		TypeMeta: metav1.TypeMeta{APIVersion: apiVersion, Kind: kind},
		ObjectMeta: metav1.ObjectMeta{
			Namespace: namespace, Name: name, UID: uid,
			OwnerReferences: []metav1.OwnerReference{{UID: ownerUID}},
		},
	}
	value.SetGroupVersionKind(schema.FromAPIVersionAndKind(apiVersion, kind))
	return value
}
