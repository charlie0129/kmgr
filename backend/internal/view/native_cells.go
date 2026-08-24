package view

import (
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func (p *Projector) nativeObjectCell(
	object *unstructured.Unstructured,
	columnID, extractorID string,
) (*kmgrv1.Cell, bool) {
	cell := newNativeCell(columnID)
	missing := func(tooltip string) (*kmgrv1.Cell, bool) {
		setMissingCell(cell, tooltip)
		return cell, true
	}
	stringValue := func(value string) (*kmgrv1.Cell, bool) {
		setNativeString(cell, value)
		return cell, true
	}
	integerValue := func(value int64, found bool) (*kmgrv1.Cell, bool) {
		if !found {
			return missing("Value is not reported by this object")
		}
		setNativeInteger(cell, value)
		return cell, true
	}
	timestampValue := func(value time.Time, relative bool) (*kmgrv1.Cell, bool) {
		if value.IsZero() {
			return missing("Timestamp is not reported by this object")
		}
		setNativeTimestamp(cell, value, p.spec.Now, relative)
		return cell, true
	}

	switch extractorID {
	case "namespace":
		return stringValue(object.GetNamespace())
	case "name":
		return stringValue(object.GetName())
	case "kind":
		kind := object.GetKind()
		if kind == "" {
			kind = p.spec.Resource.Kind
		}
		return stringValue(kind)
	case "labels":
		return stringValue(formatStringMap(object.GetLabels()))
	case "age":
		return timestampValue(object.GetCreationTimestamp().Time, true)
	case "created":
		return timestampValue(object.GetCreationTimestamp().Time, false)
	case "resourceVersion":
		return stringValue(object.GetResourceVersion())
	case "status":
		status, severity := presentationForObject(object)
		setNativeString(cell, status)
		cell.Severity = severity
		return cell, true
	case "ready":
		return p.readyCell(object, cell), true
	case "restarts":
		value := restartCount(object)
		setNativeInteger(cell, value)
		if value > 0 {
			cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_WARNING
		}
		return cell, true
	case "pod-ip":
		value, _, _ := unstructured.NestedString(object.Object, "status", "podIP")
		return stringValue(value)
	case "node":
		value, _, _ := unstructured.NestedString(object.Object, "spec", "nodeName")
		return stringValue(value)
	case "last-restart":
		return timestampValue(lastContainerRestart(object), false)
	case "service-account":
		value, _, _ := unstructured.NestedString(object.Object, "spec", "serviceAccountName")
		return stringValue(value)
	case "qos-class":
		value, _, _ := unstructured.NestedString(object.Object, "status", "qosClass")
		return stringValue(value)
	case "readiness-gates":
		return stringValue(strings.Join(readinessGates(object), ", "))
	case "nominated-node":
		value, _, _ := unstructured.NestedString(object.Object, "status", "nominatedNodeName")
		return stringValue(value)
	case "roles":
		return stringValue(strings.Join(nodeRoles(object), ", "))
	case "taints":
		value := int64(len(nestedSliceNoCopy(object.Object, "spec", "taints")))
		setNativeInteger(cell, value)
		if value > 0 {
			cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_WARNING
		}
		return cell, true
	case "internal-ip":
		return stringValue(strings.Join(nodeAddresses(object, "InternalIP"), ", "))
	case "external-ip":
		return stringValue(strings.Join(nodeAddresses(object, "ExternalIP"), ", "))
	case "kubelet-version":
		return stringValue(nestedString(object.Object, "status", "nodeInfo", "kubeletVersion"))
	case "architecture":
		return stringValue(nestedString(object.Object, "status", "nodeInfo", "architecture"))
	case "os-image":
		return stringValue(nestedString(object.Object, "status", "nodeInfo", "osImage"))
	case "kernel-version":
		return stringValue(nestedString(object.Object, "status", "nodeInfo", "kernelVersion"))
	case "up-to-date":
		return integerValue(workloadCount(object, p.spec.Resource, "updated"))
	case "available":
		return integerValue(workloadCount(object, p.spec.Resource, "available"))
	case "desired":
		return integerValue(workloadCount(object, p.spec.Resource, "desired"))
	case "current":
		return integerValue(workloadCount(object, p.spec.Resource, "current"))
	case "updated":
		return integerValue(workloadCount(object, p.spec.Resource, "updated"))
	case "ready-count":
		if p.spec.Resource.Group == "discovery.k8s.io" {
			return integerValue(endpointSliceReadyCount(object), true)
		}
		return integerValue(workloadCount(object, p.spec.Resource, "ready"))
	case "service":
		return stringValue(nestedString(object.Object, "spec", "serviceName"))
	case "selector":
		value, _, _ := unstructured.NestedFieldNoCopy(object.Object, "spec", "selector")
		return stringValue(formatSelector(value))
	case "containers":
		return stringValue(strings.Join(podTemplateValues(object, p.spec.Resource, "name"), ", "))
	case "images":
		return stringValue(strings.Join(podTemplateValues(object, p.spec.Resource, "image"), ", "))
	case "completions":
		succeeded, _, _ := unstructured.NestedInt64(object.Object, "status", "succeeded")
		desired, found, _ := unstructured.NestedInt64(object.Object, "spec", "completions")
		if !found {
			desired = 1
		}
		return stringValue(fmt.Sprintf("%d/%d", succeeded, desired))
	case "duration":
		start := nestedTime(object.Object, "status", "startTime")
		end := nestedTime(object.Object, "status", "completionTime")
		if start.IsZero() {
			return missing("Job has not started")
		}
		if end.IsZero() {
			end = p.spec.Now
		}
		setNativeDuration(cell, end.Sub(start))
		return cell, true
	case "active", "succeeded", "failed":
		if extractorID == "active" && p.spec.Resource.Resource == "cronjobs" {
			setNativeInteger(cell, int64(len(nestedSliceNoCopy(object.Object, "status", "active"))))
			return cell, true
		}
		value, found, _ := unstructured.NestedInt64(object.Object, "status", extractorID)
		return integerValue(value, found)
	case "schedule":
		return stringValue(nestedString(object.Object, "spec", "schedule"))
	case "suspended":
		value, found, _ := unstructured.NestedBool(object.Object, "spec", "suspend")
		if !found {
			value = false
		}
		setNativeBoolean(cell, value)
		return cell, true
	case "last-schedule":
		return timestampValue(nestedTime(object.Object, "status", "lastScheduleTime"), true)
	case "time-zone":
		return stringValue(nestedString(object.Object, "spec", "timeZone"))
	case "last-successful":
		return timestampValue(nestedTime(object.Object, "status", "lastSuccessfulTime"), true)
	case "reference":
		kind := nestedString(object.Object, "spec", "scaleTargetRef", "kind")
		name := nestedString(object.Object, "spec", "scaleTargetRef", "name")
		return stringValue(joinReference(kind, "", name))
	case "targets":
		return stringValue(formatHPATargets(object))
	case "minimum":
		value, found, _ := unstructured.NestedInt64(object.Object, "spec", "minReplicas")
		if !found {
			value, found = 1, true
		}
		return integerValue(value, found)
	case "maximum":
		value, found, _ := unstructured.NestedInt64(object.Object, "spec", "maxReplicas")
		return integerValue(value, found)
	case "current-replicas":
		value, found, _ := unstructured.NestedInt64(object.Object, "status", "currentReplicas")
		return integerValue(value, found)
	case "conditions":
		return stringValue(formatTrueConditions(object))
	case "min-available", "max-unavailable":
		value, found, _ := unstructured.NestedFieldNoCopy(object.Object, "spec", camelField(extractorID))
		if !found {
			return missing("Value is not configured")
		}
		return stringValue(scalarDisplay(value))
	case "disruptions-allowed", "current-healthy", "desired-healthy", "expected-pods":
		field := map[string]string{
			"disruptions-allowed": "disruptionsAllowed",
			"current-healthy":     "currentHealthy", "desired-healthy": "desiredHealthy",
			"expected-pods": "expectedPods",
		}[extractorID]
		value, found, _ := unstructured.NestedInt64(object.Object, "status", field)
		return integerValue(value, found)
	case "service-type":
		return stringValue(nestedString(object.Object, "spec", "type"))
	case "cluster-ip":
		return stringValue(nestedString(object.Object, "spec", "clusterIP"))
	case "external-address":
		return stringValue(strings.Join(serviceExternalAddresses(object), ", "))
	case "ports":
		return stringValue(formatPorts(object, p.spec.Resource))
	case "service-selector":
		value, _, _ := unstructured.NestedStringMap(object.Object, "spec", "selector")
		return stringValue(formatStringMap(value))
	case "ip-families":
		return stringValue(strings.Join(nestedStringSlice(object.Object, "spec", "ipFamilies"), ", "))
	case "session-affinity":
		return stringValue(nestedString(object.Object, "spec", "sessionAffinity"))
	case "external-traffic-policy":
		return stringValue(nestedString(object.Object, "spec", "externalTrafficPolicy"))
	case "internal-traffic-policy":
		return stringValue(nestedString(object.Object, "spec", "internalTrafficPolicy"))
	case "endpoint-count":
		return integerValue(endpointCount(object, p.spec.Resource), true)
	case "addresses":
		return stringValue(joinBounded(endpointAddresses(object, p.spec.Resource), 12))
	case "ingress-class":
		value := nestedString(object.Object, "spec", "ingressClassName")
		if value == "" {
			value = object.GetAnnotations()["kubernetes.io/ingress.class"]
		}
		return stringValue(value)
	case "hosts":
		return stringValue(strings.Join(ingressHosts(object), ", "))
	case "address":
		return stringValue(strings.Join(loadBalancerAddresses(object), ", "))
	case "tls":
		return stringValue(strings.Join(ingressTLSHosts(object), ", "))
	case "pod-selector":
		value, _, _ := unstructured.NestedFieldNoCopy(object.Object, "spec", "podSelector")
		return stringValue(formatSelector(value))
	case "policy-types":
		return stringValue(strings.Join(nestedStringSlice(object.Object, "spec", "policyTypes"), ", "))
	case "ingress-rules":
		return integerValue(int64(len(nestedSliceNoCopy(object.Object, "spec", "ingress"))), true)
	case "egress-rules":
		return integerValue(int64(len(nestedSliceNoCopy(object.Object, "spec", "egress"))), true)
	case "capacity":
		path := []string{"spec", "capacity", "storage"}
		if p.spec.Resource.Resource == "persistentvolumeclaims" {
			path = []string{"status", "capacity", "storage"}
		}
		value := nestedString(object.Object, path...)
		quantity, err := resource.ParseQuantity(value)
		if err != nil || value == "" {
			return missing("Storage capacity is not reported")
		}
		cell.DisplayText = quantity.String()
		cell.TypedValue = quantityCellValue(quantity, cell.DisplayText)
		return cell, true
	case "access-modes":
		path := []string{"spec", "accessModes"}
		if p.spec.Resource.Resource == "persistentvolumeclaims" {
			path = []string{"status", "accessModes"}
		}
		return stringValue(strings.Join(nestedStringSlice(object.Object, path...), ", "))
	case "reclaim-policy":
		if p.spec.Resource.Group == "storage.k8s.io" {
			value := nestedString(object.Object, "reclaimPolicy")
			if value == "" {
				value = "Delete"
			}
			return stringValue(value)
		}
		return stringValue(nestedString(object.Object, "spec", "persistentVolumeReclaimPolicy"))
	case "claim":
		return stringValue(joinReference("", nestedString(object.Object, "spec", "claimRef", "namespace"), nestedString(object.Object, "spec", "claimRef", "name")))
	case "storage-class":
		return stringValue(nestedString(object.Object, "spec", "storageClassName"))
	case "volume":
		return stringValue(nestedString(object.Object, "spec", "volumeName"))
	case "reason":
		if p.spec.Resource.Resource == "events" {
			return stringValue(nestedString(object.Object, "reason"))
		}
		return stringValue(nestedString(object.Object, "status", "reason"))
	case "volume-mode":
		return stringValue(nestedString(object.Object, "spec", "volumeMode"))
	case "provisioner":
		return stringValue(nestedString(object.Object, "provisioner"))
	case "binding-mode":
		return stringValue(nestedString(object.Object, "volumeBindingMode"))
	case "allow-expansion":
		value, found, _ := unstructured.NestedBool(object.Object, "allowVolumeExpansion")
		if !found {
			return missing("Expansion policy is not reported")
		}
		setNativeBoolean(cell, value)
		return cell, true
	case "parameters":
		value, _, _ := unstructured.NestedStringMap(object.Object, "parameters")
		return stringValue(formatStringMap(value))
	case "rule-count":
		return integerValue(int64(len(nestedSliceNoCopy(object.Object, "rules"))), true)
	case "rules-summary":
		return stringValue(formatRBACRules(object))
	case "role-ref":
		return stringValue(joinReference(
			nestedString(object.Object, "roleRef", "kind"), "",
			nestedString(object.Object, "roleRef", "name"),
		))
	case "subject-kinds":
		return stringValue(strings.Join(subjectKinds(object), ", "))
	case "subjects":
		return stringValue(joinBounded(subjectNames(object), 12))
	case "crd-group":
		return stringValue(nestedString(object.Object, "spec", "group"))
	case "crd-kind":
		return stringValue(nestedString(object.Object, "spec", "names", "kind"))
	case "served-versions":
		return stringValue(strings.Join(servedCRDVersions(object), ", "))
	case "scope":
		return stringValue(nestedString(object.Object, "spec", "scope"))
	case "short-names":
		return stringValue(strings.Join(nestedStringSlice(object.Object, "spec", "names", "shortNames"), ", "))
	case "categories":
		return stringValue(strings.Join(nestedStringSlice(object.Object, "spec", "names", "categories"), ", "))
	case "last-seen":
		return timestampValue(eventLastSeen(object), true)
	case "event-type":
		value := nestedString(object.Object, "type")
		setNativeString(cell, value)
		if strings.EqualFold(value, "Warning") {
			cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_WARNING
		}
		return cell, true
	case "involved-object":
		return stringValue(eventObjectReference(object))
	case "message":
		return stringValue(nestedString(object.Object, "message"))
	case "event-source":
		value := nestedString(object.Object, "reportingController")
		if instance := nestedString(object.Object, "reportingInstance"); instance != "" {
			value = joinReference(value, "", instance)
		}
		if value == "" {
			value = nestedString(object.Object, "source", "component")
			if host := nestedString(object.Object, "source", "host"); host != "" {
				value = joinReference(value, "", host)
			}
		}
		return stringValue(value)
	case "subobject":
		return stringValue(nestedString(object.Object, "involvedObject", "fieldPath"))
	case "first-seen":
		value := nestedTime(object.Object, "firstTimestamp")
		if value.IsZero() {
			value = nestedTime(object.Object, "eventTime")
		}
		if value.IsZero() {
			value = object.GetCreationTimestamp().Time
		}
		return timestampValue(value, true)
	case "event-count":
		value, found, _ := unstructured.NestedInt64(object.Object, "count")
		if series, seriesFound, _ := unstructured.NestedInt64(object.Object, "series", "count"); seriesFound && (!found || series > value) {
			value, found = series, true
		}
		if !found {
			value, found = 1, true
		}
		return integerValue(value, found)
	case "event-name":
		return stringValue(object.GetName())
	case "key-count":
		return integerValue(int64(nestedMapLength(object.Object, "data")+nestedMapLength(object.Object, "binaryData")), true)
	case "secret-type":
		return stringValue(nestedString(object.Object, "type"))
	case "data-key-count":
		return integerValue(int64(nestedMapLength(object.Object, "data")), true)
	case "secret-refs":
		return integerValue(int64(len(nestedSliceNoCopy(object.Object, "secrets"))), true)
	case "image-pull-secret-refs":
		return integerValue(int64(len(nestedSliceNoCopy(object.Object, "imagePullSecrets"))), true)
	default:
		return nil, false
	}
}

func newNativeCell(columnID string) *kmgrv1.Cell {
	return &kmgrv1.Cell{ColumnId: columnID, Severity: kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL}
}

func setMissingCell(cell *kmgrv1.Cell, tooltip string) {
	cell.DisplayText = DefaultMissingCell
	cell.TypedValue = nil
	cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
	cell.Tooltip = tooltip
}

func setNativeString(cell *kmgrv1.Cell, value string) {
	value = strings.TrimSpace(value)
	if value == "" {
		setMissingCell(cell, "Value is not reported by this object")
		return
	}
	cell.DisplayText = value
	cell.TypedValue = &kmgrv1.Cell_StringValue{StringValue: value}
}

func setNativeInteger(cell *kmgrv1.Cell, value int64) {
	cell.DisplayText = strconv.FormatInt(value, 10)
	cell.TypedValue = &kmgrv1.Cell_IntegerValue{IntegerValue: value}
}

func setNativeBoolean(cell *kmgrv1.Cell, value bool) {
	cell.DisplayText = map[bool]string{true: "Yes", false: "No"}[value]
	cell.TypedValue = &kmgrv1.Cell_BoolValue{BoolValue: value}
}

func setNativeTimestamp(cell *kmgrv1.Cell, value, now time.Time, relative bool) {
	if relative {
		cell.DisplayText = formatAge(now.Sub(value))
	} else {
		cell.DisplayText = value.Local().Format("2006-01-02 15:04:05")
	}
	cell.TypedValue = &kmgrv1.Cell_TimestampUnixMs{TimestampUnixMs: value.UnixMilli()}
	cell.Tooltip = value.Format(time.RFC3339)
}

func setNativeDuration(cell *kmgrv1.Cell, value time.Duration) {
	if value < 0 {
		value = 0
	}
	cell.DisplayText = formatAge(value)
	cell.TypedValue = &kmgrv1.Cell_NumberValue{NumberValue: value.Seconds()}
}

func (p *Projector) readyCell(object *unstructured.Unstructured, cell *kmgrv1.Cell) *kmgrv1.Cell {
	if p.spec.Resource.Group == "" && p.spec.Resource.Resource == "pods" {
		ready, total := readyContainers(object)
		if total == 0 {
			setMissingCell(cell, "Pod has no containers")
			return cell
		}
		setNativeString(cell, fmt.Sprintf("%d / %d", ready, total))
		_, cell.Severity = podPresentation(object)
		return cell
	}
	ready, _, _ := unstructured.NestedInt64(object.Object, "status", "readyReplicas")
	desired, found, _ := unstructured.NestedInt64(object.Object, "spec", "replicas")
	if !found {
		desired = 1
	}
	setNativeString(cell, fmt.Sprintf("%d / %d", ready, desired))
	if ready != desired {
		cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_WARNING
	}
	return cell
}

func nestedString(object map[string]any, fields ...string) string {
	value, _, _ := unstructured.NestedString(object, fields...)
	return value
}

func nestedStringSlice(object map[string]any, fields ...string) []string {
	values, _, _ := unstructured.NestedStringSlice(object, fields...)
	return values
}

func nestedTime(object map[string]any, fields ...string) time.Time {
	value := nestedString(object, fields...)
	if value == "" {
		return time.Time{}
	}
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return time.Time{}
	}
	return parsed
}

