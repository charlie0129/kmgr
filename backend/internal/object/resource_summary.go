package object

// This file contains the curated, display-safe projections used by object
// Details for built-in Kubernetes resources other than Nodes.  These helpers
// intentionally consume the already-authoritative unstructured object: a
// selected detail must never trigger a second resource read or a relationship
// scan.  Every collection has a small bound and every value passes through the
// final normalization in summarizeWithKind.

import (
	"encoding/json"
	"fmt"
	"math"
	"slices"
	"strconv"
	"strings"
	"time"
)

const (
	maximumSummaryPodIPs         = 64
	maximumSummaryPodConstraints = 64
	maximumSummaryPodResources   = 128
	maximumSummaryPodVolumes     = 64
	maximumSummaryPodMounts      = 128
	maximumSummaryProbeFields    = 128
	maximumSummaryWorkloadFields = 96
	maximumSummaryRoutes         = 128
	maximumSummaryTLS            = 64
	maximumSummaryServiceValues  = 64
	maximumSummaryStorageValues  = 64
	maximumSummaryPolicyRules    = 64
	maximumSummaryPolicyParts    = 64
	maximumSummaryRBACRules      = 64
	maximumSummarySubjects       = 64
	maximumSummaryDataKeys       = 64
	maximumSummaryEventFields    = 32
	maximumSummaryQuotaResources = 128
	maximumSummaryLimitItems     = 64
	maximumSummaryAnnotationKeys = 32
)

// appendSummaryText appends only non-empty values.  The final pass in
// summarizeWithKind applies the same bound again, but doing it here keeps
// intermediate strings small when a malformed object contains huge fields.
func appendSummaryText(
	fields []SummaryField,
	section, id, label, value string,
) []SummaryField {
	value = boundedSummaryText(value)
	if value == "" {
		return fields
	}
	return append(fields, SummaryField{
		Section: section, ID: id, Label: label, Value: value,
	})
}

func appendSummaryBool(
	fields []SummaryField,
	section, id, label string,
	value bool,
	found bool,
) []SummaryField {
	if !found {
		return fields
	}
	return append(fields, SummaryField{
		Section: section, ID: id, Label: label, Value: strconv.FormatBool(value),
	})
}

func appendSummaryInteger(
	fields []SummaryField,
	section, id, label string,
	value int64,
	found bool,
) []SummaryField {
	if !found {
		return fields
	}
	return append(fields, SummaryField{
		Section: section, ID: id, Label: label, Value: strconv.FormatInt(value, 10),
	})
}

func appendSummaryTimestamp(
	fields []SummaryField,
	section, id, label string,
	value time.Time,
	presentation SummaryTimestampPresentation,
) []SummaryField {
	if value.IsZero() {
		return fields
	}
	return append(fields, SummaryField{
		Section: section, ID: id, Label: label, Value: value.Format(time.RFC3339),
		Timestamp: value, TimestampPresentation: presentation,
	})
}

func summaryMapAt(object map[string]any, path ...string) (map[string]any, bool) {
	value, found, err := nestedFieldNoCopy(object, path...)
	if err != nil || !found {
		return nil, false
	}
	result, ok := value.(map[string]any)
	return result, ok
}

func nestedFieldNoCopy(object map[string]any, path ...string) (any, bool, error) {
	// Keep the helper local to this file so malformed values are treated as
	// absent instead of making an optional Summary projection fail the GET.
	if len(path) == 0 {
		return object, true, nil
	}
	current := any(object)
	for _, key := range path {
		mapping, ok := current.(map[string]any)
		if !ok {
			return nil, false, nil
		}
		current, ok = mapping[key]
		if !ok {
			return nil, false, nil
		}
	}
	return current, true, nil
}

func summaryStringAt(object map[string]any, path ...string) (string, bool) {
	value, found, err := nestedFieldNoCopy(object, path...)
	if err != nil || !found {
		return "", false
	}
	text, ok := value.(string)
	return text, ok && strings.TrimSpace(text) != ""
}

func summaryBoolAt(object map[string]any, path ...string) (bool, bool) {
	value, found, err := nestedFieldNoCopy(object, path...)
	if err != nil || !found {
		return false, false
	}
	result, ok := value.(bool)
	return result, ok
}

func summaryIntegerAt(object map[string]any, path ...string) (int64, bool) {
	value, found, err := nestedFieldNoCopy(object, path...)
	if err != nil || !found {
		return 0, false
	}
	return summaryInteger(value)
}

func summaryInteger(value any) (int64, bool) {
	switch typed := value.(type) {
	case int:
		return int64(typed), true
	case int8:
		return int64(typed), true
	case int16:
		return int64(typed), true
	case int32:
		return int64(typed), true
	case int64:
		return typed, true
	case uint:
		if uint64(typed) > math.MaxInt64 {
			return 0, false
		}
		return int64(typed), true
	case uint8:
		return int64(typed), true
	case uint16:
		return int64(typed), true
	case uint32:
		return int64(typed), true
	case uint64:
		if typed > math.MaxInt64 {
			return 0, false
		}
		return int64(typed), true
	case float32:
		if float64(typed) != math.Trunc(float64(typed)) || float64(typed) > math.MaxInt64 || float64(typed) < math.MinInt64 {
			return 0, false
		}
		return int64(typed), true
	case float64:
		if typed != math.Trunc(typed) || typed > math.MaxInt64 || typed < math.MinInt64 {
			return 0, false
		}
		return int64(typed), true
	case json.Number:
		parsed, err := strconv.ParseInt(typed.String(), 10, 64)
		return parsed, err == nil
	default:
		return 0, false
	}
}

func summaryTimeAt(object map[string]any, path ...string) time.Time {
	text, found := summaryStringAt(object, path...)
	if !found {
		return time.Time{}
	}
	value, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(text))
	if err != nil {
		return time.Time{}
	}
	return value
}

func summaryStringSliceAt(object map[string]any, path ...string) []string {
	value, found, err := nestedFieldNoCopy(object, path...)
	if err != nil || !found {
		return nil
	}
	items, ok := value.([]any)
	if !ok {
		if strings, ok := value.([]string); ok {
			return slices.Clone(strings)
		}
		return nil
	}
	result := make([]string, 0, len(items))
	for _, item := range items {
		if text, ok := item.(string); ok && strings.TrimSpace(text) != "" {
			result = append(result, text)
		}
	}
	return result
}

func summarySliceAt(object map[string]any, path ...string) []any {
	value, found, err := nestedFieldNoCopy(object, path...)
	if err != nil || !found {
		return nil
	}
	items, _ := value.([]any)
	return items
}

func summaryMapKeys(value map[string]any) []string {
	keys := make([]string, 0, len(value))
	for key := range value {
		if key != "" {
			keys = append(keys, key)
		}
	}
	slices.Sort(keys)
	return keys
}

func summaryDuration(seconds int64) string {
	if seconds < 0 {
		return ""
	}
	if seconds < 60 {
		return fmt.Sprintf("%ds", seconds)
	}
	minutes := seconds / 60
	if minutes < 60 {
		return fmt.Sprintf("%dm", minutes)
	}
	hours := minutes / 60
	if hours < 24 {
		return fmt.Sprintf("%dh", hours)
	}
	return fmt.Sprintf("%dd", hours/24)
}

func summaryScalarText(value any) (string, bool) {
	switch typed := value.(type) {
	case string:
		if strings.TrimSpace(typed) == "" {
			return "", false
		}
		return typed, true
	case bool:
		return strconv.FormatBool(typed), true
	case int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64, float32, float64, json.Number:
		if integer, ok := summaryInteger(typed); ok {
			return strconv.FormatInt(integer, 10), true
		}
		return "", false
	default:
		return "", false
	}
}

func appendScalarPath(
	fields []SummaryField,
	object map[string]any,
	section, id, label string,
	path ...string,
) []SummaryField {
	value, found, err := nestedFieldNoCopy(object, path...)
	if err != nil || !found {
		return fields
	}
	text, ok := summaryScalarText(value)
	if !ok {
		return fields
	}
	return appendSummaryText(fields, section, id, label, text)
}

func appendStringSliceFields(
	fields []SummaryField,
	section, idPrefix, label string,
	values []string,
	limit int,
) []SummaryField {
	if len(values) == 0 {
		return fields
	}
	seen := make(map[string]struct{}, min(len(values), limit))
	omitted := 0
	for _, value := range values {
		value = boundedSummaryText(value)
		if value == "" {
			omitted++
			continue
		}
		if _, duplicate := seen[value]; duplicate {
			continue
		}
		seen[value] = struct{}{}
		if len(seen) > limit {
			omitted++
			continue
		}
		fields = append(fields, SummaryField{
			Section: section,
			ID:      fmt.Sprintf("%s:%d", idPrefix, len(seen)-1),
			Label:   label,
			Value:   value,
		})
	}
	if omitted > 0 {
		fields = append(fields, omittedSummaryField(section, idPrefix+"Omitted", label, omitted))
	}
	return fields
}

func appendMapFields(
	fields []SummaryField,
	section, idPrefix, label string,
	values map[string]any,
	limit int,
) []SummaryField {
	if len(values) == 0 {
		return fields
	}
	keys := summaryMapKeys(values)
	originalCount := len(keys)
	if len(keys) > limit {
		keys = keys[:limit]
	}
	for index, key := range keys {
		text, ok := summaryScalarText(values[key])
		if !ok {
			continue
		}
		fields = append(fields, SummaryField{
			Section: section, ID: fmt.Sprintf("%s:%d", idPrefix, index),
			Label: boundedSummaryLabel(key), Value: boundedSummaryText(text),
		})
	}
	if omitted := originalCount - len(keys); omitted > 0 {
		fields = append(fields, omittedSummaryField(section, idPrefix+"Omitted", label, omitted))
	}
	return fields
}

func summaryLabelSelector(value map[string]any) string {
	parts := make([]string, 0)
	if labels, ok := summaryMapAt(value, "matchLabels"); ok {
		keys := summaryMapKeys(labels)
		if len(keys) > maximumSummarySelectors {
			keys = keys[:maximumSummarySelectors]
		}
		for _, key := range keys {
			text, ok := summaryScalarText(labels[key])
			if ok {
				parts = append(parts, key+"="+text)
			}
		}
	}
	if expressions := summarySliceAt(value, "matchExpressions"); len(expressions) > 0 {
		if len(expressions) > maximumSummarySelectors {
			expressions = expressions[:maximumSummarySelectors]
		}
		for _, raw := range expressions {
			expression, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			key, _ := summaryStringAt(expression, "key")
			op, _ := summaryStringAt(expression, "operator")
			values := summaryStringSliceAt(expression, "values")
			if key == "" || op == "" {
				continue
			}
			term := key + " " + op
			if len(values) > 0 {
				term += " (" + strings.Join(values, ",") + ")"
			}
			parts = append(parts, term)
		}
	}
	slices.Sort(parts)
	return boundedSummaryText(strings.Join(parts, ", "))
}

func formatSelectorValue(value any) string {
	mapping, ok := value.(map[string]any)
	if !ok {
		return ""
	}
	if selector := summaryLabelSelector(mapping); selector != "" {
		return selector
	}
	// A flat selector (used by Services and older APIs) is also accepted.
	keys := summaryMapKeys(mapping)
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		if text, ok := summaryScalarText(mapping[key]); ok {
			parts = append(parts, key+"="+text)
		}
	}
	return boundedSummaryText(strings.Join(parts, ", "))
}

// podDetailSummary adds the fields operators most often need while diagnosing
// a Pod.  It deliberately keeps the existing compact node/IP/container rows
// and only adds lifecycle, scheduling, resource, storage, and security
// context.
func podDetailSummary(object map[string]any) []SummaryField {
	spec, _ := summaryMapAt(object, "spec")
	status, _ := summaryMapAt(object, "status")
	result := podLifecycleSummary(object, status)
	result = podSpecSummary(result, spec, status, "")
	result = podNetworkDetailSummary(result, object, spec, status)
	return result
}

