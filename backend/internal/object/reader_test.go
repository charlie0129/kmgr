package object

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

func TestGetRejectsSameNameRecreatedUID(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "new-uid")
	reader := testReader(t, value)
	_, err := reader.Get(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "ns", Name: "pod", UID: "old-uid",
	})
	var changed *IdentityChangedError
	if !errors.As(err, &changed) || changed.ActualUID != "new-uid" {
		t.Fatalf("Get error = %#v, want IdentityChangedError", err)
	}
}

func TestResourceReturnsExactNamespacedAndClusterScopedInterfaces(t *testing.T) {
	t.Parallel()
	resolver := &recordingResolver{resource: &fakeResourceInterface{}}
	reader, err := NewReader(resolver)
	if err != nil {
		t.Fatal(err)
	}
	namespaced := Identity{
		SessionID: "session", Group: "apps", Version: "v1", Resource: "deployments",
		Namespace: "team-a", Name: "web", UID: "uid-web",
	}
	resource, err := reader.Resource(namespaced)
	if err != nil || resource != resolver.resource {
		t.Fatalf("Resource() = %#v, %v", resource, err)
	}
	if resolver.sessionID != "session" || resolver.gvr != namespaced.GVR() || resolver.namespace != "team-a" {
		t.Fatalf("resolver call = %q %#v %q", resolver.sessionID, resolver.gvr, resolver.namespace)
	}
	clusterScoped := namespaced
	clusterScoped.Namespace = ""
	clusterScoped.Name = "node-a"
	clusterScoped.Resource = "nodes"
	clusterScoped.Group = ""
	if _, err := reader.Resource(clusterScoped); err != nil || resolver.namespace != "" || resolver.gvr != clusterScoped.GVR() {
		t.Fatalf("cluster-scoped Resource() = %v, call = %#v %q", err, resolver.gvr, resolver.namespace)
	}
}

func TestDetailReturnsReadableYAMLWithoutJSONCrossingBoundary(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "uid")
	value.Object["status"] = map[string]any{"phase": "Running"}
	reader := testReader(t, value)
	detail, err := reader.Detail(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "ns", Name: "pod", UID: "uid",
	}, true, true)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(detail.YAML, []byte("kind: Pod")) || bytes.HasPrefix(bytes.TrimSpace(detail.YAML), []byte("{")) {
		t.Fatalf("detail YAML = %q", detail.YAML)
	}
	if len(detail.Summary) == 0 || detail.Summary[len(detail.Summary)-1].Value != "Running" {
		t.Fatalf("summary = %#v", detail.Summary)
	}
}

func TestDetailYAMLOmitsManagedFieldsWithoutMutatingAuthoritativeObject(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	value.SetManagedFields([]metav1.ManagedFieldsEntry{{
		Manager: "controller-manager", Operation: metav1.ManagedFieldsOperationUpdate,
	}})
	value.Object["data"] = map[string]any{
		"managedFields": "application-value",
		"mode":          "fast",
	}

	detail, err := detailFromObject(value, Identity{
		SessionID: "session", Version: "v1", Resource: "configmaps",
		Namespace: "ns", Name: "settings", UID: "uid",
	}, true, false)
	if err != nil {
		t.Fatal(err)
	}
	display, err := parseSingleYAMLObject(detail.YAML)
	if err != nil {
		t.Fatalf("parse display YAML: %v", err)
	}
	if _, found, err := unstructured.NestedFieldNoCopy(
		display.Object, "metadata", "managedFields",
	); err != nil || found {
		t.Fatalf("display YAML exposed metadata.managedFields: %#v (error %v)", display.Object, err)
	}
	data, found, err := unstructured.NestedMap(display.Object, "data")
	if err != nil || !found || data["managedFields"] != "application-value" || data["mode"] != "fast" {
		t.Fatalf("display YAML lost a non-metadata field: %#v (error %v)", display.Object, err)
	}
	managedFields := value.GetManagedFields()
	if len(managedFields) != 1 || managedFields[0].Manager != "controller-manager" {
		t.Fatalf("authoritative managedFields changed: %#v", managedFields)
	}
}

func TestPodSummaryIncludesBoundedContainerChoicesAndDeclaredPorts(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "uid")
	value.Object["spec"] = map[string]any{
		"containers": []any{
			map[string]any{
				"name": "main", "image": "private.example/application:secret-tag",
				"env": []any{map[string]any{"name": "PASSWORD", "value": "must-not-leak"}},
				"ports": []any{
					map[string]any{"name": "http", "containerPort": int64(8080), "protocol": "TCP"},
				},
			},
		},
		"initContainers":      []any{map[string]any{"name": "migrate"}},
		"ephemeralContainers": []any{map[string]any{"name": "debugger"}},
	}
	detail, err := testReader(t, value).Detail(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "ns", Name: "pod", UID: "uid",
	}, false, true)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]struct{ section, value string }{
		"container:main":              {section: "containers", value: "main"},
		"port:TCP:8080:http":          {section: "ports", value: "http: 8080/TCP"},
		"initContainer:migrate":       {section: "containers", value: "migrate"},
		"ephemeralContainer:debugger": {section: "containers", value: "debugger"},
	}
	for _, field := range detail.Summary {
		if expected, found := want[field.ID]; found {
			if field.Section != expected.section || field.Value != expected.value {
				t.Fatalf("summary field %#v, want %#v", field, expected)
			}
			delete(want, field.ID)
		}
		if strings.Contains(field.Value, "must-not-leak") || strings.Contains(field.Value, "secret-tag") {
			t.Fatalf("summary leaked an image or environment value: %#v", field)
		}
	}
	if len(want) != 0 {
		t.Fatalf("missing summary fields: %#v", want)
	}
}

