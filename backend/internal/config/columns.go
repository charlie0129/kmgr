// Package config loads kmgr's versioned, user-editable application
// configuration. Kubernetes credentials and runtime object caches never belong
// here.
package config

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"

	"github.com/charlie0129/kmgr/backend/internal/view/columns"
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
}

type resourceKey struct {
	group    string
	version  string
	resource string
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
		}
		seenIDs := make(map[string]struct{}, len(view.Columns))
		for columnIndex, definition := range view.Columns {
			if strings.TrimSpace(definition.ID) == "" {
				return nil, fmt.Errorf("views[%d].columns[%d].id must not be empty", viewIndex, columnIndex)
			}
			if _, duplicate := seenIDs[definition.ID]; duplicate {
				return nil, fmt.Errorf("view %s/%s/%s has duplicate column ID %q", key.group, key.version, key.resource, definition.ID)
			}
			seenIDs[definition.ID] = struct{}{}
			if definition.Width < 0 {
				return nil, fmt.Errorf("column %q width must not be negative", definition.ID)
			}
			switch definition.Alignment {
			case "", "leading", "center", "trailing":
			default:
				return nil, fmt.Errorf("column %q has unsupported alignment %q", definition.ID, definition.Alignment)
			}
			switch definition.Source {
			case "cel":
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
				if strings.TrimSpace(definition.Value) == "" {
					return nil, fmt.Errorf("column %q source %q requires value", definition.ID, definition.Source)
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
) (map[string]*columns.Program, string, error) {
	if c == nil {
		return nil, "", errors.New("columns configuration is unavailable")
	}
	if expectedVersion != "" && expectedVersion != c.version {
		return nil, c.version, fmt.Errorf(
			"column configuration changed from %q to %q", expectedVersion, c.version,
		)
	}
	view, ok := c.views[resourceKey{group: group, version: version, resource: resource}]
	if !ok {
		return nil, c.version, nil
	}
	requested := make(map[string]struct{}, len(requestedIDs))
	for _, id := range requestedIDs {
		requested[id] = struct{}{}
	}
	result := make(map[string]*columns.Program)
	for id, program := range view.programs {
		if len(requested) == 0 {
			if definition := columnByID(view.configuration.Columns, id); definition != nil && definition.IsEnabled() {
				result[id] = program
			}
			continue
		}
		if _, include := requested[id]; include {
			result[id] = program
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
) (map[string]*columns.Program, string, error) {
	if err := m.ReloadIfChanged(); err != nil {
		return nil, m.Version(), err
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

func stampFor(info os.FileInfo) fileStamp {
	return fileStamp{exists: true, modTime: info.ModTime().UnixNano(), size: info.Size()}
}

func columnByID(values []ColumnConfiguration, id string) *ColumnConfiguration {
	index := slices.IndexFunc(values, func(value ColumnConfiguration) bool { return value.ID == id })
	if index < 0 {
		return nil
	}
	return &values[index]
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
