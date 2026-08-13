// Package view projects Kubernetes objects into compact, typed table rows.
// Raw Kubernetes objects never cross this boundary into the GUI process.
package view

import (
	"cmp"
	"errors"
	"fmt"
	"math"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"

	viewcolumns "github.com/charlie0129/kmgr/backend/internal/view/columns"
	viewfilter "github.com/charlie0129/kmgr/backend/internal/view/filter"
)

const (
	DefaultMissingCell = "—"
	MaxColumnsPerView  = 64
)

// ProjectionSpec contains only presentation choices. Server-side namespace
// and Kubernetes selectors are applied by the caller's resource client.
type ProjectionSpec struct {
	ClusterSessionID string
	Resource         ResourceType
	NamespaceScope   NamespaceScope
	ColumnIDs        []string
	FilterExpression string
	Sort             []SortDescriptor
	CELPrograms      map[string]*viewcolumns.Program
	Metrics          metrics.Snapshot
	Now              time.Time
}

type ResourceType struct {
	Group      string
	Version    string
	Resource   string
	Kind       string
	Namespaced bool
}

type NamespaceScope struct {
	All        bool
	Namespaces []string
}

type SortDescriptor struct {
	ColumnID   string
	Descending bool
	NullsFirst bool
}

type Projector struct {
	spec       ProjectionSpec
	filter     *viewfilter.Filter
	namespaces map[string]struct{}
}

// WithMetrics returns an immutable projection revision for one optional
// metrics snapshot. Base object projection and metric refreshes may therefore
// run independently without sharing mutable activation state.
func (p *Projector) WithMetrics(snapshot metrics.Snapshot) *Projector {
	if p == nil {
		return nil
	}
	copy := *p
	copy.spec = p.spec
	copy.spec.Metrics = snapshot
	return &copy
}

func NewProjector(spec ProjectionSpec) (*Projector, error) {
	if strings.TrimSpace(spec.ClusterSessionID) == "" {
		return nil, errors.New("cluster session ID must not be empty")
	}
	if strings.TrimSpace(spec.Resource.Resource) == "" || strings.TrimSpace(spec.Resource.Version) == "" {
		return nil, errors.New("resource and version must not be empty")
	}
	if len(spec.ColumnIDs) == 0 {
		spec.ColumnIDs = defaultColumns(spec.Resource)
	}
	if len(spec.ColumnIDs) > MaxColumnsPerView {
		return nil, fmt.Errorf("view has %d columns; maximum is %d", len(spec.ColumnIDs), MaxColumnsPerView)
	}
	seenColumns := make(map[string]struct{}, len(spec.ColumnIDs))
	for _, id := range spec.ColumnIDs {
		if strings.TrimSpace(id) == "" {
			return nil, errors.New("column ID must not be empty")
		}
		if _, duplicate := seenColumns[id]; duplicate {
			return nil, fmt.Errorf("duplicate column ID %q", id)
		}
		seenColumns[id] = struct{}{}
	}
	compiledFilter, err := viewfilter.Compile(spec.FilterExpression)
	if err != nil {
		return nil, err
	}
	if spec.Now.IsZero() {
		spec.Now = time.Now()
	}
	namespaces := make(map[string]struct{}, len(spec.NamespaceScope.Namespaces))
	for _, namespace := range spec.NamespaceScope.Namespaces {
		if namespace != "" {
			namespaces[namespace] = struct{}{}
		}
	}
	return &Projector{spec: spec, filter: compiledFilter, namespaces: namespaces}, nil
}

// Project returns all visible rows in deterministic typed sort order. The
// supplied objects are treated as immutable and may safely be a UIDStore
// snapshot.
func (p *Projector) Project(objects []*unstructured.Unstructured) []*kmgrv1.ResourceRow {
	rows := make([]*kmgrv1.ResourceRow, 0, len(objects))
	for _, object := range objects {
		if row, visible := p.ProjectOne(object); visible {
			rows = append(rows, row)
		}
	}
	slices.SortStableFunc(rows, p.compareRows)
	return rows
}

