// Package config loads kmgr's versioned, user-editable application
// configuration. Kubernetes credentials and runtime object caches never belong
// here.
package config

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"sync"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	"github.com/charlie0129/kmgr/backend/internal/view/columns"
	yamlv2 "go.yaml.in/yaml/v2"
	corev1 "k8s.io/api/core/v1"
	k8svalidation "k8s.io/apimachinery/pkg/util/validation"
	"sigs.k8s.io/yaml"
)

const (
	ColumnsAPIVersion  = "kmgr.chlc.cc/v1alpha1"
	DefaultColumnsFile = "columns.yaml"
)

type ColumnsDocument struct {
	APIVersion     string                   `json:"apiVersion" yaml:"apiVersion"`
	CELEnvironment string                   `json:"celEnvironment" yaml:"celEnvironment"`
	Views          []ViewConfiguration      `json:"views,omitempty" yaml:"views,omitempty"`
	Accelerators   AcceleratorConfiguration `json:"accelerators,omitempty" yaml:"accelerators,omitempty"`
}

type ViewConfiguration struct {
	Match   ResourceMatch         `json:"match" yaml:"match"`
	Columns []ColumnConfiguration `json:"columns" yaml:"columns"`
}

type ResourceMatch struct {
	Group    string `json:"group,omitempty" yaml:"group,omitempty"`
	Version  string `json:"version" yaml:"version"`
	Resource string `json:"resource" yaml:"resource"`
}

func (m ResourceMatch) key() resourceKey {
	return resourceKey{group: m.Group, version: m.Version, resource: m.Resource}
}

type ColumnConfiguration struct {
	ID         string             `json:"id" yaml:"id"`
	Title      string             `json:"title" yaml:"title"`
	Source     string             `json:"source" yaml:"source"`
	Expression string             `json:"expression,omitempty" yaml:"expression,omitempty"`
	Value      string             `json:"value,omitempty" yaml:"value,omitempty"`
	Type       columns.ResultType `json:"type" yaml:"type"`
	Alignment  string             `json:"alignment,omitempty" yaml:"alignment,omitempty"`
	Missing    string             `json:"missing,omitempty" yaml:"missing,omitempty"`
	Width      float64            `json:"width,omitempty" yaml:"width,omitempty"`
	ListJoiner string             `json:"listJoiner,omitempty" yaml:"listJoiner,omitempty"`
	Enabled    *bool              `json:"enabled,omitempty" yaml:"enabled,omitempty"`
}

func (c ColumnConfiguration) IsEnabled() bool { return c.Enabled == nil || *c.Enabled }

type AcceleratorConfiguration struct {
	AutoDetectSuffixes []string                               `json:"autoDetectSuffixes,omitempty" yaml:"autoDetectSuffixes,omitempty"`
	Resources          map[string]AcceleratorResourceSettings `json:"resources,omitempty" yaml:"resources,omitempty"`
}

type AcceleratorResourceSettings struct {
	DisplayName string `json:"displayName,omitempty" yaml:"displayName,omitempty"`
}

type CompiledColumns struct {
	document       ColumnsDocument
	version        string
	views          map[resourceKey]compiledView
	needsMigration bool
	canonicalData  []byte
}

type compiledView struct {
	configuration ViewConfiguration
	programs      map[string]*columns.Program
	extractors    map[string]columns.Extractor
}

type resourceKey struct {
	group    string
	version  string
	resource string
}

var builtinExtractors = func() map[string]columns.ResultType {
	result := make(map[string]columns.ResultType, len(columns.NativeExtractorDefinitions))
	for value, definition := range columns.NativeExtractorDefinitions {
		result[value] = definition.Type
	}
	return result
}()

var metricExtractors = map[string]struct{}{
	"cpu": {}, "memory": {}, "ephemeral-storage": {},
}

