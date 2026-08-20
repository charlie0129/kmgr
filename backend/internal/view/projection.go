// Package view projects Kubernetes objects into compact, typed table rows.
// Raw Kubernetes objects never cross this boundary into the GUI process.
package view

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"math"
	goruntime "runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
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
	DefaultMissingCell         = "—"
	MaxColumnsPerView          = 64
	MaxProjectionWorkerLimit   = 32
	defaultProjectionWorkerCap = 8
)

// ProjectionSpec contains only presentation choices. Server-side namespace
// and Kubernetes selectors are applied by the caller's resource client.
type ProjectionSpec struct {
	ClusterSessionID                   string
	Resource                           ResourceType
	NamespaceScope                     NamespaceScope
	ColumnIDs                          []string
	FilterExpression                   string
	Sort                               []SortDescriptor
	ColumnConfigurationVersion         string
	ResolvedColumnConfigurationVersion string
	CELPrograms                        map[string]*viewcolumns.Program
	ColumnExtractors                   map[string]viewcolumns.Extractor
	// Accelerators applies the same exact-key/suffix classification used by
	// optional resource discovery, so allocation-only columns never pretend a
	// Metrics API usage sample exists.
	Accelerators metrics.AcceleratorConfig
	Metrics      metrics.Snapshot
	Now          time.Time
	// compiledFilter is supplied by the authoritative query planner so an Open
	// parses the kmgr expression exactly once. Direct projector callers leave it
	// nil and retain the public constructor's validation behavior.
	compiledFilter *viewfilter.Filter
	// WorkerLimit bounds concurrent row projection for large snapshots. Zero
	// selects a conservative process-wide default capped below GOMAXPROCS.
	WorkerLimit int
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
	spec        ProjectionSpec
	filter      *viewfilter.Filter
	namespaces  map[string]struct{}
	now         func() time.Time
	workerLimit int
	cacheKey    projectionCacheKey
}

// projectionWorkerGate bounds aggregate row work across all Projectors. A
// per-Projector WorkerLimit still controls one batch's share of this capacity,
// but concurrent views cannot each create an independent full worker pool.
var projectionWorkerGate = make(chan struct{}, min(max(goruntime.GOMAXPROCS(0), 1), defaultProjectionWorkerCap))

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
	if spec.WorkerLimit < 0 || spec.WorkerLimit > MaxProjectionWorkerLimit {
		return nil, fmt.Errorf("projection worker limit must be between 1 and %d", MaxProjectionWorkerLimit)
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
	compiledFilter := spec.compiledFilter
	if compiledFilter == nil {
		var err error
		compiledFilter, err = viewfilter.Compile(spec.FilterExpression)
		if err != nil {
			return nil, err
		}
	}
	spec.compiledFilter = nil
	// Now is a deterministic clock override used by tests and callers that
	// need a fixed projection instant. Production projectors leave it unset so
	// each projection batch captures a fresh timestamp below.
	now := time.Now
	if !spec.Now.IsZero() {
		fixed := spec.Now
		now = func() time.Time { return fixed }
	}
	spec.Now = time.Time{}
	spec.Accelerators = cloneAcceleratorConfig(spec.Accelerators)
	namespaces := make(map[string]struct{}, len(spec.NamespaceScope.Namespaces))
	for _, namespace := range spec.NamespaceScope.Namespaces {
		if namespace != "" {
			namespaces[namespace] = struct{}{}
		}
	}
	workerLimit := spec.WorkerLimit
	if workerLimit == 0 {
		workerLimit = cap(projectionWorkerGate)
	}
	return &Projector{
		spec: spec, filter: compiledFilter, namespaces: namespaces,
		now: now, workerLimit: workerLimit, cacheKey: newProjectionCacheKey(spec),
	}, nil
}

// Project returns all visible rows in deterministic typed sort order. The
// supplied objects are treated as immutable and may safely be a UIDStore
// snapshot.
func (p *Projector) Project(objects []*unstructured.Unstructured) []*kmgrv1.ResourceRow {
	rows, _ := p.ProjectContext(context.Background(), objects)
	return rows
}

// ProjectContext returns all visible rows in deterministic typed sort order
// and stops stale projection work when ctx is canceled. CEL runtime failures
// remain error cells; only context cancellation aborts the complete batch.
func (p *Projector) ProjectContext(ctx context.Context, objects []*unstructured.Unstructured) ([]*kmgrv1.ResourceRow, error) {
	return p.ProjectContextWithAdditionalCells(ctx, objects, nil)
}