func podLifecycleSummary(object, status map[string]any) []SummaryField {
	result := make([]SummaryField, 0, 16)
	result = appendScalarPath(result, status, "status", "reason", "Reason", "reason")
	result = appendScalarPath(result, status, "status", "message", "Message", "message")
	result = appendSummaryTimestamp(
		result, "status", "startTime", "Start Time",
		summaryTimeAt(status, "startTime"), SummaryTimestampElapsedSince,
	)
	if seconds, found := summaryIntegerAt(object, "metadata", "deletionGracePeriodSeconds"); found {
		result = appendSummaryText(result, "status", "deletionGracePeriod", "Deletion Grace Period", summaryDuration(seconds))
	}
	// The fields below are all Pod spec knobs that change scheduling or
	// termination behavior. Keep the raw Kubernetes spelling in the value.
	for _, field := range []struct {
		path  []string
		id    string
		label string
	}{
		{path: []string{"restartPolicy"}, id: "restartPolicy", label: "Restart Policy"},
		{path: []string{"terminationGracePeriodSeconds"}, id: "terminationGracePeriod", label: "Termination Grace Period"},
		{path: []string{"activeDeadlineSeconds"}, id: "activeDeadline", label: "Active Deadline"},
	} {
		path := append([]string{"spec"}, field.path...)
		if value, found, err := nestedFieldNoCopy(object, path...); err == nil && found {
			if field.id == "terminationGracePeriod" || field.id == "activeDeadline" {
				if seconds, ok := summaryInteger(value); ok {
					result = appendSummaryText(result, "status", field.id, field.label, summaryDuration(seconds))
				}
			} else if text, ok := summaryScalarText(value); ok {
				result = appendSummaryText(result, "status", field.id, field.label, text)
			}
		}
	}
	return result
}

// podSpecSummary is shared by Pods and controller Pod templates.  A non-empty
// prefix makes template rows unambiguous without changing their section
// semantics.  No image, command, environment value, or secret payload is
// copied into Summary.
func podSpecSummary(
	fields []SummaryField,
	spec, status map[string]any,
	prefix string,
) []SummaryField {
	if spec == nil {
		return fields
	}
	id := func(value string) string {
		if prefix == "" {
			return value
		}
		return prefix + ":" + value
	}
	label := func(value string) string {
		if prefix == "" {
			return value
		}
		return "Template " + value
	}

	for _, field := range []struct {
		key, fieldID, fieldLabel string
	}{
		{"schedulerName", "scheduler", "Scheduler"},
		{"priorityClassName", "priorityClass", "Priority Class"},
		{"preemptionPolicy", "preemptionPolicy", "Preemption Policy"},
		{"runtimeClassName", "runtimeClass", "Runtime Class"},
		{"serviceAccountName", "serviceAccount", "Service Account"},
		{"dnsPolicy", "dnsPolicy", "DNS Policy"},
		{"hostname", "hostname", "Hostname"},
		{"subdomain", "subdomain", "Subdomain"},
	} {
		if text, found := summaryStringAt(spec, field.key); found {
			section := "scheduling"
			if field.fieldID == "serviceAccount" {
				section = "security"
			}
			fields = appendSummaryText(fields, section, id(field.fieldID), label(field.fieldLabel), text)
		}
	}
	if qos, found := summaryStringAt(status, "qosClass"); found {
		fields = appendSummaryText(fields, "resources", id("qosClass"), label("QoS Class"), qos)
	}
	if priority, found := summaryIntegerAt(spec, "priority"); found {
		fields = appendSummaryInteger(fields, "scheduling", id("priority"), label("Priority"), priority, true)
	}
	for _, field := range []struct {
		key, fieldID, fieldLabel string
		section                  string
	}{
		{"hostNetwork", "hostNetwork", "Host Network", "network"},
		{"hostPID", "hostPID", "Host PID", "security"},
		{"hostIPC", "hostIPC", "Host IPC", "security"},
		{"shareProcessNamespace", "shareProcessNamespace", "Share Process Namespace", "security"},
		{"automountServiceAccountToken", "automountServiceAccountToken", "Automount Service Account Token", "security"},
		{"hostUsers", "hostUsers", "Host Users", "security"},
	} {
		if value, found := summaryBoolAt(spec, field.key); found {
			fields = appendSummaryBool(fields, field.section, id(field.fieldID), label(field.fieldLabel), value, true)
		}
	}

	if selector, ok := summaryMapAt(spec, "nodeSelector"); ok {
		fields = appendMapFields(fields, "scheduling", id("nodeSelector"), label("Node Selector"), selector, maximumSummaryPodConstraints)
	}
	fields = appendReferenceFieldsWithPrefix(fields, summarySliceAt(spec, "imagePullSecrets"), "imagePullSecret", label("Image Pull Secret"), id, "security", maximumSummaryPodConstraints)
	fields = appendTolerationSummary(fields, spec, id, label)
	fields = appendAffinitySummary(fields, spec, id, label)
	fields = appendTopologySpreadSummary(fields, spec, id, label)
	fields = appendGateSummary(fields, spec, id, label)
	fields = appendContainerSpecSummary(fields, spec, status, id, label)
	if overhead, ok := summaryMapAt(spec, "overhead"); ok {
		var omitted int
		fields, omitted = appendContainerQuantityMapFields(fields, overhead, id, label, "Pod Overhead", maximumSummaryPodResources)
		if omitted > 0 {
			fields = append(fields, omittedSummaryField("resources", id("overheadOmitted"), label("Pod Overhead"), omitted))
		}
	}
	fields = appendVolumeSummary(fields, spec, id, label)
	fields = appendPodSecurityContextSummary(fields, spec, id, label)
	return fields
}

func appendTolerationSummary(
	fields []SummaryField,
	spec map[string]any,
	id func(string) string,
	label func(string) string,
) []SummaryField {
	tolerations := summarySliceAt(spec, "tolerations")
	if len(tolerations) == 0 {
		return fields
	}
	omitted := 0
	displayed := 0
	for _, raw := range tolerations {
		if displayed >= maximumSummaryPodConstraints {
			omitted++
			continue
		}
		item, ok := raw.(map[string]any)
		if !ok {
			omitted++
			continue
		}
		parts := make([]string, 0, 4)
		for _, key := range []string{"key", "operator", "value", "effect"} {
			if text, found := summaryStringAt(item, key); found {
				if key == "key" && len(parts) == 0 {
					parts = append(parts, text)
				} else {
					parts = append(parts, key+"="+text)
				}
			}
		}
		if seconds, found := summaryIntegerAt(item, "tolerationSeconds"); found {
			parts = append(parts, "seconds="+strconv.FormatInt(seconds, 10))
		}
		if len(parts) == 0 {
			omitted++
			continue
		}
		fields = appendSummaryText(fields, "scheduling", id(fmt.Sprintf("toleration:%d", displayed)), label("Toleration"), strings.Join(parts, " "))
		displayed++
	}
	if omitted > 0 {
		fields = append(fields, omittedSummaryField("scheduling", id("tolerationsOmitted"), label("Tolerations"), omitted))
	}
	return fields
}

func appendGateSummary(
	fields []SummaryField,
	spec map[string]any,
	id func(string) string,
	label func(string) string,
) []SummaryField {
	for _, item := range []struct {
		path, fieldID, fieldLabel string
	}{
		{"readinessGates", "readinessGate", "Readiness Gate"},
		{"schedulingGates", "schedulingGate", "Scheduling Gate"},
	} {
		values := summarySliceAt(spec, item.path)
		if len(values) == 0 {
			continue
		}
		omitted := 0
		displayed := 0
		for _, raw := range values {
			if displayed >= maximumSummaryPodConstraints {
				omitted++
				continue
			}
			mapping, ok := raw.(map[string]any)
			if !ok {
				omitted++
				continue
			}
			// PodReadinessGate serializes its field as conditionType.  Keep
			// the older condition/name spellings as bounded fallbacks for
			// malformed or pre-release objects.
			name, found := summaryStringAt(mapping, "conditionType")
			if !found {
				name, found = summaryStringAt(mapping, "condition")
			}
			if !found {
				name, found = summaryStringAt(mapping, "name")
			}
			if !found {
				omitted++
				continue
			}
			fields = appendSummaryText(fields, "scheduling", id(fmt.Sprintf("%s:%d", item.fieldID, displayed)), label(item.fieldLabel), name)
			displayed++
		}
		if omitted > 0 {
			fields = append(fields, omittedSummaryField("scheduling", id(item.fieldID+"sOmitted"), label(item.fieldLabel+"s"), omitted))
		}
	}
	return fields
}

func appendAffinitySummary(
	fields []SummaryField,
	spec map[string]any,
	id func(string) string,
	label func(string) string,
) []SummaryField {
	affinity, ok := summaryMapAt(spec, "affinity")
	if !ok {
		return fields
	}
	for _, kind := range []struct {
		key, fieldID, fieldLabel string
	}{
		{"nodeAffinity", "nodeAffinity", "Node Affinity"},
		{"podAffinity", "podAffinity", "Pod Affinity"},
		{"podAntiAffinity", "podAntiAffinity", "Pod Anti-Affinity"},
	} {
		value, found := summaryAffinityKind(affinity, kind.key)
		if !found {
			continue
		}
		fields = appendSummaryText(fields, "scheduling", id(kind.fieldID), label(kind.fieldLabel), value)
	}
	return fields
}

func summaryAffinityKind(affinity map[string]any, key string) (string, bool) {
	mapping, ok := summaryMapAt(affinity, key)
	if !ok {
		return "", false
	}
	parts := make([]string, 0, 4)
	for _, phase := range []string{"requiredDuringSchedulingIgnoredDuringExecution", "preferredDuringSchedulingIgnoredDuringExecution"} {
		terms := summarySliceAt(mapping, phase)
		if len(terms) == 0 {
			continue
		}
		termTexts := make([]string, 0, min(len(terms), 8))
		for _, raw := range terms {
			term, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			weight := ""
			if number, found := summaryIntegerAt(term, "weight"); found {
				weight = fmt.Sprintf("weight=%d ", number)
			}
			selector := ""
			if value, found := summaryMapAt(term, "labelSelector"); found {
				selector = formatSelectorValue(value)
			}
			if selector == "" {
				expressions := summarySliceAt(term, "matchExpressions")
				if len(expressions) > 0 {
					selector = formatMatchExpressions(expressions)
				}
			}
			topology, _ := summaryStringAt(term, "topologyKey")
			if topology != "" {
				selector = strings.TrimSpace(selector + " topology=" + topology)
			}
			if selector != "" {
				termTexts = append(termTexts, weight+selector)
			}
		}
		if len(termTexts) > 0 {
			parts = append(parts, strings.TrimSuffix(phase, "DuringSchedulingIgnoredDuringExecution")+": "+strings.Join(termTexts, " | "))
		}
	}
	value := boundedSummaryText(strings.Join(parts, "; "))
	return value, value != ""
}

func formatMatchExpressions(values []any) string {
	parts := make([]string, 0, min(len(values), maximumSummaryPolicyParts))
	for _, raw := range values {
		mapping, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		key, _ := summaryStringAt(mapping, "key")
		op, _ := summaryStringAt(mapping, "operator")
		if key == "" || op == "" {
			continue
		}
		values := summaryStringSliceAt(mapping, "values")
		text := key + " " + op
		if len(values) > 0 {
			text += " (" + strings.Join(values, ",") + ")"
		}
		parts = append(parts, text)
		if len(parts) == maximumSummaryPolicyParts {
			break
		}
	}
	slices.Sort(parts)
	return boundedSummaryText(strings.Join(parts, ", "))
}