func TestPodSummaryIncludesMostRecentContainerRestartReason(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "uid")
	value.Object["status"] = map[string]any{
		"containerStatuses": []any{
			map[string]any{"lastState": map[string]any{"terminated": map[string]any{
				"reason": "Error", "exitCode": int64(1), "finishedAt": "2026-08-25T01:00:00Z",
			}}},
			map[string]any{"lastState": map[string]any{"terminated": map[string]any{
				"reason": "OOMKilled", "exitCode": int64(137), "finishedAt": "2026-08-25T03:00:00Z",
			}}},
		},
		"initContainerStatuses": []any{
			map[string]any{"lastState": map[string]any{"terminated": map[string]any{
				"reason": "Completed", "exitCode": int64(0), "finishedAt": "2026-08-25T02:00:00Z",
			}}},
		},
	}
	detail, err := testReader(t, value).Detail(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "ns", Name: "pod", UID: "uid",
	}, false, true)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range detail.Summary {
		if field.ID != "lastRestartReason" {
			continue
		}
		if field.Section != "status" || field.Label != "Last Restart Reason" ||
			field.Value != "OOMKilled · Exit code 137" ||
			field.Timestamp.Format(time.RFC3339) != "2026-08-25T03:00:00Z" ||
			field.TimestampPresentation != SummaryTimestampOccurredAt {
			t.Fatalf("restart reason summary = %#v", field)
		}
		return
	}
	t.Fatalf("restart reason missing from summary: %#v", detail.Summary)
}

func TestNodeSummaryIncludesSchedulingNetworkResourcesAndSystemInfo(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Node", "nodes", "", "worker-a", "uid")
	value.SetLabels(map[string]string{
		"node-role.kubernetes.io/worker":        "",
		"node-role.kubernetes.io/control-plane": "true",
	})
	value.Object["spec"] = map[string]any{
		"providerID":    "aws:///us-east-1a/i-0123456789",
		"unschedulable": true,
		"taints": []any{
			map[string]any{"key": "dedicated", "value": "gpu", "effect": "NoSchedule"},
			map[string]any{"key": "maintenance", "effect": "NoExecute"},
		},
		"podCIDR":  "10.244.0.0/24",
		"podCIDRs": []any{"10.244.0.0/24", "fd00:10::/64"},
	}
	value.Object["status"] = map[string]any{
		"addresses": []any{
			map[string]any{"type": "InternalIP", "address": "10.0.0.10"},
			map[string]any{"type": "Hostname", "address": "worker-a"},
			map[string]any{"type": "ExternalIP", "address": "203.0.113.10"},
			map[string]any{"type": "InternalIP", "address": "10.0.0.10"},
		},
		"capacity": map[string]any{
			"cpu": "8", "memory": "32Gi", "pods": "110",
		},
		"allocatable": map[string]any{
			"cpu": "7800m", "memory": "30Gi", "pods": "100",
		},
		"nodeInfo": map[string]any{
			"architecture":            "amd64",
			"containerRuntimeVersion": "containerd://1.7.20",
			"kernelVersion":           "6.8.0",
			"kubeletVersion":          "v1.33.2",
			"kubeProxyVersion":        "v1.33.2",
			"operatingSystem":         "linux",
			"osImage":                 "Ubuntu 24.04.2 LTS",
		},
	}

	detail, err := testReader(t, value).Detail(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "nodes", Name: "worker-a", UID: "uid",
	}, false, true)
	if err != nil {
		t.Fatal(err)
	}
	byID := make(map[string]SummaryField, len(detail.Summary))
	for _, field := range detail.Summary {
		byID[field.ID] = field
	}
	for id, expected := range map[string]string{
		"roles":                   "control-plane, worker",
		"unschedulable":           "true",
		"taint:0":                 "dedicated=gpu:NoSchedule",
		"taint:1":                 "maintenance:NoExecute",
		"address:0":               "worker-a",
		"address:1":               "10.0.0.10",
		"address:2":               "203.0.113.10",
		"podCIDR:0":               "10.244.0.0/24",
		"podCIDR:1":               "fd00:10::/64",
		"allocatable:cpu":         "7.8",
		"capacity:cpu":            "8",
		"allocatable:memory":      "30Gi",
		"capacity:memory":         "32Gi",
		"allocatable:pods":        "100",
		"capacity:pods":           "110",
		"providerID":              "aws:///us-east-1a/i-0123456789",
		"architecture":            "amd64",
		"containerRuntimeVersion": "containerd://1.7.20",
		"kubeletVersion":          "v1.33.2",
	} {
		field, found := byID[id]
		if !found || field.Value != expected {
			t.Errorf("summary[%q] = %#v, want value %q", id, field, expected)
		}
	}
	if detailField := byID["taint:0"]; detailField.Section != "taints" {
		t.Fatalf("taint section = %q, want taints", detailField.Section)
	}
	if byID["address:0"].Label != "Hostname" || byID["address:1"].Label != "Internal IP" {
		t.Fatalf("address labels = %#v, %#v", byID["address:0"], byID["address:1"])
	}
	if _, found := byID["podCIDR:2"]; found {
		t.Fatal("duplicate singular podCIDR was rendered")
	}
}

func TestNodeSummaryUsesLargerKubernetesQuantityUnits(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Node", "nodes", "", "worker", "uid")
	value.Object["status"] = map[string]any{
		"allocatable": map[string]any{
			"cpu":               "7800m",
			"memory":            "2108963164Ki",
			"ephemeral-storage": "464503396794",
			"hugepages-2Mi":     "131072Ki",
			"example.com/gpu":   "2",
		},
		"capacity": map[string]any{
			"memory": "2112620892Ki",
		},
	}

	fields := summaryFieldsByID(summarize(value))
	for id, expected := range map[string]string{
		"allocatable:cpu":               "7.8",
		"allocatable:memory":            "1.96Ti",
		"allocatable:ephemeral-storage": "432.6Gi",
		"allocatable:hugepages-2Mi":     "128Mi",
		"allocatable:example.com/gpu":   "2",
		"capacity:memory":               "1.97Ti",
	} {
		if field, ok := fields[id]; !ok || field.Value != expected {
			t.Errorf("summary[%q] = %#v, want value %q", id, field, expected)
		}
	}
}