func nestedMapLength(object map[string]any, fields ...string) int {
	value, found, _ := unstructured.NestedMap(object, fields...)
	if !found {
		return 0
	}
	return len(value)
}

func formatStringMap(values map[string]string) string {
	if len(values) == 0 {
		return ""
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		if values[key] == "" {
			parts = append(parts, key)
		} else {
			parts = append(parts, key+"="+values[key])
		}
	}
	return strings.Join(parts, ", ")
}

func formatSelector(value any) string {
	selector, ok := value.(map[string]any)
	if !ok || len(selector) == 0 {
		return ""
	}
	if labels, ok := selector["matchLabels"].(map[string]any); ok {
		converted := make(map[string]string, len(labels))
		for key, raw := range labels {
			converted[key] = scalarDisplay(raw)
		}
		return formatStringMap(converted)
	}
	converted := make(map[string]string, len(selector))
	for key, raw := range selector {
		converted[key] = scalarDisplay(raw)
	}
	return formatStringMap(converted)
}

func scalarDisplay(value any) string {
	switch typed := value.(type) {
	case string:
		return typed
	case int64:
		return strconv.FormatInt(typed, 10)
	case float64:
		return strconv.FormatFloat(typed, 'g', -1, 64)
	case bool:
		return strconv.FormatBool(typed)
	default:
		return fmt.Sprint(typed)
	}
}