func validateExtractor(key resourceKey, definition ColumnConfiguration) (string, error) {
	value := strings.TrimSpace(definition.Value)
	if definition.Source == "builtin" {
		if definition.ListJoiner != "" || definition.Missing != "" {
			return "", fmt.Errorf("column %q source %q does not allow CEL-only missing/listJoiner options", definition.ID, definition.Source)
		}
		canonical, known := builtinValue(value)
		if !known {
			return "", fmt.Errorf("column %q has unsupported builtin value %q", definition.ID, definition.Value)
		}
		if definition.Type != builtinExtractors[canonical] {
			return "", fmt.Errorf(
				"column %q builtin value %q requires type %q, got %q",
				definition.ID, definition.Value, builtinExtractors[canonical], definition.Type,
			)
		}
		if strings.HasPrefix(value, "pod.") && !isCoreResource(key, "pods") {
			return "", fmt.Errorf("column %q builtin value %q is only supported for core/v1 Pods", definition.ID, definition.Value)
		}
		if !builtinSupportedForResource(key, canonical) {
			return "", fmt.Errorf("column %q builtin value %q is not supported for %s/%s/%s", definition.ID, definition.Value, key.group, key.version, key.resource)
		}
		return canonical, nil
	}

	if definition.ListJoiner != "" || definition.Missing != "" {
		return "", fmt.Errorf("column %q source %q does not allow CEL-only missing/listJoiner options", definition.ID, definition.Source)
	}
	if strings.HasPrefix(value, "pod.") && !isCoreResource(key, "pods") {
		return "", fmt.Errorf("column %q metric value %q is only supported for core/v1 Pods", definition.ID, definition.Value)
	}
	if strings.HasPrefix(value, "node.") && !isCoreResource(key, "nodes") {
		return "", fmt.Errorf("column %q metric value %q is only supported for core/v1 Nodes", definition.ID, definition.Value)
	}
	canonical, known := metricValue(value)
	if !known {
		return "", fmt.Errorf("column %q has unsupported metric value %q", definition.ID, definition.Value)
	}
	if definition.Type != columns.ResultResourceUsage {
		return "", fmt.Errorf(
			"column %q metric value %q requires type %q, got %q",
			definition.ID, definition.Value, columns.ResultResourceUsage, definition.Type,
		)
	}
	if err := validateMetricResource(key, canonical); err != nil {
		return "", fmt.Errorf("column %q: %w", definition.ID, err)
	}
	return canonical, nil
}

func builtinValue(value string) (string, bool) {
	_, known := builtinExtractors[value]
	return value, known
}

func builtinSupportedForResource(key resourceKey, value string) bool {
	return columns.NativeExtractorSupports(value, key.group, key.version, key.resource)
}

func metricValue(value string) (string, bool) {
	if _, known := metricExtractors[value]; known {
		return value, true
	}
	if exact, found := strings.CutPrefix(value, "resource:"); found && strings.TrimSpace(exact) != "" {
		if problems := k8svalidation.IsQualifiedName(exact); len(problems) != 0 {
			return "", false
		}
		return "resource:" + exact, true
	}
	return "", false
}

func validateMetricResource(key resourceKey, value string) error {
	if !isCoreResource(key, "pods") && !isCoreResource(key, "nodes") {
		return fmt.Errorf("metric value %q is only supported for core/v1 Pods and Nodes", value)
	}
	if key.resource == "pods" {
		switch value {
		case "cpu", "memory", "ephemeral-storage":
			return nil
		}
		if strings.HasPrefix(value, "resource:") {
			return nil
		}
		return fmt.Errorf("metric value %q is not supported for Pods", value)
	}
	return nil
}

func isCoreResource(key resourceKey, resource string) bool {
	return key.group == "" && key.version == "v1" && key.resource == resource
}

func DefaultColumnsPath() (string, error) {
	configurationDirectory, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("resolve user application support directory: %w", err)
	}
	return filepath.Join(configurationDirectory, "kmgr", DefaultColumnsFile), nil
}

