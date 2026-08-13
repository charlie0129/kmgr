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
	ColumnExtractors map[string]viewcolumns.Extractor
	Metrics          metrics.Snapshot
	NodeAccounting   NodeAccountingSnapshot
	Now              time.Time
}

// NodeAccountingSnapshot is an immutable scheduler-allocation revision for a
// Nodes projection. Ready remains false while the shared cluster-wide Pod
// snapshot is loading. Err records an optional dependency failure without
// affecting the base Node LIST/WATCH or Metrics API enrichment.
type NodeAccountingSnapshot struct {
	Active     bool
	Ready      bool
	Err        error
	Nodes      map[string]metrics.NodeAccounting
	Discovered metrics.DiscoveredResources
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
	now        func() time.Time
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

// WithNodeAccounting returns an immutable projection revision for scheduler
// allocation derived from the current Node and Pod stores.
func (p *Projector) WithNodeAccounting(snapshot NodeAccountingSnapshot) *Projector {
	if p == nil {
		return nil
	}
	copy := *p
	copy.spec = p.spec
	copy.spec.NodeAccounting = cloneNodeAccountingSnapshot(snapshot)
	return &copy
}

func cloneNodeAccountingSnapshot(snapshot NodeAccountingSnapshot) NodeAccountingSnapshot {
	result := NodeAccountingSnapshot{Active: snapshot.Active, Ready: snapshot.Ready, Err: snapshot.Err}
	result.Discovered.EphemeralStorage = snapshot.Discovered.EphemeralStorage
	result.Discovered.HugePages = slices.Clone(snapshot.Discovered.HugePages)
	result.Discovered.Accelerators = slices.Clone(snapshot.Discovered.Accelerators)
	if snapshot.Nodes == nil {
		return result
	}
	result.Nodes = make(map[string]metrics.NodeAccounting, len(snapshot.Nodes))
	for name, accounting := range snapshot.Nodes {
		accounting.Capacity = accounting.Capacity.DeepCopy()
		accounting.Allocatable = accounting.Allocatable.DeepCopy()
		accounting.Requested = accounting.Requested.DeepCopy()
		accounting.Limited = accounting.Limited.DeepCopy()
		if accounting.Usage != nil {
			usage := make(metrics.ResourceMeasurements, len(accounting.Usage))
			for resourceName, measurement := range accounting.Usage {
				measurement.Quantity = measurement.Quantity.DeepCopy()
				usage[resourceName] = measurement
			}
			accounting.Usage = usage
		}
		result.Nodes[name] = accounting
	}
	return result
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
	for id, extractor := range spec.ColumnExtractors {
		if strings.TrimSpace(id) == "" || strings.TrimSpace(extractor.Source) == "" || strings.TrimSpace(extractor.Value) == "" {
			return nil, errors.New("column extractor ID and value must not be blank")
		}
		if extractor.Source != "builtin" && extractor.Source != "metric" {
			return nil, fmt.Errorf("column %q has unsupported extractor source %q", id, extractor.Source)
		}
	}
	compiledFilter, err := viewfilter.Compile(spec.FilterExpression)
	if err != nil {
		return nil, err
	}
	// Now is a deterministic clock override used by tests and callers that
	// need a fixed projection instant. Production projectors leave it unset so
	// each projection batch captures a fresh timestamp below.
	now := time.Now
	if !spec.Now.IsZero() {
		fixed := spec.Now
		now = func() time.Time { return fixed }
	}
	spec.Now = time.Time{}
	namespaces := make(map[string]struct{}, len(spec.NamespaceScope.Namespaces))
	for _, namespace := range spec.NamespaceScope.Namespaces {
		if namespace != "" {
			namespaces[namespace] = struct{}{}
		}
	}
	return &Projector{spec: spec, filter: compiledFilter, namespaces: namespaces, now: now}, nil
}

// Project returns all visible rows in deterministic typed sort order. The
// supplied objects are treated as immutable and may safely be a UIDStore
// snapshot.
func (p *Projector) Project(objects []*unstructured.Unstructured) []*kmgrv1.ResourceRow {
	batch := p.beginBatch()
	rows := make([]*kmgrv1.ResourceRow, 0, len(objects))
	for _, object := range objects {
		if row, visible := batch.projectOne(object); visible {
			rows = append(rows, row)
		}
	}
	slices.SortStableFunc(rows, batch.compareRows)
	return rows
}

// ProjectOne computes a single compact row and whether it belongs to the
// current namespace/filter projection.
func (p *Projector) ProjectOne(object *unstructured.Unstructured) (*kmgrv1.ResourceRow, bool) {
	return p.beginBatch().projectOne(object)
}

// beginBatch captures the CEL `now` activation exactly once. Callers that
// project several objects from one LIST/WATCH/metrics revision must reuse the
// returned projector for every object in that batch.
func (p *Projector) beginBatch() *Projector {
	if p == nil {
		return nil
	}
	batch := *p
	batch.spec = p.spec
	if p.now != nil {
		batch.spec.Now = p.now()
	} else {
		batch.spec.Now = time.Now()
	}
	return &batch
}

func (p *Projector) projectOne(object *unstructured.Unstructured) (*kmgrv1.ResourceRow, bool) {
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
	extractorID := p.extractorID(columnID)
	if extractorID == NodePodCountColumn && isNodeResource(p.spec.Resource) {
		return p.nodePodCountCell(object, columnID)
	}
	if resourceName, field, allocationColumn := nodeAllocationColumn(p.spec.Resource, extractorID); allocationColumn {
		return p.nodeAllocationCell(object, columnID, resourceName, field)
	}
	if resourceName, metricColumn := metricColumnResource(p.spec.Resource, extractorID); metricColumn {
		return p.resourceUsageCell(object, columnID, resourceName)
	}
	cell := &kmgrv1.Cell{ColumnId: columnID, Severity: kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL}
	switch extractorID {
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

func (p *Projector) extractorID(columnID string) string {
	if p != nil {
		if extractor := p.spec.ColumnExtractors[columnID]; extractor.Value != "" {
			return extractor.Value
		}
	}
	return columnID
}

func (p *Projector) extractorSource(columnID string) string {
	if p != nil {
		return p.spec.ColumnExtractors[columnID].Source
	}
	return ""
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
	activation := metricsActivation(sample, p.spec.Metrics.State)
	if kind != metrics.NodeMetrics {
		return activation
	}
	accounting, ready := p.nodeAccountingFor(object)
	activation["accountingAvailable"] = ready
	if !ready {
		activation["requests"] = map[string]any{}
		activation["limits"] = map[string]any{}
		activation["allocatable"] = map[string]any{}
		activation["capacity"] = map[string]any{}
		return activation
	}
	activation["requests"] = resourceListActivation(accounting.Requested)
	activation["limits"] = resourceListActivation(accounting.Limited)
	activation["allocatable"] = resourceListActivation(accounting.Allocatable)
	activation["capacity"] = resourceListActivation(accounting.Capacity)
	activation["podCount"] = accounting.PodCount
	return activation
}

func resourceListActivation(values corev1.ResourceList) map[string]any {
	result := make(map[string]any, len(values))
	for name, value := range values {
		result[string(name)] = quantityNumeric(name, value)
	}
	return result
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
		if _, exact := exactResourceColumn(p.extractorID(columnID)); exact &&
			!hasRequest && !hasLimit && !measurement.HasValue() {
			cell.DisplayText = DefaultMissingCell
			cell.TypedValue = nil
			cell.Tooltip = "Exact resource " + string(resourceName) + " is not present on this Pod"
			cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
			return cell
		}
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
		var request, limit *resource.Quantity
		if accounting, ready := p.nodeAccountingFor(object); ready {
			requested, hasRequest := accounting.Requested[resourceName]
			limited, hasLimit := accounting.Limited[resourceName]
			request = optionalQuantity(requested, hasRequest)
			limit = optionalQuantity(limited, hasLimit)
		}
		setUsageQuantities(usage, measurement, request, limit, optionalQuantity(allocatable, hasAllocatable))
		cell.DisplayText = formatUsageDisplay(
			measurement, nil, nil, optionalQuantity(allocatable, hasAllocatable),
		)
		cell.Tooltip = formatUsageTooltip(
			measurement, request, limit, optionalQuantity(allocatable, hasAllocatable),
			optionalQuantity(capacity, hasCapacity),
		)
		if p.spec.NodeAccounting.Err != nil {
			cell.Tooltip += "\nScheduler accounting: unavailable (" + p.spec.NodeAccounting.Err.Error() + ")"
		}
	}
	if measurement.State == metrics.MeasurementStale {
		cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_WARNING
	} else if !measurement.HasValue() {
		cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
	}
	return cell
}

func (p *Projector) nodeAccountingFor(object *unstructured.Unstructured) (metrics.NodeAccounting, bool) {
	if p == nil || object == nil || !p.spec.NodeAccounting.Active || !p.spec.NodeAccounting.Ready {
		return metrics.NodeAccounting{}, false
	}
	accounting, found := p.spec.NodeAccounting.Nodes[object.GetName()]
	return accounting, found
}

func (p *Projector) nodeAllocationCell(
	object *unstructured.Unstructured,
	columnID string,
	resourceName corev1.ResourceName,
	field nodeAllocationField,
) *kmgrv1.Cell {
	cell := &kmgrv1.Cell{
		ColumnId: columnID,
		Severity: kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL,
	}
	usage := &kmgrv1.ResourceUsageValue{
		ResourceName: string(resourceName),
		Unit:         resourceUnit(resourceName),
	}
	cell.TypedValue = &kmgrv1.Cell_Usage{Usage: usage}
	if !p.spec.NodeAccounting.Active || (!p.spec.NodeAccounting.Ready && p.spec.NodeAccounting.Err == nil) {
		cell.DisplayText = "Calculating…"
		cell.Tooltip = "Summing effective requests and limits from bound, non-terminal Pods"
		cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
		return cell
	}
	if p.spec.NodeAccounting.Err != nil && !p.spec.NodeAccounting.Ready {
		cell.DisplayText = DefaultMissingCell
		cell.TypedValue = nil
		cell.Tooltip = "Scheduler accounting is unavailable: " + p.spec.NodeAccounting.Err.Error()
		cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
		return cell
	}
	accounting, found := p.nodeAccountingFor(object)
	if !found {
		cell.DisplayText = DefaultMissingCell
		cell.Tooltip = "Node scheduler accounting is unavailable"
		cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
		return cell
	}
	allocatable, hasAllocatable := accounting.Allocatable[resourceName]
	capacity, hasCapacity := accounting.Capacity[resourceName]
	requested, hasRequest := accounting.Requested[resourceName]
	limited, hasLimit := accounting.Limited[resourceName]
	if _, exact := exactResourceColumn(p.extractorID(columnID)); exact &&
		!hasAllocatable && !hasCapacity && !hasRequest && !hasLimit {
		cell.DisplayText = DefaultMissingCell
		cell.TypedValue = nil
		cell.Tooltip = "Exact resource " + string(resourceName) + " is not present on this Node"
		cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
		return cell
	}
	var value *resource.Quantity
	label := "Summed effective requests"
	if field == nodeLimited {
		value = optionalQuantity(limited, hasLimit)
		usage.Limit = quantityNumeric(resourceName, limited)
		label = "Summed effective limits"
	} else {
		value = optionalQuantity(requested, hasRequest)
		usage.Requested = quantityNumeric(resourceName, requested)
	}
	if hasAllocatable {
		usage.Capacity = quantityNumeric(resourceName, allocatable)
	}
	cell.DisplayText = quantityDisplay(value) + " / " + quantityDisplay(optionalQuantity(allocatable, hasAllocatable))
	parts := []string{label + ": " + quantityDisplay(value)}
	if field == nodeRequested && hasLimit {
		parts = append(parts, "Summed effective limits: "+limited.String())
	}
	if hasAllocatable {
		parts = append(parts, "Allocatable: "+allocatable.String())
	}
	if hasCapacity {
		parts = append(parts, "Physical capacity: "+capacity.String())
	}
	cell.Tooltip = strings.Join(parts, "\n")
	return cell
}

func (p *Projector) nodePodCountCell(object *unstructured.Unstructured, columnID string) *kmgrv1.Cell {
	cell := &kmgrv1.Cell{ColumnId: columnID, Severity: kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL}
	usage := &kmgrv1.ResourceUsageValue{ResourceName: string(corev1.ResourcePods), Unit: "count"}
	cell.TypedValue = &kmgrv1.Cell_Usage{Usage: usage}
	if !p.spec.NodeAccounting.Active || (!p.spec.NodeAccounting.Ready && p.spec.NodeAccounting.Err == nil) {
		cell.DisplayText = "Calculating…"
		cell.Tooltip = "Counting bound, non-terminal Pods"
		cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
		return cell
	}
	if p.spec.NodeAccounting.Err != nil && !p.spec.NodeAccounting.Ready {
		cell.DisplayText = DefaultMissingCell
		cell.TypedValue = nil
		cell.Tooltip = "Pod counting is unavailable: " + p.spec.NodeAccounting.Err.Error()
		cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
		return cell
	}
	accounting, found := p.nodeAccountingFor(object)
	if !found {
		cell.DisplayText = DefaultMissingCell
		cell.Tooltip = "Node Pod accounting is unavailable"
		cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
		return cell
	}
	allocatable, hasAllocatable := accounting.Allocatable[corev1.ResourcePods]
	capacity, hasCapacity := accounting.Capacity[corev1.ResourcePods]
	usage.Requested = float64(accounting.PodCount)
	if hasAllocatable {
		usage.Capacity = quantityNumeric(corev1.ResourcePods, allocatable)
	}
	cell.DisplayText = strconv.FormatInt(accounting.PodCount, 10) + " / " + quantityDisplay(optionalQuantity(allocatable, hasAllocatable))
	parts := []string{"Bound non-terminal Pods: " + strconv.FormatInt(accounting.PodCount, 10)}
	if hasAllocatable {
		parts = append(parts, "Allocatable Pod capacity: "+allocatable.String())
	}
	if hasCapacity {
		parts = append(parts, "Physical Pod capacity: "+capacity.String())
	}
	cell.Tooltip = strings.Join(parts, "\n")
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
	if value.GetCapacity() != 0 {
		if value.GetRequested() != 0 {
			return value.GetRequested() / value.GetCapacity(), true
		}
		if value.GetLimit() != 0 {
			return value.GetLimit() / value.GetCapacity(), true
		}
	}
	if value.GetRequested() != 0 {
		return value.GetRequested(), true
	}
	if value.GetLimit() != 0 {
		return value.GetLimit(), true
	}
	// Exact-resource cells are omitted entirely when the resource is absent.
	// A retained typed value whose quantities are all zero therefore represents
	// a real Kubernetes zero and must participate in numeric sorting.
	if value.GetResourceName() != "" {
		return 0, true
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