func appendTopologySpreadSummary(
	fields []SummaryField,
	spec map[string]any,
	id func(string) string,
	label func(string) string,
) []SummaryField {
	values := summarySliceAt(spec, "topologySpreadConstraints")
	if len(values) == 0 {
		return fields
	}
	omitted := 0
	displayed := 0
	for _, raw := range values {
		if displayed >= maximumSummaryPodConstraints {
			omitted++
			continue
		}
		mapping, ok := raw.(map[string]any)
		if !ok {
			omitted++
			continue
		}
		parts := make([]string, 0, 4)
		if value, found := summaryIntegerAt(mapping, "maxSkew"); found {
			parts = append(parts, fmt.Sprintf("maxSkew=%d", value))
		}
		for _, key := range []string{"topologyKey", "whenUnsatisfiable", "minDomains", "nodeAffinityPolicy", "nodeTaintsPolicy"} {
			if text, found := summaryStringAt(mapping, key); found {
				parts = append(parts, key+"="+text)
			} else if number, found := summaryIntegerAt(mapping, key); found {
				parts = append(parts, key+"="+strconv.FormatInt(number, 10))
			}
		}
		if selector, found := summaryMapAt(mapping, "labelSelector"); found {
			if text := formatSelectorValue(selector); text != "" {
				parts = append(parts, "selector="+text)
			}
		}
		if len(parts) == 0 {
			omitted++
			continue
		}
		fields = appendSummaryText(fields, "scheduling", id(fmt.Sprintf("topologySpread:%d", displayed)), label("Topology Spread"), strings.Join(parts, " "))
		displayed++
	}
	if omitted > 0 {
		fields = append(fields, omittedSummaryField("scheduling", id("topologySpreadOmitted"), label("Topology Spread"), omitted))
	}
	return fields
}

func appendContainerSpecSummary(
	fields []SummaryField,
	spec, status map[string]any,
	id func(string) string,
	label func(string) string,
) []SummaryField {
	type groupSpec struct {
		specKey, statusKey, idPrefix, label string
	}
	groups := []groupSpec{
		{specKey: "containers", statusKey: "containerStatuses", idPrefix: "container", label: "Container"},
		{specKey: "initContainers", statusKey: "initContainerStatuses", idPrefix: "initContainer", label: "Init Container"},
		{specKey: "ephemeralContainers", statusKey: "ephemeralContainerStatuses", idPrefix: "ephemeralContainer", label: "Ephemeral Container"},
	}
	statusByGroup := make(map[string]map[string]map[string]any, len(groups))
	for _, group := range groups {
		statusByGroup[group.statusKey] = summaryContainerStatusByName(status, group.statusKey)
	}
	remainingStates := maximumSummaryContainers
	remainingProbes := maximumSummaryProbeFields
	remainingResources := maximumSummaryPodResources
	remainingMounts := maximumSummaryPodMounts
	omittedStates := 0
	omittedProbes := 0
	omittedResources := 0
	omittedMounts := 0
	for _, group := range groups {
		containers := summarySliceAt(spec, group.specKey)
		for _, raw := range containers {
			if remainingStates == 0 {
				omittedStates++
				continue
			}
			container, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			name, found := summaryStringAt(container, "name")
			if !found || !validSummaryToken(name, maximumSummaryNameBytes) {
				continue
			}
			if status != nil {
				containerID := id("state:" + group.idPrefix + ":" + name)
				if state := formatContainerState(statusByGroup[group.statusKey][name]); state != "" {
					fields = appendSummaryText(fields, "status", containerID, label(group.label+" "+name), state)
				} else {
					fields = appendSummaryText(fields, "status", containerID, label(group.label+" "+name), "Pending")
				}
			}
			remainingStates--

			for _, probe := range []struct {
				key, fieldID, fieldLabel string
			}{
				{"readinessProbe", "readinessProbe", "Readiness Probe"},
				{"livenessProbe", "livenessProbe", "Liveness Probe"},
				{"startupProbe", "startupProbe", "Startup Probe"},
			} {
				value, found := summaryMapAt(container, probe.key)
				if !found {
					continue
				}
				text := formatProbe(value)
				if text == "" {
					continue
				}
				if remainingProbes == 0 {
					omittedProbes++
					continue
				}
				fields = appendSummaryText(fields, "containers", id(fmt.Sprintf("%s:%s:%s", probe.fieldID, group.idPrefix, name)), label(group.label+" "+name+" "+probe.fieldLabel), text)
				remainingProbes--
			}

			if resources, found := summaryMapAt(container, "resources"); found {
				var omitted int
				fields, remainingResources, omitted = appendContainerResourceFields(
					fields, resources, id, label, group.label+" "+name, remainingResources,
				)
				omittedResources += omitted
			}
			if mounts := summarySliceAt(container, "volumeMounts"); len(mounts) > 0 {
				var omitted int
				fields, remainingMounts, omitted = appendVolumeMountFields(fields, mounts, id, label, group.label+" "+name, remainingMounts)
				omittedMounts += omitted
			}
		}
	}
	if omittedStates > 0 {
		fields = append(fields, omittedSummaryField("status", id("containerStatesOmitted"), label("Container States"), omittedStates))
	}
	if omittedProbes > 0 {
		fields = append(fields, omittedSummaryField("containers", id("probesOmitted"), label("Probes"), omittedProbes))
	}
	if omittedResources > 0 {
		fields = append(fields, omittedSummaryField("resources", id("containerResourcesOmitted"), label("Container Resources"), omittedResources))
	}
	if omittedMounts > 0 {
		fields = append(fields, omittedSummaryField("storage", id("mountsOmitted"), label("Volume Mounts"), omittedMounts))
	}
	return fields
}

func summaryContainerStatusByName(status map[string]any, key string) map[string]map[string]any {
	result := make(map[string]map[string]any)
	for _, raw := range summarySliceAt(status, key) {
		mapping, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		name, found := summaryStringAt(mapping, "name")
		if found {
			if _, duplicate := result[name]; !duplicate {
				result[name] = mapping
			}
		}
	}
	return result
}

func formatContainerState(status map[string]any) string {
	if status == nil {
		return ""
	}
	parts := make([]string, 0, 4)
	state, _ := summaryMapAt(status, "state")
	if state == nil {
		return "Pending"
	}
	for _, item := range []struct {
		key, title string
	}{
		{"running", "Running"}, {"waiting", "Waiting"}, {"terminated", "Terminated"},
	} {
		if detail, found := summaryMapAt(state, item.key); found {
			text := item.title
			if reason, ok := summaryStringAt(detail, "reason"); ok {
				text += ": " + reason
			}
			if exitCode, ok := summaryIntegerAt(detail, "exitCode"); ok && item.key == "terminated" {
				text += fmt.Sprintf(" · Exit code %d", exitCode)
			}
			parts = append(parts, text)
			break
		}
	}
	if len(parts) == 0 {
		parts = append(parts, "Pending")
	}
	if ready, found := summaryBoolAt(status, "ready"); found {
		if ready {
			parts = append(parts, "Ready")
		} else {
			parts = append(parts, "Not ready")
		}
	}
	if restarts, found := summaryIntegerAt(status, "restartCount"); found && restarts > 0 {
		parts = append(parts, fmt.Sprintf("%d restarts", restarts))
	}
	return boundedSummaryText(strings.Join(parts, " · "))
}

func formatProbe(probe map[string]any) string {
	parts := make([]string, 0, 6)
	if httpGet, found := summaryMapAt(probe, "httpGet"); found {
		method := "HTTP"
		if value, ok := summaryStringAt(httpGet, "scheme"); ok {
			method = strings.ToUpper(value)
		}
		path, _ := summaryStringAt(httpGet, "path")
		port := ""
		if text, ok := summaryStringAt(httpGet, "port"); ok {
			port = text
		} else if number, ok := summaryIntegerAt(httpGet, "port"); ok {
			port = strconv.FormatInt(number, 10)
		}
		text := method + " GET"
		if path != "" {
			text += " " + path
		}
		if port != "" {
			text += ":" + port
		}
		parts = append(parts, text)
	}
	if tcp, found := summaryMapAt(probe, "tcpSocket"); found {
		port := ""
		if text, ok := summaryStringAt(tcp, "port"); ok {
			port = text
		} else if number, ok := summaryIntegerAt(tcp, "port"); ok {
			port = strconv.FormatInt(number, 10)
		}
		parts = append(parts, "TCP"+suffixPort(port))
	}
	if grpc, found := summaryMapAt(probe, "grpc"); found {
		port, _ := summaryIntegerAt(grpc, "port")
		text := "gRPC"
		if port > 0 {
			text += ":" + strconv.FormatInt(port, 10)
		}
		if service, ok := summaryStringAt(grpc, "service"); ok {
			text += " " + service
		}
		parts = append(parts, text)
	}
	if _, found := summaryMapAt(probe, "exec"); found {
		// Do not include the command: it can contain credentials or tokens.
		parts = append(parts, "Exec")
	}
	for _, key := range []string{"initialDelaySeconds", "periodSeconds", "timeoutSeconds", "failureThreshold", "successThreshold", "terminationGracePeriodSeconds"} {
		if number, ok := summaryIntegerAt(probe, key); ok {
			parts = append(parts, key+"="+strconv.FormatInt(number, 10))
		}
	}
	return boundedSummaryText(strings.Join(parts, " · "))
}

func suffixPort(port string) string {
	if port == "" {
		return ""
	}
	return ":" + port
}

func appendContainerResourceFields(
	fields []SummaryField,
	resources map[string]any,
	id func(string) string,
	label func(string) string,
	containerLabel string,
	remaining int,
) ([]SummaryField, int, int) {
	omitted := 0
	for _, resourceClass := range []struct {
		key, idPrefix, title string
	}{
		{"requests", "request", "Request"}, {"limits", "limit", "Limit"},
	} {
		values, ok := summaryMapAt(resources, resourceClass.key)
		if !ok {
			continue
		}
		for _, name := range summaryMapKeys(values) {
			if remaining == 0 {
				if _, valid := summaryQuantityText(values[name]); valid {
					omitted++
				}
				continue
			}
			quantity, ok := summaryQuantityText(values[name])
			if !ok {
				continue
			}
			fields = appendSummaryText(fields, "resources", id(fmt.Sprintf("%s:%s:%s", resourceClass.idPrefix, containerLabel, name)), label(containerLabel+" "+resourceClass.title+" "+summaryResourceLabel(name)), quantity)
			remaining--
		}
	}
	return fields, remaining, omitted
}

func appendVolumeSummary(
	fields []SummaryField,
	spec map[string]any,
	id func(string) string,
	label func(string) string,
) []SummaryField {
	volumes := summarySliceAt(spec, "volumes")
	if len(volumes) == 0 {
		return fields
	}
	displayed := 0
	omitted := 0
	for _, raw := range volumes {
		if displayed >= maximumSummaryPodVolumes {
			omitted++
			continue
		}
		volume, ok := raw.(map[string]any)
		if !ok {
			omitted++
			continue
		}
		name, found := summaryStringAt(volume, "name")
		if !found {
			omitted++
			continue
		}
		source := formatVolumeSource(volume)
		if source == "" {
			source = "Unknown source"
		}
		fields = appendSummaryText(fields, "storage", id(fmt.Sprintf("volume:%d", displayed)), label("Volume "+name), source)
		displayed++
	}
	if omitted > 0 {
		fields = append(fields, omittedSummaryField("storage", id("volumesOmitted"), label("Volumes"), omitted))
	}
	return fields
}

func formatVolumeSource(volume map[string]any) string {
	for _, source := range []struct {
		key, title string
	}{
		{"persistentVolumeClaim", "PVC"},
		{"configMap", "ConfigMap"},
		{"secret", "Secret"},
		{"projected", "Projected"},
		{"emptyDir", "EmptyDir"},
		{"downwardAPI", "Downward API"},
		{"hostPath", "Host Path"},
		{"csi", "CSI"},
		{"ephemeral", "Ephemeral"},
		{"nfs", "NFS"},
	} {
		mapping, found := summaryMapAt(volume, source.key)
		if !found {
			continue
		}
		parts := []string{source.title}
		for _, key := range []string{"claimName", "name", "driver", "volumeHandle", "path", "server", "readOnly", "fsType"} {
			if text, ok := summaryStringAt(mapping, key); ok {
				parts = append(parts, key+"="+text)
			} else if value, ok := summaryBoolAt(mapping, key); ok {
				parts = append(parts, key+"="+strconv.FormatBool(value))
			}
		}
		return boundedSummaryText(strings.Join(parts, " "))
	}
	return ""
}