// ParseColumns validates the document's fields and compiles every CEL program
// once. The apiVersion value is metadata: a non-empty value is accepted when
// the rest of the document is current-compatible, and the in-memory document
// is canonicalized to ColumnsAPIVersion. An invalid edit never becomes a
// partially active configuration.
func ParseColumns(data []byte, compiler *columns.Compiler) (*CompiledColumns, error) {
	if compiler == nil {
		return nil, errors.New("CEL compiler must not be nil")
	}
	document, raw, err := decodeColumnsDocument(data)
	if err != nil {
		return nil, fmt.Errorf("parse columns configuration: %w", err)
	}
	sourceAPIVersion := document.APIVersion
	if strings.TrimSpace(document.APIVersion) == "" {
		return nil, errors.New("columns apiVersion must not be empty")
	}
	if document.CELEnvironment != columns.EnvironmentVersion {
		return nil, fmt.Errorf(
			"unsupported CEL environment %q; expected %q",
			document.CELEnvironment, columns.EnvironmentVersion,
		)
	}
	if err := validateAcceleratorConfiguration(document.Accelerators); err != nil {
		return nil, err
	}

	document.APIVersion = ColumnsAPIVersion
	compiled := &CompiledColumns{
		document:       cloneDocument(document),
		version:        digestColumnsData(data),
		needsMigration: sourceAPIVersion != ColumnsAPIVersion,
		views:          make(map[resourceKey]compiledView, len(document.Views)),
	}
	for viewIndex, view := range document.Views {
		key := view.Match.key()
		if strings.TrimSpace(key.version) == "" || strings.TrimSpace(key.resource) == "" {
			return nil, fmt.Errorf("views[%d].match requires version and resource", viewIndex)
		}
		if _, duplicate := compiled.views[key]; duplicate {
			return nil, fmt.Errorf(
				"duplicate view match %s/%s/%s", key.group, key.version, key.resource,
			)
		}
		entry := compiledView{
			configuration: cloneView(view),
			programs:      make(map[string]*columns.Program),
			extractors:    make(map[string]columns.Extractor),
		}
		seenIDs := make(map[string]struct{}, len(view.Columns))
		for columnIndex, definition := range view.Columns {
			if strings.TrimSpace(definition.ID) == "" {
				return nil, fmt.Errorf("views[%d].columns[%d].id must not be empty", viewIndex, columnIndex)
			}
			if strings.TrimSpace(definition.Title) == "" {
				return nil, fmt.Errorf("views[%d].columns[%d].title must not be empty", viewIndex, columnIndex)
			}
			if _, duplicate := seenIDs[definition.ID]; duplicate {
				return nil, fmt.Errorf("view %s/%s/%s has duplicate column ID %q", key.group, key.version, key.resource, definition.ID)
			}
			seenIDs[definition.ID] = struct{}{}
			if !validColumnWidth(definition.Width) {
				return nil, fmt.Errorf("column %q width must be finite and non-negative", definition.ID)
			}
			switch definition.Alignment {
			case "", "leading", "center", "trailing":
			default:
				return nil, fmt.Errorf("column %q has unsupported alignment %q", definition.ID, definition.Alignment)
			}
			switch definition.Source {
			case "cel":
				if strings.TrimSpace(definition.Value) != "" {
					return nil, fmt.Errorf("column %q source %q does not allow value", definition.ID, definition.Source)
				}
				program, err := compiler.Compile(columns.Definition{
					ID: definition.ID, Title: definition.Title,
					Expression: definition.Expression, ResultType: definition.Type,
					Missing: definition.Missing, ListJoiner: definition.ListJoiner,
				})
				if err != nil {
					return nil, fmt.Errorf("view %s/%s/%s: %w", key.group, key.version, key.resource, err)
				}
				entry.programs[definition.ID] = program
			case "builtin", "metric":
				if strings.TrimSpace(definition.Expression) != "" {
					return nil, fmt.Errorf("column %q source %q does not allow expression", definition.ID, definition.Source)
				}
				if strings.TrimSpace(definition.Value) == "" {
					return nil, fmt.Errorf("column %q source %q requires value", definition.ID, definition.Source)
				}
				extractor, err := validateExtractor(key, definition)
				if err != nil {
					return nil, err
				}
				entry.extractors[definition.ID] = columns.Extractor{
					Source: definition.Source, Value: extractor,
				}
			case "server":
				if strings.TrimSpace(definition.Expression) != "" || strings.TrimSpace(definition.Value) != "" {
					return nil, fmt.Errorf("column %q source %q does not allow expression or value", definition.ID, definition.Source)
				}
				if definition.Missing != "" || definition.ListJoiner != "" {
					return nil, fmt.Errorf("column %q source %q does not allow CEL-only missing/listJoiner options", definition.ID, definition.Source)
				}
				switch definition.Type {
				case columns.ResultString, columns.ResultInteger, columns.ResultNumber,
					columns.ResultBoolean, columns.ResultQuantity, columns.ResultTimestamp,
					columns.ResultDuration:
				default:
					return nil, fmt.Errorf("column %q has unsupported server result type %q", definition.ID, definition.Type)
				}
			case "":
				return nil, fmt.Errorf("column %q source must not be empty", definition.ID)
			default:
				return nil, fmt.Errorf("column %q has unsupported source %q", definition.ID, definition.Source)
			}
		}
		compiled.views[key] = entry
	}
	if compiled.needsMigration {
		compiled.canonicalData, err = marshalMigratedColumns(raw)
		if err != nil {
			return nil, fmt.Errorf("encode migrated columns configuration: %w", err)
		}
		// The active document is the canonical migrated representation, so its
		// content identity must be derived from those bytes even when callers use
		// ParseColumns directly without a ColumnManager persistence boundary.
		compiled.version = digestColumnsData(compiled.canonicalData)
	}
	return compiled, nil
}

// marshalMigratedColumns emits the canonical metadata while retaining every
// validated field that was actually present in the source document. Encoding
// the decoded model here would apply its `omitempty` tags and could silently
// erase meaningful values such as an explicit width of 0 or an empty list of
// accelerator suffixes. The raw JSON-compatible tree has already passed the
// strict field/type walk, so changing only apiVersion is the minimal safe
// migration.
func marshalMigratedColumns(raw any) ([]byte, error) {
	root, ok := raw.(map[string]any)
	if !ok {
		return nil, errors.New("columns document root is not an object")
	}
	root["apiVersion"] = ColumnsAPIVersion
	return json.Marshal(root)
}

