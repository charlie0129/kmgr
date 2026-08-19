// Package cluster owns kubeconfig discovery and the construction of Kubernetes
// client configuration. It intentionally does not contact an API server while
// discovering contexts.
package cluster

import (
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
)

// DefaultNamespace is the namespace Kubernetes clients use when a context
// does not declare one.
const DefaultNamespace = "default"

// UnsupportedAuthMechanism identifies a kubeconfig authentication mechanism
// that kmgr deliberately does not run.
type UnsupportedAuthMechanism string

const (
	UnsupportedAuthExec     UnsupportedAuthMechanism = "exec"
	UnsupportedAuthProvider UnsupportedAuthMechanism = "auth-provider"
)

// ContextInfo is credential-free metadata suitable for showing in the
// cluster chooser. IDs are deterministic for an unchanged context and target,
// independent of kubeconfig ordering.
type ContextInfo struct {
	ID                         string
	Name                       string
	ClusterID                  string
	ClusterName                string
	ServerHostname             string
	DefaultNamespace           string
	AuthenticationHint         string
	SourcePath                 string
	ContextSourcePath          string
	ClusterSourcePath          string
	AuthInfoSourcePath         string
	SourcePaths                []string
	Current                    bool
	UnsupportedAuthentications []UnsupportedAuthMechanism
}

// Catalog is an immutable snapshot of the kubeconfigs visible when Discover
// was called. Reloading is done by creating a new Catalog.
type Catalog struct {
	contexts []ContextInfo
	bindings map[string]contextBinding
}

// contextBinding keeps the exact configuration snapshot that produced a
// chooser row. Auto-discovered sibling files are deliberately kept separate:
// standalone kubeconfigs commonly reuse names such as "kubernetes-admin", and
// flattening them through client-go's map merge would silently attach an
// earlier file's credentials to a later file's context.
type contextBinding struct {
	config      clientcmdapi.Config
	contextName string
}

// ContextNotFoundError reports a stale or unknown opaque context reference.
type ContextNotFoundError struct {
	Reference string
}

func (e *ContextNotFoundError) Error() string {
	return fmt.Sprintf("kubeconfig context %q was not found", e.Reference)
}

// UnsupportedAuthenticationError is returned before client-go is allowed to
// construct a transport. In particular, no exec credential command is run.
type UnsupportedAuthenticationError struct {
	ContextName  string
	AuthInfoName string
	Mechanisms   []UnsupportedAuthMechanism
}

func (e *UnsupportedAuthenticationError) Error() string {
	mechanisms := make([]string, len(e.Mechanisms))
	for index, mechanism := range e.Mechanisms {
		mechanisms[index] = string(mechanism)
	}
	return fmt.Sprintf(
		"kubeconfig context %q uses unsupported %s authentication for user %q",
		e.ContextName,
		strings.Join(mechanisms, " and "),
		e.AuthInfoName,
	)
}

// Discover loads kubeconfig using client-go's normal rules: KUBECONFIG is a
// path-list whose earlier entries win. When KUBECONFIG is unset, the normal
// ~/.kube/config has first precedence and other valid, regular kubeconfig
// files directly beside it are merged in deterministic filename order.
func Discover() (*Catalog, error) {
	rules := clientcmd.NewDefaultClientConfigLoadingRules()
	if os.Getenv(clientcmd.RecommendedConfigPathEnvVar) != "" {
		return DiscoverWithRules(rules)
	}
	return discoverHomeDirectory(rules)
}

// DiscoverPaths loads an explicitly supplied kubeconfig precedence list using
// the same merge behavior as KUBECONFIG. An empty list uses the normal ambient
// kubeconfig loading rules.
func DiscoverPaths(paths []string) (*Catalog, error) {
	if len(paths) == 0 {
		return Discover()
	}

	precedence := make([]string, 0, len(paths))
	for _, path := range paths {
		if path == "" {
			return nil, errors.New("kubeconfig path must not be empty")
		}
		precedence = append(precedence, filepath.Clean(path))
	}
	rules := clientcmd.NewDefaultClientConfigLoadingRules()
	rules.ExplicitPath = ""
	rules.Precedence = precedence
	// Explicit paths supplied by the app are already the complete precedence
	// list. Do not run client-go's legacy home-directory migration rules.
	rules.MigrationRules = nil
	rules.WarnIfAllMissing = false
	return DiscoverWithRules(rules)
}

