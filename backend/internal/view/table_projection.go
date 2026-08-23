package view

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	viewfilter "github.com/charlie0129/kmgr/backend/internal/view/filter"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type projectedTableColumn struct {
	index      int
	definition *kmgrv1.ResourceColumnSchema
	tableType  string
	format     string
}

// tableObjectPolicy keeps the common CRD/aggregated Table path compact. Server
// cells already carry printer output; PartialObjectMetadata supplies the UID,
// name, namespace, labels, timestamps, and resourceVersion needed by native
// identity columns and local metadata filters. Any dependency on status,
// arbitrary fields, CEL, or another object-backed extractor selects the full
// representation before the LIST/WATCH is opened.
func tableObjectPolicy(projector *Projector) metav1.IncludeObjectPolicy {
	if projector == nil || projector.filter == nil {
		return metav1.IncludeObject
	}
	for _, term := range projector.filter.Terms() {
		switch term.Kind {
		case viewfilter.Text, viewfilter.Namespace, viewfilter.Name, viewfilter.Label,
			viewfilter.NativeLabel:
			// Bare text reads projected cells, including server Table cells; these
			// terms use metadata or those projected cells.
		case viewfilter.NativeField:
			// Metadata-only native field selectors are checked below.
		case viewfilter.Field:
			// A local field term is metadata-safe when its path is covered by
			// PartialObjectMetadata; the path check below handles the rest.
		default:
			return metav1.IncludeObject
		}
	}
	// PartialObjectMetadata retains the complete metadata object, so native
	// field selectors restricted to metadata can still be checked locally
	// without promoting a large Table stream to full objects. Kubernetes field
	// selectors over spec/status (for example spec.nodeName) still require the
	// raw representation.
	for _, path := range projector.filter.FieldPaths() {
		if !strings.HasPrefix(path, "metadata.") {
			return metav1.IncludeObject
		}
	}
	for _, displayID := range projector.spec.ColumnIDs {
		if !metadataTableColumn(projector, displayID) {
			return metav1.IncludeObject
		}
	}
	for _, descriptor := range projector.spec.Sort {
		if !metadataTableColumn(projector, descriptor.ColumnID) {
			return metav1.IncludeObject
		}
	}
	return metav1.IncludeMetadata
}

func metadataTableColumn(projector *Projector, displayID string) bool {
	if projector == nil || projector.spec.CELPrograms[displayID] != nil {
		return false
	}
	if extractor := projector.spec.ColumnExtractors[displayID]; extractor.Source != "" {
		if extractor.Source != "builtin" {
			return false
		}
		displayID = extractor.Value
	} else if strings.HasPrefix(displayID, "server-") {
		return true
	}
	switch displayID {
	case "namespace", "name", "labels", "age", "created", "resourceVersion":
		return true
	default:
		return false
	}
}

func projectTableSchema(columns []metav1.TableColumnDefinition) (*kmgrv1.ViewSchema, []projectedTableColumn) {
	if len(columns) == 0 {
		return nil, nil
	}
	definitions := make([]*kmgrv1.ResourceColumnSchema, 0, len(columns))
	projected := make([]projectedTableColumn, 0, len(columns))
	occurrences := make(map[string]int)
	for index, column := range columns {
		if isNativeIdentityTableColumn(column.Name) {
			continue
		}
		occurrences[column.Name]++
		id := serverTableColumnID(column.Name, occurrences[column.Name])
		resultType, alignment := serverTableResultType(column)
		definition := &kmgrv1.ResourceColumnSchema{
			Id: id, Title: strings.TrimSpace(column.Name), ResultType: resultType,
			Alignment: alignment, Width: serverTableColumnWidth(column, resultType),
			DefaultVisible: column.Priority == 0, Priority: column.Priority,
			Format: column.Format, Description: column.Description,
		}
		if definition.Title == "" {
			definition.Title = id
		}
		definitions = append(definitions, definition)
		projected = append(projected, projectedTableColumn{
			index: index, definition: definition, tableType: strings.ToLower(column.Type), format: column.Format,
		})
	}
	encoded, _ := json.Marshal(columns)
	revision := fmt.Sprintf("sha256:%x", sha256.Sum256(encoded))
	return &kmgrv1.ViewSchema{Columns: definitions, ServerTable: true, Revision: revision}, projected
}

func isNativeIdentityTableColumn(name string) bool {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "name", "namespace", "age":
		return true
	default:
		return false
	}
}

func serverTableColumnID(name string, occurrence int) string {
	encoded := base64.RawURLEncoding.EncodeToString([]byte(strings.TrimSpace(name)))
	if encoded == "" {
		encoded = "column"
	}
	id := "server-" + encoded
	if occurrence > 1 {
		id += "-" + strconv.Itoa(occurrence)
	}
	return id
}