func appendVolumeMountFields(
	fields []SummaryField,
	mounts []any,
	id func(string) string,
	label func(string) string,
	containerLabel string,
	remaining int,
) ([]SummaryField, int, int) {
	displayed := 0
	omitted := 0
	for _, raw := range mounts {
		if remaining == 0 {
			omitted++
			continue
		}
		mount, ok := raw.(map[string]any)
		if !ok {
			omitted++
			continue
		}
		name, foundName := summaryStringAt(mount, "name")
		path, foundPath := summaryStringAt(mount, "mountPath")
		if !foundName && !foundPath {
			omitted++
			continue
		}
		text := name
		if path != "" {
			text += " → " + path
		}
		if subPath, ok := summaryStringAt(mount, "subPath"); ok {
			text += " (subPath " + subPath + ")"
		}
		if readOnly, ok := summaryBoolAt(mount, "readOnly"); ok && readOnly {
			text += " (read-only)"
		}
		fields = appendSummaryText(fields, "storage", id(fmt.Sprintf("mount:%s:%d", containerLabel, displayed)), label(containerLabel+" Mount"), text)
		displayed++
		remaining--
	}
	return fields, remaining, omitted
}

func appendPodSecurityContextSummary(
	fields []SummaryField,
	spec map[string]any,
	id func(string) string,
	label func(string) string,
) []SummaryField {
	context, ok := summaryMapAt(spec, "securityContext")
	if !ok {
		return fields
	}
	for _, key := range []string{"runAsUser", "runAsGroup", "fsGroup", "runAsNonRoot", "fsGroupChangePolicy", "seLinuxOptions", "seccompProfile", "windowsOptions"} {
		value, found := context[key]
		if !found {
			continue
		}
		var text string
		if scalar, ok := summaryScalarText(value); ok {
			text = scalar
		} else if mapping, ok := value.(map[string]any); ok {
			text = formatSecurityMap(mapping)
		}
		if text != "" {
			fields = appendSummaryText(fields, "security", id("podSecurity:"+key), label("Pod "+securityLabel(key)), text)
		}
	}
	return fields
}

func formatSecurityMap(value map[string]any) string {
	parts := make([]string, 0, len(value))
	for _, key := range summaryMapKeys(value) {
		// Windows security contexts may carry a complete GMSA credential
		// specification.  More generally, provider-specific security maps can
		// grow credential-bearing scalar fields over time.  Keep the Summary
		// projection display-safe by omitting keys whose names clearly identify
		// secret material; the explicit YAML surface remains available for users
		// who intentionally need the complete object.
		if summarySensitiveKey(key) {
			continue
		}
		if text, ok := summaryScalarText(value[key]); ok {
			parts = append(parts, key+"="+text)
		}
	}
	return boundedSummaryText(strings.Join(parts, " "))
}

func summarySensitiveKey(value string) bool {
	lower := strings.ToLower(value)
	for _, marker := range []string{"credential", "password", "secret", "token", "privatekey", "private-key"} {
		if strings.Contains(lower, marker) {
			return true
		}
	}
	return false
}

func securityLabel(key string) string {
	var builder strings.Builder
	previousLower := false
	for _, current := range key {
		if current == '_' || current == '-' {
			if builder.Len() > 0 {
				builder.WriteByte(' ')
			}
			previousLower = false
			continue
		}
		if current >= 'A' && current <= 'Z' && previousLower {
			builder.WriteByte(' ')
		}
		if builder.Len() == 0 || (builder.Len() > 0 && !previousLower && current >= 'a' && current <= 'z') {
			// Preserve the original case for acronyms, but capitalize the first
			// character of ordinary lower-camel keys.
			if builder.Len() == 0 && current >= 'a' && current <= 'z' {
				current -= 'a' - 'A'
			}
		}
		builder.WriteRune(current)
		previousLower = current >= 'a' && current <= 'z'
	}
	return builder.String()
}

func summaryResourceLabel(name string) string {
	if name == "storage" {
		return "Storage"
	}
	return nodeResourceLabel(name)
}

func podNetworkDetailSummary(
	fields []SummaryField,
	object, spec, status map[string]any,
) []SummaryField {
	for _, family := range []struct {
		path, idPrefix, label string
	}{
		{"podIPs", "podIP", "Pod IP"},
		{"hostIPs", "hostIP", "Host IP"},
	} {
		values := summarySliceAt(status, family.path)
		if len(values) == 0 {
			continue
		}
		seen := make(map[string]struct{})
		primary := ""
		if family.idPrefix == "podIP" {
			primary, _ = summaryStringAt(status, "podIP")
		} else {
			primary, _ = summaryStringAt(status, "hostIP")
		}
		displayed := 0
		omitted := 0
		for _, raw := range values {
			var text string
			if item, ok := raw.(map[string]any); ok {
				text, _ = summaryStringAt(item, "ip")
			} else {
				text, _ = raw.(string)
			}
			if text == "" {
				omitted++
				continue
			}
			if text == primary {
				continue
			}
			if _, duplicate := seen[text]; duplicate {
				continue
			}
			seen[text] = struct{}{}
			if displayed >= maximumSummaryPodIPs {
				omitted++
				continue
			}
			fields = appendSummaryText(fields, "network", fmt.Sprintf("%s:%d", family.idPrefix, displayed), family.label, text)
			displayed++
		}
		if omitted > 0 {
			fields = append(fields, omittedSummaryField("network", family.idPrefix+"sOmitted", family.label+"s", omitted))
		}
	}
	if dns, ok := summaryMapAt(spec, "dnsConfig"); ok {
		fields = appendStringSliceFields(fields, "network", "dnsNameserver", "DNS Nameserver", summaryStringSliceAt(dns, "nameservers"), maximumSummaryPodIPs)
		fields = appendStringSliceFields(fields, "network", "dnsSearch", "DNS Search Domain", summaryStringSliceAt(dns, "searches"), maximumSummaryPodIPs)
	}
	return fields
}

func workloadDetailSummary(object map[string]any, kind string) []SummaryField {
	spec, _ := summaryMapAt(object, "spec")
	if spec == nil {
		return nil
	}
	result := make([]SummaryField, 0, maximumSummaryWorkloadFields)
	result = appendWorkloadRolloutSummary(result, object, spec, kind)
	if template, ok := summaryMapAt(spec, "template"); ok {
		if templateSpec, ok := summaryMapAt(template, "spec"); ok {
			result = podSpecSummary(result, templateSpec, nil, "template")
			result = append(result, podTemplateContainerSummary(templateSpec)...)
		}
		if templateMetadata, ok := summaryMapAt(template, "metadata"); ok {
			if labels, ok := summaryMapAt(templateMetadata, "labels"); ok {
				result = appendMapFields(result, "rollout", "templateLabel", "Template Labels", labels, maximumSummaryPodConstraints)
			}
		}
	}
	if kind == "Job" {
		result = appendJobSpecSummary(result, spec, object)
	}
	return result
}

func appendWorkloadRolloutSummary(
	fields []SummaryField,
	object, spec map[string]any,
	kind string,
) []SummaryField {
	result := fields
	if strategy, ok := summaryMapAt(spec, "strategy"); ok {
		if text, found := summaryStringAt(strategy, "type"); found {
			result = appendSummaryText(result, "rollout", "strategy", "Strategy", text)
		}
		if rolling, found := summaryMapAt(strategy, "rollingUpdate"); found {
			for _, key := range []string{"maxSurge", "maxUnavailable"} {
				if value, found := rolling[key]; found {
					if text, ok := summaryScalarText(value); ok {
						result = appendSummaryText(result, "rollout", key, securityLabel(key), text)
					}
				}
			}
		}
	}
	for _, field := range []struct {
		key, id, label string
	}{
		{"minReadySeconds", "minReadySeconds", "Min Ready Seconds"},
		{"progressDeadlineSeconds", "progressDeadlineSeconds", "Progress Deadline Seconds"},
		{"revisionHistoryLimit", "revisionHistoryLimit", "Revision History Limit"},
		{"podManagementPolicy", "podManagementPolicy", "Pod Management Policy"},
		{"serviceName", "serviceName", "Service Name"},
		{"partition", "partition", "Update Partition"},
	} {
		if text, found := summaryStringAt(spec, field.key); found {
			result = appendSummaryText(result, "rollout", field.id, field.label, text)
		} else if number, found := summaryIntegerAt(spec, field.key); found {
			result = appendSummaryInteger(result, "rollout", field.id, field.label, number, true)
		}
	}
	if paused, found := summaryBoolAt(spec, "paused"); found {
		result = appendSummaryBool(result, "rollout", "paused", "Paused", paused, true)
	}
	if revision, found := summaryStringAt(object, "metadata", "annotations", "deployment.kubernetes.io/revision"); found {
		result = appendSummaryText(result, "rollout", "revision", "Revision", revision)
	}
	if revision, found := summaryStringAt(object, "metadata", "annotations", "controller.kubernetes.io/hash"); found && kind == "DaemonSet" {
		result = appendSummaryText(result, "rollout", "controllerHash", "Controller Hash", revision)
	}
	if collision, found := summaryIntegerAt(object, "status", "collisionCount"); found {
		result = appendSummaryInteger(result, "rollout", "collisionCount", "Collision Count", collision, true)
	}
	if kind == "StatefulSet" {
		if update, ok := summaryMapAt(spec, "updateStrategy"); ok {
			if text, found := summaryStringAt(update, "type"); found {
				result = appendSummaryText(result, "rollout", "updateStrategy", "Update Strategy", text)
			}
			if rolling, ok := summaryMapAt(update, "rollingUpdate"); ok {
				if partition, found := summaryIntegerAt(rolling, "partition"); found {
					result = appendSummaryInteger(result, "rollout", "partition", "Update Partition", partition, true)
				}
			}
		}
		for _, field := range []struct {
			path, id, label string
		}{
			{"status.currentRevision", "currentRevision", "Current Revision"},
			{"status.updateRevision", "updateRevision", "Update Revision"},
		} {
			path := strings.Split(field.path, ".")
			if text, found := summaryStringAt(object, path...); found {
				result = appendSummaryText(result, "rollout", field.id, field.label, text)
			}
		}
		if claims := summarySliceAt(spec, "volumeClaimTemplates"); len(claims) > 0 {
			result = appendVolumeClaimTemplateSummary(result, claims)
		}
	}
	if kind == "DaemonSet" {
		if update, ok := summaryMapAt(spec, "updateStrategy"); ok {
			if text, found := summaryStringAt(update, "type"); found {
				result = appendSummaryText(result, "rollout", "updateStrategy", "Update Strategy", text)
			}
			if rolling, ok := summaryMapAt(update, "rollingUpdate"); ok {
				for _, key := range []string{"maxUnavailable", "maxSurge"} {
					if value, found := rolling[key]; found {
						if text, ok := summaryScalarText(value); ok {
							result = appendSummaryText(result, "rollout", key, securityLabel(key), text)
						}
					}
				}
			}
		}
	}
	if kind == "ReplicaSet" {
		if revision, found := summaryStringAt(object, "metadata", "annotations", "deployment.kubernetes.io/revision"); found {
			result = appendSummaryText(result, "rollout", "revision", "Revision", revision)
		}
	}
	return result
}

func appendVolumeClaimTemplateSummary(fields []SummaryField, claims []any) []SummaryField {
	displayed := 0
	omitted := 0
	for _, raw := range claims {
		if displayed >= maximumSummaryStorageValues {
			omitted++
			continue
		}
		claim, ok := raw.(map[string]any)
		if !ok {
			omitted++
			continue
		}
		metadata, _ := summaryMapAt(claim, "metadata")
		name, _ := summaryStringAt(metadata, "name")
		spec, _ := summaryMapAt(claim, "spec")
		if name == "" {
			omitted++
			continue
		}
		parts := []string{}
		if storageClass, found := summaryStringAt(spec, "storageClassName"); found {
			parts = append(parts, "class="+storageClass)
		}
		if modes := summaryStringSliceAt(spec, "accessModes"); len(modes) > 0 {
			parts = append(parts, "access="+strings.Join(modes, ","))
		}
		if resources, ok := summaryMapAt(spec, "resources"); ok {
			if requests, ok := summaryMapAt(resources, "requests"); ok {
				if storage, ok := summaryQuantityText(requests["storage"]); ok {
					parts = append(parts, "request="+storage)
				}
			}
		}
		value := strings.Join(parts, " ")
		if value == "" {
			value = "Configured"
		}
		fields = appendSummaryText(fields, "storage", fmt.Sprintf("claimTemplate:%d", displayed), "Volume Claim Template "+name, value)
		displayed++
	}
	if omitted > 0 {
		fields = append(fields, omittedSummaryField("storage", "claimTemplatesOmitted", "Volume Claim Templates", omitted))
	}
	return fields
}