func digestColumnsData(data []byte) string {
	return fmt.Sprintf("sha256:%x", sha256.Sum256(data))
}

// decodeColumnsDocument deliberately separates YAML parsing from Go's struct
// decoder. sigs.k8s.io/yaml.UnmarshalStrict performs a compatibility-breaking
// coercion (for example, a numeric scalar into a string field). Converting to
// JSON without a target and checking the raw shape first lets us reject those
// type changes while still accepting ordinary YAML syntax.
func decodeColumnsDocument(data []byte) (ColumnsDocument, any, error) {
	if err := preflightYAML(data); err != nil {
		return ColumnsDocument{}, nil, err
	}
	jsonData, err := yaml.YAMLToJSONStrict(data)
	if err != nil {
		return ColumnsDocument{}, nil, err
	}
	var raw any
	rawDecoder := json.NewDecoder(bytes.NewReader(jsonData))
	rawDecoder.UseNumber()
	if err := rawDecoder.Decode(&raw); err != nil {
		return ColumnsDocument{}, nil, err
	}
	if err := ensureJSONEOF(rawDecoder); err != nil {
		return ColumnsDocument{}, nil, err
	}
	if err := validateJSONShape(raw, reflect.TypeOf(ColumnsDocument{}), ""); err != nil {
		return ColumnsDocument{}, nil, err
	}
	if err := validateRequiredColumnsFields(raw); err != nil {
		return ColumnsDocument{}, nil, err
	}

	var document ColumnsDocument
	decoder := json.NewDecoder(bytes.NewReader(jsonData))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&document); err != nil {
		return ColumnsDocument{}, nil, err
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return ColumnsDocument{}, nil, err
	}
	return document, raw, nil
}

// validateRequiredColumnsFields covers fields whose omission cannot be given
// a safe default by the engine. The generic shape walk deliberately permits
// omissions so additive fields can migrate; these records are the opposite
// case and have always been part of the document's identity.
func validateRequiredColumnsFields(raw any) error {
	root, ok := raw.(map[string]any)
	if !ok {
		return errors.New("columns document root is not an object")
	}
	viewsValue, present := root["views"]
	if !present {
		return nil
	}
	views, ok := viewsValue.([]any)
	if !ok {
		// validateJSONShape already reports the useful type error.
		return nil
	}
	for viewIndex, viewValue := range views {
		view, ok := viewValue.(map[string]any)
		if !ok {
			continue
		}
		if _, present := view["match"]; !present {
			return fmt.Errorf("views[%d].match is required", viewIndex)
		}
		if _, present := view["columns"]; !present {
			return fmt.Errorf("views[%d].columns is required", viewIndex)
		}
		match, ok := view["match"].(map[string]any)
		if ok {
			if _, present := match["version"]; !present {
				return fmt.Errorf("views[%d].match.version is required", viewIndex)
			}
			if _, present := match["resource"]; !present {
				return fmt.Errorf("views[%d].match.resource is required", viewIndex)
			}
		}
		columnsValue, ok := view["columns"].([]any)
		if !ok {
			continue
		}
		for columnIndex, columnValue := range columnsValue {
			column, ok := columnValue.(map[string]any)
			if !ok {
				continue
			}
			for _, field := range []string{"id", "title", "source", "type"} {
				if _, present := column[field]; !present {
					return fmt.Errorf(
						"views[%d].columns[%d].%s is required",
						viewIndex, columnIndex, field,
					)
				}
			}
		}
	}
	return nil
}

// preflightYAML retains the YAML parser's native map shape long enough to
// reject constructs that YAMLToJSONStrict intentionally coerces. In
// particular, a numeric/bool mapping key is not the same field as its string
// representation, and a second YAML document must not be silently ignored.
// The subsequent JSON conversion remains the canonical decoder so its YAML
// 1.1 scalar behavior stays aligned with the rest of the backend.
func preflightYAML(data []byte) error {
	decoder := yamlv2.NewDecoder(bytes.NewReader(data))
	decoder.SetStrict(true)
	var first any
	if err := decoder.Decode(&first); err != nil {
		return err
	}
	if err := validateYAMLMapKeys(first, ""); err != nil {
		return err
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return errors.New("multiple YAML documents are not supported")
		}
		return err
	}
	return nil
}

