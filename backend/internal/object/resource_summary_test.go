package object

import (
	"fmt"
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func summaryFieldsByID(fields []SummaryField) map[string]SummaryField {
	result := make(map[string]SummaryField, len(fields))
	for _, field := range fields {
		result[field.ID] = field
	}
	return result
}

func summaryHas(fields []SummaryField, section, label, value string) bool {
	for _, field := range fields {
		if field.Section == section && field.Label == label && field.Value == value {
			return true
		}
	}
	return false
}

func TestPodSummaryIncludesLifecycleSchedulingResourcesStorageAndSecurity(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("v1", "Pod", "pods", "team-a", "api", "uid")
	value.Object["spec"] = map[string]any{
		"restartPolicy":                 "Always",
		"schedulerName":                 "custom-scheduler",
		"priorityClassName":             "critical",
		"priority":                      int64(1000),
		"serviceAccountName":            "workload",
		"runtimeClassName":              "kata",
		"terminationGracePeriodSeconds": int64(45),
		"nodeSelector":                  map[string]any{"zone": "east"},
		"tolerations": []any{map[string]any{
			"key": "dedicated", "operator": "Equal", "value": "batch", "effect": "NoSchedule",
		}},
		"readinessGates": []any{map[string]any{
			"conditionType": "example.com/ready",
		}},
		"topologySpreadConstraints": []any{map[string]any{
			"maxSkew": int64(1), "topologyKey": "topology.kubernetes.io/zone",
			"whenUnsatisfiable": "DoNotSchedule", "labelSelector": map[string]any{
				"matchLabels": map[string]any{"app": "api"},
			},
		}},
		"containers": []any{map[string]any{
			"name":  "api",
			"env":   []any{map[string]any{"name": "TOKEN", "value": "never-in-summary"}},
			"image": "private.example/api:credential-looking-tag",
			"resources": map[string]any{
				"requests": map[string]any{"cpu": "250m", "memory": "128Mi"},
				"limits":   map[string]any{"cpu": "1", "memory": "256Mi"},
			},
			"readinessProbe": map[string]any{
				"httpGet":       map[string]any{"path": "/readyz", "port": int64(8080)},
				"periodSeconds": int64(5),
			},
			"volumeMounts": []any{map[string]any{"name": "config", "mountPath": "/etc/app", "readOnly": true}},
		}},
		"volumes": []any{map[string]any{"name": "config", "configMap": map[string]any{"name": "api-config"}}},
		"securityContext": map[string]any{
			"runAsNonRoot": true, "runAsUser": int64(1000),
			"windowsOptions": map[string]any{
				"hostProcess":        true,
				"gmsaCredentialSpec": "credential-spec-must-not-appear",
			},
		},
	}
	value.Object["status"] = map[string]any{
		"phase":     "Running",
		"reason":    "",
		"startTime": "2026-08-28T01:00:00Z",
		"podIPs":    []any{map[string]any{"ip": "10.0.0.7"}, map[string]any{"ip": "fd00::7"}},
		"containerStatuses": []any{map[string]any{
			"name": "api", "ready": true, "restartCount": int64(2),
			"state": map[string]any{"running": map[string]any{}},
		}},
	}

	fields := summarize(value)
	for _, expected := range []struct {
		section, label, value string
	}{
		{"status", "Restart Policy", "Always"},
		{"scheduling", "Scheduler", "custom-scheduler"},
		{"scheduling", "Priority Class", "critical"},
		{"scheduling", "Priority", "1000"},
		{"security", "Service Account", "workload"},
		{"scheduling", "zone", "east"},
		{"scheduling", "Toleration", "dedicated operator=Equal value=batch effect=NoSchedule"},
		{"scheduling", "Readiness Gate", "example.com/ready"},
		{"resources", "Container api Request CPU", "250m"},
		{"resources", "Container api Limit Memory", "256Mi"},
		{"containers", "Container api Readiness Probe", "HTTP GET /readyz:8080 · periodSeconds=5"},
		{"storage", "Volume config", "ConfigMap name=api-config"},
		{"security", "Pod Run As Non Root", "true"},
		{"status", "Container api", "Running · Ready · 2 restarts"},
		{"network", "Pod IP", "fd00::7"},
	} {
		if !summaryHas(fields, expected.section, expected.label, expected.value) {
			t.Errorf("summary missing %s/%s=%q\nfields=%#v", expected.section, expected.label, expected.value, fields)
		}
	}
	for _, field := range fields {
		if strings.Contains(field.Value, "never-in-summary") ||
			strings.Contains(field.Value, "credential-looking-tag") ||
			strings.Contains(field.Value, "credential-spec-must-not-appear") {
			t.Fatalf("Pod Summary exposed sensitive container input: %#v", field)
		}
	}
}

func TestWorkloadSummariesIncludeRolloutAndTemplateContext(t *testing.T) {
	t.Parallel()
	deployment := kubernetesObject("apps/v1", "Deployment", "deployments", "team-a", "api", "uid")
	deployment.Object["metadata"].(map[string]any)["annotations"] = map[string]any{
		"deployment.kubernetes.io/revision": "7",
	}
	deployment.Object["spec"] = map[string]any{
		"replicas": int64(3),
		"strategy": map[string]any{"type": "RollingUpdate", "rollingUpdate": map[string]any{
			"maxSurge": "25%", "maxUnavailable": int64(1),
		}},
		"minReadySeconds":         int64(10),
		"progressDeadlineSeconds": int64(600),
		"paused":                  true,
		"template": map[string]any{
			"metadata": map[string]any{"labels": map[string]any{"app": "api"}},
			"spec": map[string]any{
				"serviceAccountName": "api",
				"containers": []any{map[string]any{
					"name": "api", "resources": map[string]any{
						"requests": map[string]any{"cpu": "100m"},
					},
				}},
			},
		},
	}
	deployment.Object["status"] = map[string]any{
		"replicas": int64(3), "readyReplicas": int64(2), "updatedReplicas": int64(2),
		"availableReplicas": int64(2), "observedGeneration": int64(4),
	}
	fields := summarize(deployment)
	for _, expected := range []struct{ section, label, value string }{
		{"rollout", "Strategy", "RollingUpdate"},
		{"rollout", "Max Surge", "25%"},
		{"rollout", "Max Unavailable", "1"},
		{"rollout", "Revision", "7"},
		{"rollout", "Min Ready Seconds", "10"},
		{"rollout", "Progress Deadline Seconds", "600"},
		{"rollout", "Paused", "true"},
		{"security", "Template Service Account", "api"},
		{"resources", "Template Container api Request CPU", "100m"},
		{"rollout", "app", "api"},
	} {
		if !summaryHas(fields, expected.section, expected.label, expected.value) {
			t.Errorf("Deployment summary missing %s/%s=%q", expected.section, expected.label, expected.value)
		}
	}

	stateful := kubernetesObject("apps/v1", "StatefulSet", "statefulsets", "team-a", "db", "uid-stateful")
	stateful.Object["spec"] = map[string]any{
		"serviceName": "db-headless", "podManagementPolicy": "Parallel",
		"updateStrategy": map[string]any{"type": "RollingUpdate", "rollingUpdate": map[string]any{"partition": int64(2)}},
		"template":       map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"name": "db"}}}},
		"volumeClaimTemplates": []any{map[string]any{
			"metadata": map[string]any{"name": "data"},
			"spec":     map[string]any{"storageClassName": "fast", "accessModes": []any{"ReadWriteOnce"}, "resources": map[string]any{"requests": map[string]any{"storage": "20Gi"}}},
		}},
	}
	stateful.Object["status"] = map[string]any{"currentRevision": "db-abc", "updateRevision": "db-def"}
	statefulFields := summarize(stateful)
	for _, expected := range []struct{ section, label, value string }{
		{"rollout", "Service Name", "db-headless"},
		{"rollout", "Pod Management Policy", "Parallel"},
		{"rollout", "Update Partition", "2"},
		{"rollout", "Current Revision", "db-abc"},
		{"rollout", "Update Revision", "db-def"},
		{"storage", "Volume Claim Template data", "class=fast access=ReadWriteOnce request=20Gi"},
	} {
		if !summaryHas(statefulFields, expected.section, expected.label, expected.value) {
			t.Errorf("StatefulSet summary missing %s/%s=%q", expected.section, expected.label, expected.value)
		}
	}
}

