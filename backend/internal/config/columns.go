// Package config loads kmgr's versioned, user-editable application
// configuration. Kubernetes credentials and runtime object caches never belong
// here.
package config

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	"github.com/charlie0129/kmgr/backend/internal/view/columns"
	corev1 "k8s.io/api/core/v1"
	k8svalidation "k8s.io/apimachinery/pkg/util/validation"
	"sigs.k8s.io/yaml"
)

const (
	ColumnsAPIVersion  = "kmgr.charlie0129.dev/v1alpha1"
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
	document ColumnsDocument
	version  string
	views    map[resourceKey]compiledView
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

var builtinExtractors = map[string]columns.ResultType{
	"namespace":       columns.ResultString,
	"name":            columns.ResultString,
	"kind":            columns.ResultString,
	"status":          columns.ResultString,
	"roles":           columns.ResultString,
	"taints":          columns.ResultInteger,
	"ip":              columns.ResultString,
	"replicas":        columns.ResultString,
	"node":            columns.ResultString,
	"ready":           columns.ResultString,
	"restarts":        columns.ResultInteger,
	"age":             columns.ResultDuration,
	"created":         columns.ResultTimestamp,
	"resourceVersion": columns.ResultString,
}

var metricExtractors = map[string]struct{}{
	"cpu": {}, "memory": {}, "ephemeral-storage": {},
	"cpu-requests": {}, "cpu-limits": {},
	"memory-requests": {}, "memory-limits": {},
	"ephemeral-storage-requests": {},
	"ephemeral-storage-limits":   {},
	"pod-count":                  {},
}

var nodeOnlyMetricExtractors = map[string]struct{}{
	"cpu-requests": {}, "cpu-limits": {},
	"memory-requests": {}, "memory-limits": {},
	"ephemeral-storage-requests": {},
	"ephemeral-storage-limits":   {},
	"pod-count":                  {},
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
	aliases := map[string]string{
		"pod.status":   "status",
		"pod.node":     "node",
		"pod.ready":    "ready",
		"pod.restarts": "restarts",
	}
	if canonical := aliases[value]; canonical != "" {
		value = canonical
	}
	_, known := builtinExtractors[value]
	return value, known
}

func builtinSupportedForResource(key resourceKey, value string) bool {
	switch value {
	case "node", "ready", "restarts":
		return isCoreResource(key, "pods")
	case "roles", "taints", "ip":
		return isCoreResource(key, "nodes")
	case "replicas":
		return isReplicaWorkload(key)
	default:
		return true
	}
}

func isReplicaWorkload(key resourceKey) bool {
	if key.group == "apps" && key.version == "v1" {
		switch key.resource {
		case "deployments", "statefulsets", "daemonsets", "replicasets":
			return true
		}
	}
	return isCoreResource(key, "replicationcontrollers")
}

func metricValue(value string) (string, bool) {
	aliases := map[string]string{
		"pod.cpu.usageRequestLimit":               "cpu",
		"pod.memory.usageRequestLimit":            "memory",
		"pod.ephemeral-storage.usageRequestLimit": "ephemeral-storage",
		"node.cpu.usageAllocatable":               "cpu",
		"node.memory.usageAllocatable":            "memory",
		"node.ephemeral-storage.usageAllocatable": "ephemeral-storage",
	}
	if canonical := aliases[value]; canonical != "" {
		value = canonical
	}
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
		if _, nodeOnly := nodeOnlyMetricExtractors[value]; nodeOnly {
			return fmt.Errorf("metric value %q is not supported for Pods", value)
		}
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

// ParseColumns validates both schema versions and compiles every CEL program
// once. An invalid edit never becomes a partially active configuration.
func ParseColumns(data []byte, compiler *columns.Compiler) (*CompiledColumns, error) {
	if compiler == nil {
		return nil, errors.New("CEL compiler must not be nil")
	}
	var document ColumnsDocument
	if err := yaml.UnmarshalStrict(data, &document); err != nil {
		return nil, fmt.Errorf("parse columns configuration: %w", err)
	}
	if document.APIVersion != ColumnsAPIVersion {
		return nil, fmt.Errorf(
			"unsupported columns apiVersion %q; expected %q",
			document.APIVersion, ColumnsAPIVersion,
		)
	}
	if document.CELEnvironment != columns.EnvironmentVersion {
		return nil, fmt.Errorf(
			"unsupported CEL environment %q; expected %q",
			document.CELEnvironment, columns.EnvironmentVersion,
		)
	}
	normalizeLegacyNativeColumnTypes(&document)
	if err := validateAcceleratorConfiguration(document.Accelerators); err != nil {
		return nil, err
	}

	compiled := &CompiledColumns{
		document: cloneDocument(document),
		version:  fmt.Sprintf("sha256:%x", sha256.Sum256(data)),
		views:    make(map[resourceKey]compiledView, len(document.Views)),
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
			case "":
				return nil, fmt.Errorf("column %q source must not be empty", definition.ID)
			default:
				return nil, fmt.Errorf("column %q has unsupported source %q", definition.ID, definition.Source)
			}
		}
		compiled.views[key] = entry
	}
	return compiled, nil
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

// normalizeLegacyNativeColumnTypes accepts the two incorrect declared types
// emitted by older native macOS default layouts. The migration is deliberately
// restricted to the exact built-in IDs and values that Kmgr wrote; unrelated
// invalid custom definitions must continue to fail validation.
func normalizeLegacyNativeColumnTypes(document *ColumnsDocument) {
	if document == nil {
		return
	}
	for viewIndex := range document.Views {
		for columnIndex := range document.Views[viewIndex].Columns {
			definition := &document.Views[viewIndex].Columns[columnIndex]
			if definition.Source != "builtin" || definition.ID != definition.Value {
				continue
			}
			switch {
			case definition.Value == "ready" && definition.Type == columns.ResultNumber:
				definition.Type = columns.ResultString
			case definition.Value == "age" && definition.Type == columns.ResultTimestamp:
				definition.Type = columns.ResultDuration
			}
		}
	}
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

func (c *CompiledColumns) Document() ColumnsDocument {
	if c == nil {
		return ColumnsDocument{}
	}
	return cloneDocument(c.document)
}

// AcceleratorConfig exposes a caller-owned scheduler-discovery configuration
// without coupling the view runtime to the configuration package.
func (c *CompiledColumns) AcceleratorConfig() metrics.AcceleratorConfig {
	if c == nil {
		return metrics.AcceleratorConfig{}
	}
	return acceleratorMetricsConfig(c.document.Accelerators)
}

func (c *CompiledColumns) View(group, version, resource string) (ViewConfiguration, bool) {
	if c == nil {
		return ViewConfiguration{}, false
	}
	view, ok := c.views[resourceKey{group: group, version: version, resource: resource}]
	return cloneView(view.configuration), ok
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
	mu       sync.RWMutex
	path     string
	compiler *columns.Compiler
	current  *CompiledColumns
	stamp    fileStamp
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
		return nil, err
	}
	return manager, nil
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
	m.mu.Lock()
	m.current = compiled
	m.stamp = stampFor(info)
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

func (m *ColumnManager) Document() ColumnsDocument {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.current.Document()
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