// DiscoverWithRules is useful to embed discovery in callers with an explicit
// kubeconfig path and to test loading behavior. The supplied rules are copied
// and are not mutated.
func DiscoverWithRules(rules *clientcmd.ClientConfigLoadingRules) (*Catalog, error) {
	if rules == nil {
		return nil, errors.New("kubeconfig loading rules must not be nil")
	}

	// client-go also resolves a relative exec.command as part of loading. kmgr
	// never needs that path because exec authentication is unsupported. Resolve
	// only passive credential files so an unavailable plugin cannot prevent the
	// chooser from identifying it as unsupported.
	loadingRules := *rules
	loadingRules.DoNotResolvePaths = true
	config, err := loadingRules.Load()
	if err != nil {
		return nil, fmt.Errorf("load kubeconfig: %w", err)
	}
	if err := resolveCredentialPaths(config); err != nil {
		return nil, fmt.Errorf("resolve kubeconfig paths: %w", err)
	}

	return newCatalog(config), nil
}

// discoverHomeDirectory extends the standards-compliant default file with
// top-level kubeconfigs stored alongside it. Candidate inspection is entirely
// local: it does not construct transports or contact an API server.
func discoverHomeDirectory(rules *clientcmd.ClientConfigLoadingRules) (*Catalog, error) {
	if rules == nil || len(rules.Precedence) == 0 {
		return DiscoverWithRules(rules)
	}
	defaultPath := filepath.Clean(rules.Precedence[0])
	directory := filepath.Dir(defaultPath)
	candidates, err := homeKubeconfigCandidates(directory, defaultPath)
	if err != nil {
		// Preserve client-go behavior when the default directory does not exist
		// or cannot be inspected; loading the normal default remains authoritative.
		return DiscoverWithRules(rules)
	}
	return discoverIndependentFiles(candidates, defaultPath)
}

// discoverIndependentFiles catalogs each automatically discovered sibling as
// its own kubeconfig authority. Opaque context IDs bind every chooser row to
// the cluster and credentials from the file that produced it.
func discoverIndependentFiles(paths []string, defaultPath string) (*Catalog, error) {
	catalog := newEmptyCatalog()
	for _, path := range paths {
		if _, err := os.Stat(path); os.IsNotExist(err) {
			continue
		}
		rules := clientcmd.NewDefaultClientConfigLoadingRules()
		rules.ExplicitPath = path
		rules.MigrationRules = nil
		rules.WarnIfAllMissing = false

		fileCatalog, err := DiscoverWithRules(rules)
		if err != nil {
			// Candidate validation already rejected malformed sibling files.
			// Preserve normal client-go behavior for the authoritative default.
			if filepath.Clean(path) == filepath.Clean(defaultPath) {
				return nil, err
			}
			continue
		}
		catalog.append(fileCatalog, filepath.Clean(path) == filepath.Clean(defaultPath))
	}
	catalog.finish()
	return catalog, nil
}

func homeKubeconfigCandidates(directory, defaultPath string) ([]string, error) {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, err
	}
	defaultPath = filepath.Clean(defaultPath)
	result := []string{defaultPath}
	for _, entry := range entries {
		path := filepath.Join(directory, entry.Name())
		if filepath.Clean(path) == defaultPath {
			continue
		}
		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		config, err := clientcmd.LoadFromFile(path)
		if err != nil || clientcmdapi.IsConfigEmpty(config) ||
			(len(config.Contexts) == 0 && len(config.Clusters) == 0 && len(config.AuthInfos) == 0) {
			continue
		}
		result = append(result, path)
	}
	return result, nil
}

// Contexts returns a copy sorted by exact context name. It never contains
// bearer tokens, passwords, certificate data, or plugin configuration.
func (c *Catalog) Contexts() []ContextInfo {
	if c == nil {
		return nil
	}
	result := make([]ContextInfo, len(c.contexts))
	for index := range c.contexts {
		result[index] = c.contexts[index]
		result[index].SourcePaths = append([]string(nil), c.contexts[index].SourcePaths...)
		result[index].UnsupportedAuthentications = append(
			[]UnsupportedAuthMechanism(nil),
			c.contexts[index].UnsupportedAuthentications...,
		)
	}
	return result
}

// Context looks up metadata by deterministic opaque ID.
func (c *Catalog) Context(reference string) (ContextInfo, bool) {
	if c == nil {
		return ContextInfo{}, false
	}
	for _, info := range c.contexts {
		if info.ID == reference {
			result := info
			result.SourcePaths = append([]string(nil), info.SourcePaths...)
			result.UnsupportedAuthentications = append(
				[]UnsupportedAuthMechanism(nil),
				info.UnsupportedAuthentications...,
			)
			return result, true
		}
	}
	return ContextInfo{}, false
}