func TestCronJobAndIngressSummariesIncludeScheduleAndRoutes(t *testing.T) {
	t.Parallel()
	cron := kubernetesObject("batch/v1", "CronJob", "cronjobs", "team-a", "backup", "uid-cron")
	cron.Object["spec"] = map[string]any{
		"schedule": "*/5 * * * *", "timeZone": "UTC", "concurrencyPolicy": "Forbid",
		"suspend": false, "startingDeadlineSeconds": int64(120),
		"jobTemplate": map[string]any{"spec": map[string]any{
			"parallelism": int64(1), "completions": int64(1),
			"template": map[string]any{"spec": map[string]any{"containers": []any{map[string]any{"name": "backup"}}}},
		}},
	}
	cron.Object["status"] = map[string]any{"lastScheduleTime": "2026-08-29T01:00:00Z"}
	cronFields := summarize(cron)
	for _, expected := range []struct{ section, label, value string }{
		{"job", "Schedule", "*/5 * * * *"},
		{"job", "Time Zone", "UTC"},
		{"job", "Concurrency Policy", "Forbid"},
		{"job", "Starting Deadline", "2m"},
		{"job", "Job Template Parallelism", "1"},
		{"containers", "Template Container", "backup"},
	} {
		if !summaryHas(cronFields, expected.section, expected.label, expected.value) {
			t.Errorf("CronJob summary missing %s/%s=%q", expected.section, expected.label, expected.value)
		}
	}

	ingress := kubernetesObject("networking.k8s.io/v1", "Ingress", "ingresses", "team-a", "web", "uid-ingress")
	ingress.Object["spec"] = map[string]any{
		"ingressClassName": "nginx",
		"defaultBackend":   map[string]any{"service": map[string]any{"name": "default", "port": map[string]any{"number": int64(80)}}},
		"rules": []any{map[string]any{"host": "example.test", "http": map[string]any{"paths": []any{map[string]any{
			"path": "/api", "pathType": "Prefix", "backend": map[string]any{"service": map[string]any{"name": "api", "port": map[string]any{"name": "http"}}},
		}}}}},
		"tls": []any{map[string]any{"hosts": []any{"example.test"}, "secretName": "web-tls"}},
	}
	ingress.Object["status"] = map[string]any{"loadBalancer": map[string]any{"ingress": []any{map[string]any{"ip": "203.0.113.10"}}}}
	ingressFields := summarize(ingress)
	for _, expected := range []struct{ section, label, value string }{
		{"routing", "Ingress Class", "nginx"},
		{"routing", "Default Backend", "default:80"},
		{"routing", "Route", "example.test /api (Prefix) → api:http"},
		{"routing", "TLS", "example.test → web-tls"},
		{"routing", "Load Balancer Address", "203.0.113.10"},
	} {
		if !summaryHas(ingressFields, expected.section, expected.label, expected.value) {
			t.Errorf("Ingress summary missing %s/%s=%q", expected.section, expected.label, expected.value)
		}
	}
}