func TestNodeSummaryUsesNodeIdentityWhenTypeMetaIsOmitted(t *testing.T) {
	t.Parallel()
	value := &unstructured.Unstructured{Object: map[string]any{
		"metadata": map[string]any{
			"name": "worker", "uid": "uid", "resourceVersion": "rv-1",
		},
		"spec": map[string]any{
			"taints": []any{map[string]any{
				"key": "dedicated", "effect": "NoSchedule",
			}},
		},
	}}
	detail, err := detailFromObject(value, Identity{
		SessionID: "session", Version: "v1", Resource: "nodes", Name: "worker", UID: "uid",
	}, false, true)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range detail.Summary {
		if field.ID == "taint:0" && field.Value == "dedicated:NoSchedule" {
			return
		}
	}
	t.Fatalf("Node projection missing when TypeMeta is omitted: %#v", detail.Summary)
}

func TestNodeSummaryKeepsTaintsSectionVisibleWhenEmpty(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Node", "nodes", "", "worker", "uid")
	fields := summaryFieldsByID(summarize(value))
	field, found := fields["taints"]
	if !found {
		t.Fatalf("empty Node omitted Taints summary: %#v", fields)
	}
	if field.Section != "taints" || field.Label != "Taints" || field.Value != "None" {
		t.Fatalf("empty Taints summary = %#v", field)
	}
}

func TestNodeSummaryBoundsCollectionsAndSkipsInvalidQuantities(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Node", "nodes", "", "worker", "uid")
	taints := make([]any, maximumSummaryNodeTaints+8)
	addresses := make([]any, maximumSummaryAddresses+8)
	cidrs := make([]any, maximumSummaryNodeCIDRs+8)
	resources := make(map[string]any, maximumSummaryNodeResources+2)
	for index := range taints {
		taints[index] = map[string]any{
			"key": fmt.Sprintf("taint-%d", index), "effect": "NoSchedule",
		}
	}
	for index := range addresses {
		addresses[index] = map[string]any{
			"type": "InternalIP", "address": fmt.Sprintf("10.0.0.%d", index+1),
		}
	}
	for index := range cidrs {
		cidrs[index] = fmt.Sprintf("10.%d.0.0/16", index+1)
	}
	for index := range maximumSummaryNodeResources + 1 {
		resources[fmt.Sprintf("example.test/resource-%d", index)] = "1"
	}
	resources["not-a-quantity"] = map[string]any{"unexpected": true}
	value.Object["spec"] = map[string]any{
		"taints":   taints,
		"podCIDRs": cidrs,
	}
	value.Object["status"] = map[string]any{
		"addresses":   addresses,
		"allocatable": resources,
	}

	fields := summarize(value)
	counts := make(map[string]int)
	markers := make(map[string]bool)
	for _, field := range fields {
		switch {
		case field.Section == "taints" && strings.HasPrefix(field.ID, "taint:"):
			counts["taints"]++
		case field.Section == "network" && strings.HasPrefix(field.ID, "address:"):
			counts["addresses"]++
		case field.Section == "network" && strings.HasPrefix(field.ID, "podCIDR:"):
			counts["cidrs"]++
		case field.Section == "resources" && strings.HasPrefix(field.ID, "allocatable:"):
			counts["resources"]++
		}
		if strings.HasSuffix(field.ID, "Omitted") {
			markers[field.ID] = true
		}
	}
	if counts["taints"] != maximumSummaryNodeTaints || !markers["taintsOmitted"] {
		t.Errorf("bounded taints = %d/%t", counts["taints"], markers["taintsOmitted"])
	}
	if counts["addresses"] != maximumSummaryAddresses || !markers["addressesOmitted"] {
		t.Errorf("bounded addresses = %d/%t", counts["addresses"], markers["addressesOmitted"])
	}
	if counts["cidrs"] != maximumSummaryNodeCIDRs || !markers["podCIDRsOmitted"] {
		t.Errorf("bounded pod CIDRs = %d/%t", counts["cidrs"], markers["podCIDRsOmitted"])
	}
	if counts["resources"] != maximumSummaryNodeResources || !markers["resourcesOmitted"] {
		t.Errorf("bounded resources = %d/%t", counts["resources"], markers["resourcesOmitted"])
	}
	for _, field := range fields {
		if strings.Contains(field.ID, "not-a-quantity") {
			t.Fatalf("invalid resource was included: %#v", field)
		}
	}
}

func TestServiceSummaryIncludesDeclaredAndTargetPorts(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Service", "services", "ns", "web", "uid")
	value.Object["spec"] = map[string]any{
		"type":        "LoadBalancer",
		"clusterIP":   "10.0.0.42",
		"selector":    map[string]any{"tier": "frontend", "app": "api"},
		"externalIPs": []any{"203.0.113.10"},
		"ports": []any{
			map[string]any{"name": "http", "port": int64(80), "targetPort": int64(8080)},
			map[string]any{"name": "admin", "port": int64(8443), "targetPort": "admin", "protocol": "TCP"},
		},
	}
	value.Object["status"] = map[string]any{"loadBalancer": map[string]any{"ingress": []any{
		map[string]any{"hostname": "public.example.test"},
	}}}
	detail, err := testReader(t, value).Detail(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "services", Namespace: "ns", Name: "web", UID: "uid",
	}, false, true)
	if err != nil {
		t.Fatal(err)
	}
	ports := make([]string, 0, 2)
	ids := make([]string, 0, 2)
	for _, field := range detail.Summary {
		if field.Section == "ports" {
			ports = append(ports, field.Value)
			ids = append(ids, field.ID)
		}
	}
	if got, want := strings.Join(ports, ","), "http: 80/TCP → 8080,admin: 8443/TCP → admin"; got != want {
		t.Fatalf("service port summary = %q, want %q", got, want)
	}
	if got, want := strings.Join(ids, ","), "port:TCP:80:http,port:TCP:8443:admin"; got != want {
		t.Fatalf("service port IDs = %q, want %q", got, want)
	}
	selectors := make([]string, 0, 2)
	addresses := make([]string, 0, 2)
	serviceFields := make(map[string]string)
	for _, field := range detail.Summary {
		switch field.Section {
		case "selectors":
			selectors = append(selectors, field.Label+"="+field.Value)
		case "endpoints":
			addresses = append(addresses, field.Value)
		case "service":
			serviceFields[field.ID] = field.Value
		}
	}
	if got, want := strings.Join(selectors, ","), "app=api,tier=frontend"; got != want {
		t.Fatalf("service selectors = %q, want %q", got, want)
	}
	if got, want := strings.Join(addresses, ","), "203.0.113.10,public.example.test"; got != want {
		t.Fatalf("service endpoint addresses = %q, want %q", got, want)
	}
	if serviceFields["type"] != "LoadBalancer" || serviceFields["clusterIP"] != "10.0.0.42" {
		t.Fatalf("service overview = %#v", serviceFields)
	}
}