func appendJobSpecSummary(fields []SummaryField, spec, object map[string]any) []SummaryField {
	return appendJobFields(fields, spec, object, "")
}

func appendJobFields(
	fields []SummaryField,
	spec, object map[string]any,
	prefix string,
) []SummaryField {
	id := func(value string) string {
		if prefix == "" {
			return value
		}
		return prefix + ":" + value
	}
	label := func(value string) string {
		if prefix == "" {
			return value
		}
		return "Job Template " + value
	}
	for _, field := range []struct {
		key, fieldID, fieldLabel string
	}{
		{"completionMode", "completionMode", "Completion Mode"},
		{"backoffLimit", "backoffLimit", "Backoff Limit"},
		{"activeDeadlineSeconds", "activeDeadline", "Active Deadline Seconds"},
		{"ttlSecondsAfterFinished", "ttlAfterFinished", "TTL After Finished"},
		{"podFailurePolicy", "podFailurePolicy", "Pod Failure Policy"},
	} {
		if text, found := summaryStringAt(spec, field.key); found {
			fields = appendSummaryText(fields, "job", id(field.fieldID), label(field.fieldLabel), text)
		} else if number, found := summaryIntegerAt(spec, field.key); found {
			value := strconv.FormatInt(number, 10)
			if field.key == "activeDeadlineSeconds" || field.key == "ttlSecondsAfterFinished" {
				value = summaryDuration(number)
			}
			fields = appendSummaryText(fields, "job", id(field.fieldID), label(field.fieldLabel), value)
		}
	}
	if parallelism, found := summaryIntegerAt(spec, "parallelism"); found {
		fields = appendSummaryInteger(fields, "job", id("parallelism"), label("Parallelism"), parallelism, true)
	}
	if completions, found := summaryIntegerAt(spec, "completions"); found {
		fields = appendSummaryInteger(fields, "job", id("completions"), label("Desired Completions"), completions, true)
	}
	for _, field := range []struct {
		key, id, label string
	}{
		{"active", "active", "Active"}, {"succeeded", "succeeded", "Succeeded"}, {"failed", "failed", "Failed"},
	} {
		if value, found := summaryIntegerAt(object, "status", field.key); found {
			fields = appendSummaryInteger(fields, "job", id(field.id), label(field.label), value, true)
		}
	}
	fields = appendSummaryTimestamp(fields, "job", id("startTime"), label("Start Time"), summaryTimeAt(object, "status", "startTime"), SummaryTimestampElapsedSince)
	fields = appendSummaryTimestamp(fields, "job", id("completionTime"), label("Completion Time"), summaryTimeAt(object, "status", "completionTime"), SummaryTimestampOccurredAt)
	return fields
}

func cronJobSummary(object map[string]any) []SummaryField {
	spec, _ := summaryMapAt(object, "spec")
	if spec == nil {
		return nil
	}
	result := make([]SummaryField, 0, 32)
	for _, field := range []struct {
		key, id, label string
	}{
		{"schedule", "schedule", "Schedule"},
		{"timeZone", "timeZone", "Time Zone"},
		{"concurrencyPolicy", "concurrencyPolicy", "Concurrency Policy"},
	} {
		if text, found := summaryStringAt(spec, field.key); found {
			result = appendSummaryText(result, "job", field.id, field.label, text)
		}
	}
	for _, field := range []struct {
		key, id, label string
	}{
		{"suspend", "suspend", "Suspended"},
		{"startingDeadlineSeconds", "startingDeadline", "Starting Deadline"},
		{"successfulJobsHistoryLimit", "successfulHistoryLimit", "Successful Jobs History Limit"},
		{"failedJobsHistoryLimit", "failedHistoryLimit", "Failed Jobs History Limit"},
	} {
		if value, found := summaryBoolAt(spec, field.key); found {
			result = appendSummaryBool(result, "job", field.id, field.label, value, true)
		} else if number, found := summaryIntegerAt(spec, field.key); found {
			text := strconv.FormatInt(number, 10)
			if field.key == "startingDeadlineSeconds" {
				text = summaryDuration(number)
			}
			result = appendSummaryText(result, "job", field.id, field.label, text)
		}
	}
	active := summarySliceAt(object, "status", "active")
	if len(active) > 0 {
		result = appendSummaryInteger(result, "job", "active", "Active", int64(len(active)), true)
		for index, raw := range active {
			if index >= maximumSummaryStorageValues {
				break
			}
			ref, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			name, found := summaryStringAt(ref, "name")
			if found {
				result = appendSummaryText(result, "job", fmt.Sprintf("activeJob:%d", index), "Active Job", name)
			}
		}
	}
	result = appendSummaryTimestamp(result, "job", "lastScheduleTime", "Last Schedule Time", summaryTimeAt(object, "status", "lastScheduleTime"), SummaryTimestampOccurredAt)
	result = appendSummaryTimestamp(result, "job", "lastSuccessfulTime", "Last Successful Time", summaryTimeAt(object, "status", "lastSuccessfulTime"), SummaryTimestampOccurredAt)
	if template, ok := summaryMapAt(spec, "jobTemplate"); ok {
		if templateSpec, ok := summaryMapAt(template, "spec"); ok {
			result = appendJobFields(result, templateSpec, templateSpec, "template")
			if podTemplate, ok := summaryMapAt(templateSpec, "template"); ok {
				if podSpec, ok := summaryMapAt(podTemplate, "spec"); ok {
					result = podSpecSummary(result, podSpec, nil, "template")
					result = append(result, podTemplateContainerSummary(podSpec)...)
				}
			}
		}
	}
	return result
}

func podTemplateContainerSummary(spec map[string]any) []SummaryField {
	fields := podContainerSummary(map[string]any{"spec": spec})
	for index := range fields {
		fields[index].ID = "template:" + fields[index].ID
		fields[index].Label = "Template " + fields[index].Label
	}
	return fields
}

func serviceDetailSummary(object map[string]any) []SummaryField {
	spec, _ := summaryMapAt(object, "spec")
	if spec == nil {
		return nil
	}
	result := make([]SummaryField, 0, 24)
	// ClusterIPs and IP families are kept as individual rows so dual-stack
	// services remain copyable and do not lose ordering information.
	clusterIPs := summaryStringSliceAt(spec, "clusterIPs")
	if primary, found := summaryStringAt(spec, "clusterIP"); found {
		filtered := make([]string, 0, len(clusterIPs))
		for _, value := range clusterIPs {
			if value != primary {
				filtered = append(filtered, value)
			}
		}
		clusterIPs = filtered
	}
	result = appendStringSliceFields(result, "network", "clusterIP", "Cluster IP", clusterIPs, maximumSummaryServiceValues)
	result = appendStringSliceFields(result, "network", "ipFamily", "IP Family", summaryStringSliceAt(spec, "ipFamilies"), maximumSummaryServiceValues)
	for _, field := range []struct {
		key, id, label string
	}{
		{"ipFamilyPolicy", "ipFamilyPolicy", "IP Family Policy"},
		{"sessionAffinity", "sessionAffinity", "Session Affinity"},
		{"externalTrafficPolicy", "externalTrafficPolicy", "External Traffic Policy"},
		{"internalTrafficPolicy", "internalTrafficPolicy", "Internal Traffic Policy"},
		{"loadBalancerClass", "loadBalancerClass", "Load Balancer Class"},
		{"trafficDistribution", "trafficDistribution", "Traffic Distribution"},
	} {
		if text, found := summaryStringAt(spec, field.key); found {
			result = appendSummaryText(result, "service", field.id, field.label, text)
		}
	}
	for _, field := range []struct {
		key, id, label string
	}{
		{"publishNotReadyAddresses", "publishNotReadyAddresses", "Publish Not-Ready Addresses"},
		{"allocateLoadBalancerNodePorts", "allocateLoadBalancerNodePorts", "Allocate Load Balancer Node Ports"},
	} {
		if value, found := summaryBoolAt(spec, field.key); found {
			result = appendSummaryBool(result, "service", field.id, field.label, value, true)
		}
	}
	if timeout, found := summaryIntegerAt(spec, "sessionAffinityConfig", "clientIP", "timeoutSeconds"); found {
		result = appendSummaryText(result, "service", "sessionAffinityTimeout", "Session Affinity Timeout", summaryDuration(timeout))
	}
	if health, found := summaryIntegerAt(spec, "healthCheckNodePort"); found && health > 0 {
		result = appendSummaryInteger(result, "service", "healthCheckNodePort", "Health Check Node Port", health, true)
	}
	result = appendStringSliceFields(result, "network", "loadBalancerSourceRange", "Load Balancer Source Range", summaryStringSliceAt(spec, "loadBalancerSourceRanges"), maximumSummaryServiceValues)
	result = appendServicePortDetailSummary(result, spec)
	return result
}

func appendServicePortDetailSummary(fields []SummaryField, spec map[string]any) []SummaryField {
	ports := summarySliceAt(spec, "ports")
	if len(ports) == 0 {
		return fields
	}
	displayed := 0
	omitted := 0
	for _, raw := range ports {
		if displayed >= maximumSummaryPorts {
			omitted++
			continue
		}
		port, ok := raw.(map[string]any)
		if !ok {
			omitted++
			continue
		}
		name, _ := summaryStringAt(port, "name")
		if name == "" {
			name = fmt.Sprintf("Port %d", displayed+1)
		}
		parts := []string{}
		if nodePort, found := summaryIntegerAt(port, "nodePort"); found && nodePort > 0 {
			parts = append(parts, "nodePort="+strconv.FormatInt(nodePort, 10))
		}
		if appProtocol, found := summaryStringAt(port, "appProtocol"); found {
			parts = append(parts, "appProtocol="+appProtocol)
		}
		if protocol, found := summaryStringAt(port, "protocol"); found && strings.ToUpper(protocol) != "TCP" {
			parts = append(parts, "protocol="+strings.ToUpper(protocol))
		}
		if len(parts) == 0 {
			continue
		}
		fields = appendSummaryText(fields, "service", fmt.Sprintf("portDetail:%d", displayed), name, strings.Join(parts, " "))
		displayed++
	}
	if omitted > 0 {
		fields = append(fields, omittedSummaryField("service", "portDetailsOmitted", "Port Details", omitted))
	}
	return fields
}

func ingressSummary(object map[string]any) []SummaryField {
	spec, _ := summaryMapAt(object, "spec")
	if spec == nil {
		return nil
	}
	result := make([]SummaryField, 0, 32)
	class, found := summaryStringAt(spec, "ingressClassName")
	if !found {
		class, found = summaryStringAt(object, "metadata", "annotations", "kubernetes.io/ingress.class")
	}
	if found {
		result = appendSummaryText(result, "routing", "ingressClass", "Ingress Class", class)
	}
	if backend, ok := summaryMapAt(spec, "defaultBackend"); ok {
		if text := formatIngressBackend(backend); text != "" {
			result = appendSummaryText(result, "routing", "defaultBackend", "Default Backend", text)
		}
	} else if backend, ok := summaryMapAt(spec, "backend"); ok {
		// networking.k8s.io/v1beta1 and extensions/v1beta1 called this field
		// backend. Keep the fallback narrowly scoped to the same shape.
		if text := formatIngressBackend(backend); text != "" {
			result = appendSummaryText(result, "routing", "defaultBackend", "Default Backend", text)
		}
	}
	result = appendIngressLoadBalancerFields(result, object)
	result = appendIngressRuleFields(result, spec)
	result = appendIngressTLSFields(result, spec)
	result = appendIngressAnnotationFields(result, object)
	return result
}