// ProjectContextWithAdditionalCells merges server Table cells before filter
// and sort evaluation. The cells came from the same API response as each full
// object and therefore never represent a cross-resource dependency.
func (p *Projector) ProjectContextWithAdditionalCells(
	ctx context.Context,
	objects []*unstructured.Unstructured,
	additional map[string][]*kmgrv1.Cell,
) ([]*kmgrv1.ResourceRow, error) {
	if ctx == nil {
		return nil, errors.New("projection context must not be nil")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	batch := p.beginBatch()
	if batch == nil || len(objects) == 0 {
		return nil, nil
	}

	type result struct {
		row     *kmgrv1.ResourceRow
		visible bool
	}
	projected := make([]result, len(objects))
	err := projectBoundedContext(ctx, len(objects), batch.workerLimit, func(index int) error {
		object := objects[index]
		var cells []*kmgrv1.Cell
		if object != nil {
			cells = additional[string(object.GetUID())]
		}
		row, visible, err := batch.projectOneAdmittedWithCells(ctx, object, cells)
		if err != nil {
			return err
		}
		projected[index].row, projected[index].visible = row, visible
		return nil
	})
	if err != nil {
		return nil, err
	}

	rows := make([]*kmgrv1.ResourceRow, 0, len(objects))
	for _, result := range projected {
		if result.visible {
			rows = append(rows, result.row)
		}
	}
	if err := sortRowsContext(ctx, rows, batch.compareRows); err != nil {
		return nil, err
	}
	return rows, nil
}

func projectBoundedContext(ctx context.Context, count, workerLimit int, project func(index int) error) error {
	if ctx == nil {
		return errors.New("projection context must not be nil")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if count <= 0 || project == nil {
		return nil
	}
	workerCount := min(max(workerLimit, 1), count, cap(projectionWorkerGate))
	workerCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	var next atomic.Int64
	var firstErr error
	var errOnce sync.Once
	var workers sync.WaitGroup
	workers.Add(workerCount)
	for range workerCount {
		go func() {
			defer workers.Done()
			for {
				if workerCtx.Err() != nil {
					return
				}
				index := int(next.Add(1) - 1)
				if index >= count {
					return
				}
				if err := runProjectionWorker(workerCtx, func() error { return project(index) }); err != nil {
					errOnce.Do(func() {
						firstErr = err
						cancel()
					})
					return
				}
			}
		}()
	}
	workers.Wait()
	if firstErr != nil {
		return firstErr
	}
	return ctx.Err()
}

func runProjectionWorker(ctx context.Context, project func() error) error {
	select {
	case projectionWorkerGate <- struct{}{}:
		defer func() { <-projectionWorkerGate }()
		if err := ctx.Err(); err != nil {
			return err
		}
		return project()
	case <-ctx.Done():
		return ctx.Err()
	}
}

// ProjectOne computes a single compact row and whether it belongs to the
// current namespace/filter projection. The object is treated as immutable for
// the call, and the returned protobuf row retains no nested object aliases.
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
	return p.projectOneWithCells(object, nil)
}

func (p *Projector) projectOneWithCells(
	object *unstructured.Unstructured,
	additional []*kmgrv1.Cell,
) (*kmgrv1.ResourceRow, bool) {
	var row *kmgrv1.ResourceRow
	var visible bool
	_ = runProjectionWorker(context.Background(), func() error {
		row, visible, _ = p.projectOneAdmittedWithCells(context.Background(), object, additional)
		return nil
	})
	return row, visible
}

func (p *Projector) projectOneAdmittedWithCells(
	ctx context.Context,
	object *unstructured.Unstructured,
	additional []*kmgrv1.Cell,
) (*kmgrv1.ResourceRow, bool, error) {
	if err := ctx.Err(); err != nil {
		return nil, false, err
	}
	if object == nil || object.GetUID() == "" || !p.includesNamespace(object.GetNamespace()) {
		return nil, false, nil
	}

	cells := make([]*kmgrv1.Cell, 0, len(p.spec.ColumnIDs)+len(additional))
	visibleText := make([]string, 0, len(p.spec.ColumnIDs)+len(additional))
	additionalByID := make(map[string]*kmgrv1.Cell, len(additional))
	for _, cell := range additional {
		if cell != nil && cell.GetColumnId() != "" {
			additionalByID[cell.GetColumnId()] = cell
		}
	}
	usedAdditional := make(map[string]struct{}, len(additionalByID))
	var celActivation *viewcolumns.Activation
	for _, columnID := range p.spec.ColumnIDs {
		var cell *kmgrv1.Cell
		if serverCell := additionalByID[columnID]; serverCell != nil {
			cell = serverCell
			usedAdditional[columnID] = struct{}{}
		} else if program := p.spec.CELPrograms[columnID]; program != nil {
			if celActivation == nil {
				activation := p.celActivationForObject(object)
				celActivation = &activation
			}
			var err error
			cell, err = p.celCellContext(ctx, program, *celActivation)
			if err != nil {
				return nil, false, err
			}
		} else {
			cell = p.builtinCell(object, columnID)
		}
		cells = append(cells, cell)
		visibleText = append(visibleText, cell.GetDisplayText())
	}
	for _, cell := range additional {
		if cell == nil {
			continue
		}
		if _, used := usedAdditional[cell.GetColumnId()]; used {
			continue
		}
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
		return nil, false, nil
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
	}, true, nil
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
	extractorID := p.extractorID(columnID)
	if resourceName, metricColumn := metricColumnResource(p.spec.Resource, extractorID); metricColumn {
		return p.resourceUsageCell(object, columnID, resourceName)
	}
	if cell, supported := p.nativeObjectCell(object, columnID, extractorID); supported {
		return cell
	}
	// Unknown IDs remain visible as missing values. A server Table cell with
	// the same ID is merged before this fallback is reached.
	cell := newNativeCell(columnID)
	setMissingCell(cell, fmt.Sprintf("Column %q is not available for this resource", columnID))
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

func (p *Projector) celActivationForObject(object *unstructured.Unstructured) viewcolumns.Activation {
	isSecret := p.spec.Resource.Group == "" && p.spec.Resource.Version == "v1" &&
		p.spec.Resource.Resource == "secrets"
	return viewcolumns.Activation{
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
	}
}

func (p *Projector) celCellContext(ctx context.Context, program *viewcolumns.Program, activation viewcolumns.Activation) (*kmgrv1.Cell, error) {
	definition := program.Definition()
	missing := definition.Missing
	if missing == "" {
		missing = viewcolumns.DefaultMissing
	}
	cell := &kmgrv1.Cell{
		ColumnId: definition.ID, DisplayText: missing,
		Severity: kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL,
	}
	value, err := program.EvaluateContext(ctx, activation)
	if err != nil {
		if ctxErr := ctx.Err(); ctxErr != nil && errors.Is(err, ctxErr) {
			return nil, ctxErr
		}
		if isMissingCELDataError(err) {
			cell.DisplayText = missing
			cell.Tooltip = "Value is not present on this object"
			cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
		} else {
			cell.Tooltip = err.Error()
			cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_ERROR
		}
		return cell, nil
	}
	cell.DisplayText = value.Display
	if value.Missing {
		cell.Tooltip = "Value is not present on this object"
		cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
		return cell, nil
	}
	switch {
	case value.String != nil:
		cell.TypedValue = &kmgrv1.Cell_StringValue{StringValue: *value.String}
	case value.Quantity != nil:
		cell.TypedValue = quantityCellValue(*value.Quantity, value.Display)
	case value.Integer != nil:
		cell.TypedValue = &kmgrv1.Cell_IntegerValue{IntegerValue: *value.Integer}
	case value.Number != nil:
		cell.TypedValue = &kmgrv1.Cell_NumberValue{NumberValue: *value.Number}
	case value.Boolean != nil:
		cell.TypedValue = &kmgrv1.Cell_BoolValue{BoolValue: *value.Boolean}
	case value.Time != nil:
		cell.TypedValue = &kmgrv1.Cell_TimestampUnixMs{TimestampUnixMs: value.Time.UnixMilli()}
	case value.Duration != nil:
		cell.TypedValue = &kmgrv1.Cell_NumberValue{NumberValue: value.Duration.Seconds()}
	}
	return cell, nil
}

func isMissingCELDataError(err error) bool {
	if err == nil {
		return false
	}
	message := strings.ToLower(err.Error())
	for _, marker := range []string{
		"no such key", "key not found", "field not found", "no such field",
		"does not contain field", "missing field", "unknown field",
	} {
		if strings.Contains(message, marker) {
			return true
		}
	}
	return false
}

func quantityCellValue(value resource.Quantity, display string) *kmgrv1.Cell_QuantityValue {
	return &kmgrv1.Cell_QuantityValue{QuantityValue: &kmgrv1.KubernetesQuantityValue{
		Exact: value.String(), Display: display, SortValue: value.AsApproximateFloat64(),
	}}
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
	if kind == metrics.PodMetrics {
		var pod corev1.Pod
		if err := runtime.DefaultUnstructuredConverter.FromUnstructured(object.Object, &pod); err != nil {
			activation["accountingAvailable"] = false
			activation["requests"] = map[string]any{}
			activation["limits"] = map[string]any{}
			return activation
		}
		requests, limits := metrics.EffectivePodResources(&pod)
		activation["accountingAvailable"] = true
		activation["requests"] = resourceListActivation(requests)
		activation["limits"] = resourceListActivation(limits)
		return activation
	}
	var node corev1.Node
	if err := runtime.DefaultUnstructuredConverter.FromUnstructured(object.Object, &node); err != nil {
		activation["accountingAvailable"] = false
		activation["requests"] = map[string]any{}
		activation["limits"] = map[string]any{}
		activation["allocatable"] = map[string]any{}
		activation["capacity"] = map[string]any{}
		return activation
	}
	activation["accountingAvailable"] = true
	activation["requests"] = map[string]any{}
	activation["limits"] = map[string]any{}
	activation["allocatable"] = resourceListActivation(node.Status.Allocatable)
	activation["capacity"] = resourceListActivation(node.Status.Capacity)
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

	schedulerAllocationOnly := false
	switch kind {
	case metrics.PodMetrics:
		var pod corev1.Pod
		if err := runtime.DefaultUnstructuredConverter.FromUnstructured(object.Object, &pod); err != nil {
			cell.DisplayText = DefaultMissingCell
			cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_ERROR
			cell.Tooltip = "Pod resource accounting could not be calculated"
			return cell
		}
		requests, limits := metrics.EffectivePodResources(&pod)
		request, hasRequest := requests[resourceName]
		limit, hasLimit := limits[resourceName]
		requestValue := optionalQuantity(request, hasRequest)
		limitValue := optionalQuantity(limit, hasLimit)
		if _, exact := exactResourceColumn(p.extractorID(columnID)); exact &&
			!hasRequest && !hasLimit && !measurement.HasValue() {
			cell.DisplayText = DefaultMissingCell
			cell.TypedValue = nil
			cell.Tooltip = "Exact resource " + string(resourceName) + " is not present on this Pod"
			cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
			return cell
		}
		setUsageQuantities(usage, measurement, requestValue, limitValue, nil)
		schedulerAllocationOnly = !measurement.HasValue() &&
			(requestValue != nil || limitValue != nil) &&
			metrics.IsAcceleratorResource(resourceName, p.spec.Accelerators)
		if schedulerAllocationOnly {
			cell.DisplayText = formatRequestLimitDisplay(resourceName, requestValue, limitValue)
		} else {
			cell.DisplayText = formatUsageDisplay(
				resourceName, measurement, requestValue, limitValue, nil,
			)
		}
		cell.Tooltip = formatUsageTooltip(
			resourceName, measurement, requestValue, limitValue, nil, nil,
			p.spec.Now,
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
		allocatableValue := optionalQuantity(allocatable, hasAllocatable)
		capacityValue := optionalQuantity(capacity, hasCapacity)
		if _, exact := exactResourceColumn(p.extractorID(columnID)); exact &&
			!hasAllocatable && !hasCapacity && !measurement.HasValue() {
			cell.DisplayText = DefaultMissingCell
			cell.TypedValue = nil
			cell.Tooltip = "Exact resource " + string(resourceName) + " is not present on this Node"
			cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
			return cell
		}
		setUsageQuantities(usage, measurement, nil, nil, allocatableValue)
		// Node views intentionally do not open Pod metrics just to infer
		// accelerator allocation. When usage is unavailable, the only truthful
		// value is the node's allocatable count; avoid the misleading "— / 8"
		// form and keep it a normal (black) cell.
		schedulerAllocationOnly = !measurement.HasValue() && allocatableValue != nil &&
			metrics.IsOptionalSchedulerResource(resourceName, p.spec.Accelerators)
		if schedulerAllocationOnly {
			cell.DisplayText = formatResourceQuantity(resourceName, allocatableValue)
		} else {
			cell.DisplayText = formatUsageDisplay(
				resourceName, measurement, nil, nil, allocatableValue,
			)
		}
		cell.Tooltip = formatUsageTooltip(
			resourceName, measurement, nil, nil, allocatableValue,
			capacityValue, p.spec.Now,
		)
	}
	if measurement.State == metrics.MeasurementStale && measurement.HasValue() {
		cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_WARNING
	} else if !measurement.HasValue() {
		if schedulerAllocationOnly {
			cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL
		} else {
			cell.Severity = kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
		}
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
		used := quantityNumeric(name, measurement.Quantity)
		value.Used = used
		value.MeasuredAtUnixMs = measurement.Timestamp.UnixMilli()
		value.Provider = measurement.Provider
		value.MeasurementScope = measurement.Scope
	}
	if request != nil {
		value.Requested = numberPointer(quantityNumeric(name, *request))
	}
	if limit != nil {
		value.Limit = numberPointer(quantityNumeric(name, *limit))
	}
	if allocatable != nil {
		value.Capacity = numberPointer(quantityNumeric(name, *allocatable))
	}
	setUsageSortValue(value)
}

func setUsageSortValue(value *kmgrv1.ResourceUsageValue) {
	if value == nil {
		return
	}
	value.SortValue = nil
	switch {
	case value.GetUsageAvailable():
		value.SortValue = numberPointer(value.GetUsed())
	case value.Requested != nil:
		value.SortValue = numberPointer(value.GetRequested())
	case value.Limit != nil:
		value.SortValue = numberPointer(value.GetLimit())
	case value.Capacity != nil:
		value.SortValue = numberPointer(value.GetCapacity())
	}
}

func numberPointer(value float64) *float64 { return &value }

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
	resourceName corev1.ResourceName,
	measurement metrics.Measurement,
	request, limit, allocatable *resource.Quantity,
) string {
	parts := make([]string, 0, 3)
	if measurement.HasValue() {
		parts = append(parts, formatResourceQuantity(resourceName, &measurement.Quantity))
	} else {
		parts = append(parts, DefaultMissingCell)
	}
	if allocatable != nil {
		parts = append(parts, formatResourceQuantity(resourceName, allocatable))
		return strings.Join(parts, " / ")
	}
	parts = append(parts, formatResourceQuantity(resourceName, request), formatResourceQuantity(resourceName, limit))
	return strings.Join(parts, " / ")
}

func formatRequestLimitDisplay(
	resourceName corev1.ResourceName,
	request, limit *resource.Quantity,
) string {
	return strings.Join([]string{
		formatResourceQuantity(resourceName, request),
		formatResourceQuantity(resourceName, limit),
	}, " / ")
}

func formatUsageTooltip(
	resourceName corev1.ResourceName,
	measurement metrics.Measurement,
	request, limit, allocatable, capacity *resource.Quantity,
	now time.Time,
) string {
	parts := make([]string, 0, 7)
	if resourceName != "" {
		parts = append(parts, "Resource: "+string(resourceName))
	}
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
			if !now.IsZero() && !now.Before(measurement.Timestamp) {
				parts = append(parts, "Metric age: "+formatAge(now.Sub(measurement.Timestamp)))
			}
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

// sortRowsContext uses the same stable ordering as slices.SortStableFunc, but
// checks cancellation during comparisons so an obsolete large sort does not
// continue after its projection revision has been superseded.
func sortRowsContext(
	ctx context.Context,
	rows []*kmgrv1.ResourceRow,
	compare func(left, right *kmgrv1.ResourceRow) int,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	var canceled atomic.Bool
	slices.SortStableFunc(rows, func(left, right *kmgrv1.ResourceRow) int {
		if canceled.Load() {
			return 0
		}
		select {
		case <-ctx.Done():
			canceled.Store(true)
			return 0
		default:
			return compare(left, right)
		}
	})
	if canceled.Load() {
		return ctx.Err()
	}
	return nil
}

func defaultColumns(resource ResourceType) []string {
	columns := make([]string, 0, 12)
	if resource.Namespaced {
		columns = append(columns, "namespace")
	}
	columns = append(columns, "name")
	if native := viewcolumns.DefaultNativeColumns(
		resource.Group, resource.Version, resource.Resource,
	); len(native) != 0 {
		return append(columns, native...)
	}
	return append(columns, "age")
}

func statusText(object *unstructured.Unstructured) string {
	if object == nil {
		return "Active"
	}
	kind := strings.ToLower(object.GetKind())
	if kind == "pod" {
		return podStatusText(object)
	}
	if object.GetDeletionTimestamp() != nil {
		return nodeSchedulingStatus(object, "Terminating", kind == "node")
	}
	if kind == "node" {
		status := "Active"
		conditions := nestedSliceNoCopy(object.Object, "status", "conditions")
		for _, raw := range conditions {
			condition, _ := raw.(map[string]any)
			if condition["type"] == "Ready" {
				if condition["status"] == "True" {
					status = "Ready"
				} else {
					status = "NotReady"
				}
				break
			}
		}
		return nodeSchedulingStatus(object, status, true)
	}
	if value, found, _ := unstructured.NestedString(object.Object, "status", "phase"); found && value != "" {
		return value
	}
	if kind == "job" {
		return jobStatusText(object)
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

func jobStatusText(object *unstructured.Unstructured) string {
	for _, raw := range nestedSliceNoCopy(object.Object, "status", "conditions") {
		condition, _ := raw.(map[string]any)
		if condition["status"] != "True" {
			continue
		}
		switch condition["type"] {
		case "Complete":
			return "Complete"
		case "Failed":
			return "Failed"
		case "Suspended":
			return "Suspended"
		}
	}
	if suspended, _, _ := unstructured.NestedBool(object.Object, "spec", "suspend"); suspended {
		return "Suspended"
	}
	if active, _, _ := unstructured.NestedInt64(object.Object, "status", "active"); active > 0 {
		return "Running"
	}
	succeeded, _, _ := unstructured.NestedInt64(object.Object, "status", "succeeded")
	completions, found, _ := unstructured.NestedInt64(object.Object, "spec", "completions")
	if !found {
		completions = 1
	}
	if succeeded >= completions {
		return "Complete"
	}
	if failed, _, _ := unstructured.NestedInt64(object.Object, "status", "failed"); failed > 0 {
		return "Failed"
	}
	return "Pending"
}

func nodeSchedulingStatus(
	object *unstructured.Unstructured,
	status string,
	isNode bool,
) string {
	if !isNode {
		return status
	}
	unschedulable, found, err := unstructured.NestedBool(
		object.Object, "spec", "unschedulable",
	)
	if err == nil && found && unschedulable {
		return status + ",Unschedulable"
	}
	return status
}

func statusSeverity(status string) kmgrv1.CellSeverity {
	folded := strings.ToLower(status)
	switch {
	case strings.Contains(folded, "fail"), strings.Contains(folded, "error"), strings.Contains(folded, "crash"), strings.Contains(folded, "notready"):
		return kmgrv1.CellSeverity_CELL_SEVERITY_ERROR
	case strings.Contains(folded, "pending"), strings.Contains(folded, "progress"), strings.Contains(folded, "terminating"), strings.Contains(folded, "unknown"), strings.Contains(folded, "unschedulable"):
		return kmgrv1.CellSeverity_CELL_SEVERITY_WARNING
	default:
		return kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL
	}
}

// presentationForObject preserves the generic status mapping for arbitrary
// resources while applying the richer Pod state palette used by the native
// table.
func presentationForObject(object *unstructured.Unstructured) (string, kmgrv1.CellSeverity) {
	status := statusText(object)
	if object != nil && strings.EqualFold(object.GetKind(), "pod") {
		return podPresentationWithStatus(object, status)
	}
	return status, statusSeverity(status)
}

// podPresentation is the single authority for both Status and Ready styling.
// Keeping these columns on one state classification prevents combinations
// such as a blue Terminating status with a yellow Ready count, or a red
// liveness failure beside a merely yellow Ready count.
func podPresentation(object *unstructured.Unstructured) (string, kmgrv1.CellSeverity) {
	return podPresentationWithStatus(object, podStatusText(object))
}

func podPresentationWithStatus(
	object *unstructured.Unstructured,
	status string,
) (string, kmgrv1.CellSeverity) {
	folded := strings.ToLower(status)
	ready, total := readyContainers(object)
	phase := strings.ToLower(nestedString(object.Object, "status", "phase"))
	switch {
	case object.GetDeletionTimestamp() != nil || strings.Contains(folded, "terminating"):
		return status, kmgrv1.CellSeverity_CELL_SEVERITY_TERMINATING
	case podCompleted(object) || folded == "succeeded" || folded == "completed":
		return status, kmgrv1.CellSeverity_CELL_SEVERITY_MUTED
	case podStatusIsError(folded) || phase == "failed":
		return status, kmgrv1.CellSeverity_CELL_SEVERITY_ERROR
	case podStatusIsInitializing(folded):
		return status, kmgrv1.CellSeverity_CELL_SEVERITY_INFO
	case podStatusIsPending(folded) || phase == "pending" || strings.Contains(folded, "unknown"):
		return status, kmgrv1.CellSeverity_CELL_SEVERITY_WARNING
	case phase == "running" && total > 0 && ready != total:
		return status, kmgrv1.CellSeverity_CELL_SEVERITY_ERROR
	default:
		return status, kmgrv1.CellSeverity_CELL_SEVERITY_NORMAL
	}
}

func podStatusText(object *unstructured.Unstructured) string {
	if object.GetDeletionTimestamp() != nil {
		return "Terminating"
	}
	statusReason := nestedString(object.Object, "status", "reason")
	if statusReason == "NodeLost" {
		return "Unknown"
	}

	// Init containers take precedence over the ordinary phase, matching the
	// useful diagnostic state shown by k9s without converting the whole object.
	initStatuses := nestedSliceNoCopy(object.Object, "status", "initContainerStatuses")
	initCount := len(nestedSliceNoCopy(object.Object, "spec", "initContainers"))
	for index, raw := range initStatuses {
		status, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		state, _ := nestedAnyMap(status, "state")
		if waiting, ok := nestedAnyMap(state, "waiting"); ok {
			if reason, _ := waiting["reason"].(string); reason != "" && reason != "PodInitializing" {
				return "Init:" + reason
			}
		}
		if terminated, ok := nestedAnyMap(state, "terminated"); ok {
			exitCode := nestedInt64Value(terminated["exitCode"])
			if exitCode != 0 {
				if reason, _ := terminated["reason"].(string); reason != "" {
					return "Init:" + reason
				}
				return fmt.Sprintf("Init:ExitCode:%d", exitCode)
			}
			continue
		}
		if initCount > 0 {
			return fmt.Sprintf("Init:%d/%d", index, initCount)
		}
	}

	containerStatuses := nestedSliceNoCopy(object.Object, "status", "containerStatuses")
	hasRunning := false
	allReady := len(containerStatuses) > 0
	for _, raw := range containerStatuses {
		status, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		state, _ := nestedAnyMapValue(status["state"])
		if waiting, ok := nestedAnyMap(state, "waiting"); ok {
			if reason, _ := waiting["reason"].(string); reason != "" {
				return reason
			}
		}
		if terminated, ok := nestedAnyMap(state, "terminated"); ok {
			if reason, _ := terminated["reason"].(string); reason != "" {
				return reason
			}
			if exitCode := nestedInt64Value(terminated["exitCode"]); exitCode != 0 {
				return fmt.Sprintf("ExitCode:%d", exitCode)
			}
		}
		if running := state["running"]; running != nil {
			hasRunning = true
		}
		ready, _ := status["ready"].(bool)
		allReady = allReady && ready
	}

	phase := nestedString(object.Object, "status", "phase")
	if statusReason != "" && (phase == "Failed" || phase == "Unknown") {
		return statusReason
	}
	if phase == "Succeeded" {
		if hasRunning {
			if allReady {
				return "Running"
			}
			return "NotReady"
		}
		return "Succeeded"
	}
	if phase == "Running" && len(containerStatuses) > 0 && !allReady && !hasRunning {
		return "NotReady"
	}
	if phase != "" {
		return phase
	}
	if statusReason != "" {
		return statusReason
	}
	return "Pending"
}

func nestedAnyMap(value map[string]any, key string) (map[string]any, bool) {
	if value == nil {
		return nil, false
	}
	return nestedAnyMapValue(value[key])
}

func nestedAnyMapValue(value any) (map[string]any, bool) {
	result, ok := value.(map[string]any)
	return result, ok
}

func nestedInt64Value(value any) int64 {
	switch value := value.(type) {
	case int:
		return int64(value)
	case int32:
		return int64(value)
	case int64:
		return value
	case uint:
		return int64(value)
	case uint32:
		return int64(value)
	case uint64:
		if value > uint64(math.MaxInt64) {
			return math.MaxInt64
		}
		return int64(value)
	case float64:
		return int64(value)
	default:
		return 0
	}
}

func podCompleted(object *unstructured.Unstructured) bool {
	if object == nil {
		return false
	}
	return strings.EqualFold(nestedString(object.Object, "status", "phase"), "Succeeded")
}

func podStatusIsError(status string) bool {
	for _, token := range []string{
		"fail", "error", "oomkilled", "evicted", "crashloop", "notready",
		"createcontainererror", "runcontainererror", "exitcode:", "liveness",
	} {
		if strings.Contains(status, token) {
			return true
		}
	}
	return false
}

func podStatusIsInitializing(status string) bool {
	return strings.Contains(status, "init:") || strings.Contains(status, "initializ") ||
		strings.Contains(status, "containercreating")
}

func podStatusIsPending(status string) bool {
	return strings.Contains(status, "pending") || strings.Contains(status, "scheduling") ||
		strings.Contains(status, "imagepull")
}

func nodeRoles(object *unstructured.Unstructured) []string {
	const prefix = "node-role.kubernetes.io/"
	roles := make([]string, 0)
	for key := range object.GetLabels() {
		role, found := strings.CutPrefix(key, prefix)
		if found && role != "" {
			roles = append(roles, role)
		}
	}
	slices.Sort(roles)
	return roles
}

func readyContainers(object *unstructured.Unstructured) (ready, total int) {
	statuses := nestedSliceNoCopy(object.Object, "status", "containerStatuses")
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
		containers := nestedSliceNoCopy(object.Object, "spec", "containers")
		total = len(containers)
	}
	return ready, total
}

func restartCount(object *unstructured.Unstructured) int64 {
	statuses := nestedSliceNoCopy(object.Object, "status", "containerStatuses")
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

// nestedSliceNoCopy returns a read-only view of a JSON slice. Projector inputs
// are immutable UID-store snapshots or immutable WATCH values, and every
// caller only inspects scalar fields before returning detached protobuf
// cells. Keeping that contract here avoids NestedSlice's recursive copy for
// every projected row without retaining raw-object aliases in projected state.
func nestedSliceNoCopy(object map[string]any, fields ...string) []any {
	value, found, err := unstructured.NestedFieldNoCopy(object, fields...)
	if err != nil || !found {
		return nil
	}
	result, ok := value.([]any)
	if !ok {
		return nil
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
	case *kmgrv1.Cell_IntegerValue:
		if rightValue, ok := right.GetTypedValue().(*kmgrv1.Cell_IntegerValue); ok {
			return cmp.Compare(leftValue.IntegerValue, rightValue.IntegerValue)
		}
	case *kmgrv1.Cell_QuantityValue:
		if rightValue, ok := right.GetTypedValue().(*kmgrv1.Cell_QuantityValue); ok {
			return compareQuantityValues(leftValue.QuantityValue, rightValue.QuantityValue)
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
			return compareUsageValues(
				leftValue.Usage,
				rightValue.Usage,
				nullsFirst,
			)
		}
	}
	return strings.Compare(left.GetDisplayText(), right.GetDisplayText())
}

func compareQuantityValues(left, right *kmgrv1.KubernetesQuantityValue) int {
	leftQuantity, leftErr := resource.ParseQuantity(left.GetExact())
	rightQuantity, rightErr := resource.ParseQuantity(right.GetExact())
	if leftErr == nil && rightErr == nil {
		return leftQuantity.Cmp(rightQuantity)
	}
	// Invalid quantities cannot be emitted by the current compiler, but older
	// or newer peers may send values this process cannot parse. Keep ordering
	// deterministic without trusting an approximate hint as authoritative.
	return strings.Compare(left.GetExact(), right.GetExact())
}

func compareUsageValues(
	left, right *kmgrv1.ResourceUsageValue,
	nullsFirst bool,
) int {
	leftValue, leftAvailable := usageSortValue(left)
	rightValue, rightAvailable := usageSortValue(right)
	if leftAvailable != rightAvailable {
		leftMissing := !leftAvailable
		if leftMissing == nullsFirst {
			return -1
		}
		return 1
	}
	return cmp.Compare(leftValue, rightValue)
}

func usageSortValue(value *kmgrv1.ResourceUsageValue) (float64, bool) {
	if value == nil || value.SortValue == nil {
		return 0, false
	}
	return value.GetSortValue(), true
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