// ProjectOne computes a single compact row and whether it belongs to the
// current namespace/filter projection.
func (p *Projector) ProjectOne(object *unstructured.Unstructured) (*kmgrv1.ResourceRow, bool) {
	if object == nil || object.GetUID() == "" || !p.includesNamespace(object.GetNamespace()) {
		return nil, false
	}

	cells := make([]*kmgrv1.Cell, 0, len(p.spec.ColumnIDs))
	visibleText := make([]string, 0, len(p.spec.ColumnIDs))
	for _, columnID := range p.spec.ColumnIDs {
		cell := p.builtinCell(object, columnID)
		cells = append(cells, cell)
		visibleText = append(visibleText, cell.GetDisplayText())
	}

	fields := make(map[string]string)
	for _, term := range p.filter.Terms() {
		if term.Kind != viewfilter.Field {
			continue
		}
		if value, found := nestedScalar(object.Object, term.Key); found {
			fields[term.Key] = value
		}
	}
	if !p.filter.Match(viewfilter.Candidate{
		Namespace:   object.GetNamespace(),
		Name:        object.GetName(),
		Status:      statusText(object),
		Labels:      object.GetLabels(),
		Fields:      fields,
		VisibleText: visibleText,
	}) {
		return nil, false
	}

	return &kmgrv1.ResourceRow{
		Identity: &kmgrv1.ResourceIdentity{
			ClusterSessionId: p.spec.ClusterSessionID,
			Group:            p.spec.Resource.Group,
			Version:          p.spec.Resource.Version,
			Resource:         p.spec.Resource.Resource,
			Namespace:        object.GetNamespace(),
			Name:             object.GetName(),
			Uid:              string(object.GetUID()),
		},
		Cells: cells,
	}, true
}

func (p *Projector) includesNamespace(namespace string) bool {
	if !p.spec.Resource.Namespaced || p.spec.NamespaceScope.All {
		return true
	}
	if len(p.namespaces) == 0 {
		return namespace == "default"
	}
	_, ok := p.namespaces[namespace]
	return ok
}

func (p *Projector) builtinCell(object *unstructured.Unstructured, columnID string) *kmgrv1.Cell {
	if program := p.spec.CELPrograms[columnID]; program != nil {
		return p.celCell(object, program)
	}
	if resourceName, metricColumn := metricColumnResource(p.spec.Resource, columnID); metricColumn {
		return p.resourceUsageCell(object, columnID, resourceName)
	}
	cell := &kmgrv1.Cell{ColumnId: columnID, Severity: kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL}
	switch columnID {
	case "namespace":
		setStringCell(cell, valueOrMissing(object.GetNamespace()))
	case "name":
		setStringCell(cell, valueOrMissing(object.GetName()))
	case "kind":
		kind := object.GetKind()
		if kind == "" {
			kind = p.spec.Resource.Kind
		}
		setStringCell(cell, valueOrMissing(kind))
	case "status":
		status := statusText(object)
		setStringCell(cell, status)
		cell.Severity = statusSeverity(status)
	case "node":
		value, _, _ := unstructured.NestedString(object.Object, "spec", "nodeName")
		setStringCell(cell, valueOrMissing(value))
	case "ready":
		ready, total := readyContainers(object)
		if total == 0 {
			setStringCell(cell, DefaultMissingCell)
		} else {
			text := fmt.Sprintf("%d/%d", ready, total)
			cell.DisplayText = text
			cell.TypedValue = &kmgrv1.Cell_NumberValue{NumberValue: float64(ready) / float64(total)}
			if ready != total {
				cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_WARNING
			}
		}
	case "restarts":
		restarts := restartCount(object)
		cell.DisplayText = strconv.FormatInt(restarts, 10)
		cell.TypedValue = &kmgrv1.Cell_NumberValue{NumberValue: float64(restarts)}
		if restarts > 0 {
			cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_WARNING
		}
	case "age":
		created := object.GetCreationTimestamp().Time
		if created.IsZero() {
			setStringCell(cell, DefaultMissingCell)
		} else {
			cell.DisplayText = formatAge(p.spec.Now.Sub(created))
			cell.TypedValue = &kmgrv1.Cell_TimestampUnixMs{TimestampUnixMs: created.UnixMilli()}
			cell.Tooltip = created.Format(time.RFC3339)
		}
	case "created":
		created := object.GetCreationTimestamp().Time
		if created.IsZero() {
			setStringCell(cell, DefaultMissingCell)
		} else {
			cell.DisplayText = created.Local().Format("2006-01-02 15:04:05")
			cell.TypedValue = &kmgrv1.Cell_TimestampUnixMs{TimestampUnixMs: created.UnixMilli()}
			cell.Tooltip = created.Format(time.RFC3339)
		}
	case "resourceVersion":
		setStringCell(cell, valueOrMissing(object.GetResourceVersion()))
	default:
		// Unknown IDs are intentionally visible as missing values. Later column
		// registries can replace them with CEL/metric extractors without ever
		// exposing raw objects to Swift.
		setStringCell(cell, DefaultMissingCell)
		cell.Tooltip = fmt.Sprintf("Column %q is not available for this resource", columnID)
		cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
	}
	return cell
}