func TestWorkloadSummaryCarriesOnlyRepresentablePodSelectors(t *testing.T) {
	t.Parallel()
	for _, kind := range []string{"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"} {
		t.Run(kind, func(t *testing.T) {
			value := kubernetesObject("apps/v1", kind, strings.ToLower(kind)+"s", "ns", "workload", "uid")
			value.Object["spec"] = map[string]any{"selector": map[string]any{
				"matchLabels": map[string]any{"tier": "frontend", "app": "api"},
				"matchExpressions": []any{map[string]any{
					"key": "track", "operator": "In", "values": []any{"stable"},
				}},
			}}
			fields := summarize(value)
			selectors := make(map[string]string)
			for _, field := range fields {
				if field.Section == "selectors" {
					selectors[field.ID] = field.Label + "=" + field.Value
				}
			}
			if selectors["selector:0"] != "app=api" || selectors["selector:1"] != "tier=frontend" {
				t.Fatalf("selector summary = %#v", selectors)
			}
			if !strings.Contains(selectors["selectorExpressions"], "cannot be represented") {
				t.Fatalf("match-expression marker = %q", selectors["selectorExpressions"])
			}
		})
	}
}

func TestReplicationControllerSummaryCarriesFlatPodSelector(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "ReplicationController", "replicationcontrollers", "ns", "legacy", "uid")
	value.Object["spec"] = map[string]any{"selector": map[string]any{"app": "legacy"}}
	fields := summarize(value)
	for _, field := range fields {
		if field.Section == "selectors" && field.Label == "app" && field.Value == "legacy" {
			return
		}
	}
	t.Fatalf("flat selector missing from %#v", fields)
}

func TestDetailCarriesCanonicalWorkloadPodLabelSelector(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name, group, version, resource, apiVersion, kind string
	}{
		{name: "Deployment", group: "apps", version: "v1", resource: "deployments", apiVersion: "apps/v1", kind: "Deployment"},
		{name: "StatefulSet", group: "apps", version: "v1", resource: "statefulsets", apiVersion: "apps/v1", kind: "StatefulSet"},
		{name: "DaemonSet", group: "apps", version: "v1", resource: "daemonsets", apiVersion: "apps/v1", kind: "DaemonSet"},
		{name: "ReplicaSet", group: "apps", version: "v1", resource: "replicasets", apiVersion: "apps/v1", kind: "ReplicaSet"},
		{name: "Job", group: "batch", version: "v1", resource: "jobs", apiVersion: "batch/v1", kind: "Job"},
	}
	const want = "app=api,debug,!deprecated,tier=frontend,track in (canary,stable),zone notin (east,west)"
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			value := kubernetesObject(test.apiVersion, test.kind, test.resource, "ns", "workload", "uid")
			value.Object["spec"] = map[string]any{"selector": map[string]any{
				"matchLabels": map[string]any{"tier": "frontend", "app": "api"},
				"matchExpressions": []any{
					map[string]any{"key": "track", "operator": "In", "values": []any{"stable", "canary"}},
					map[string]any{"key": "zone", "operator": "NotIn", "values": []any{"west", "east"}},
					map[string]any{"key": "debug", "operator": "Exists"},
					map[string]any{"key": "deprecated", "operator": "DoesNotExist"},
				},
			}}
			detail, err := detailFromObject(value, Identity{
				SessionID: "session", Group: test.group, Version: test.version,
				Resource: test.resource, Namespace: "ns", Name: "workload", UID: "uid",
			}, false, true)
			if err != nil {
				t.Fatal(err)
			}
			if detail.PodLabelSelector != want {
				t.Fatalf("PodLabelSelector = %q, want %q", detail.PodLabelSelector, want)
			}
		})
	}
}

func TestDetailCarriesCanonicalFlatPodLabelSelector(t *testing.T) {
	t.Parallel()
	for _, resource := range []string{"services", "replicationcontrollers"} {
		resource := resource
		t.Run(resource, func(t *testing.T) {
			t.Parallel()
			kind := "Service"
			if resource == "replicationcontrollers" {
				kind = "ReplicationController"
			}
			value := kubernetesObject("v1", kind, resource, "ns", "selected", "uid")
			value.Object["spec"] = map[string]any{
				"selector": map[string]any{"tier": "frontend", "app": "api"},
			}
			detail, err := detailFromObject(value, Identity{
				SessionID: "session", Version: "v1", Resource: resource,
				Namespace: "ns", Name: "selected", UID: "uid",
			}, false, true)
			if err != nil {
				t.Fatal(err)
			}
			if got, want := detail.PodLabelSelector, "app=api,tier=frontend"; got != want {
				t.Fatalf("PodLabelSelector = %q, want %q", got, want)
			}
		})
	}
}