// RESTConfig returns client-go configuration for a context ID. It is
// a local operation; constructing it does not connect to the cluster.
func (c *Catalog) RESTConfig(reference string) (*rest.Config, error) {
	if c == nil {
		return nil, &ContextNotFoundError{Reference: reference}
	}
	binding, ok := c.bindings[reference]
	if !ok {
		return nil, &ContextNotFoundError{Reference: reference}
	}
	name := binding.contextName
	contextConfig := binding.config.Contexts[name]
	if contextConfig == nil {
		return nil, &ContextNotFoundError{Reference: reference}
	}

	authInfo, authInfoExists := binding.config.AuthInfos[contextConfig.AuthInfo]
	mechanisms := unsupportedAuthentication(authInfo)
	if len(mechanisms) != 0 {
		return nil, &UnsupportedAuthenticationError{
			ContextName:  name,
			AuthInfoName: contextConfig.AuthInfo,
			Mechanisms:   append([]UnsupportedAuthMechanism(nil), mechanisms...),
		}
	}
	if contextConfig.AuthInfo != "" && (!authInfoExists || authInfo == nil) {
		return nil, fmt.Errorf(
			"build client configuration for context %q: user %q was not found",
			name,
			contextConfig.AuthInfo,
		)
	}

	clusterConfig, clusterExists := binding.config.Clusters[contextConfig.Cluster]
	if contextConfig.Cluster != "" && (!clusterExists || clusterConfig == nil) {
		return nil, fmt.Errorf(
			"build client configuration for context %q: cluster %q was not found",
			name,
			contextConfig.Cluster,
		)
	}

	clientConfig := clientcmd.NewNonInteractiveClientConfig(
		binding.config,
		name,
		&clientcmd.ConfigOverrides{},
		nil,
	)
	restConfig, err := clientConfig.ClientConfig()
	if err != nil {
		return nil, fmt.Errorf("build client configuration for context %q: %w", name, err)
	}
	return restConfig, nil
}

func newCatalog(config *clientcmdapi.Config) *Catalog {
	catalog := newEmptyCatalog()
	catalog.addConfig(config)
	catalog.finish()
	return catalog
}

func newEmptyCatalog() *Catalog {
	return &Catalog{bindings: make(map[string]contextBinding)}
}

func (c *Catalog) append(other *Catalog, retainCurrent bool) {
	if c == nil || other == nil {
		return
	}
	for _, info := range other.contexts {
		binding, ok := other.bindings[info.ID]
		if !ok {
			continue
		}
		info.ID = stableID("context-source", info.ID, info.ContextSourcePath)
		info.Current = retainCurrent && info.Current
		c.addBinding(info, binding)
	}
}

func (c *Catalog) addConfig(config *clientcmdapi.Config) {
	if c == nil || config == nil {
		return
	}
	for _, info := range buildContextInfo(config) {
		c.addBinding(info, contextBinding{
			config:      *config.DeepCopy(),
			contextName: info.Name,
		})
	}
}

func (c *Catalog) addBinding(info ContextInfo, binding contextBinding) {
	if _, exists := c.bindings[info.ID]; exists {
		return
	}
	c.contexts = append(c.contexts, info)
	c.bindings[info.ID] = binding
}

func (c *Catalog) finish() {
	sort.Slice(c.contexts, func(left, right int) bool {
		if c.contexts[left].Name != c.contexts[right].Name {
			return c.contexts[left].Name < c.contexts[right].Name
		}
		return c.contexts[left].ID < c.contexts[right].ID
	})
}