func (p *Projector) celCell(object *unstructured.Unstructured, program *viewcolumns.Program) *kmgrv1.Cell {
	definition := program.Definition()
	missing := definition.Missing
	if missing == "" {
		missing = viewcolumns.DefaultMissing
	}
	cell := &kmgrv1.Cell{
		ColumnId: definition.ID, DisplayText: missing,
		Severity: kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL,
	}
	isSecret := p.spec.Resource.Group == "" && p.spec.Resource.Version == "v1" &&
		p.spec.Resource.Resource == "secrets"
	value, err := program.Evaluate(viewcolumns.Activation{
		Object:  viewcolumns.SanitizeObjectActivation(object.Object, isSecret),
		Metrics: p.metricsForObject(object),
		Context: map[string]any{
			"clusterSessionID": p.spec.ClusterSessionID,
			"group":            p.spec.Resource.Group, "version": p.spec.Resource.Version,
			"resource": p.spec.Resource.Resource, "kind": p.spec.Resource.Kind,
			"namespaced":    p.spec.Resource.Namespaced,
			"allNamespaces": p.spec.NamespaceScope.All,
			"namespaces":    append([]string(nil), p.spec.NamespaceScope.Namespaces...),
		},
		Now: p.spec.Now,
	})
	if err != nil {
		cell.Tooltip = err.Error()
		cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_ERROR
		return cell
	}
	cell.DisplayText = value.Display
	switch {
	case value.String != nil:
		cell.TypedValue = &kmgrv1.Cell_StringValue{StringValue: *value.String}
	case value.Integer != nil:
		cell.TypedValue = &kmgrv1.Cell_NumberValue{NumberValue: float64(*value.Integer)}
	case value.Number != nil:
		cell.TypedValue = &kmgrv1.Cell_NumberValue{NumberValue: *value.Number}
	case value.Boolean != nil:
		cell.TypedValue = &kmgrv1.Cell_BoolValue{BoolValue: *value.Boolean}
	case value.Time != nil:
		cell.TypedValue = &kmgrv1.Cell_TimestampUnixMs{TimestampUnixMs: value.Time.UnixMilli()}
	case value.Duration != nil:
		cell.TypedValue = &kmgrv1.Cell_NumberValue{NumberValue: value.Duration.Seconds()}
	}
	return cell
}

func (p *Projector) metricsForObject(object *unstructured.Unstructured) map[string]any {
	kind, supported := metricKindFor(p.spec.Resource)
	if !supported || object == nil {
		return map[string]any{}
	}
	sample := sampleForObject(
		p.spec.Metrics, string(object.GetUID()), object.GetNamespace(), object.GetName(), kind,
	)
	return metricsActivation(sample, p.spec.Metrics.State)
}