func TestDetailOmitsUnsafePodLabelSelectorsWithoutFailing(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name     string
		identity Identity
		spec     map[string]any
	}{
		{
			name: "missing Service selector",
			identity: Identity{SessionID: "session", Version: "v1", Resource: "services",
				Namespace: "ns", Name: "selected", UID: "uid"},
			spec: map[string]any{},
		},
		{
			name: "empty Service selector",
			identity: Identity{SessionID: "session", Version: "v1", Resource: "services",
				Namespace: "ns", Name: "selected", UID: "uid"},
			spec: map[string]any{"selector": map[string]any{}},
		},
		{
			name: "malformed Service selector",
			identity: Identity{SessionID: "session", Version: "v1", Resource: "services",
				Namespace: "ns", Name: "selected", UID: "uid"},
			spec: map[string]any{"selector": map[string]any{"not a label key": "api"}},
		},
		{
			name: "empty workload selector",
			identity: Identity{SessionID: "session", Group: "apps", Version: "v1", Resource: "deployments",
				Namespace: "ns", Name: "selected", UID: "uid"},
			spec: map[string]any{"selector": map[string]any{"matchLabels": map[string]any{}}},
		},
		{
			name: "invalid workload operator",
			identity: Identity{SessionID: "session", Group: "apps", Version: "v1", Resource: "deployments",
				Namespace: "ns", Name: "selected", UID: "uid"},
			spec: map[string]any{"selector": map[string]any{"matchExpressions": []any{
				map[string]any{"key": "track", "operator": "Around", "values": []any{"stable"}},
			}}},
		},
		{
			name: "malformed workload value type",
			identity: Identity{SessionID: "session", Group: "apps", Version: "v1", Resource: "deployments",
				Namespace: "ns", Name: "selected", UID: "uid"},
			spec: map[string]any{"selector": map[string]any{"matchLabels": map[string]any{"app": int64(7)}}},
		},
		{
			name: "familiar Kind on unsupported GVR",
			identity: Identity{SessionID: "session", Group: "example.test", Version: "v1", Resource: "deployments",
				Namespace: "ns", Name: "selected", UID: "uid"},
			spec: map[string]any{"selector": map[string]any{"matchLabels": map[string]any{"app": "api"}}},
		},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			value := kubernetesObject("apps/v1", "Deployment", test.identity.Resource, "ns", "selected", "uid")
			value.Object["spec"] = test.spec
			detail, err := detailFromObject(value, test.identity, false, true)
			if err != nil {
				t.Fatalf("detailFromObject returned an error for an optional selector: %v", err)
			}
			if detail.PodLabelSelector != "" {
				t.Fatalf("PodLabelSelector = %q, want omission", detail.PodLabelSelector)
			}
		})
	}
}

func TestPodLabelSelectorIsCompleteBeyondSummaryBound(t *testing.T) {
	t.Parallel()
	selectorCount := maximumSummarySelectors + 20
	selectors := make(map[string]any, selectorCount)
	wantTerms := make([]string, selectorCount)
	for index := range selectorCount {
		key := fmt.Sprintf("selector-%03d", index)
		value := fmt.Sprintf("value-%03d", index)
		selectors[key] = value
		wantTerms[index] = key + "=" + value
	}
	value := kubernetesObject("v1", "Service", "services", "ns", "selected", "uid")
	value.Object["spec"] = map[string]any{"selector": selectors}
	detail, err := detailFromObject(value, Identity{
		SessionID: "session", Version: "v1", Resource: "services",
		Namespace: "ns", Name: "selected", UID: "uid",
	}, false, true)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := detail.PodLabelSelector, strings.Join(wantTerms, ","); got != want {
		t.Fatalf("complete PodLabelSelector = %q, want %q", got, want)
	}
	selectorFields := 0
	omitted := false
	for _, field := range detail.Summary {
		if field.Section != "selectors" {
			continue
		}
		if field.ID == "selectorsOmitted" {
			omitted = true
		} else {
			selectorFields++
		}
	}
	if selectorFields != maximumSummarySelectors || !omitted {
		t.Fatalf("bounded selector summary = %d fields, omitted=%t", selectorFields, omitted)
	}
}

func TestDetailResponseCarriesPodLabelSelector(t *testing.T) {
	t.Parallel()
	response := detailResponse("request", &kmgrv1.ResourceIdentity{}, Detail{
		PodLabelSelector: "app=api,track in (canary,stable)",
	})
	if got, want := response.GetPodLabelSelector(), "app=api,track in (canary,stable)"; got != want {
		t.Fatalf("PodLabelSelector = %q, want %q", got, want)
	}
}

func TestDetailResponseCarriesSummaryTimestampPresentation(t *testing.T) {
	t.Parallel()
	when := time.Date(2026, 8, 25, 3, 0, 0, 123_000_000, time.UTC)
	response := detailResponse("request", &kmgrv1.ResourceIdentity{}, Detail{
		Summary: []SummaryField{
			{Timestamp: when, TimestampPresentation: SummaryTimestampElapsedSince},
			{Timestamp: when, TimestampPresentation: SummaryTimestampOccurredAt},
		},
	})
	if len(response.SummaryFields) != 2 {
		t.Fatalf("summary fields = %#v", response.SummaryFields)
	}
	if response.SummaryFields[0].TimestampUnixMs != when.UnixMilli() ||
		response.SummaryFields[0].TimestampPresentation !=
			kmgrv1.SummaryTimestampPresentation_SUMMARY_TIMESTAMP_PRESENTATION_ELAPSED_SINCE {
		t.Fatalf("elapsed timestamp = %#v", response.SummaryFields[0])
	}
	if response.SummaryFields[1].TimestampUnixMs != when.UnixMilli() ||
		response.SummaryFields[1].TimestampPresentation !=
			kmgrv1.SummaryTimestampPresentation_SUMMARY_TIMESTAMP_PRESENTATION_OCCURRED_AT {
		t.Fatalf("occurrence timestamp = %#v", response.SummaryFields[1])
	}
}