func buildContextInfo(config *clientcmdapi.Config) []ContextInfo {
	contexts := make([]ContextInfo, 0, len(config.Contexts))
	for name, contextConfig := range config.Contexts {
		if contextConfig == nil {
			continue
		}

		clusterConfig := config.Clusters[contextConfig.Cluster]
		authInfo := config.AuthInfos[contextConfig.AuthInfo]
		server := ""
		clusterSource := ""
		if clusterConfig != nil {
			server = clusterConfig.Server
			clusterSource = absoluteSourcePath(clusterConfig.LocationOfOrigin)
		}
		contextSource := absoluteSourcePath(contextConfig.LocationOfOrigin)
		authSource := ""
		if authInfo != nil {
			authSource = absoluteSourcePath(authInfo.LocationOfOrigin)
		}

		clusterID := stableID("cluster", contextConfig.Cluster, server)
		contextID := stableID("context", name, clusterID)
		namespace := contextConfig.Namespace
		if namespace == "" {
			namespace = DefaultNamespace
		}

		info := ContextInfo{
			ID:                         contextID,
			Name:                       name,
			ClusterID:                  clusterID,
			ClusterName:                contextConfig.Cluster,
			ServerHostname:             serverHostname(server),
			DefaultNamespace:           namespace,
			AuthenticationHint:         authenticationHint(authInfo),
			SourcePath:                 firstNonEmpty(contextSource, clusterSource, authSource),
			ContextSourcePath:          contextSource,
			ClusterSourcePath:          clusterSource,
			AuthInfoSourcePath:         authSource,
			SourcePaths:                uniqueNonEmpty(contextSource, clusterSource, authSource),
			Current:                    name == config.CurrentContext,
			UnsupportedAuthentications: unsupportedAuthentication(authInfo),
		}
		contexts = append(contexts, info)
	}
	return contexts
}

func resolveCredentialPaths(config *clientcmdapi.Config) error {
	for _, clusterConfig := range config.Clusters {
		if clusterConfig == nil || clusterConfig.LocationOfOrigin == "" {
			continue
		}
		base, err := sourceDirectory(clusterConfig.LocationOfOrigin)
		if err != nil {
			return err
		}
		if err := clientcmd.ResolvePaths(
			[]*string{&clusterConfig.CertificateAuthority},
			base,
		); err != nil {
			return err
		}
	}

	for _, authInfo := range config.AuthInfos {
		if authInfo == nil || authInfo.LocationOfOrigin == "" {
			continue
		}
		base, err := sourceDirectory(authInfo.LocationOfOrigin)
		if err != nil {
			return err
		}
		if err := clientcmd.ResolvePaths(
			[]*string{&authInfo.ClientCertificate, &authInfo.ClientKey, &authInfo.TokenFile},
			base,
		); err != nil {
			return err
		}
	}
	return nil
}

func sourceDirectory(source string) (string, error) {
	base, err := filepath.Abs(filepath.Dir(source))
	if err != nil {
		return "", fmt.Errorf("determine absolute directory for kubeconfig %q: %w", source, err)
	}
	return base, nil
}

func unsupportedAuthentication(authInfo *clientcmdapi.AuthInfo) []UnsupportedAuthMechanism {
	if authInfo == nil {
		return nil
	}
	var mechanisms []UnsupportedAuthMechanism
	if authInfo.Exec != nil {
		mechanisms = append(mechanisms, UnsupportedAuthExec)
	}
	if authInfo.AuthProvider != nil {
		mechanisms = append(mechanisms, UnsupportedAuthProvider)
	}
	return mechanisms
}

func authenticationHint(authInfo *clientcmdapi.AuthInfo) string {
	if authInfo == nil {
		return "No credentials"
	}
	mechanisms := unsupportedAuthentication(authInfo)
	if len(mechanisms) != 0 {
		names := make([]string, len(mechanisms))
		for index, mechanism := range mechanisms {
			names[index] = string(mechanism)
		}
		return "Unsupported: " + strings.Join(names, ", ")
	}

	var methods []string
	if authInfo.ClientCertificate != "" || len(authInfo.ClientCertificateData) != 0 {
		methods = append(methods, "Client certificate")
	}
	if authInfo.Token != "" || authInfo.TokenFile != "" {
		methods = append(methods, "Bearer token")
	}
	if authInfo.Username != "" || authInfo.Password != "" {
		methods = append(methods, "Username/password")
	}
	if len(methods) == 0 {
		return "No credentials"
	}
	return strings.Join(methods, " + ")
}

func stableID(kind string, values ...string) string {
	hash := sha256.New()
	_, _ = hash.Write([]byte("kmgr/" + kind + "/v1"))
	for _, value := range values {
		_, _ = hash.Write([]byte{0})
		_, _ = hash.Write([]byte(value))
	}
	digest := hash.Sum(nil)
	return kind + "_" + base64.RawURLEncoding.EncodeToString(digest[:18])
}

func serverHostname(server string) string {
	parsed, err := url.Parse(server)
	if err == nil && parsed.Hostname() != "" {
		return parsed.Hostname()
	}
	return server
}

func absoluteSourcePath(source string) string {
	if source == "" {
		return ""
	}
	absolute, err := filepath.Abs(source)
	if err != nil {
		return filepath.Clean(source)
	}
	return filepath.Clean(absolute)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func uniqueNonEmpty(values ...string) []string {
	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		if value == "" {
			continue
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}