func appendIngressLoadBalancerFields(fields []SummaryField, object map[string]any) []SummaryField {
	values := summarySliceAt(object, "status", "loadBalancer", "ingress")
	if len(values) == 0 {
		return fields
	}
	displayed := 0
	omitted := 0
	for _, raw := range values {
		if displayed >= maximumSummaryAddresses {
			omitted++
			continue
		}
		entry, ok := raw.(map[string]any)
		if !ok {
			omitted++
			continue
		}
		address, _ := summaryStringAt(entry, "ip")
		if address == "" {
			address, _ = summaryStringAt(entry, "hostname")
		}
		if address == "" {
			omitted++
			continue
		}
		if ports := formatIngressPorts(summarySliceAt(entry, "ports")); ports != "" {
			address += " (" + ports + ")"
		}
		fields = appendSummaryText(fields, "routing", fmt.Sprintf("loadBalancer:%d", displayed), "Load Balancer Address", address)
		displayed++
	}
	if omitted > 0 {
		fields = append(fields, omittedSummaryField("routing", "loadBalancersOmitted", "Load Balancer Addresses", omitted))
	}
	return fields
}

func formatIngressPorts(values []any) string {
	parts := make([]string, 0, len(values))
	for _, raw := range values {
		port, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		name, _ := summaryStringAt(port, "name")
		protocol, _ := summaryStringAt(port, "protocol")
		number, numberFound := summaryIntegerAt(port, "port")
		text := name
		if numberFound {
			text = strconv.FormatInt(number, 10)
		}
		if protocol != "" {
			text += "/" + strings.ToUpper(protocol)
		}
		if text != "" {
			parts = append(parts, text)
		}
	}
	slices.Sort(parts)
	return boundedSummaryText(strings.Join(parts, ", "))
}

func appendIngressRuleFields(fields []SummaryField, spec map[string]any) []SummaryField {
	rules := summarySliceAt(spec, "rules")
	if len(rules) == 0 {
		return fields
	}
	displayed := 0
	omitted := 0
	for _, raw := range rules {
		rule, ok := raw.(map[string]any)
		if !ok {
			omitted++
			continue
		}
		host, _ := summaryStringAt(rule, "host")
		if host == "" {
			host = "*"
		}
		http, _ := summaryMapAt(rule, "http")
		paths := summarySliceAt(http, "paths")
		if len(paths) == 0 {
			if displayed >= maximumSummaryRoutes {
				omitted++
				continue
			}
			fields = appendSummaryText(fields, "routing", fmt.Sprintf("route:%d", displayed), "Route", host+" → (no HTTP paths)")
			displayed++
			continue
		}
		for _, rawPath := range paths {
			if displayed >= maximumSummaryRoutes {
				omitted++
				continue
			}
			path, ok := rawPath.(map[string]any)
			if !ok {
				omitted++
				continue
			}
			pathText, _ := summaryStringAt(path, "path")
			if pathText == "" {
				pathText = "/"
			}
			pathType, _ := summaryStringAt(path, "pathType")
			backend, _ := summaryMapAt(path, "backend")
			text := host + " " + pathText
			if pathType != "" {
				text += " (" + pathType + ")"
			}
			if backendText := formatIngressBackend(backend); backendText != "" {
				text += " → " + backendText
			}
			fields = appendSummaryText(fields, "routing", fmt.Sprintf("route:%d", displayed), "Route", text)
			displayed++
		}
	}
	if omitted > 0 {
		fields = append(fields, omittedSummaryField("routing", "routesOmitted", "Routes", omitted))
	}
	return fields
}

func formatIngressBackend(backend map[string]any) string {
	if backend == nil {
		return ""
	}
	if service, ok := summaryMapAt(backend, "service"); ok {
		name, _ := summaryStringAt(service, "name")
		port := ""
		if number, found := summaryIntegerAt(service, "port", "number"); found {
			port = strconv.FormatInt(number, 10)
		} else if text, found := summaryStringAt(service, "port", "name"); found {
			port = text
		}
		if name != "" {
			if port != "" {
				return name + ":" + port
			}
			return name
		}
	}
	if resource, ok := summaryMapAt(backend, "resource"); ok {
		name, _ := summaryStringAt(resource, "name")
		kind, _ := summaryStringAt(resource, "kind")
		apiGroup, _ := summaryStringAt(resource, "apiGroup")
		parts := []string{}
		if apiGroup != "" {
			parts = append(parts, apiGroup)
		}
		if kind != "" {
			parts = append(parts, kind)
		}
		if name != "" {
			parts = append(parts, name)
		}
		return strings.Join(parts, "/")
	}
	if name, found := summaryStringAt(backend, "serviceName"); found {
		port := ""
		if text, ok := summaryStringAt(backend, "servicePort"); ok {
			port = text
		} else if number, ok := summaryIntegerAt(backend, "servicePort"); ok {
			port = strconv.FormatInt(number, 10)
		}
		if port != "" {
			return name + ":" + port
		}
		return name
	}
	if name, found := summaryStringAt(backend, "name"); found {
		if number, ok := summaryIntegerAt(backend, "port"); ok {
			return name + ":" + strconv.FormatInt(number, 10)
		}
		return name
	}
	return ""
}

func appendIngressTLSFields(fields []SummaryField, spec map[string]any) []SummaryField {
	values := summarySliceAt(spec, "tls")
	if len(values) == 0 {
		return fields
	}
	displayed := 0
	omitted := 0
	for _, raw := range values {
		if displayed >= maximumSummaryTLS {
			omitted++
			continue
		}
		item, ok := raw.(map[string]any)
		if !ok {
			omitted++
			continue
		}
		hosts := summaryStringSliceAt(item, "hosts")
		secret, _ := summaryStringAt(item, "secretName")
		text := strings.Join(hosts, ", ")
		if text == "" {
			text = "All hosts"
		}
		if secret != "" {
			text += " → " + secret
		}
		fields = appendSummaryText(fields, "routing", fmt.Sprintf("tls:%d", displayed), "TLS", text)
		displayed++
	}
	if omitted > 0 {
		fields = append(fields, omittedSummaryField("routing", "tlsOmitted", "TLS Entries", omitted))
	}
	return fields
}

func appendIngressAnnotationFields(fields []SummaryField, object map[string]any) []SummaryField {
	annotations, ok := summaryMapAt(object, "metadata", "annotations")
	if !ok {
		return fields
	}
	// These keys affect routing behavior and are safe to surface as a compact
	// allow-list. Authentication/credential-bearing annotations stay in the
	// normal metadata section and are never copied into a special projection.
	allowed := map[string]struct{}{
		"nginx.ingress.kubernetes.io/rewrite-target":       {},
		"nginx.ingress.kubernetes.io/use-regex":            {},
		"nginx.ingress.kubernetes.io/ssl-redirect":         {},
		"nginx.ingress.kubernetes.io/backend-protocol":     {},
		"nginx.ingress.kubernetes.io/proxy-body-size":      {},
		"nginx.ingress.kubernetes.io/proxy-read-timeout":   {},
		"nginx.ingress.kubernetes.io/proxy-send-timeout":   {},
		"traefik.ingress.kubernetes.io/router.entrypoints": {},
		"traefik.ingress.kubernetes.io/router.tls":         {},
		"alb.ingress.kubernetes.io/scheme":                 {},
		"alb.ingress.kubernetes.io/target-type":            {},
	}
	keys := summaryMapKeys(annotations)
	displayed := 0
	omitted := 0
	for _, key := range keys {
		if _, found := allowed[key]; !found {
			continue
		}
		if displayed >= maximumSummaryAnnotationKeys {
			omitted++
			continue
		}
		value, ok := summaryScalarText(annotations[key])
		if !ok {
			continue
		}
		fields = appendSummaryText(fields, "routing", fmt.Sprintf("annotation:%d", displayed), key, value)
		displayed++
	}
	if omitted > 0 {
		fields = append(fields, omittedSummaryField("routing", "annotationsOmitted", "Routing Annotations", omitted))
	}
	return fields
}

func persistentVolumeClaimSummary(object map[string]any) []SummaryField {
	spec, _ := summaryMapAt(object, "spec")
	status, _ := summaryMapAt(object, "status")
	if spec == nil && status == nil {
		return nil
	}
	result := make([]SummaryField, 0, 24)
	for _, source := range []struct {
		mapping map[string]any
		key     string
		label   string
	}{
		{mapping: spec, key: "storageClassName", label: "Storage Class"},
		{mapping: spec, key: "volumeName", label: "Bound Volume"},
		{mapping: spec, key: "volumeMode", label: "Volume Mode"},
	} {
		if text, found := summaryStringAt(source.mapping, source.key); found {
			result = appendSummaryText(result, "storage", strings.ToLower(strings.ReplaceAll(source.label, " ", "")), source.label, text)
		}
	}
	accessModes := summaryStringSliceAt(status, "accessModes")
	if len(accessModes) == 0 {
		accessModes = summaryStringSliceAt(spec, "accessModes")
	}
	result = appendStringSliceFields(result, "storage", "accessMode", "Access Mode", accessModes, maximumSummaryStorageValues)
	result = appendQuantityMapFields(result, status, "capacity", "Capacity", "capacity", maximumSummaryStorageValues)
	if resources, ok := summaryMapAt(spec, "resources"); ok {
		result = appendQuantityMapFields(result, resources, "request", "Requested", "requests", maximumSummaryStorageValues)
	}
	if allocated, ok := summaryMapAt(status, "allocatedResources"); ok {
		result = appendQuantityMapFields(result, map[string]any{"allocated": allocated}, "allocated", "Allocated", "allocated", maximumSummaryStorageValues)
	}
	if dataSource, ok := summaryMapAt(spec, "dataSource"); ok {
		result = appendDataSourceField(result, "Data Source", "dataSource", dataSource)
	}
	if dataSource, ok := summaryMapAt(spec, "dataSourceRef"); ok {
		result = appendDataSourceField(result, "Data Source Reference", "dataSourceRef", dataSource)
	}
	if selector, ok := summaryMapAt(spec, "selector"); ok {
		if text := formatSelectorValue(selector); text != "" {
			result = appendSummaryText(result, "storage", "selector", "Selector", text)
		}
	}
	result = appendStatusMapFields(result, status, "allocatedResourceStatuses", "Allocated Resource Status", maximumSummaryStorageValues)
	return result
}

func persistentVolumeSummary(object map[string]any) []SummaryField {
	spec, _ := summaryMapAt(object, "spec")
	status, _ := summaryMapAt(object, "status")
	if spec == nil && status == nil {
		return nil
	}
	result := make([]SummaryField, 0, 28)
	for _, field := range []struct {
		mapping        map[string]any
		key, id, label string
	}{
		{spec, "storageClassName", "storageClass", "Storage Class"},
		{spec, "persistentVolumeReclaimPolicy", "reclaimPolicy", "Reclaim Policy"},
		{spec, "volumeMode", "volumeMode", "Volume Mode"},
		{status, "reason", "reason", "Reason"},
		{status, "message", "message", "Message"},
	} {
		if text, found := summaryStringAt(field.mapping, field.key); found {
			result = appendSummaryText(result, "storage", field.id, field.label, text)
		}
	}
	result = appendQuantityMapFields(result, spec, "capacity", "Capacity", "capacity", maximumSummaryStorageValues)
	result = appendStringSliceFields(result, "storage", "accessMode", "Access Mode", summaryStringSliceAt(spec, "accessModes"), maximumSummaryStorageValues)
	result = appendStringSliceFields(result, "storage", "mountOption", "Mount Option", summaryStringSliceAt(spec, "mountOptions"), maximumSummaryStorageValues)
	if claimRef, ok := summaryMapAt(spec, "claimRef"); ok {
		parts := []string{}
		for _, key := range []string{"namespace", "name", "uid"} {
			if text, found := summaryStringAt(claimRef, key); found {
				parts = append(parts, key+"="+text)
			}
		}
		if len(parts) > 0 {
			result = appendSummaryText(result, "storage", "claimRef", "Claim", strings.Join(parts, " "))
		}
	}
	if nodeAffinity, ok := summaryMapAt(spec, "nodeAffinity"); ok {
		if text := formatNodeAffinity(nodeAffinity); text != "" {
			result = appendSummaryText(result, "scheduling", "nodeAffinity", "Node Affinity", text)
		}
	}
	if source := formatPersistentVolumeSource(spec); source != "" {
		result = appendSummaryText(result, "storage", "source", "Volume Source", source)
	}
	return result
}