func (p *Projector) resourceUsageCell(
	object *unstructured.Unstructured,
	columnID string,
	resourceName corev1.ResourceName,
) *kmgrv1.Cell {
	cell := &kmgrv1.Cell{
		ColumnId: columnID,
		Severity: kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL,
	}
	usage := &kmgrv1.ResourceUsageValue{ResourceName: string(resourceName)}
	cell.TypedValue = &kmgrv1.Cell_Usage{Usage: usage}

	kind, supported := metricKindFor(p.spec.Resource)
	if !supported || object == nil {
		cell.DisplayText = DefaultMissingCell
		cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
		cell.Tooltip = "Resource accounting is not available for this resource type"
		return cell
	}
	sample := sampleForObject(
		p.spec.Metrics, string(object.GetUID()), object.GetNamespace(), object.GetName(), kind,
	)
	measurement := metrics.UnavailableMeasurement("Kubernetes Metrics API has not reported this resource")
	if p.spec.Metrics.Err != nil {
		switch {
		case errors.Is(p.spec.Metrics.Err, metrics.ErrMetricsAPIForbidden):
			measurement = metrics.UnavailableMeasurement("Kubernetes Metrics API access is forbidden")
		case errors.Is(p.spec.Metrics.Err, metrics.ErrMetricsAPIUnavailable):
			measurement = metrics.UnavailableMeasurement("Kubernetes Metrics API is unavailable")
		default:
			measurement = metrics.UnavailableMeasurement("metrics provider is unavailable")
		}
	}
	if p.spec.Metrics.State == metrics.MeasurementCurrent || p.spec.Metrics.State == metrics.MeasurementStale {
		measurement = metrics.MeasurementFor(
			sample, resourceName, metrics.MetricsAPIGroupVersion, measurementScope(kind),
		)
		if measurement.HasValue() && p.spec.Metrics.State == metrics.MeasurementStale {
			measurement = metrics.StaleMeasurement(
				measurement.Quantity, measurement.Provider, measurement.Scope,
				measurement.Timestamp, "the latest metrics refresh failed",
			)
		}
	}

	switch kind {
	case metrics.PodMetrics:
		var pod corev1.Pod
		if err := runtime.DefaultUnstructuredConverter.FromUnstructured(object.Object, &pod); err != nil {
			cell.DisplayText = DefaultMissingCell
			cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_ERROR
			cell.Tooltip = "Pod resource accounting could not be calculated"
			return cell
		}
		accounting := metrics.AccountPod(&pod, metrics.ResourceMeasurements{resourceName: measurement})
		request, hasRequest := accounting.Requests[resourceName]
		limit, hasLimit := accounting.Limits[resourceName]
		setUsageQuantities(usage, measurement, optionalQuantity(request, hasRequest), optionalQuantity(limit, hasLimit), nil)
		cell.DisplayText = formatUsageDisplay(
			measurement, optionalQuantity(request, hasRequest), optionalQuantity(limit, hasLimit), nil,
		)
		cell.Tooltip = formatUsageTooltip(
			measurement, optionalQuantity(request, hasRequest), optionalQuantity(limit, hasLimit), nil, nil,
		)
	case metrics.NodeMetrics:
		var node corev1.Node
		if err := runtime.DefaultUnstructuredConverter.FromUnstructured(object.Object, &node); err != nil {
			cell.DisplayText = DefaultMissingCell
			cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_ERROR
			cell.Tooltip = "Node resource accounting could not be calculated"
			return cell
		}
		allocatable, hasAllocatable := node.Status.Allocatable[resourceName]
		capacity, hasCapacity := node.Status.Capacity[resourceName]
		setUsageQuantities(usage, measurement, nil, nil, optionalQuantity(allocatable, hasAllocatable))
		cell.DisplayText = formatUsageDisplay(
			measurement, nil, nil, optionalQuantity(allocatable, hasAllocatable),
		)
		cell.Tooltip = formatUsageTooltip(
			measurement, nil, nil, optionalQuantity(allocatable, hasAllocatable),
			optionalQuantity(capacity, hasCapacity),
		)
	}
	if measurement.State == metrics.MeasurementStale {
		cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_WARNING
	} else if !measurement.HasValue() {
		cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
	}
	return cell
}

func setUsageQuantities(
	value *kmgrv1.ResourceUsageValue,
	measurement metrics.Measurement,
	request, limit, allocatable *resource.Quantity,
) {
	name := corev1.ResourceName(value.GetResourceName())
	value.Unit = resourceUnit(name)
	value.UsageAvailable = measurement.HasValue()
	if measurement.HasValue() {
		value.Used = quantityNumeric(name, measurement.Quantity)
		value.MeasuredAtUnixMs = measurement.Timestamp.UnixMilli()
		value.Provider = measurement.Provider
		value.MeasurementScope = measurement.Scope
	}
	if request != nil {
		value.Requested = quantityNumeric(name, *request)
	}
	if limit != nil {
		value.Limit = quantityNumeric(name, *limit)
	}
	if allocatable != nil {
		value.Capacity = quantityNumeric(name, *allocatable)
	}
}