func lastContainerRestart(object *unstructured.Unstructured) time.Time {
	var latest time.Time
	for _, statusField := range []string{"containerStatuses", "initContainerStatuses", "ephemeralContainerStatuses"} {
		for _, raw := range nestedSliceNoCopy(object.Object, "status", statusField) {
			status, _ := raw.(map[string]any)
			candidate := nestedTime(status, "lastState", "terminated", "finishedAt")
			if candidate.After(latest) {
				latest = candidate
			}
		}
	}
	return latest
}

func readinessGates(object *unstructured.Unstructured) []string {
	var values []string
	for _, raw := range nestedSliceNoCopy(object.Object, "spec", "readinessGates") {
		gate, _ := raw.(map[string]any)
		if value, _ := gate["conditionType"].(string); value != "" {
			values = append(values, value)
		}
	}
	slices.Sort(values)
	return values
}

func nodeAddresses(object *unstructured.Unstructured, addressType string) []string {
	var values []string
	for _, raw := range nestedSliceNoCopy(object.Object, "status", "addresses") {
		address, _ := raw.(map[string]any)
		if address["type"] != addressType {
			continue
		}
		if value, _ := address["address"].(string); value != "" {
			values = append(values, value)
		}
	}
	return sortedUniqueStrings(values)
}