func validateYAMLMapKeys(value any, path string) error {
	switch typed := value.(type) {
	case map[interface{}]interface{}:
		for key, child := range typed {
			stringKey, ok := key.(string)
			if !ok {
				return fmt.Errorf("%s contains a non-string mapping key", displayJSONPath(path))
			}
			if err := validateYAMLMapKeys(child, joinJSONPath(path, stringKey)); err != nil {
				return err
			}
		}
	case []interface{}:
		for index, child := range typed {
			if err := validateYAMLMapKeys(child, fmt.Sprintf("%s[%d]", displayJSONPath(path), index)); err != nil {
				return err
			}
		}
	}
	return nil
}

func ensureJSONEOF(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return errors.New("multiple documents are not supported")
		}
		return err
	}
	return nil
}

// validateJSONShape checks field names and scalar/container types before the
// final decode. It intentionally permits omitted fields: additions with safe
// zero/default semantics are the migration case. Present fields, including
// fields nested in one record of a view, must retain their exact current shape.
func validateJSONShape(value any, typ reflect.Type, path string) error {
	if value == nil {
		if typ.Kind() == reflect.Pointer || typ.Kind() == reflect.Interface {
			return nil
		}
		return fmt.Errorf("%s must not be null", displayJSONPath(path))
	}
	for typ.Kind() == reflect.Pointer {
		typ = typ.Elem()
	}

	switch typ.Kind() {
	case reflect.Struct:
		object, ok := value.(map[string]any)
		if !ok {
			return fmt.Errorf("%s must be an object", displayJSONPath(path))
		}
		fields := jsonFields(typ)
		for key, fieldValue := range object {
			field, known := fields[key]
			if !known {
				return fmt.Errorf("unknown field %s", joinJSONPath(path, key))
			}
			if err := validateJSONShape(fieldValue, field.Type, joinJSONPath(path, key)); err != nil {
				return err
			}
		}
	case reflect.Map:
		object, ok := value.(map[string]any)
		if !ok || typ.Key().Kind() != reflect.String {
			return fmt.Errorf("%s must be an object", displayJSONPath(path))
		}
		for key, fieldValue := range object {
			if err := validateJSONShape(fieldValue, typ.Elem(), joinJSONPath(path, key)); err != nil {
				return err
			}
		}
	case reflect.Slice:
		array, ok := value.([]any)
		if !ok {
			return fmt.Errorf("%s must be an array", displayJSONPath(path))
		}
		for index, element := range array {
			if err := validateJSONShape(element, typ.Elem(), fmt.Sprintf("%s[%d]", displayJSONPath(path), index)); err != nil {
				return err
			}
		}
	case reflect.Array:
		array, ok := value.([]any)
		if !ok || len(array) != typ.Len() {
			return fmt.Errorf("%s must be an array of length %d", displayJSONPath(path), typ.Len())
		}
		for index, element := range array {
			if err := validateJSONShape(element, typ.Elem(), fmt.Sprintf("%s[%d]", displayJSONPath(path), index)); err != nil {
				return err
			}
		}
	case reflect.String:
		if _, ok := value.(string); !ok {
			return fmt.Errorf("%s must be a string", displayJSONPath(path))
		}
	case reflect.Bool:
		if _, ok := value.(bool); !ok {
			return fmt.Errorf("%s must be a boolean", displayJSONPath(path))
		}
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		number, ok := value.(json.Number)
		if !ok {
			return fmt.Errorf("%s must be an integer", displayJSONPath(path))
		}
		parsed, err := strconv.ParseInt(string(number), 10, typ.Bits())
		if err != nil {
			return fmt.Errorf("%s must be an integer in range", displayJSONPath(path))
		}
		_ = parsed
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
		number, ok := value.(json.Number)
		if !ok {
			return fmt.Errorf("%s must be an unsigned integer", displayJSONPath(path))
		}
		parsed, err := strconv.ParseUint(string(number), 10, typ.Bits())
		if err != nil {
			return fmt.Errorf("%s must be an unsigned integer in range", displayJSONPath(path))
		}
		_ = parsed
	case reflect.Float32, reflect.Float64:
		number, ok := value.(json.Number)
		if !ok {
			return fmt.Errorf("%s must be a number", displayJSONPath(path))
		}
		parsed, err := strconv.ParseFloat(string(number), typ.Bits())
		if err != nil || math.IsNaN(parsed) || math.IsInf(parsed, 0) {
			return fmt.Errorf("%s must be a finite number", displayJSONPath(path))
		}
	case reflect.Interface:
		// Interface-valued fields have no schema-level type constraint.
		return nil
	default:
		return fmt.Errorf("%s has unsupported field type %s", displayJSONPath(path), typ)
	}
	return nil
}