func TestWorkloadSummaryPreservesMaximumQualifiedSelectorKey(t *testing.T) {
	t.Parallel()
	prefix := strings.Repeat("a", 63) + "." + strings.Repeat("b", 63) + "." +
		strings.Repeat("c", 63) + "." + strings.Repeat("d", 61)
	key := prefix + "/" + strings.Repeat("e", 63)
	value := kubernetesObject("apps/v1", "Deployment", "deployments", "ns", "workload", "uid")
	value.Object["spec"] = map[string]any{"selector": map[string]any{
		"matchLabels": map[string]any{key: "selected"},
	}}
	for _, field := range summarize(value) {
		if field.Section == "selectors" && field.Label == key && field.Value == "selected" {
			return
		}
	}
	t.Fatalf("qualified selector key was truncated in %#v", summarize(value))
}

func TestGenericSummaryIncludesConditionsOwnersAndWorkloadStatus(t *testing.T) {
	t.Parallel()
	controller := true
	value := kubernetesObject("apps/v1", "Deployment", "deployments", "team-a", "api", "uid")
	value.SetGeneration(7)
	value.SetOwnerReferences([]metav1.OwnerReference{{
		APIVersion: "apps/v1", Kind: "ReplicaSet", Name: "api-784dc9", UID: "owner-uid", Controller: &controller,
	}})
	value.Object["spec"] = map[string]any{"replicas": int64(5)}
	value.Object["status"] = map[string]any{
		"observedGeneration": int64(7), "replicas": int64(5), "readyReplicas": int64(4),
		"conditions": []any{map[string]any{
			"type": "Available", "status": "True", "reason": "MinimumReplicasAvailable",
			"message":            "Deployment has minimum availability",
			"lastTransitionTime": "2026-08-14T02:03:04Z",
		}},
	}
	detail, err := testReader(t, value).Detail(context.Background(), Identity{
		SessionID: "session", Group: "apps", Version: "v1", Resource: "deployments",
		Namespace: "team-a", Name: "api", UID: "uid",
	}, false, true)
	if err != nil {
		t.Fatal(err)
	}
	byID := make(map[string]SummaryField)
	for _, field := range detail.Summary {
		byID[field.ID] = field
	}
	for id, expected := range map[string]string{
		"generation":         "7",
		"observedGeneration": "7",
		"desiredReplicas":    "5",
		"replicas":           "5",
		"readyReplicas":      "4",
	} {
		if byID[id].Value != expected {
			t.Errorf("summary[%q] = %#v, want value %q", id, byID[id], expected)
		}
	}
	condition := byID["condition:0"]
	if condition.Section != "conditions" || condition.Label != "Available" ||
		!strings.Contains(condition.Value, "MinimumReplicasAvailable") ||
		!strings.Contains(condition.Value, "Deployment has minimum availability") ||
		condition.Timestamp.Format(time.RFC3339) != "2026-08-14T02:03:04Z" ||
		condition.TimestampPresentation != SummaryTimestampElapsedSince ||
		strings.Contains(condition.Value, "2026-08-14") {
		t.Errorf("condition summary = %#v", condition)
	}
	owner := byID["owner:0"]
	if owner.Section != "owners" || !strings.Contains(owner.Value, "ReplicaSet/api-784dc9") ||
		!strings.Contains(owner.Value, "controller") || !strings.Contains(owner.Value, "owner-uid") {
		t.Errorf("owner summary = %#v", owner)
	}
}

func TestSummaryBoundsGenericMetadataAndNormalizesUntrustedText(t *testing.T) {
	t.Parallel()
	multibyte := boundedSummaryText(strings.Repeat("界", maximumSummaryValueBytes))
	if !utf8.ValidString(multibyte) || len(multibyte) > maximumSummaryValueBytes ||
		!strings.HasSuffix(multibyte, "…") {
		t.Fatalf("multibyte summary bound produced %d invalid bytes", len(multibyte))
	}
	conditionCount := maximumSummaryConditions + 20
	ownerCount := maximumSummaryOwners + 20
	selectorCount := maximumSummarySelectors + 20
	conditions := make([]any, conditionCount)
	owners := make([]any, ownerCount)
	selectors := make(map[string]any, selectorCount)
	for index := range conditions {
		conditions[index] = map[string]any{
			"type": fmt.Sprintf("Ready-%d", index), "status": "False",
			"message": strings.Repeat("very long\ncondition\x00 ", maximumSummaryValueBytes),
		}
	}
	for index := range owners {
		owners[index] = map[string]any{
			"apiVersion": "apps/v1", "kind": "Deployment", "name": fmt.Sprintf("owner-%d", index),
			"uid": fmt.Sprintf("owner-uid-%d", index),
		}
	}
	for index := range selectorCount {
		selectors[fmt.Sprintf("selector-%03d", index)] = strings.Repeat("x", maximumSummaryValueBytes+100)
	}
	value := kubernetesObject("v1", "Service", "services", "ns", "web", "uid")
	metadata := value.Object["metadata"].(map[string]any)
	metadata["ownerReferences"] = owners
	value.Object["spec"] = map[string]any{"selector": selectors}
	value.Object["status"] = map[string]any{"conditions": conditions}
	detail, err := testReader(t, value).Detail(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "services", Namespace: "ns", Name: "web", UID: "uid",
	}, false, true)
	if err != nil {
		t.Fatal(err)
	}
	counts := make(map[string]int)
	omissionMarkers := make(map[string]bool)
	for _, field := range detail.Summary {
		counts[field.Section]++
		if len(field.Label) > maximumSummaryLabelBytes || len(field.Value) > maximumSummaryValueBytes {
			t.Fatalf("unbounded summary field = %#v", field)
		}
		if strings.ContainsAny(field.Value, "\x00\n\r\t") {
			t.Fatalf("summary did not normalize whitespace: %#v", field)
		}
		if strings.HasSuffix(field.ID, "Omitted") {
			omissionMarkers[field.Section] = true
		}
	}
	for section, maximum := range map[string]int{
		"conditions": maximumSummaryConditions + 1,
		"owners":     maximumSummaryOwners + 1,
		"selectors":  maximumSummarySelectors + 1,
	} {
		if counts[section] != maximum || !omissionMarkers[section] {
			t.Errorf("%s summary count/marker = %d/%t, want %d/true", section, counts[section], omissionMarkers[section], maximum)
		}
	}
}