func optionalQuantity(value resource.Quantity, present bool) *resource.Quantity {
	if !present {
		return nil
	}
	copy := value.DeepCopy()
	return &copy
}

func measurementScope(kind metrics.APIKind) string {
	if kind == metrics.PodMetrics {
		return "pod containers"
	}
	return "node"
}

func resourceUnit(name corev1.ResourceName) string {
	if name == corev1.ResourceCPU {
		return "cores"
	}
	if name == corev1.ResourceMemory || name == corev1.ResourceEphemeralStorage ||
		strings.HasPrefix(string(name), corev1.ResourceHugePagesPrefix) {
		return "bytes"
	}
	return "count"
}

func quantityNumeric(name corev1.ResourceName, quantity resource.Quantity) float64 {
	if quantity.IsZero() {
		return 0
	}
	return quantity.AsApproximateFloat64()
}

func formatUsageDisplay(
	measurement metrics.Measurement,
	request, limit, allocatable *resource.Quantity,
) string {
	parts := make([]string, 0, 3)
	if measurement.HasValue() {
		parts = append(parts, measurement.Quantity.String())
	} else {
		parts = append(parts, DefaultMissingCell)
	}
	if allocatable != nil {
		parts = append(parts, allocatable.String())
		return strings.Join(parts, " / ")
	}
	parts = append(parts, quantityDisplay(request), quantityDisplay(limit))
	return strings.Join(parts, " / ")
}

func quantityDisplay(quantity *resource.Quantity) string {
	if quantity == nil {
		return DefaultMissingCell
	}
	return quantity.String()
}

func formatUsageTooltip(
	measurement metrics.Measurement,
	request, limit, allocatable, capacity *resource.Quantity,
) string {
	parts := make([]string, 0, 6)
	if measurement.HasValue() {
		parts = append(parts, "Actual usage: "+measurement.Quantity.String())
		if measurement.Provider != "" {
			parts = append(parts, "Provider: "+measurement.Provider)
		}
		if measurement.Scope != "" {
			parts = append(parts, "Scope: "+measurement.Scope)
		}
		if !measurement.Timestamp.IsZero() {
			parts = append(parts, "Measured: "+measurement.Timestamp.Format(time.RFC3339))
		}
		if measurement.State == metrics.MeasurementStale {
			parts = append(parts, "State: stale (the latest refresh failed)")
		}
	} else {
		unavailable := "Actual usage: unavailable"
		if measurement.Message != "" {
			unavailable += " (" + measurement.Message + ")"
		}
		parts = append(parts, unavailable)
	}
	if request != nil {
		parts = append(parts, "Effective request: "+request.String())
	}
	if limit != nil {
		parts = append(parts, "Effective limit: "+limit.String())
	}
	if allocatable != nil {
		parts = append(parts, "Allocatable: "+allocatable.String())
	}
	if capacity != nil {
		parts = append(parts, "Physical capacity: "+capacity.String())
	}
	return strings.Join(parts, "\n")
}

func (p *Projector) compareRows(left, right *kmgrv1.ResourceRow) int {
	for _, descriptor := range p.spec.Sort {
		leftCell := cellByID(left, descriptor.ColumnID)
		rightCell := cellByID(right, descriptor.ColumnID)
		result := compareCells(leftCell, rightCell, descriptor.NullsFirst)
		if descriptor.Descending {
			result = -result
		}
		if result != 0 {
			return result
		}
	}
	if result := cmp.Compare(left.GetIdentity().GetNamespace(), right.GetIdentity().GetNamespace()); result != 0 {
		return result
	}
	if result := cmp.Compare(left.GetIdentity().GetName(), right.GetIdentity().GetName()); result != 0 {
		return result
	}
	return cmp.Compare(left.GetIdentity().GetUid(), right.GetIdentity().GetUid())
}

func defaultColumns(resource ResourceType) []string {
	columns := make([]string, 0, 9)
	if resource.Namespaced {
		columns = append(columns, "namespace")
	}
	columns = append(columns, "name")
	if strings.EqualFold(resource.Kind, "Pod") || resource.Resource == "pods" {
		columns = append(columns, "ready", "status", "restarts", "node", PodCPUColumn, PodMemoryColumn)
	} else if strings.EqualFold(resource.Kind, "Node") || resource.Resource == "nodes" {
		columns = append(columns, "status", NodeCPUUsageColumn, NodeMemoryUsageColumn)
	} else {
		columns = append(columns, "status")
	}
	return append(columns, "age")
}