func jsonFields(typ reflect.Type) map[string]reflect.StructField {
	result := make(map[string]reflect.StructField, typ.NumField())
	for index := 0; index < typ.NumField(); index++ {
		field := typ.Field(index)
		if field.PkgPath != "" { // unexported
			continue
		}
		name := strings.Split(field.Tag.Get("json"), ",")[0]
		if name == "-" {
			continue
		}
		if name == "" {
			name = field.Name
		}
		result[name] = field
	}
	return result
}

func displayJSONPath(path string) string {
	if path == "" {
		return "document"
	}
	return path
}

func joinJSONPath(path, key string) string {
	if path == "" {
		return key
	}
	return path + "." + key
}

func validColumnWidth(width float64) bool {
	return width >= 0 && !math.IsNaN(width) && !math.IsInf(width, 0)
}

func validateAcceleratorConfiguration(configuration AcceleratorConfiguration) error {
	names := make([]string, 0, len(configuration.Resources))
	for name := range configuration.Resources {
		names = append(names, name)
	}
	slices.Sort(names)
	for _, name := range names {
		if !isExtendedResourceName(name) {
			return fmt.Errorf("accelerators.resources key %q must be a valid Kubernetes extended-resource name", name)
		}
	}
	return nil
}

// isExtendedResourceName mirrors the Kubernetes core resource contract without
// importing the implementation-only kubernetes module: extended resources are
// qualified, outside the native kubernetes.io namespace, and do not use the
// requests. quota prefix.
func isExtendedResourceName(name string) bool {
	return strings.Contains(name, "/") &&
		!strings.Contains(name, corev1.ResourceDefaultNamespacePrefix) &&
		!strings.HasPrefix(name, corev1.DefaultResourceRequestsPrefix) &&
		len(k8svalidation.IsQualifiedName(corev1.DefaultResourceRequestsPrefix+name)) == 0
}

func EmptyColumns() *CompiledColumns {
	return &CompiledColumns{
		document: ColumnsDocument{
			APIVersion: ColumnsAPIVersion, CELEnvironment: columns.EnvironmentVersion,
		},
		version: "builtin",
		views:   make(map[resourceKey]compiledView),
	}
}

func (c *CompiledColumns) Version() string {
	if c == nil {
		return ""
	}
	return c.version
}

// AcceleratorConfig exposes a caller-owned scheduler-discovery configuration
// without coupling the view runtime to the configuration package.
func (c *CompiledColumns) AcceleratorConfig() metrics.AcceleratorConfig {
	if c == nil {
		return metrics.AcceleratorConfig{}
	}
	return acceleratorMetricsConfig(c.document.Accelerators)
}

func (c *CompiledColumns) Resolve(
	group, version, resource string,
	requestedIDs []string,
	expectedVersion string,
) (columns.Resolution, string, error) {
	if c == nil {
		return columns.Resolution{}, "", errors.New("columns configuration is unavailable")
	}
	if expectedVersion != "" && expectedVersion != c.version {
		return columns.Resolution{}, c.version, fmt.Errorf(
			"column configuration changed from %q to %q", expectedVersion, c.version,
		)
	}
	view, ok := c.views[resourceKey{group: group, version: version, resource: resource}]
	if !ok {
		return columns.Resolution{}, c.version, nil
	}
	requested := make(map[string]struct{}, len(requestedIDs))
	for _, id := range requestedIDs {
		requested[id] = struct{}{}
	}
	result := columns.Resolution{
		Programs:   make(map[string]*columns.Program),
		Extractors: make(map[string]columns.Extractor),
	}
	for _, definition := range view.configuration.Columns {
		if len(requested) == 0 && !definition.IsEnabled() {
			continue
		}
		if len(requested) != 0 {
			if _, include := requested[definition.ID]; !include {
				continue
			}
		}
		if program := view.programs[definition.ID]; program != nil {
			result.Programs[definition.ID] = program
		}
		if extractor := view.extractors[definition.ID]; extractor.Value != "" {
			result.Extractors[definition.ID] = extractor
		}
	}
	return result, c.version, nil
}

type ColumnManager struct {
	mu                sync.RWMutex
	path              string
	compiler          *columns.Compiler
	current           *CompiledColumns
	stamp             fileStamp
	initialLoadNotice string
}

type fileStamp struct {
	exists  bool
	modTime int64
	size    int64
}