func workloadCount(object *unstructured.Unstructured, resourceType ResourceType, field string) (int64, bool) {
	paths := map[string][]string{}
	switch resourceType.Resource {
	case "daemonsets":
		paths = map[string][]string{
			"desired": {"status", "desiredNumberScheduled"}, "current": {"status", "currentNumberScheduled"},
			"ready": {"status", "numberReady"}, "updated": {"status", "updatedNumberScheduled"},
			"available": {"status", "numberAvailable"},
		}
	case "statefulsets":
		paths = map[string][]string{
			"desired": {"spec", "replicas"}, "current": {"status", "currentReplicas"},
			"ready": {"status", "readyReplicas"}, "updated": {"status", "updatedReplicas"},
		}
	default:
		paths = map[string][]string{
			"desired": {"spec", "replicas"}, "current": {"status", "replicas"},
			"ready": {"status", "readyReplicas"}, "updated": {"status", "updatedReplicas"},
			"available": {"status", "availableReplicas"},
		}
	}
	path := paths[field]
	if len(path) == 0 {
		return 0, false
	}
	value, found, _ := unstructured.NestedInt64(object.Object, path...)
	if !found && field == "desired" {
		return 1, true
	}
	return value, found
}

func podTemplateValues(object *unstructured.Unstructured, resourceType ResourceType, field string) []string {
	path := []string{"spec", "template", "spec", "containers"}
	if resourceType.Resource == "cronjobs" {
		path = []string{"spec", "jobTemplate", "spec", "template", "spec", "containers"}
	}
	var result []string
	for _, raw := range nestedSliceNoCopy(object.Object, path...) {
		container, _ := raw.(map[string]any)
		if value, _ := container[field].(string); value != "" {
			result = append(result, value)
		}
	}
	return sortedUniqueStrings(result)
}