func setStringCell(cell *kmgrv1.Cell, value string) {
	cell.DisplayText = value
	if value != DefaultMissingCell {
		cell.TypedValue = &kmgrv1.Cell_StringValue{StringValue: value}
	}
}

func valueOrMissing(value string) string {
	if value == "" {
		return DefaultMissingCell
	}
	return value
}

func statusText(object *unstructured.Unstructured) string {
	if object.GetDeletionTimestamp() != nil {
		return "Terminating"
	}
	kind := strings.ToLower(object.GetKind())
	if kind == "node" {
		conditions, _, _ := unstructured.NestedSlice(object.Object, "status", "conditions")
		for _, raw := range conditions {
			condition, _ := raw.(map[string]any)
			if condition["type"] == "Ready" {
				if condition["status"] == "True" {
					return "Ready"
				}
				return "NotReady"
			}
		}
	}
	if value, found, _ := unstructured.NestedString(object.Object, "status", "phase"); found && value != "" {
		return value
	}
	if kind == "deployment" || kind == "statefulset" || kind == "daemonset" || kind == "replicaset" {
		ready, _, _ := unstructured.NestedInt64(object.Object, "status", "readyReplicas")
		desired, _, _ := unstructured.NestedInt64(object.Object, "spec", "replicas")
		if kind == "daemonset" {
			desired, _, _ = unstructured.NestedInt64(object.Object, "status", "desiredNumberScheduled")
			ready, _, _ = unstructured.NestedInt64(object.Object, "status", "numberReady")
		}
		if desired > 0 && ready >= desired {
			return "Ready"
		}
		if desired > 0 {
			return fmt.Sprintf("Progressing %d/%d", ready, desired)
		}
	}
	if value, found, _ := unstructured.NestedString(object.Object, "type"); kind == "event" && found {
		return value
	}
	return "Active"
}

func statusSeverity(status string) kmgrv1.CellSeverity {
	folded := strings.ToLower(status)
	switch {
	case strings.Contains(folded, "fail"), strings.Contains(folded, "error"), strings.Contains(folded, "crash"), strings.Contains(folded, "notready"):
		return kmgrv1.CellSeverity_CELL_SEVERITY_ERROR
	case strings.Contains(folded, "pending"), strings.Contains(folded, "progress"), strings.Contains(folded, "terminating"), strings.Contains(folded, "unknown"):
		return kmgrv1.CellSeverity_CELL_SEVERITY_WARNING
	default:
		return kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL
	}
}

func readyContainers(object *unstructured.Unstructured) (ready, total int) {
	statuses, _, _ := unstructured.NestedSlice(object.Object, "status", "containerStatuses")
	for _, raw := range statuses {
		status, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		total++
		if value, ok := status["ready"].(bool); ok && value {
			ready++
		}
	}
	if total == 0 {
		containers, _, _ := unstructured.NestedSlice(object.Object, "spec", "containers")
		total = len(containers)
	}
	return ready, total
}

func restartCount(object *unstructured.Unstructured) int64 {
	statuses, _, _ := unstructured.NestedSlice(object.Object, "status", "containerStatuses")
	var result int64
	for _, raw := range statuses {
		status, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		switch value := status["restartCount"].(type) {
		case int64:
			result += value
		case int32:
			result += int64(value)
		case float64:
			result += int64(value)
		}
	}
	return result
}

func nestedScalar(object map[string]any, path string) (string, bool) {
	segments := strings.Split(strings.TrimPrefix(path, "."), ".")
	if len(segments) == 0 {
		return "", false
	}
	value, found, err := unstructured.NestedFieldNoCopy(object, segments...)
	if err != nil || !found || value == nil {
		return "", false
	}
	switch typed := value.(type) {
	case string:
		return typed, true
	case bool:
		return strconv.FormatBool(typed), true
	case int64:
		return strconv.FormatInt(typed, 10), true
	case int32:
		return strconv.FormatInt(int64(typed), 10), true
	case float64:
		return strconv.FormatFloat(typed, 'g', -1, 64), true
	default:
		return "", false
	}
}