func NewColumnManager(path string, compiler *columns.Compiler) (*ColumnManager, error) {
	if strings.TrimSpace(path) == "" {
		return nil, errors.New("columns path must not be empty")
	}
	if compiler == nil {
		return nil, errors.New("CEL compiler must not be nil")
	}
	manager := &ColumnManager{path: path, compiler: compiler, current: EmptyColumns()}
	if err := manager.Reload(); err != nil {
		// The macOS preflight normally backs up and replaces this file before
		// the helper starts. Keep the helper independently safe if a race or a
		// non-Swift caller presents an incompatible or unreadable path: use
		// built-ins, make a best-effort backup/default replacement, and pin the
		// current stamp so the same path does not trigger a reload on every
		// request. The next external edit is still observed normally.
		manager.mu.Lock()
		manager.current = EmptyColumns()
		manager.initialLoadNotice = recoverInvalidColumnsFile(path, err)
		if info, statErr := os.Stat(path); statErr == nil {
			manager.stamp = stampFor(info)
		}
		manager.mu.Unlock()
		return manager, nil
	}
	return manager, nil
}

// InitialLoadNotice reports a startup recovery performed after an incompatible
// columns document was encountered. It is intentionally informational: the
// manager remains usable with built-in columns even when the filesystem could
// not be repaired. Later external edits retain the last valid configuration
// contract and do not mutate user files from inside Resolve.
func (m *ColumnManager) InitialLoadNotice() string {
	if m == nil {
		return ""
	}
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.initialLoadNotice
}

// recoverInvalidColumnsFile is used at startup when a configuration cannot be
// loaded safely. A malformed edit made while the helper is running still
// leaves the last compiled configuration active until the user explicitly
// repairs/reloads it. Existing bytes are copied before replacement, and the
// replacement itself is atomic within the containing directory.
func recoverInvalidColumnsFile(path string, cause error) string {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Sprintf(
			"columns configuration is incompatible (%s); built-in columns are in use, and the original file could not be inspected",
			compactError(cause),
		)
	}
	if !info.Mode().IsRegular() {
		return fmt.Sprintf(
			"columns configuration is incompatible (%s); built-in columns are in use, and the original path is not a regular file",
			compactError(cause),
		)
	}

	original, err := os.ReadFile(path)
	if err != nil {
		return fmt.Sprintf(
			"columns configuration is incompatible (%s); built-in columns are in use, and the original could not be backed up",
			compactError(cause),
		)
	}
	backupPath, err := writeInvalidColumnsBackup(path, original)
	if err != nil {
		return fmt.Sprintf(
			"columns configuration is incompatible (%s); built-in columns are in use, and the original could not be backed up",
			compactError(cause),
		)
	}

	defaults, err := yaml.Marshal(ColumnsDocument{
		APIVersion:     ColumnsAPIVersion,
		CELEnvironment: columns.EnvironmentVersion,
	})
	if err != nil {
		return fmt.Sprintf(
			"columns configuration was backed up to %s, but defaults could not be encoded; built-in columns are in use",
			backupPath,
		)
	}
	if err := atomicallyReplaceColumnsFile(path, defaults); err != nil {
		return fmt.Sprintf(
			"columns configuration was backed up to %s, but replacing it with defaults failed (%s); built-in columns are in use",
			backupPath, compactError(err),
		)
	}
	return fmt.Sprintf(
		"columns configuration was incompatible (%s), backed up to %s, and replaced with defaults",
		compactError(cause), backupPath,
	)
}

func compactError(err error) string {
	if err == nil {
		return "unknown validation error"
	}
	message := strings.Join(strings.Fields(err.Error()), " ")
	if len(message) > 512 {
		message = message[:512] + "…"
	}
	return message
}

func writeInvalidColumnsBackup(path string, data []byte) (string, error) {
	directory := filepath.Dir(path)
	base := filepath.Base(path)
	for attempt := 0; attempt < 8; attempt++ {
		var random [16]byte
		if _, err := rand.Read(random[:]); err != nil {
			return "", err
		}
		candidate := filepath.Join(
			directory,
			fmt.Sprintf("%s.invalid-%s.bak", base, uuidLike(random)),
		)
		file, err := os.OpenFile(candidate, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			if errors.Is(err, os.ErrExist) {
				continue
			}
			return "", err
		}
		writeErr := func() error {
			if _, err := file.Write(data); err != nil {
				return err
			}
			if err := file.Sync(); err != nil {
				return err
			}
			return file.Close()
		}()
		if writeErr != nil {
			_ = file.Close()
			_ = os.Remove(candidate)
			return "", writeErr
		}
		if err := os.Chmod(candidate, 0o600); err != nil {
			_ = os.Remove(candidate)
			return "", err
		}
		return candidate, nil
	}
	return "", errors.New("could not allocate a unique backup path")
}

func uuidLike(value [16]byte) string {
	hexValue := hex.EncodeToString(value[:])
	return hexValue[0:8] + "-" + hexValue[8:12] + "-" +
		hexValue[12:16] + "-" + hexValue[16:20] + "-" + hexValue[20:32]
}