func TestSecretSummaryNeverIncludesPayloadOrProviderStatus(t *testing.T) {
	t.Parallel()
	const sentinel = "must-never-cross-the-secret-summary-boundary"
	value := kubernetesObject("v1", "Secret", "secrets", "ns", "credentials", "uid")
	value.Object["data"] = map[string]any{"token": base64.StdEncoding.EncodeToString([]byte(sentinel))}
	value.Object["stringData"] = map[string]any{"password": sentinel}
	value.Object["type"] = "kubernetes.io/tls"
	value.Object["status"] = map[string]any{
		"phase":      sentinel,
		"conditions": []any{map[string]any{"type": "Synced", "message": sentinel}},
	}
	detail, err := testReader(t, value).Detail(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "secrets", Namespace: "ns", Name: "credentials", UID: "uid",
	}, false, true)
	if err != nil {
		t.Fatal(err)
	}
	foundType := false
	for _, field := range detail.Summary {
		if strings.Contains(field.Label, sentinel) || strings.Contains(field.Value, sentinel) ||
			field.Section == "status" || field.Section == "conditions" {
			t.Fatalf("Secret summary exposed a payload-derived field: %#v", field)
		}
		if field.Section == "secret" && field.ID == "type" && field.Value == "kubernetes.io/tls" {
			foundType = true
		}
	}
	if !foundType {
		t.Fatalf("Secret summary omitted its non-sensitive type: %#v", detail.Summary)
	}
}

func TestPodSummaryBoundsUntrustedContainerAndPortCounts(t *testing.T) {
	t.Parallel()
	containers := make([]any, maximumSummaryContainers+20)
	ports := make([]any, maximumSummaryPorts+20)
	for index := range ports {
		ports[index] = map[string]any{"containerPort": int64(index + 1)}
	}
	for index := range containers {
		containers[index] = map[string]any{"name": fmt.Sprintf("container-%d", index), "ports": ports}
	}
	value := kubernetesObject("v1", "Pod", "pods", "ns", "pod", "uid")
	value.Object["spec"] = map[string]any{"containers": containers}
	detail, err := testReader(t, value).Detail(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "pods", Namespace: "ns", Name: "pod", UID: "uid",
	}, false, true)
	if err != nil {
		t.Fatal(err)
	}
	containerFields := 0
	portFields := 0
	omittedContainers := ""
	for _, field := range detail.Summary {
		if field.Section == "ports" {
			portFields++
		} else if field.Section == "containers" && field.ID == "containersOmitted" {
			omittedContainers = field.Value
		} else if field.Section == "containers" {
			containerFields++
		}
	}
	if containerFields != maximumSummaryContainers || portFields != maximumSummaryPorts {
		t.Fatalf("bounded summary counts = containers %d, ports %d", containerFields, portFields)
	}
	if omittedContainers != "20 not shown" {
		t.Fatalf("omitted container marker = %q", omittedContainers)
	}
}