func cellByID(row *kmgrv1.ResourceRow, id string) *kmgrv1.Cell {
	for _, cell := range row.GetCells() {
		if cell.GetColumnId() == id {
			return cell
		}
	}
	return nil
}

func compareCells(left, right *kmgrv1.Cell, nullsFirst bool) int {
	leftMissing := left == nil || left.GetTypedValue() == nil
	rightMissing := right == nil || right.GetTypedValue() == nil
	if leftMissing || rightMissing {
		if leftMissing && rightMissing {
			return 0
		}
		if leftMissing == nullsFirst {
			return -1
		}
		return 1
	}
	switch leftValue := left.GetTypedValue().(type) {
	case *kmgrv1.Cell_StringValue:
		if rightValue, ok := right.GetTypedValue().(*kmgrv1.Cell_StringValue); ok {
			return strings.Compare(strings.ToLower(leftValue.StringValue), strings.ToLower(rightValue.StringValue))
		}
	case *kmgrv1.Cell_NumberValue:
		if rightValue, ok := right.GetTypedValue().(*kmgrv1.Cell_NumberValue); ok {
			if math.IsNaN(leftValue.NumberValue) || math.IsNaN(rightValue.NumberValue) {
				return strings.Compare(left.GetDisplayText(), right.GetDisplayText())
			}
			return cmp.Compare(leftValue.NumberValue, rightValue.NumberValue)
		}
	case *kmgrv1.Cell_TimestampUnixMs:
		if rightValue, ok := right.GetTypedValue().(*kmgrv1.Cell_TimestampUnixMs); ok {
			return cmp.Compare(leftValue.TimestampUnixMs, rightValue.TimestampUnixMs)
		}
	case *kmgrv1.Cell_BoolValue:
		if rightValue, ok := right.GetTypedValue().(*kmgrv1.Cell_BoolValue); ok {
			switch {
			case leftValue.BoolValue == rightValue.BoolValue:
				return 0
			case !leftValue.BoolValue:
				return -1
			default:
				return 1
			}
		}
	case *kmgrv1.Cell_OpaqueSortValue:
		if rightValue, ok := right.GetTypedValue().(*kmgrv1.Cell_OpaqueSortValue); ok {
			return slices.Compare(leftValue.OpaqueSortValue, rightValue.OpaqueSortValue)
		}
	case *kmgrv1.Cell_Usage:
		if rightValue, ok := right.GetTypedValue().(*kmgrv1.Cell_Usage); ok {
			return compareUsageValues(leftValue.Usage, rightValue.Usage)
		}
	}
	return strings.Compare(left.GetDisplayText(), right.GetDisplayText())
}

func compareUsageValues(left, right *kmgrv1.ResourceUsageValue) int {
	leftValue, leftAvailable := usageSortValue(left)
	rightValue, rightAvailable := usageSortValue(right)
	if leftAvailable != rightAvailable {
		if leftAvailable {
			return 1
		}
		return -1
	}
	return cmp.Compare(leftValue, rightValue)
}

func usageSortValue(value *kmgrv1.ResourceUsageValue) (float64, bool) {
	if value == nil {
		return 0, false
	}
	if value.GetUsageAvailable() {
		denominator := value.GetCapacity()
		if denominator == 0 {
			denominator = value.GetRequested()
		}
		if denominator == 0 {
			denominator = value.GetLimit()
		}
		if denominator != 0 {
			return value.GetUsed() / denominator, true
		}
		return value.GetUsed(), true
	}
	if value.GetRequested() != 0 && value.GetCapacity() != 0 {
		return value.GetRequested() / value.GetCapacity(), true
	}
	if value.GetRequested() != 0 {
		return value.GetRequested(), true
	}
	if value.GetLimit() != 0 {
		return value.GetLimit(), true
	}
	return 0, false
}

func formatAge(duration time.Duration) string {
	if duration < 0 {
		duration = 0
	}
	seconds := int64(duration / time.Second)
	switch {
	case seconds < 60:
		return fmt.Sprintf("%ds", seconds)
	case seconds < 3600:
		return fmt.Sprintf("%dm", seconds/60)
	case seconds < 86_400:
		return fmt.Sprintf("%dh", seconds/3600)
	default:
		return fmt.Sprintf("%dd", seconds/86_400)
	}
}