func formatHPATargets(object *unstructured.Unstructured) string {
	currentMetrics := nestedSliceNoCopy(object.Object, "status", "currentMetrics")
	targetMetrics := nestedSliceNoCopy(object.Object, "spec", "metrics")
	count := max(len(currentMetrics), len(targetMetrics))
	result := make([]string, 0, count)
	for index := 0; index < count; index++ {
		current := hpaMetricAt(currentMetrics, index)
		target := hpaMetricAt(targetMetrics, index)
		metricType, currentBody := hpaMetricBody(current)
		targetType, targetBody := hpaMetricBody(target)
		if metricType == "" {
			metricType, currentBody = targetType, nil
		}
		if targetType != "" && metricType != targetType {
			targetBody = nil
		}
		name := hpaMetricName(currentBody)
		if name == "" {
			name = hpaMetricName(targetBody)
		}
		if name == "" {
			name = metricType
		}
		currentValue := hpaMetricValue(currentBody, "current")
		targetValue := hpaMetricValue(targetBody, "target")
		if currentValue == "" {
			currentValue = "<unknown>"
		}
		if targetValue == "" {
			targetValue = "<unknown>"
		}
		value := currentValue + "/" + targetValue
		if name != "" {
			value = name + ": " + value
		}
		result = append(result, value)
	}
	if len(result) != 0 {
		return strings.Join(result, ", ")
	}

	current, currentFound, _ := unstructured.NestedInt64(
		object.Object, "status", "currentCPUUtilizationPercentage",
	)
	target, targetFound, _ := unstructured.NestedInt64(
		object.Object, "spec", "targetCPUUtilizationPercentage",
	)
	if !currentFound && !targetFound {
		return ""
	}
	currentText := "<unknown>"
	if currentFound {
		currentText = strconv.FormatInt(current, 10) + "%"
	}
	targetText := "<unknown>"
	if targetFound {
		targetText = strconv.FormatInt(target, 10) + "%"
	}
	return "cpu: " + currentText + "/" + targetText
}