func appendQuantityMapFields(
	fields []SummaryField,
	object map[string]any,
	idPrefix, label, path string,
	limit int,
) []SummaryField {
	values, ok := summaryMapAt(object, path)
	if !ok {
		return fields
	}
	keys := summaryMapKeys(values)
	originalCount := len(keys)
	if len(keys) > limit {
		keys = keys[:limit]
	}
	for index, key := range keys {
		quantity, valid := summaryQuantityText(values[key])
		if !valid {
			continue
		}
		fields = appendSummaryText(fields, "resources", fmt.Sprintf("%s:%d", idPrefix, index), label+" "+summaryResourceLabel(key), quantity)
	}
	if omitted := originalCount - len(keys); omitted > 0 {
		fields = append(fields, omittedSummaryField("resources", idPrefix+"Omitted", label, omitted))
	}
	return fields
}

func appendDataSourceField(fields []SummaryField, label, id string, value map[string]any) []SummaryField {
	parts := []string{}
	for _, key := range []string{"kind", "name", "apiGroup"} {
		if text, found := summaryStringAt(value, key); found {
			parts = append(parts, key+"="+text)
		}
	}
	if len(parts) == 0 {
		return fields
	}
	return appendSummaryText(fields, "storage", id, label, strings.Join(parts, " "))
}

func appendStatusMapFields(
	fields []SummaryField,
	object map[string]any,
	path, label string,
	limit int,
) []SummaryField {
	values, ok := summaryMapAt(object, path)
	if !ok {
		return fields
	}
	keys := summaryMapKeys(values)
	if len(keys) > limit {
		keys = keys[:limit]
	}
	for index, key := range keys {
		if text, ok := summaryScalarText(values[key]); ok {
			fields = appendSummaryText(fields, "storage", fmt.Sprintf("%s:%d", path, index), label+" "+key, text)
		}
	}
	return fields
}

func formatPersistentVolumeSource(spec map[string]any) string {
	if spec == nil {
		return ""
	}
	for _, source := range []struct {
		key, title string
	}{
		{"csi", "CSI"}, {"hostPath", "Host Path"}, {"nfs", "NFS"}, {"local", "Local"},
		{"awsElasticBlockStore", "AWS EBS"}, {"gcePersistentDisk", "GCE PD"}, {"azureDisk", "Azure Disk"},
		{"azureFile", "Azure File"}, {"iscsi", "iSCSI"}, {"fc", "Fibre Channel"}, {"rbd", "RBD"},
		{"cephfs", "CephFS"}, {"cinder", "Cinder"}, {"vsphereVolume", "vSphere"}, {"flexVolume", "FlexVolume"},
		{"photonPersistentDisk", "Photon"}, {"portworxVolume", "Portworx"}, {"quobyte", "Quobyte"},
		{"scaleIO", "ScaleIO"}, {"storageos", "StorageOS"},
	} {
		mapping, found := summaryMapAt(spec, source.key)
		if !found {
			continue
		}
		parts := []string{source.title}
		for _, key := range []string{"driver", "volumeHandle", "fsType", "server", "path", "volumeID", "diskName", "diskURI", "pdName", "volumeName", "iqn", "targetPortal"} {
			if text, found := summaryStringAt(mapping, key); found {
				parts = append(parts, key+"="+text)
			}
		}
		return boundedSummaryText(strings.Join(parts, " "))
	}
	return ""
}

func formatNodeAffinity(value map[string]any) string {
	parts := []string{}
	if required, ok := summaryMapAt(value, "required"); ok {
		if terms := summarySliceAt(required, "nodeSelectorTerms"); len(terms) > 0 {
			parts = append(parts, fmt.Sprintf("required=%d terms", len(terms)))
		}
	}
	if preferred := summarySliceAt(value, "preferred"); len(preferred) > 0 {
		parts = append(parts, fmt.Sprintf("preferred=%d terms", len(preferred)))
	}
	return boundedSummaryText(strings.Join(parts, " "))
}

func storageClassSummary(object map[string]any) []SummaryField {
	result := make([]SummaryField, 0, 16)
	for _, field := range []struct {
		key, id, label string
	}{
		{"provisioner", "provisioner", "Provisioner"},
		{"reclaimPolicy", "reclaimPolicy", "Reclaim Policy"},
		{"volumeBindingMode", "bindingMode", "Binding Mode"},
	} {
		if text, found := summaryStringAt(object, field.key); found {
			result = appendSummaryText(result, "storage", field.id, field.label, text)
		}
	}
	if value, found := summaryBoolAt(object, "allowVolumeExpansion"); found {
		result = appendSummaryBool(result, "storage", "allowExpansion", "Allow Expansion", value, true)
	}
	result = appendStringSliceFields(result, "storage", "mountOption", "Mount Option", summaryStringSliceAt(object, "mountOptions"), maximumSummaryStorageValues)
	if parameters, ok := summaryMapAt(object, "parameters"); ok {
		keys := summaryMapKeys(parameters)
		if len(keys) > maximumSummaryStorageValues {
			keys = keys[:maximumSummaryStorageValues]
		}
		for index, key := range keys {
			// Parameter values can contain credentials. Show names in Summary;
			// the complete map remains available in YAML.
			result = appendSummaryText(result, "storage", fmt.Sprintf("parameter:%d", index), "Parameter", key)
		}
	}
	return result
}

func networkPolicySummary(object map[string]any) []SummaryField {
	spec, _ := summaryMapAt(object, "spec")
	if spec == nil {
		return nil
	}
	result := make([]SummaryField, 0, 24)
	if selector, ok := summaryMapAt(spec, "podSelector"); ok {
		if text := formatSelectorValue(selector); text != "" {
			result = appendSummaryText(result, "policy", "podSelector", "Pod Selector", text)
		} else {
			result = appendSummaryText(result, "policy", "podSelector", "Pod Selector", "All Pods")
		}
	}
	result = appendStringSliceFields(result, "policy", "policyType", "Policy Type", summaryStringSliceAt(spec, "policyTypes"), maximumSummaryStorageValues)
	result = appendNetworkPolicyRuleFields(result, summarySliceAt(spec, "ingress"), "Ingress")
	result = appendNetworkPolicyRuleFields(result, summarySliceAt(spec, "egress"), "Egress")
	return result
}

func appendNetworkPolicyRuleFields(fields []SummaryField, rules []any, direction string) []SummaryField {
	if len(rules) == 0 {
		return fields
	}
	displayed := 0
	omitted := 0
	for _, raw := range rules {
		if displayed >= maximumSummaryPolicyRules {
			omitted++
			continue
		}
		rule, ok := raw.(map[string]any)
		if !ok {
			omitted++
			continue
		}
		parts := make([]string, 0, 3)
		if direction == "Ingress" {
			parts = append(parts, "from="+formatPolicyPeers(summarySliceAt(rule, "from")))
		} else {
			parts = append(parts, "to="+formatPolicyPeers(summarySliceAt(rule, "to")))
		}
		if ports := formatNetworkPolicyPorts(summarySliceAt(rule, "ports")); ports != "" {
			parts = append(parts, "ports="+ports)
		} else {
			parts = append(parts, "ports=all")
		}
		text := strings.Join(parts, " ")
		fields = appendSummaryText(fields, "policy", fmt.Sprintf("%sRule:%d", strings.ToLower(direction), displayed), direction+" Rule", text)
		displayed++
	}
	if omitted > 0 {
		fields = append(fields, omittedSummaryField("policy", strings.ToLower(direction)+"RulesOmitted", direction+" Rules", omitted))
	}
	return fields
}

func formatPolicyPeers(peers []any) string {
	if len(peers) == 0 {
		return "all"
	}
	parts := make([]string, 0, min(len(peers), maximumSummaryPolicyParts))
	for _, raw := range peers {
		peer, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		peerParts := []string{}
		if selector, ok := summaryMapAt(peer, "podSelector"); ok {
			text := formatSelectorValue(selector)
			if text == "" {
				text = "all pods"
			}
			peerParts = append(peerParts, "pods="+text)
		}
		if selector, ok := summaryMapAt(peer, "namespaceSelector"); ok {
			text := formatSelectorValue(selector)
			if text == "" {
				text = "all namespaces"
			}
			peerParts = append(peerParts, "namespaces="+text)
		}
		if block, ok := summaryMapAt(peer, "ipBlock"); ok {
			if cidr, found := summaryStringAt(block, "cidr"); found {
				text := "cidr=" + cidr
				if except := summaryStringSliceAt(block, "except"); len(except) > 0 {
					text += " except=" + strings.Join(except, ",")
				}
				peerParts = append(peerParts, text)
			}
		}
		if len(peerParts) == 0 {
			peerParts = append(peerParts, "all")
		}
		parts = append(parts, strings.Join(peerParts, ";"))
		if len(parts) == maximumSummaryPolicyParts {
			break
		}
	}
	if len(parts) == 0 {
		return "all"
	}
	return boundedSummaryText(strings.Join(parts, " | "))
}

func formatNetworkPolicyPorts(ports []any) string {
	if len(ports) == 0 {
		return ""
	}
	parts := make([]string, 0, min(len(ports), maximumSummaryPolicyParts))
	for _, raw := range ports {
		port, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		protocol, _ := summaryStringAt(port, "protocol")
		if protocol == "" {
			protocol = "TCP"
		}
		value := ""
		if text, found := summaryStringAt(port, "port"); found {
			value = text
		} else if number, found := summaryIntegerAt(port, "port"); found {
			value = strconv.FormatInt(number, 10)
		}
		if value == "" {
			value = "all"
		}
		if end, found := summaryIntegerAt(port, "endPort"); found {
			value += "-" + strconv.FormatInt(end, 10)
		}
		parts = append(parts, strings.ToUpper(protocol)+":"+value)
		if len(parts) == maximumSummaryPolicyParts {
			break
		}
	}
	return boundedSummaryText(strings.Join(parts, ", "))
}

func rbacSummary(object map[string]any, kind string) []SummaryField {
	result := make([]SummaryField, 0, 24)
	switch kind {
	case "Role", "ClusterRole":
		result = appendRBACRuleFields(result, summarySliceAt(object, "rules"))
		if aggregation, ok := summaryMapAt(object, "aggregationRule"); ok {
			if selectors := summarySliceAt(aggregation, "clusterRoleSelectors"); len(selectors) > 0 {
				for index, raw := range selectors {
					if index >= maximumSummaryPolicyRules {
						break
					}
					selector, ok := raw.(map[string]any)
					if !ok {
						continue
					}
					if text := formatSelectorValue(selector); text != "" {
						result = appendSummaryText(result, "policy", fmt.Sprintf("aggregationSelector:%d", index), "Aggregation Selector", text)
					}
				}
			}
		}
	case "RoleBinding", "ClusterRoleBinding":
		if roleRef, ok := summaryMapAt(object, "roleRef"); ok {
			parts := []string{}
			for _, key := range []string{"kind", "name", "apiGroup"} {
				if text, found := summaryStringAt(roleRef, key); found {
					parts = append(parts, key+"="+text)
				}
			}
			if len(parts) > 0 {
				result = appendSummaryText(result, "policy", "roleRef", "Role Reference", strings.Join(parts, " "))
			}
		}
		result = appendRBACSubjectFields(result, summarySliceAt(object, "subjects"))
	}
	return result
}

func appendRBACRuleFields(fields []SummaryField, rules []any) []SummaryField {
	if len(rules) == 0 {
		return fields
	}
	displayed := 0
	omitted := 0
	for _, raw := range rules {
		if displayed >= maximumSummaryRBACRules {
			omitted++
			continue
		}
		rule, ok := raw.(map[string]any)
		if !ok {
			omitted++
			continue
		}
		parts := []string{}
		for _, key := range []string{"apiGroups", "resources", "resourceNames", "verbs", "nonResourceURLs"} {
			values := summaryStringSliceAt(rule, key)
			if len(values) > 0 {
				parts = append(parts, key+"="+strings.Join(values, ","))
			}
		}
		if len(parts) == 0 {
			omitted++
			continue
		}
		fields = appendSummaryText(fields, "policy", fmt.Sprintf("rule:%d", displayed), "Rule", strings.Join(parts, " "))
		displayed++
	}
	if omitted > 0 {
		fields = append(fields, omittedSummaryField("policy", "rulesOmitted", "Rules", omitted))
	}
	return fields
}