func TestServiceStoragePolicyAndAccessSummaries(t *testing.T) {
	t.Parallel()
	service := kubernetesObject("v1", "Service", "services", "team-a", "web", "uid-service")
	service.Object["spec"] = map[string]any{
		"type": "LoadBalancer", "clusterIP": "10.0.0.10", "clusterIPs": []any{"10.0.0.10", "fd00::10"},
		"ipFamilies": []any{"IPv4", "IPv6"}, "ipFamilyPolicy": "PreferDualStack",
		"externalTrafficPolicy": "Local", "internalTrafficPolicy": "Cluster",
		"sessionAffinity": "ClientIP", "sessionAffinityConfig": map[string]any{"clientIP": map[string]any{"timeoutSeconds": int64(3600)}},
		"healthCheckNodePort": int64(32000), "publishNotReadyAddresses": true,
		"loadBalancerSourceRanges": []any{"10.0.0.0/8"},
		"ports":                    []any{map[string]any{"name": "http", "port": int64(80), "targetPort": int64(8080), "nodePort": int64(30080), "appProtocol": "http"}},
	}
	serviceFields := summarize(service)
	for _, expected := range []struct{ section, label, value string }{
		{"network", "Cluster IP", "fd00::10"},
		{"network", "IP Family", "IPv6"},
		{"service", "IP Family Policy", "PreferDualStack"},
		{"service", "External Traffic Policy", "Local"},
		{"service", "Session Affinity Timeout", "1h"},
		{"service", "Health Check Node Port", "32000"},
		{"service", "http", "nodePort=30080 appProtocol=http"},
	} {
		if !summaryHas(serviceFields, expected.section, expected.label, expected.value) {
			t.Errorf("Service summary missing %s/%s=%q", expected.section, expected.label, expected.value)
		}
	}

	pvc := kubernetesObject("v1", "PersistentVolumeClaim", "persistentvolumeclaims", "team-a", "data", "uid-pvc")
	pvc.Object["spec"] = map[string]any{
		"storageClassName": "fast", "volumeName": "pv-data", "volumeMode": "Filesystem",
		"accessModes": []any{"ReadWriteOnce"}, "resources": map[string]any{"requests": map[string]any{"storage": "10Gi"}},
		"dataSource": map[string]any{"kind": "VolumeSnapshot", "name": "snap-1", "apiGroup": "snapshot.storage.k8s.io"},
	}
	pvc.Object["status"] = map[string]any{"phase": "Bound", "accessModes": []any{"ReadWriteOnce"}, "capacity": map[string]any{"storage": "10Gi"}}
	pvcFields := summarize(pvc)
	for _, expected := range []struct{ section, label, value string }{
		{"storage", "Storage Class", "fast"},
		{"storage", "Bound Volume", "pv-data"},
		{"storage", "Volume Mode", "Filesystem"},
		{"storage", "Access Mode", "ReadWriteOnce"},
		{"resources", "Capacity Storage", "10Gi"},
		{"resources", "Requested Storage", "10Gi"},
		{"storage", "Data Source", "kind=VolumeSnapshot name=snap-1 apiGroup=snapshot.storage.k8s.io"},
	} {
		if !summaryHas(pvcFields, expected.section, expected.label, expected.value) {
			t.Errorf("PVC summary missing %s/%s=%q", expected.section, expected.label, expected.value)
		}
	}

	policy := kubernetesObject("networking.k8s.io/v1", "NetworkPolicy", "networkpolicies", "team-a", "allow-api", "uid-policy")
	policy.Object["spec"] = map[string]any{
		"podSelector": map[string]any{"matchLabels": map[string]any{"app": "api"}},
		"policyTypes": []any{"Ingress", "Egress"},
		"ingress": []any{map[string]any{
			"from":  []any{map[string]any{"namespaceSelector": map[string]any{"matchLabels": map[string]any{"team": "frontend"}}}},
			"ports": []any{map[string]any{"protocol": "TCP", "port": int64(8080)}},
		}},
	}
	policyFields := summarize(policy)
	for _, expected := range []struct{ section, label, value string }{
		{"policy", "Pod Selector", "app=api"},
		{"policy", "Policy Type", "Ingress"},
		{"policy", "Ingress Rule", "from=namespaces=team=frontend ports=TCP:8080"},
	} {
		if !summaryHas(policyFields, expected.section, expected.label, expected.value) {
			t.Errorf("NetworkPolicy summary missing %s/%s=%q", expected.section, expected.label, expected.value)
		}
	}

	role := kubernetesObject("rbac.authorization.k8s.io/v1", "RoleBinding", "rolebindings", "team-a", "api", "uid-role")
	role.Object["roleRef"] = map[string]any{"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "api-reader"}
	role.Object["subjects"] = []any{map[string]any{"kind": "ServiceAccount", "namespace": "team-a", "name": "api"}}
	roleFields := summarize(role)
	if !summaryHas(roleFields, "policy", "Role Reference", "kind=Role name=api-reader apiGroup=rbac.authorization.k8s.io") ||
		!summaryHas(roleFields, "policy", "Subject", "ServiceAccount/team-a/api") {
		t.Fatalf("RoleBinding summary missing references: %#v", roleFields)
	}
}

func TestConfigMapSecretEventSummariesStayMetadataOnly(t *testing.T) {
	t.Parallel()
	config := kubernetesObject("v1", "ConfigMap", "configmaps", "team-a", "settings", "uid-config")
	config.Object["immutable"] = true
	config.Object["data"] = map[string]any{"app.yaml": "password: do-not-show", "mode": "fast"}
	config.Object["binaryData"] = map[string]any{"icon": "AAE="}
	configFields := summarize(config)
	if !summaryHas(configFields, "data", "Immutable", "true") || !summaryHas(configFields, "data", "Data Key", "app.yaml") ||
		strings.Contains(strings.Join(summaryValues(configFields), " "), "do-not-show") {
		t.Fatalf("ConfigMap summary = %#v", configFields)
	}

	secret := kubernetesObject("v1", "Secret", "secrets", "team-a", "credentials", "uid-secret")
	secret.Object["type"] = "kubernetes.io/tls"
	secret.Object["data"] = map[string]any{"tls.key": "c2Vuc2l0aXZl"}
	secret.Object["stringData"] = map[string]any{"password": "never-show"}
	secretFields := summarize(secret)
	for _, field := range secretFields {
		if field.Section == "status" || field.Section == "conditions" || strings.Contains(field.Value, "never-show") || strings.Contains(field.Value, "sensitive") {
			t.Fatalf("Secret summary crossed metadata boundary: %#v", field)
		}
	}
	if !summaryHas(secretFields, "secret", "Type", "kubernetes.io/tls") || !summaryHas(secretFields, "data", "Data Key", "tls.key") {
		t.Fatalf("Secret metadata summary missing: %#v", secretFields)
	}

	event := kubernetesObject("v1", "Event", "events", "team-a", "api.1", "uid-event")
	event.Object["type"] = "Warning"
	event.Object["reason"] = "BackOff"
	event.Object["message"] = "Back-off restarting failed container"
	event.Object["involvedObject"] = map[string]any{"kind": "Pod", "namespace": "team-a", "name": "api", "fieldPath": "spec.containers{api}"}
	event.Object["count"] = int64(4)
	event.Object["lastTimestamp"] = "2026-08-29T01:02:03Z"
	eventFields := summarize(event)
	for _, expected := range []struct{ section, label, value string }{
		{"event", "Type", "Warning"}, {"event", "Reason", "BackOff"},
		{"event", "Message", "Back-off restarting failed container"}, {"event", "Involved Name", "api"}, {"event", "Count", "4"},
	} {
		if !summaryHas(eventFields, expected.section, expected.label, expected.value) {
			t.Errorf("Event summary missing %s/%s=%q", expected.section, expected.label, expected.value)
		}
	}
}

func TestSummaryIdentityFallbackProjectsBuiltInResources(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name, group, version, resource, expectedKind, section, label, value string
	}{
		{"ingress", "networking.k8s.io", "v1", "ingresses", "Ingress", "routing", "Ingress Class", "nginx"},
		{"pvc", "", "v1", "persistentvolumeclaims", "PersistentVolumeClaim", "storage", "Storage Class", "fast"},
		{"network policy", "networking.k8s.io", "v1", "networkpolicies", "NetworkPolicy", "policy", "Policy Type", "Ingress"},
		{"cronjob", "batch", "v1", "cronjobs", "CronJob", "job", "Schedule", "0 * * * *"},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			value := &unstructured.Unstructured{Object: map[string]any{
				"metadata": map[string]any{"name": "object", "uid": "uid", "resourceVersion": "rv"},
			}}
			switch test.resource {
			case "ingresses":
				value.Object["spec"] = map[string]any{"ingressClassName": "nginx"}
			case "persistentvolumeclaims":
				value.Object["spec"] = map[string]any{"storageClassName": "fast"}
			case "networkpolicies":
				value.Object["spec"] = map[string]any{"policyTypes": []any{"Ingress"}}
			case "cronjobs":
				value.Object["spec"] = map[string]any{"schedule": "0 * * * *"}
			}
			fields := summarizeForIdentity(value, Identity{
				Group: test.group, Version: test.version, Resource: test.resource,
				Name: "object", UID: "uid",
			})
			byID := summaryFieldsByID(fields)
			if byID["kind"].Value != test.expectedKind || !summaryHas(fields, test.section, test.label, test.value) {
				t.Fatalf("identity projection = %#v", fields)
			}
		})
	}
}