func hpaMetricAt(values []any, index int) map[string]any {
	if index < 0 || index >= len(values) {
		return nil
	}
	value, _ := values[index].(map[string]any)
	return value
}

func hpaMetricBody(metric map[string]any) (string, map[string]any) {
	metricType, _ := metric["type"].(string)
	if metricType == "" {
		return "", nil
	}
	key := strings.ToLower(metricType[:1]) + metricType[1:]
	body, _ := metric[key].(map[string]any)
	return metricType, body
}

func hpaMetricName(body map[string]any) string {
	if body == nil {
		return ""
	}
	if name, _ := body["name"].(string); name != "" {
		if container, _ := body["container"].(string); container != "" {
			return container + "/" + name
		}
		return name
	}
	metric, _ := body["metric"].(map[string]any)
	name, _ := metric["name"].(string)
	return name
}

func hpaMetricValue(body map[string]any, field string) string {
	values, _ := body[field].(map[string]any)
	if values == nil {
		return ""
	}
	if value, ok := values["averageUtilization"].(int64); ok {
		return strconv.FormatInt(value, 10) + "%"
	}
	for _, key := range []string{"averageValue", "value"} {
		if value, ok := values[key].(string); ok && value != "" {
			return value
		}
	}
	return ""
}

func formatTrueConditions(object *unstructured.Unstructured) string {
	var result []string
	for _, raw := range nestedSliceNoCopy(object.Object, "status", "conditions") {
		condition, _ := raw.(map[string]any)
		if condition["status"] != "True" {
			continue
		}
		if value, _ := condition["type"].(string); value != "" {
			result = append(result, value)
		}
	}
	return strings.Join(sortedUniqueStrings(result), ", ")
}