func atomicallyReplaceColumnsFile(path string, data []byte) error {
	directory := filepath.Dir(path)
	temporary, err := os.CreateTemp(directory, "."+filepath.Base(path)+".reset-")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	removeTemporary := true
	defer func() {
		if removeTemporary {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return err
	}
	removeTemporary = false
	return os.Chmod(path, 0o600)
}

func (m *ColumnManager) Reload() error {
	info, err := os.Stat(m.path)
	if errors.Is(err, os.ErrNotExist) {
		m.mu.Lock()
		m.current = EmptyColumns()
		m.stamp = fileStamp{}
		m.mu.Unlock()
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect columns configuration: %w", err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("columns configuration %q is not a regular file", m.path)
	}
	data, err := os.ReadFile(m.path)
	if err != nil {
		return fmt.Errorf("read columns configuration: %w", err)
	}
	compiled, err := ParseColumns(data, m.compiler)
	if err != nil {
		return err
	}
	if compiled.needsMigration {
		// Field compatibility has already been established by ParseColumns.
		// Persist only the canonical metadata rewrite before swapping the active
		// configuration, so a failed migration can never leave a half-installed
		// in-memory view. Constructor callers recover to defaults; a runtime
		// reload keeps its last valid configuration active until the file is
		// repaired.
		if err := atomicallyReplaceColumnsFile(m.path, compiled.canonicalData); err != nil {
			return fmt.Errorf("persist migrated columns configuration: %w", err)
		}
		data = compiled.canonicalData
		compiled.version = digestColumnsData(data)
		info, err = os.Stat(m.path)
		if err != nil {
			return fmt.Errorf("inspect migrated columns configuration: %w", err)
		}
	}
	m.mu.Lock()
	m.current = compiled
	m.stamp = stampFor(info)
	if compiled.needsMigration {
		m.initialLoadNotice = "Programmable columns migrated to the current format."
	}
	m.mu.Unlock()
	return nil
}

// ReloadIfChanged is called at explicit view/column operations, never once per
// projected object. If an external edit is invalid, the last valid compiled
// programs remain installed and the caller receives the validation error.
func (m *ColumnManager) ReloadIfChanged() error {
	info, err := os.Stat(m.path)
	if errors.Is(err, os.ErrNotExist) {
		m.mu.RLock()
		changed := m.stamp.exists
		m.mu.RUnlock()
		if changed {
			return m.Reload()
		}
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect columns configuration: %w", err)
	}
	stamp := stampFor(info)
	m.mu.RLock()
	changed := stamp != m.stamp
	m.mu.RUnlock()
	if !changed {
		return nil
	}
	return m.Reload()
}

func (m *ColumnManager) Resolve(
	group, version, resource string,
	requestedIDs []string,
	expectedVersion string,
) (columns.Resolution, string, error) {
	if err := m.ReloadIfChanged(); err != nil {
		return columns.Resolution{}, m.Version(), err
	}
	m.mu.RLock()
	current := m.current
	m.mu.RUnlock()
	return current.Resolve(group, version, resource, requestedIDs, expectedVersion)
}

func (m *ColumnManager) Version() string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.current.Version()
}

// AcceleratorConfig returns an immutable exact-resource mapping for backend
// scheduler accounting and discovery.
func (m *ColumnManager) AcceleratorConfig() metrics.AcceleratorConfig {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.current.AcceleratorConfig()
}

func acceleratorMetricsConfig(value AcceleratorConfiguration) metrics.AcceleratorConfig {
	result := metrics.AcceleratorConfig{AutoDetectSuffixes: slices.Clone(value.AutoDetectSuffixes)}
	if value.Resources != nil {
		result.Resources = make(map[string]metrics.AcceleratorResourceConfig, len(value.Resources))
		for name, settings := range value.Resources {
			result.Resources[name] = metrics.AcceleratorResourceConfig{DisplayName: settings.DisplayName}
		}
	}
	return result
}

func stampFor(info os.FileInfo) fileStamp {
	return fileStamp{exists: true, modTime: info.ModTime().UnixNano(), size: info.Size()}
}

func cloneDocument(value ColumnsDocument) ColumnsDocument {
	value.Views = slices.Clone(value.Views)
	for index := range value.Views {
		value.Views[index] = cloneView(value.Views[index])
	}
	value.Accelerators.AutoDetectSuffixes = slices.Clone(value.Accelerators.AutoDetectSuffixes)
	if value.Accelerators.Resources != nil {
		resources := make(map[string]AcceleratorResourceSettings, len(value.Accelerators.Resources))
		for name, settings := range value.Accelerators.Resources {
			resources[name] = settings
		}
		value.Accelerators.Resources = resources
	}
	return value
}

func cloneView(value ViewConfiguration) ViewConfiguration {
	value.Columns = slices.Clone(value.Columns)
	return value
}