func appendRBACSubjectFields(fields []SummaryField, subjects []any) []SummaryField {
	if len(subjects) == 0 {
		return fields
	}
	displayed := 0
	omitted := 0
	for _, raw := range subjects {
		if displayed >= maximumSummarySubjects {
			omitted++
			continue
		}
		subject, ok := raw.(map[string]any)
		if !ok {
			omitted++
			continue
		}
		kind, _ := summaryStringAt(subject, "kind")
		name, _ := summaryStringAt(subject, "name")
		namespace, _ := summaryStringAt(subject, "namespace")
		if kind == "" && name == "" {
			omitted++
			continue
		}
		parts := make([]string, 0, 3)
		for _, value := range []string{kind, namespace, name} {
			if value != "" {
				parts = append(parts, value)
			}
		}
		text := strings.Join(parts, "/")
		fields = appendSummaryText(fields, "policy", fmt.Sprintf("subject:%d", displayed), "Subject", text)
		displayed++
	}
	if omitted > 0 {
		fields = append(fields, omittedSummaryField("policy", "subjectsOmitted", "Subjects", omitted))
	}
	return fields
}

func serviceAccountSummary(object map[string]any) []SummaryField {
	result := make([]SummaryField, 0, 12)
	if value, found := summaryBoolAt(object, "automountServiceAccountToken"); found {
		result = appendSummaryBool(result, "security", "automountServiceAccountToken", "Automount Service Account Token", value, true)
	}
	result = appendReferenceFields(result, summarySliceAt(object, "secrets"), "secret", "Token Secret", maximumSummaryStorageValues)
	result = appendReferenceFields(result, summarySliceAt(object, "imagePullSecrets"), "imagePullSecret", "Image Pull Secret", maximumSummaryStorageValues)
	return result
}

func appendReferenceFields(fields []SummaryField, refs []any, idPrefix, label string, limit int) []SummaryField {
	return appendReferenceFieldsWithPrefix(fields, refs, idPrefix, label, func(value string) string { return value }, "security", limit)
}

func appendReferenceFieldsWithPrefix(
	fields []SummaryField,
	refs []any,
	idPrefix, label string,
	id func(string) string,
	section string,
	limit int,
) []SummaryField {
	if len(refs) == 0 {
		return fields
	}
	displayed := 0
	omitted := 0
	for _, raw := range refs {
		if displayed >= limit {
			omitted++
			continue
		}
		ref, ok := raw.(map[string]any)
		if !ok {
			omitted++
			continue
		}
		name, found := summaryStringAt(ref, "name")
		if !found {
			omitted++
			continue
		}
		fields = appendSummaryText(fields, section, id(fmt.Sprintf("%s:%d", idPrefix, displayed)), label, name)
		displayed++
	}
	if omitted > 0 {
		fields = append(fields, omittedSummaryField(section, id(idPrefix+"sOmitted"), label+"s", omitted))
	}
	return fields
}

func appendContainerQuantityMapFields(
	fields []SummaryField,
	values map[string]any,
	id func(string) string,
	label func(string) string,
	name string,
	limit int,
) ([]SummaryField, int) {
	remaining := limit
	omitted := 0
	for _, resourceName := range summaryMapKeys(values) {
		if remaining == 0 {
			if _, valid := summaryQuantityText(values[resourceName]); valid {
				omitted++
			}
			break
		}
		quantity, ok := summaryQuantityText(values[resourceName])
		if !ok {
			continue
		}
		fields = appendSummaryText(fields, "resources", id("overhead:"+resourceName), label(name+" "+summaryResourceLabel(resourceName)), quantity)
		remaining--
	}
	return fields, omitted
}

func configMapSummary(object map[string]any) []SummaryField {
	result := make([]SummaryField, 0, 16)
	if value, found := summaryBoolAt(object, "immutable"); found {
		result = appendSummaryBool(result, "data", "immutable", "Immutable", value, true)
	}
	result = appendDataKeySummary(result, object, "data", "Data Key")
	result = appendDataKeySummary(result, object, "binaryData", "Binary Data Key")
	return result
}

func secretSummary(object map[string]any) []SummaryField {
	result := make([]SummaryField, 0, 16)
	if value, found := summaryBoolAt(object, "immutable"); found {
		result = appendSummaryBool(result, "secret", "immutable", "Immutable", value, true)
	}
	result = appendDataKeySummary(result, object, "data", "Data Key")
	result = appendDataKeySummary(result, object, "stringData", "String Data Key")
	return result
}

func appendDataKeySummary(fields []SummaryField, object map[string]any, key, label string) []SummaryField {
	values, ok := summaryMapAt(object, key)
	if !ok {
		return fields
	}
	keys := summaryMapKeys(values)
	originalCount := len(keys)
	if len(keys) > maximumSummaryDataKeys {
		keys = keys[:maximumSummaryDataKeys]
	}
	for index, name := range keys {
		// Only key identity and presence are exposed. Values can be sensitive in
		// both ConfigMaps and Secrets; Data/YAML is the explicit opt-in surface.
		fields = appendSummaryText(fields, "data", fmt.Sprintf("%s:%d", key, index), label, name)
	}
	if omitted := originalCount - len(keys); omitted > 0 {
		fields = append(fields, omittedSummaryField("data", key+"Omitted", label+"s", omitted))
	}
	return fields
}

func eventSummary(object map[string]any) []SummaryField {
	result := make([]SummaryField, 0, maximumSummaryEventFields)
	for _, field := range []struct {
		path      []string
		id, label string
	}{
		{[]string{"type"}, "type", "Type"},
		{[]string{"reason"}, "reason", "Reason"},
		{[]string{"action"}, "action", "Action"},
		{[]string{"message"}, "message", "Message"},
		{[]string{"involvedObject", "kind"}, "involvedKind", "Involved Kind"},
		{[]string{"involvedObject", "namespace"}, "involvedNamespace", "Involved Namespace"},
		{[]string{"involvedObject", "name"}, "involvedName", "Involved Name"},
		{[]string{"involvedObject", "fieldPath"}, "involvedField", "Involved Field"},
		{[]string{"reportingController"}, "reportingController", "Reporting Controller"},
		{[]string{"reportingInstance"}, "reportingInstance", "Reporting Instance"},
	} {
		result = appendScalarPath(result, object, "event", field.id, field.label, field.path...)
	}
	if source, ok := summaryMapAt(object, "source"); ok {
		if text, found := summaryStringAt(source, "component"); found {
			result = appendSummaryText(result, "event", "sourceComponent", "Source Component", text)
		}
		if text, found := summaryStringAt(source, "host"); found {
			result = appendSummaryText(result, "event", "sourceHost", "Source Host", text)
		}
	}
	count, found := summaryIntegerAt(object, "count")
	if seriesCount, seriesFound := summaryIntegerAt(object, "series", "count"); seriesFound && (!found || seriesCount > count) {
		count, found = seriesCount, true
	}
	if !found {
		count, found = 1, true
	}
	result = appendSummaryInteger(result, "event", "count", "Count", count, found)
	for _, field := range []struct {
		path      []string
		id, label string
		mode      SummaryTimestampPresentation
	}{
		{[]string{"eventTime"}, "eventTime", "Event Time", SummaryTimestampOccurredAt},
		{[]string{"series", "lastObservedTime"}, "lastObservedTime", "Last Observed", SummaryTimestampElapsedSince},
		{[]string{"lastTimestamp"}, "lastTimestamp", "Last Seen", SummaryTimestampElapsedSince},
		{[]string{"firstTimestamp"}, "firstTimestamp", "First Seen", SummaryTimestampElapsedSince},
	} {
		result = appendSummaryTimestamp(result, "event", field.id, field.label, summaryTimeAt(object, field.path...), field.mode)
	}
	return result
}

func podDisruptionBudgetSummary(object map[string]any) []SummaryField {
	spec, _ := summaryMapAt(object, "spec")
	status, _ := summaryMapAt(object, "status")
	result := make([]SummaryField, 0, 16)
	for _, field := range []struct {
		key, id, label string
	}{
		{"minAvailable", "minAvailable", "Min Available"},
		{"maxUnavailable", "maxUnavailable", "Max Unavailable"},
		{"unhealthyPodEvictionPolicy", "unhealthyPodEvictionPolicy", "Unhealthy Pod Eviction Policy"},
	} {
		if value, found := spec[field.key]; found {
			if text, ok := summaryScalarText(value); ok {
				result = appendSummaryText(result, "policy", field.id, field.label, text)
			}
		}
	}
	for _, field := range []struct {
		key, id, label string
	}{
		{"expectedPods", "expectedPods", "Expected Pods"},
		{"currentHealthy", "currentHealthy", "Current Healthy"},
		{"desiredHealthy", "desiredHealthy", "Desired Healthy"},
		{"disruptionsAllowed", "disruptionsAllowed", "Disruptions Allowed"},
	} {
		if value, found := summaryIntegerAt(status, field.key); found {
			result = appendSummaryInteger(result, "policy", field.id, field.label, value, true)
		}
	}
	if selector, ok := summaryMapAt(spec, "selector"); ok {
		if text := formatSelectorValue(selector); text != "" {
			result = appendSummaryText(result, "policy", "selector", "Selector", text)
		}
	}
	return result
}

func resourceQuotaSummary(object map[string]any) []SummaryField {
	result := make([]SummaryField, 0, 24)
	if spec, ok := summaryMapAt(object, "spec"); ok {
		result = appendQuotaMapFields(result, spec, "hard", "Hard")
	}
	if status, ok := summaryMapAt(object, "status"); ok {
		result = appendQuotaMapFields(result, status, "used", "Used")
	}
	return result
}

func appendQuotaMapFields(fields []SummaryField, object map[string]any, key, label string) []SummaryField {
	values, ok := summaryMapAt(object, key)
	if !ok {
		return fields
	}
	keys := summaryMapKeys(values)
	originalCount := len(keys)
	if len(keys) > maximumSummaryQuotaResources {
		keys = keys[:maximumSummaryQuotaResources]
	}
	for index, name := range keys {
		quantity, ok := summaryQuantityText(values[name])
		if !ok {
			continue
		}
		fields = appendSummaryText(fields, "resources", fmt.Sprintf("%s:%d", strings.ToLower(label), index), label+" "+summaryResourceLabel(name), quantity)
	}
	if omitted := originalCount - len(keys); omitted > 0 {
		fields = append(fields, omittedSummaryField("resources", strings.ToLower(label)+"Omitted", label, omitted))
	}
	return fields
}

func limitRangeSummary(object map[string]any) []SummaryField {
	items := summarySliceAt(object, "spec", "limits")
	if len(items) == 0 {
		return nil
	}
	result := make([]SummaryField, 0, 24)
	displayed := 0
	omitted := 0
	for _, raw := range items {
		if displayed >= maximumSummaryLimitItems {
			omitted++
			continue
		}
		item, ok := raw.(map[string]any)
		if !ok {
			omitted++
			continue
		}
		typeName, _ := summaryStringAt(item, "type")
		if typeName == "" {
			typeName = "Limit"
		}
		for _, field := range []struct {
			key, label string
		}{
			{"default", "Default"}, {"defaultRequest", "Default Request"}, {"max", "Max"}, {"min", "Min"}, {"maxLimitRequestRatio", "Max Limit/Request Ratio"},
		} {
			values, ok := summaryMapAt(item, field.key)
			if !ok {
				continue
			}
			for _, name := range summaryMapKeys(values) {
				if value, valid := summaryQuantityText(values[name]); valid {
					if displayed >= maximumSummaryLimitItems {
						omitted++
						continue
					}
					result = appendSummaryText(result, "resources", fmt.Sprintf("limit:%d", displayed), typeName+" "+field.label+" "+summaryResourceLabel(name), value)
					displayed++
				}
			}
		}
	}
	if omitted > 0 {
		result = append(result, omittedSummaryField("resources", "limitsOmitted", "Limit Entries", omitted))
	}
	return result
}