func camelField(value string) string {
	parts := strings.Split(value, "-")
	for index := 1; index < len(parts); index++ {
		parts[index] = strings.ToUpper(parts[index][:1]) + parts[index][1:]
	}
	return strings.Join(parts, "")
}

func serviceExternalAddresses(object *unstructured.Unstructured) []string {
	result := nestedStringSlice(object.Object, "spec", "externalIPs")
	if externalName := nestedString(object.Object, "spec", "externalName"); externalName != "" {
		result = append(result, externalName)
	}
	return sortedUniqueStrings(append(result, loadBalancerAddresses(object)...))
}

func formatPorts(object *unstructured.Unstructured, resourceType ResourceType) string {
	var result []string
	switch {
	case resourceType.Group == "" && resourceType.Resource == "services":
		for _, raw := range nestedSliceNoCopy(object.Object, "spec", "ports") {
			port, _ := raw.(map[string]any)
			value := scalarDisplay(port["port"])
			if protocol, _ := port["protocol"].(string); protocol != "" && protocol != "TCP" {
				value += "/" + protocol
			}
			if nodePort := scalarDisplay(port["nodePort"]); nodePort != "" && nodePort != "<nil>" && nodePort != "0" {
				value += ":" + nodePort
			}
			result = append(result, value)
		}
	case resourceType.Group == "" && resourceType.Resource == "endpoints":
		for _, subsetRaw := range nestedSliceNoCopy(object.Object, "subsets") {
			subset, _ := subsetRaw.(map[string]any)
			for _, portRaw := range sliceFromMap(subset, "ports") {
				port, _ := portRaw.(map[string]any)
				result = append(result, scalarDisplay(port["port"]))
			}
		}
	case resourceType.Group == "discovery.k8s.io":
		for _, portRaw := range nestedSliceNoCopy(object.Object, "ports") {
			port, _ := portRaw.(map[string]any)
			result = append(result, scalarDisplay(port["port"]))
		}
	case resourceType.Group == "networking.k8s.io" && resourceType.Resource == "ingresses":
		if len(nestedSliceNoCopy(object.Object, "spec", "rules")) != 0 {
			result = append(result, "80")
		}
		if len(nestedSliceNoCopy(object.Object, "spec", "tls")) != 0 {
			result = append(result, "443")
		}
	}
	return strings.Join(sortedUniqueStrings(result), ", ")
}

func endpointCount(object *unstructured.Unstructured, resourceType ResourceType) int64 {
	if resourceType.Group == "discovery.k8s.io" {
		return int64(len(nestedSliceNoCopy(object.Object, "endpoints")))
	}
	var count int64
	for _, raw := range nestedSliceNoCopy(object.Object, "subsets") {
		subset, _ := raw.(map[string]any)
		count += int64(len(sliceFromMap(subset, "addresses")) + len(sliceFromMap(subset, "notReadyAddresses")))
	}
	return count
}

func endpointSliceReadyCount(object *unstructured.Unstructured) int64 {
	var count int64
	for _, raw := range nestedSliceNoCopy(object.Object, "endpoints") {
		endpoint, _ := raw.(map[string]any)
		conditions, _ := endpoint["conditions"].(map[string]any)
		ready, found := conditions["ready"].(bool)
		if !found || ready {
			count++
		}
	}
	return count
}

func endpointAddresses(object *unstructured.Unstructured, resourceType ResourceType) []string {
	var result []string
	if resourceType.Group == "discovery.k8s.io" {
		for _, raw := range nestedSliceNoCopy(object.Object, "endpoints") {
			endpoint, _ := raw.(map[string]any)
			result = append(result, stringSliceFromMap(endpoint, "addresses")...)
		}
		return sortedUniqueStrings(result)
	}
	for _, raw := range nestedSliceNoCopy(object.Object, "subsets") {
		subset, _ := raw.(map[string]any)
		for _, field := range []string{"addresses", "notReadyAddresses"} {
			for _, addressRaw := range sliceFromMap(subset, field) {
				address, _ := addressRaw.(map[string]any)
				if value, _ := address["ip"].(string); value != "" {
					result = append(result, value)
				}
			}
		}
	}
	return sortedUniqueStrings(result)
}