func TestResourceSummariesBoundCollectionsAndNormalizeValues(t *testing.T) {
	t.Parallel()
	value := kubernetesObject("networking.k8s.io/v1", "Ingress", "ingresses", "team-a", "web", "uid")
	routes := make([]any, maximumSummaryRoutes+10)
	for index := range routes {
		routes[index] = map[string]any{
			"host": fmt.Sprintf("host-%03d.example.test", index),
			"http": map[string]any{"paths": []any{map[string]any{
				"path": "/api", "pathType": "Prefix", "backend": map[string]any{"service": map[string]any{"name": "api", "port": map[string]any{"number": int64(80)}}},
			}}},
		}
	}
	value.Object["spec"] = map[string]any{"rules": routes}
	fields := summarize(value)
	routeCount := 0
	omitted := false
	for _, field := range fields {
		if field.Section == "routing" && strings.HasPrefix(field.ID, "route:") {
			routeCount++
		}
		if field.ID == "routesOmitted" {
			omitted = true
		}
		if len(field.Label) > maximumSummaryLabelBytes || len(field.Value) > maximumSummaryValueBytes {
			t.Fatalf("unbounded resource summary field = %#v", field)
		}
	}
	if routeCount != maximumSummaryRoutes || !omitted {
		t.Fatalf("bounded ingress routes = %d/%t", routeCount, omitted)
	}
}