func TestSecretDataDecodesRawBytes(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Secret", "secrets", "ns", "credentials", "uid")
	value.Object["data"] = map[string]any{
		"binary": base64.StdEncoding.EncodeToString([]byte{0, 1, 2, 255}),
		"token":  base64.StdEncoding.EncodeToString([]byte("super-secret-token")),
	}
	reader := testReader(t, value)
	data, err := reader.GetData(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "secrets", Namespace: "ns", Name: "credentials", UID: "uid",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !data.Secret || len(data.Entries) != 2 {
		t.Fatalf("data = %#v", data)
	}
	if data.Entries[0].Key != "binary" || data.Entries[0].Kind != DataBinary || !bytes.Equal(data.Entries[0].Value, []byte{0, 1, 2, 255}) {
		t.Fatalf("binary entry = %#v", data.Entries[0])
	}
	if data.Entries[1].Key != "token" || data.Entries[1].Kind != DataText || string(data.Entries[1].Value) != "super-secret-token" {
		t.Fatalf("token entry metadata mismatch")
	}
}

func TestConfigMapPreservesTextAndBinaryKinds(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	value.Object["data"] = map[string]any{"config.yaml": "enabled: true\n"}
	value.Object["binaryData"] = map[string]any{"icon": base64.StdEncoding.EncodeToString([]byte{0x89, 0x50, 0x4e, 0x47})}
	reader := testReader(t, value)
	data, err := reader.GetData(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(data.Entries) != 2 || data.Entries[0].Kind != DataText || data.Entries[1].Kind != DataBinary {
		t.Fatalf("entries = %#v", data.Entries)
	}
	if data.Entries[0].ContentHash == ([32]byte{}) || data.Entries[1].ContentHash == ([32]byte{}) {
		t.Fatal("content hashes were not populated")
	}
}

func TestConfigMapRejectsDuplicateTextAndBinaryKey(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	value.Object["data"] = map[string]any{"same": "text"}
	value.Object["binaryData"] = map[string]any{"same": base64.StdEncoding.EncodeToString([]byte("binary"))}
	reader := testReader(t, value)
	_, err := reader.GetData(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid",
	})
	if err == nil || !strings.Contains(err.Error(), "both data and binaryData") {
		t.Fatalf("GetData error = %v", err)
	}
}

func TestUpdateSecretUsesRawBytesAndOptimisticConcurrency(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Secret", "secrets", "ns", "credentials", "uid")
	value.Object["data"] = map[string]any{"token": base64.StdEncoding.EncodeToString([]byte("old"))}
	reader := testReader(t, value)
	loaded, err := reader.GetData(context.Background(), Identity{
		SessionID: "session", Version: "v1", Resource: "secrets", Namespace: "ns", Name: "credentials", UID: "uid",
	})
	if err != nil {
		t.Fatal(err)
	}
	updated, err := reader.UpdateData(context.Background(), loaded.Identity, loaded.ResourceVersion, []DataMutation{{
		Type: MutationSet, Key: "token", Kind: DataText, Value: []byte("new-value"),
		ExpectedContentHash: loaded.Entries[0].ContentHash[:],
	}})
	if err != nil {
		t.Fatal(err)
	}
	if !updated.Secret || len(updated.Entries) != 1 || string(updated.Entries[0].Value) != "new-value" {
		t.Fatalf("updated data metadata mismatch: %#v", updated)
	}
	fresh, err := reader.GetData(context.Background(), loaded.Identity)
	if err != nil {
		t.Fatal(err)
	}
	if string(fresh.Entries[0].Value) != "new-value" {
		t.Fatalf("fresh value = %q", fresh.Entries[0].Value)
	}
}

func TestUpdateDataRejectsResourceVersionAndPerKeyConflicts(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	value.Object["data"] = map[string]any{"one": "server"}
	reader := testReader(t, value)
	identity := Identity{SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid"}

	_, err := reader.UpdateData(context.Background(), identity, "stale-rv", []DataMutation{{
		Type: MutationSet, Key: "one", Kind: DataText, Value: []byte("local"),
	}})
	var versionConflict *ResourceVersionConflictError
	if !errors.As(err, &versionConflict) {
		t.Fatalf("resource version error = %#v", err)
	}

	wrongHash := make([]byte, 32)
	_, err = reader.UpdateData(context.Background(), identity, "rv-1", []DataMutation{{
		Type: MutationSet, Key: "one", Kind: DataText, Value: []byte("local"), ExpectedContentHash: wrongHash,
	}})
	var dataConflict *DataConflictError
	if !errors.As(err, &dataConflict) || len(dataConflict.CurrentHash) != 32 {
		t.Fatalf("key conflict error = %#v", err)
	}
}

func TestUpdateConfigMapRenamePreservesBinaryKind(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	value.Object["binaryData"] = map[string]any{"old.bin": base64.StdEncoding.EncodeToString([]byte{0, 1})}
	reader := testReader(t, value)
	identity := Identity{SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid"}
	loaded, err := reader.GetData(context.Background(), identity)
	if err != nil {
		t.Fatal(err)
	}
	updated, err := reader.UpdateData(context.Background(), identity, "rv-1", []DataMutation{{
		Type: MutationRename, Key: "old.bin", NewKey: "new.bin", ExpectedContentHash: loaded.Entries[0].ContentHash[:],
	}})
	if err != nil {
		t.Fatal(err)
	}
	if len(updated.Entries) != 1 || updated.Entries[0].Key != "new.bin" || updated.Entries[0].Kind != DataBinary {
		t.Fatalf("renamed entry = %#v", updated.Entries)
	}
}

func TestUpdateDataCreateOnlySetRejectsAnExistingKey(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "ConfigMap", "configmaps", "ns", "settings", "uid")
	value.Object["data"] = map[string]any{"claimed": "server value"}
	reader := testReader(t, value)
	identity := Identity{SessionID: "session", Version: "v1", Resource: "configmaps", Namespace: "ns", Name: "settings", UID: "uid"}

	_, err := reader.UpdateData(context.Background(), identity, "rv-1", []DataMutation{{
		Type: MutationSet, Key: "claimed", Kind: DataText, Value: []byte("local value"),
	}})
	var conflict *DataConflictError
	if !errors.As(err, &conflict) || conflict.Key != "claimed" || len(conflict.CurrentHash) != 32 {
		t.Fatalf("create-only set error = %#v, want DataConflictError with current hash", err)
	}
}

type fakeResolver struct {
	client      dynamic.Interface
	contextName string
}

func (r fakeResolver) Resource(_ string, gvr schema.GroupVersionResource, namespace string) (dynamic.ResourceInterface, error) {
	resource := r.client.Resource(gvr)
	if namespace != "" {
		return resource.Namespace(namespace), nil
	}
	return resource, nil
}

func (r fakeResolver) ContextName(string) (string, bool) {
	return r.contextName, r.contextName != ""
}

type recordingResolver struct {
	resource  dynamic.ResourceInterface
	sessionID string
	gvr       schema.GroupVersionResource
	namespace string
}

func (r *recordingResolver) Resource(sessionID string, gvr schema.GroupVersionResource, namespace string) (dynamic.ResourceInterface, error) {
	r.sessionID, r.gvr, r.namespace = sessionID, gvr, namespace
	return r.resource, nil
}

type fakeResourceInterface struct{ dynamic.ResourceInterface }

func testReader(t *testing.T, objects ...runtime.Object) *Reader {
	t.Helper()
	scheme := runtime.NewScheme()
	client := dynamicfake.NewSimpleDynamicClient(scheme, objects...)
	reader, err := NewReader(fakeResolver{client: client})
	if err != nil {
		t.Fatal(err)
	}
	return reader
}

func kubernetesObject(apiVersion, kind, resource, namespace, name, uid string) *unstructured.Unstructured {
	value := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": apiVersion,
		"kind":       kind,
		"metadata": map[string]any{
			"namespace":       namespace,
			"name":            name,
			"uid":             uid,
			"resourceVersion": "rv-1",
		},
	}}
	value.SetGroupVersionKind(schema.FromAPIVersionAndKind(apiVersion, kind))
	_ = resource
	return value
}