func serverTableResultType(column metav1.TableColumnDefinition) (string, string) {
	typeName := strings.ToLower(column.Type)
	format := strings.ToLower(column.Format)
	switch {
	case format == "quantity":
		return "quantity", "trailing"
	case typeName == "integer":
		return "integer", "trailing"
	case typeName == "number":
		return "number", "trailing"
	case typeName == "boolean":
		return "boolean", "center"
	case typeName == "date" || typeName == "timestamp" || format == "date-time":
		return "timestamp", "trailing"
	default:
		return "string", "leading"
	}
}

func serverTableColumnWidth(column metav1.TableColumnDefinition, resultType string) float64 {
	switch resultType {
	case "boolean":
		return 90
	case "integer", "number":
		return 110
	case "timestamp":
		return 120
	case "quantity":
		return 130
	default:
		return float64(min(max(len(column.Name)*9+50, 100), 320))
	}
}

func projectTableCells(
	columns []projectedTableColumn,
	values []any,
	now time.Time,
) []*kmgrv1.Cell {
	result := make([]*kmgrv1.Cell, 0, len(columns))
	for _, column := range columns {
		var value any
		if column.index >= 0 && column.index < len(values) {
			value = values[column.index]
		}
		result = append(result, projectTableCell(column, value, now))
	}
	return result
}

func projectTableCell(column projectedTableColumn, value any, now time.Time) *kmgrv1.Cell {
	cell := newNativeCell(column.definition.GetId())
	if value == nil {
		setMissingCell(cell, "The apiserver returned no value for this Table column")
		return cell
	}
	typeName := strings.ToLower(column.definition.GetResultType())
	switch typeName {
	case "integer":
		integer, ok := tableInteger(value)
		if !ok {
			setMissingCell(cell, fmt.Sprintf("The apiserver returned %T for an integer Table column", value))
			return cell
		}
		setNativeInteger(cell, integer)
	case "number":
		number, ok := tableNumber(value)
		if !ok {
			setMissingCell(cell, fmt.Sprintf("The apiserver returned %T for a numeric Table column", value))
			return cell
		}
		cell.DisplayText = strconv.FormatFloat(number, 'g', -1, 64)
		cell.TypedValue = &kmgrv1.Cell_NumberValue{NumberValue: number}
	case "boolean":
		boolean, ok := value.(bool)
		if !ok {
			setMissingCell(cell, fmt.Sprintf("The apiserver returned %T for a boolean Table column", value))
			return cell
		}
		setNativeBoolean(cell, boolean)
	case "quantity":
		quantity, err := resource.ParseQuantity(fmt.Sprint(value))
		if err != nil {
			setMissingCell(cell, "The apiserver returned an invalid Kubernetes quantity")
			return cell
		}
		cell.DisplayText = quantity.String()
		cell.TypedValue = quantityCellValue(quantity, cell.DisplayText)
	case "timestamp":
		valueTime, ok := tableTime(value)
		if !ok {
			setMissingCell(cell, "The apiserver returned an invalid Table timestamp")
			return cell
		}
		setNativeTimestamp(cell, valueTime, now, true)
	default:
		setNativeString(cell, fmt.Sprint(value))
	}
	return cell
}

func tableInteger(value any) (int64, bool) {
	switch typed := value.(type) {
	case int64:
		return typed, true
	case int32:
		return int64(typed), true
	case int:
		return int64(typed), true
	case float64:
		integer := int64(typed)
		return integer, float64(integer) == typed
	case json.Number:
		integer, err := typed.Int64()
		return integer, err == nil
	case string:
		integer, err := strconv.ParseInt(typed, 10, 64)
		return integer, err == nil
	default:
		return 0, false
	}
}

func tableNumber(value any) (float64, bool) {
	switch typed := value.(type) {
	case float64:
		return typed, true
	case float32:
		return float64(typed), true
	case int64:
		return float64(typed), true
	case int:
		return float64(typed), true
	case json.Number:
		number, err := typed.Float64()
		return number, err == nil
	case string:
		number, err := strconv.ParseFloat(typed, 64)
		return number, err == nil
	default:
		return 0, false
	}
}

func tableTime(value any) (time.Time, bool) {
	switch typed := value.(type) {
	case time.Time:
		return typed, !typed.IsZero()
	case metav1.Time:
		return typed.Time, !typed.IsZero()
	case string:
		parsed, err := time.Parse(time.RFC3339Nano, typed)
		return parsed, err == nil
	default:
		return time.Time{}, false
	}
}