func TestMalformedResourceSummaryNeverPanics(t *testing.T) {
	t.Parallel()
	resources := []struct {
		kind, group, resource string
	}{
		{"Pod", "", "pods"}, {"Deployment", "apps", "deployments"}, {"Ingress", "networking.k8s.io", "ingresses"},
		{"Service", "", "services"}, {"PersistentVolume", "", "persistentvolumes"}, {"NetworkPolicy", "networking.k8s.io", "networkpolicies"},
		{"Role", "rbac.authorization.k8s.io", "roles"}, {"Event", "", "events"}, {"ResourceQuota", "", "resourcequotas"},
	}
	for _, resource := range resources {
		resource := resource
		t.Run(resource.kind, func(t *testing.T) {
			defer func() {
				if recovered := recover(); recovered != nil {
					t.Fatalf("summary panicked for %s: %v", resource.kind, recovered)
				}
			}()
			value := kubernetesObject("v1", resource.kind, resource.resource, "ns", "object", "uid")
			value.Object["spec"] = map[string]any{
				"containers": "not-a-list", "tolerations": map[string]any{}, "rules": "not-a-list",
				"ports": "not-a-list", "selector": "not-a-map", "resources": "not-a-map",
			}
			value.Object["status"] = map[string]any{"conditions": "not-a-list", "addresses": "not-a-list"}
			_ = summarize(value)
		})
	}
}

func summaryValues(fields []SummaryField) []string {
	result := make([]string, 0, len(fields))
	for _, field := range fields {
		result = append(result, field.Value)
	}
	return result
}