func ingressHosts(object *unstructured.Unstructured) []string {
	var values []string
	for _, raw := range nestedSliceNoCopy(object.Object, "spec", "rules") {
		rule, _ := raw.(map[string]any)
		value, _ := rule["host"].(string)
		if value == "" {
			value = "*"
		}
		values = append(values, value)
	}
	return sortedUniqueStrings(values)
}

func ingressTLSHosts(object *unstructured.Unstructured) []string {
	var values []string
	for _, raw := range nestedSliceNoCopy(object.Object, "spec", "tls") {
		tls, _ := raw.(map[string]any)
		values = append(values, stringSliceFromMap(tls, "hosts")...)
	}
	return sortedUniqueStrings(values)
}

func loadBalancerAddresses(object *unstructured.Unstructured) []string {
	var values []string
	for _, raw := range nestedSliceNoCopy(object.Object, "status", "loadBalancer", "ingress") {
		ingress, _ := raw.(map[string]any)
		for _, field := range []string{"ip", "hostname"} {
			if value, _ := ingress[field].(string); value != "" {
				values = append(values, value)
			}
		}
	}
	return sortedUniqueStrings(values)
}

func formatRBACRules(object *unstructured.Unstructured) string {
	var values []string
	for _, raw := range nestedSliceNoCopy(object.Object, "rules") {
		rule, _ := raw.(map[string]any)
		verbs := strings.Join(stringSliceFromMap(rule, "verbs"), ",")
		resources := strings.Join(stringSliceFromMap(rule, "resources"), ",")
		if resources == "" {
			resources = strings.Join(stringSliceFromMap(rule, "nonResourceURLs"), ",")
		}
		values = append(values, verbs+":"+resources)
	}
	return joinBounded(values, 6)
}

func subjectKinds(object *unstructured.Unstructured) []string {
	var result []string
	for _, raw := range nestedSliceNoCopy(object.Object, "subjects") {
		subject, _ := raw.(map[string]any)
		if value, _ := subject["kind"].(string); value != "" {
			result = append(result, value)
		}
	}
	return sortedUniqueStrings(result)
}

func subjectNames(object *unstructured.Unstructured) []string {
	var result []string
	for _, raw := range nestedSliceNoCopy(object.Object, "subjects") {
		subject, _ := raw.(map[string]any)
		kind, _ := subject["kind"].(string)
		name, _ := subject["name"].(string)
		namespace, _ := subject["namespace"].(string)
		result = append(result, joinReference(kind, namespace, name))
	}
	return sortedUniqueStrings(result)
}

func servedCRDVersions(object *unstructured.Unstructured) []string {
	var result []string
	for _, raw := range nestedSliceNoCopy(object.Object, "spec", "versions") {
		version, _ := raw.(map[string]any)
		served, _ := version["served"].(bool)
		name, _ := version["name"].(string)
		if served && name != "" {
			result = append(result, name)
		}
	}
	return result
}

func eventLastSeen(object *unstructured.Unstructured) time.Time {
	for _, path := range [][]string{
		{"series", "lastObservedTime"}, {"eventTime"}, {"lastTimestamp"}, {"firstTimestamp"},
	} {
		if value := nestedTime(object.Object, path...); !value.IsZero() {
			return value
		}
	}
	return object.GetCreationTimestamp().Time
}

func eventObjectReference(object *unstructured.Unstructured) string {
	return joinReference(
		nestedString(object.Object, "involvedObject", "kind"),
		nestedString(object.Object, "involvedObject", "namespace"),
		nestedString(object.Object, "involvedObject", "name"),
	)
}

func joinReference(kind, namespace, name string) string {
	value := name
	if namespace != "" {
		value = namespace + "/" + value
	}
	if kind != "" {
		value = kind + "/" + value
	}
	return strings.Trim(value, "/")
}

func joinBounded(values []string, limit int) string {
	values = sortedUniqueStrings(values)
	if len(values) <= limit {
		return strings.Join(values, ", ")
	}
	return strings.Join(values[:limit], ", ") + fmt.Sprintf(" … +%d", len(values)-limit)
}

func sortedUniqueStrings(values []string) []string {
	result := values[:0]
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" && value != "<nil>" {
			result = append(result, value)
		}
	}
	slices.Sort(result)
	return slices.Compact(result)
}

func sliceFromMap(value map[string]any, field string) []any {
	result, _ := value[field].([]any)
	return result
}

func stringSliceFromMap(value map[string]any, field string) []string {
	raw := sliceFromMap(value, field)
	result := make([]string, 0, len(raw))
	for _, item := range raw {
		if text, ok := item.(string); ok {
			result = append(result, text)
		}
	}
	return result
}
