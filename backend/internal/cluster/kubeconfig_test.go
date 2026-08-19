package cluster

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"k8s.io/client-go/tools/clientcmd"
)

func TestDiscoverUsesKUBECONFIGMergeRulesAndProvenance(t *testing.T) {
	tempDirectory := t.TempDir()
	firstPath := filepath.Join(tempDirectory, "one", "config")
	secondPath := filepath.Join(tempDirectory, "two", "config")
	writeFile(t, firstPath, `
apiVersion: v1
kind: Config
clusters:
- name: shared
  cluster:
    server: https://first.example.test:6443
- name: first-only
  cluster:
    server: https://first-only.example.test
users:
- name: first-user
  user:
    token: first-token
contexts:
- name: alpha
  context:
    cluster: shared
    user: first-user
- name: from-first
  context:
    cluster: first-only
    user: first-user
current-context: alpha
`)
	writeFile(t, secondPath, `
apiVersion: v1
kind: Config
clusters:
- name: shared
  cluster:
    server: https://ignored.example.test
- name: second-only
  cluster:
    server: https://second.example.test:8443/path
users:
- name: second-user
  user:
    username: operator
    password: secret
contexts:
- name: beta
  context:
    cluster: second-only
    user: second-user
    namespace: kube-system
current-context: beta
`)

	t.Setenv(clientcmd.RecommendedConfigPathEnvVar, strings.Join(
		[]string{firstPath, secondPath},
		string(os.PathListSeparator),
	))
	catalog, err := Discover()
	if err != nil {
		t.Fatalf("Discover() error = %v", err)
	}

	contexts := catalog.Contexts()
	if names := contextNames(contexts); !reflect.DeepEqual(names, []string{"alpha", "beta", "from-first"}) {
		t.Fatalf("context names = %v", names)
	}

	alpha := requireContextNamed(t, catalog, "alpha")
	if !alpha.Current {
		t.Error("alpha.Current = false, want true (first file wins for current-context)")
	}
	if alpha.ServerHostname != "first.example.test" {
		t.Errorf("alpha.ServerHostname = %q", alpha.ServerHostname)
	}
	if alpha.DefaultNamespace != DefaultNamespace {
		t.Errorf("alpha.DefaultNamespace = %q", alpha.DefaultNamespace)
	}
	if alpha.ContextSourcePath != firstPath || alpha.ClusterSourcePath != firstPath || alpha.AuthInfoSourcePath != firstPath {
		t.Errorf("alpha provenance = %#v", alpha)
	}
	if !reflect.DeepEqual(alpha.SourcePaths, []string{firstPath}) {
		t.Errorf("alpha.SourcePaths = %v", alpha.SourcePaths)
	}

	beta := requireContextNamed(t, catalog, "beta")
	if beta.Current {
		t.Error("beta.Current = true, want false")
	}
	if beta.ServerHostname != "second.example.test" || beta.DefaultNamespace != "kube-system" {
		t.Errorf("beta metadata = %#v", beta)
	}
	if beta.SourcePath != secondPath || !reflect.DeepEqual(beta.SourcePaths, []string{secondPath}) {
		t.Errorf("beta provenance = %#v", beta)
	}
}

func TestDiscoverFindsTopLevelKubeconfigsThroughSymlinkedHomeDirectory(t *testing.T) {
	home := t.TempDir()
	documents := filepath.Join(home, "Documents", "kube")
	if err := os.MkdirAll(documents, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(documents, filepath.Join(home, ".kube")); err != nil {
		t.Fatal(err)
	}
	defaultPath := filepath.Join(home, ".kube", "config")
	writeFile(t, defaultPath, kubeconfigForContext("orbstack", "shared", "https://orbstack.example.test"))
	for index := 0; index < 90; index++ {
		name := fmt.Sprintf("cluster-%02d", index)
		writeFile(t, filepath.Join(documents, name+".kubeconfig"),
			kubeconfigForContext(name, name, "https://"+name+".example.test"))
	}
	writeFile(t, filepath.Join(documents, "extra.yaml"),
		kubeconfigForContext("yaml-context", "yaml", "https://yaml.example.test"))
	writeFile(t, filepath.Join(documents, "without-extension"),
		kubeconfigForContext("bare-context", "bare", "https://bare.example.test"))
	writeFile(t, filepath.Join(documents, "init.sh"), "export KUBECONFIG=/must/not/run\n")
	writeFile(t, filepath.Join(documents, "broken.yml"), "apiVersion: v1\nkind: Config\ncontexts: [\n")
	if err := os.Mkdir(filepath.Join(documents, "cache"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(documents, "cache", "nested.kubeconfig"),
		kubeconfigForContext("nested", "nested", "https://nested.example.test"))

	t.Setenv("HOME", home)
	t.Setenv(clientcmd.RecommendedConfigPathEnvVar, "")
	withRecommendedHomeFile(t, defaultPath)
	catalog, err := Discover()
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	contexts := catalog.Contexts()
	if len(contexts) != 93 {
		t.Fatalf("context count = %d, want 93; names=%v", len(contexts), contextNames(contexts))
	}
	for _, name := range []string{"orbstack", "cluster-00", "cluster-89", "yaml-context", "bare-context"} {
		if !hasContextNamed(catalog, name) {
			t.Errorf("context %q was not discovered", name)
		}
	}
	if hasContextNamed(catalog, "nested") {
		t.Fatal("discovery recursed into a subdirectory")
	}
	info := requireContextNamed(t, catalog, "cluster-00")
	if info.ContextSourcePath != filepath.Join(home, ".kube", "cluster-00.kubeconfig") {
		t.Fatalf("symlinked source provenance = %q", info.ContextSourcePath)
	}
}

func TestHomeKubeconfigDiscoveryKeepsDefaultAndSiblingContextsDistinct(t *testing.T) {
	home := t.TempDir()
	kubeDirectory := filepath.Join(home, ".kube")
	defaultPath := filepath.Join(kubeDirectory, "config")
	writeFile(t, defaultPath, `
apiVersion: v1
kind: Config
clusters:
- name: shared
  cluster: {server: https://default.example.test}
contexts:
- name: duplicate
  context: {cluster: shared}
current-context: duplicate
`)
	writeFile(t, filepath.Join(kubeDirectory, "a.kubeconfig"), `
apiVersion: v1
kind: Config
clusters:
- name: shared
  cluster: {server: https://a.example.test}
- name: a-only
  cluster: {server: https://a-only.example.test}
contexts:
- name: duplicate
  context: {cluster: a-only}
- name: lexical-duplicate
  context: {cluster: a-only}
- name: from-a
  context: {cluster: a-only}
current-context: lexical-duplicate
`)
	writeFile(t, filepath.Join(kubeDirectory, "z.kubeconfig"), `
apiVersion: v1
kind: Config
clusters:
- name: shared
  cluster: {server: https://z.example.test}
- name: z-only
  cluster: {server: https://z-only.example.test}
contexts:
- name: lexical-duplicate
  context: {cluster: z-only}
- name: from-z
  context: {cluster: z-only}
current-context: from-z
`)

	t.Setenv("HOME", home)
	t.Setenv(clientcmd.RecommendedConfigPathEnvVar, "")
	withRecommendedHomeFile(t, defaultPath)
	catalog, err := Discover()
	if err != nil {
		t.Fatal(err)
	}
	duplicate := requireContextNamedFrom(t, catalog, "duplicate", defaultPath)
	if duplicate.ServerHostname != "default.example.test" ||
		duplicate.ContextSourcePath != defaultPath ||
		duplicate.ClusterSourcePath != defaultPath {
		t.Fatalf("default duplicate provenance = %#v", duplicate)
	}
	aPath := filepath.Join(kubeDirectory, "a.kubeconfig")
	zPath := filepath.Join(kubeDirectory, "z.kubeconfig")
	aDuplicate := requireContextNamedFrom(t, catalog, "duplicate", aPath)
	if aDuplicate.ServerHostname != "a-only.example.test" || aDuplicate.Current {
		t.Fatalf("sibling duplicate binding = %#v", aDuplicate)
	}
	lexicalA := requireContextNamedFrom(t, catalog, "lexical-duplicate", aPath)
	if lexicalA.ServerHostname != "a-only.example.test" || lexicalA.Current {
		t.Fatalf("a lexical duplicate binding = %#v", lexicalA)
	}
	lexicalZ := requireContextNamedFrom(t, catalog, "lexical-duplicate", zPath)
	if lexicalZ.ServerHostname != "z-only.example.test" || lexicalZ.Current {
		t.Fatalf("z lexical duplicate binding = %#v", lexicalZ)
	}
	fromZ := requireContextNamed(t, catalog, "from-z")
	if fromZ.ServerHostname != "z-only.example.test" {
		t.Fatalf("from-z = %#v", fromZ)
	}
	if current := requireContextNamedFrom(t, catalog, "duplicate", defaultPath); !current.Current {
		t.Fatalf("default current-context did not retain precedence: %#v", current)
	}
}

func TestHomeDiscoveryBindsEachContextToCredentialsFromItsOwnSource(t *testing.T) {
	home := t.TempDir()
	kubeDirectory := filepath.Join(home, ".kube")
	defaultPath := filepath.Join(kubeDirectory, "config")
	firstPath := filepath.Join(kubeDirectory, "a.kubeconfig")
	secondPath := filepath.Join(kubeDirectory, "z.kubeconfig")
	writeFile(t, defaultPath, kubeconfigForContext(
		"orbstack", "orbstack", "https://orbstack.example.test"))
	writeFile(t, firstPath, kubeconfigWithSharedNames(
		"admin@first", "first", "https://first.example.test", "first-certificate", "first-key"))
	writeFile(t, secondPath, kubeconfigWithSharedNames(
		"admin@second", "second", "https://second.example.test", "second-certificate", "second-key"))

	t.Setenv("HOME", home)
	t.Setenv(clientcmd.RecommendedConfigPathEnvVar, "")
	withRecommendedHomeFile(t, defaultPath)
	catalog, err := Discover()
	if err != nil {
		t.Fatal(err)
	}

	first := requireContextNamed(t, catalog, "admin@first")
	second := requireContextNamed(t, catalog, "admin@second")
	firstConfig, err := catalog.RESTConfig(first.ID)
	if err != nil {
		t.Fatal(err)
	}
	secondConfig, err := catalog.RESTConfig(second.ID)
	if err != nil {
		t.Fatal(err)
	}
	if firstConfig.Host != "https://first.example.test" ||
		string(firstConfig.TLSClientConfig.CertData) != "first-certificate" ||
		string(firstConfig.TLSClientConfig.KeyData) != "first-key" {
		t.Fatalf("first context was not bound to its source configuration")
	}
	if secondConfig.Host != "https://second.example.test" ||
		string(secondConfig.TLSClientConfig.CertData) != "second-certificate" ||
		string(secondConfig.TLSClientConfig.KeyData) != "second-key" {
		t.Fatalf("second context was not bound to its source configuration")
	}

	// This is the regression: client-go's ordinary flat merge resolves the
	// shared user name from the earlier file, even for the later context.
	flat, err := DiscoverPaths([]string{firstPath, secondPath})
	if err != nil {
		t.Fatal(err)
	}
	flatSecond, err := flat.RESTConfig(requireContextNamed(t, flat, "admin@second").ID)
	if err != nil {
		t.Fatal(err)
	}
	if string(flatSecond.TLSClientConfig.CertData) != "first-certificate" {
		t.Fatal("test fixture no longer reproduces client-go's flat-merge credential collision")
	}
}

func TestHomeDiscoveryKeepsSameNameContextsDistinctByOpaqueID(t *testing.T) {
	home := t.TempDir()
	kubeDirectory := filepath.Join(home, ".kube")
	defaultPath := filepath.Join(kubeDirectory, "config")
	firstPath := filepath.Join(kubeDirectory, "a.kubeconfig")
	secondPath := filepath.Join(kubeDirectory, "z.kubeconfig")
	writeFile(t, defaultPath, kubeconfigForContext(
		"orbstack", "orbstack", "https://orbstack.example.test"))
	writeFile(t, firstPath, kubeconfigWithSharedNames(
		"default", "first", "https://first.example.test", "first-certificate", "first-key"))
	writeFile(t, secondPath, kubeconfigWithSharedNames(
		"default", "second", "https://second.example.test", "second-certificate", "second-key"))

	t.Setenv("HOME", home)
	t.Setenv(clientcmd.RecommendedConfigPathEnvVar, "")
	withRecommendedHomeFile(t, defaultPath)
	catalog, err := Discover()
	if err != nil {
		t.Fatal(err)
	}
	var duplicates []ContextInfo
	for _, info := range catalog.Contexts() {
		if info.Name == "default" {
			duplicates = append(duplicates, info)
		}
	}
	if len(duplicates) != 2 || duplicates[0].ID == duplicates[1].ID {
		t.Fatalf("same-name contexts were not independently addressable: %#v", duplicates)
	}
	configs := make(map[string]string)
	for _, info := range duplicates {
		config, err := catalog.RESTConfig(info.ID)
		if err != nil {
			t.Fatal(err)
		}
		configs[config.Host] = string(config.TLSClientConfig.CertData)
	}
	if !reflect.DeepEqual(configs, map[string]string{
		"https://first.example.test":  "first-certificate",
		"https://second.example.test": "second-certificate",
	}) {
		t.Fatalf("same-name source bindings = %v", configs)
	}
}

func TestDiscoverWithKUBECONFIGDoesNotScanHomeDirectory(t *testing.T) {
	home := t.TempDir()
	homeConfig := filepath.Join(home, ".kube", "extra.kubeconfig")
	envConfig := filepath.Join(t.TempDir(), "explicit")
	writeFile(t, homeConfig, kubeconfigForContext("home-only", "home", "https://home.example.test"))
	writeFile(t, envConfig, kubeconfigForContext("env-only", "env", "https://env.example.test"))
	t.Setenv("HOME", home)
	t.Setenv(clientcmd.RecommendedConfigPathEnvVar, envConfig)
	catalog, err := Discover()
	if err != nil {
		t.Fatal(err)
	}
	if names := contextNames(catalog.Contexts()); !reflect.DeepEqual(names, []string{"env-only"}) {
		t.Fatalf("KUBECONFIG contexts = %v", names)
	}
}

func TestRESTConfigLoadsRelativeAndEmbeddedCredentials(t *testing.T) {
	tempDirectory := t.TempDir()
	configPath := filepath.Join(tempDirectory, "nested", "config")
	caPath := filepath.Join(tempDirectory, "nested", "pki", "ca.pem")
	certificatePath := filepath.Join(tempDirectory, "nested", "pki", "client.pem")
	keyPath := filepath.Join(tempDirectory, "nested", "pki", "client-key.pem")
	tokenPath := filepath.Join(tempDirectory, "nested", "credentials", "token")
	writeFile(t, caPath, "CA BYTES")
	writeFile(t, certificatePath, "CERT BYTES")
	writeFile(t, keyPath, "KEY BYTES")
	writeFile(t, tokenPath, "file-token\n")
	writeFile(t, configPath, `
apiVersion: v1
kind: Config
clusters:
- name: file-cluster
  cluster:
    server: https://files.example.test
    certificate-authority: pki/ca.pem
    tls-server-name: kubernetes.internal
- name: embedded-cluster
  cluster:
    server: https://embedded.example.test
    certificate-authority-data: `+base64.StdEncoding.EncodeToString([]byte("EMBEDDED CA"))+`
users:
- name: file-user
  user:
    client-certificate: pki/client.pem
    client-key: pki/client-key.pem
    tokenFile: credentials/token
- name: embedded-user
  user:
    client-certificate-data: `+base64.StdEncoding.EncodeToString([]byte("EMBEDDED CERT"))+`
    client-key-data: `+base64.StdEncoding.EncodeToString([]byte("EMBEDDED KEY"))+`
    token: embedded-token
- name: basic-user
  user:
    username: alice
    password: password
contexts:
- name: files
  context:
    cluster: file-cluster
    user: file-user
- name: embedded
  context:
    cluster: embedded-cluster
    user: embedded-user
- name: basic
  context:
    cluster: embedded-cluster
    user: basic-user
current-context: files
`)

	catalog := discoverExplicit(t, configPath)
	filesInfo := requireContextNamed(t, catalog, "files")
	filesConfig, err := catalog.RESTConfig(filesInfo.ID)
	if err != nil {
		t.Fatalf("RESTConfig(files ID) error = %v", err)
	}
	if filesConfig.Host != "https://files.example.test" || filesConfig.TLSClientConfig.ServerName != "kubernetes.internal" {
		t.Errorf("files REST config target = %#v", filesConfig)
	}
	if filesConfig.TLSClientConfig.CAFile != caPath || filesConfig.TLSClientConfig.CertFile != certificatePath || filesConfig.TLSClientConfig.KeyFile != keyPath {
		t.Errorf("relative TLS paths were not resolved: %#v", filesConfig.TLSClientConfig)
	}
	if filesConfig.BearerTokenFile != tokenPath {
		t.Errorf("BearerTokenFile = %q, want %q", filesConfig.BearerTokenFile, tokenPath)
	}

	embeddedConfig, err := catalog.RESTConfig(requireContextNamed(t, catalog, "embedded").ID)
	if err != nil {
		t.Fatalf("RESTConfig(embedded) error = %v", err)
	}
	if string(embeddedConfig.TLSClientConfig.CAData) != "EMBEDDED CA" ||
		string(embeddedConfig.TLSClientConfig.CertData) != "EMBEDDED CERT" ||
		string(embeddedConfig.TLSClientConfig.KeyData) != "EMBEDDED KEY" {
		t.Errorf("embedded TLS data = %#v", embeddedConfig.TLSClientConfig)
	}
	if embeddedConfig.BearerToken != "embedded-token" {
		t.Errorf("BearerToken = %q", embeddedConfig.BearerToken)
	}
	basicConfig, err := catalog.RESTConfig(requireContextNamed(t, catalog, "basic").ID)
	if err != nil {
		t.Fatalf("RESTConfig(basic) error = %v", err)
	}
	if basicConfig.Username != "alice" || basicConfig.Password != "password" {
		t.Errorf("basic authentication = %q/%q", basicConfig.Username, basicConfig.Password)
	}
}

func TestUnsupportedAuthenticationIsReportedAndNeverExecuted(t *testing.T) {
	tempDirectory := t.TempDir()
	configPath := filepath.Join(tempDirectory, "config")
	markerPath := filepath.Join(tempDirectory, "plugin-ran")
	pluginPath := filepath.Join(tempDirectory, "credential-plugin")
	writeExecutable(t, pluginPath, "#!/bin/sh\ntouch "+shellQuote(markerPath)+"\nexit 42\n")
	writeFile(t, configPath, `
apiVersion: v1
kind: Config
clusters:
- name: cluster
  cluster:
    server: https://example.test
users:
- name: exec-user
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1
      command: ./credential-plugin
      interactiveMode: Never
- name: provider-user
  user:
    auth-provider:
      name: oidc
      config:
        client-secret: must-not-leak
- name: both-user
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1
      command: ./credential-plugin
      interactiveMode: Never
    auth-provider:
      name: oidc
contexts:
- name: exec
  context: {cluster: cluster, user: exec-user}
- name: provider
  context: {cluster: cluster, user: provider-user}
- name: both
  context: {cluster: cluster, user: both-user}
`)

	catalog := discoverExplicit(t, configPath)
	checks := map[string][]UnsupportedAuthMechanism{
		"exec":     {UnsupportedAuthExec},
		"provider": {UnsupportedAuthProvider},
		"both":     {UnsupportedAuthExec, UnsupportedAuthProvider},
	}
	for contextName, wantMechanisms := range checks {
		contextInfo := requireContextNamed(t, catalog, contextName)
		if !reflect.DeepEqual(contextInfo.UnsupportedAuthentications, wantMechanisms) {
			t.Errorf("%s unsupported mechanisms = %v, want %v", contextName, contextInfo.UnsupportedAuthentications, wantMechanisms)
		}

		_, err := catalog.RESTConfig(contextInfo.ID)
		var unsupportedError *UnsupportedAuthenticationError
		if !errors.As(err, &unsupportedError) {
			t.Fatalf("RESTConfig(%s) error = %T %v", contextName, err, err)
		}
		if !reflect.DeepEqual(unsupportedError.Mechanisms, wantMechanisms) {
			t.Errorf("RESTConfig(%s) mechanisms = %v", contextName, unsupportedError.Mechanisms)
		}
		if strings.Contains(unsupportedError.Error(), "must-not-leak") {
			t.Errorf("error leaked auth-provider configuration: %v", unsupportedError)
		}
	}
	if _, err := os.Stat(markerPath); !os.IsNotExist(err) {
		t.Fatalf("exec credential plugin ran; stat marker error = %v", err)
	}
}

func TestStableIdentity(t *testing.T) {
	tempDirectory := t.TempDir()
	firstPath := filepath.Join(tempDirectory, "first")
	secondPath := filepath.Join(tempDirectory, "second")
	config := `
apiVersion: v1
kind: Config
clusters:
- name: target
  cluster: {server: https://example.test:6443}
users:
- name: operator
  user: {token: token}
contexts:
- name: production
  context: {cluster: target, user: operator}
`
	writeFile(t, firstPath, config)
	writeFile(t, secondPath, config)
	first := discoverExplicit(t, firstPath).Contexts()[0]
	second := discoverExplicit(t, secondPath).Contexts()[0]
	if first.ID != second.ID || first.ClusterID != second.ClusterID {
		t.Errorf("identity changed with source path: first=%#v second=%#v", first, second)
	}
	if !strings.HasPrefix(first.ID, "context_") || !strings.HasPrefix(first.ClusterID, "cluster_") {
		t.Errorf("unexpected IDs: context=%q cluster=%q", first.ID, first.ClusterID)
	}
}

func TestCatalogRejectsDisplayNameReferences(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config")
	writeFile(t, configPath, kubeconfigForContext("production", "target", "https://example.test"))
	catalog := discoverExplicit(t, configPath)
	info := requireContextNamed(t, catalog, "production")

	if _, ok := catalog.Context(info.Name); ok {
		t.Fatal("Context accepted a display name instead of an opaque ID")
	}
	_, err := catalog.RESTConfig(info.Name)
	var notFoundError *ContextNotFoundError
	if !errors.As(err, &notFoundError) {
		t.Fatalf("RESTConfig(display name) error = %T %v", err, err)
	}
}

func TestUnknownContext(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config")
	writeFile(t, configPath, `
apiVersion: v1
kind: Config
clusters: []
users: []
contexts: []
`)
	catalog := discoverExplicit(t, configPath)
	_, err := catalog.RESTConfig("missing")
	var notFoundError *ContextNotFoundError
	if !errors.As(err, &notFoundError) {
		t.Fatalf("RESTConfig(missing) error = %T %v", err, err)
	}
}

func TestDiscoverPathsUsesExplicitMergeOrder(t *testing.T) {
	t.Parallel()
	directory := t.TempDir()
	first := filepath.Join(directory, "first")
	second := filepath.Join(directory, "second")
	writeFile(t, first, `
apiVersion: v1
kind: Config
clusters:
- name: target
  cluster: {server: https://first.example.test}
contexts:
- name: first
  context: {cluster: target}
`)
	writeFile(t, second, `
apiVersion: v1
kind: Config
clusters:
- name: target
  cluster: {server: https://ignored.example.test}
- name: other
  cluster: {server: https://second.example.test}
contexts:
- name: second
  context: {cluster: other}
`)
	catalog, err := DiscoverPaths([]string{first, second})
	if err != nil {
		t.Fatal(err)
	}
	if names := contextNames(catalog.Contexts()); !reflect.DeepEqual(names, []string{"first", "second"}) {
		t.Fatalf("context names = %v", names)
	}
	info := requireContextNamed(t, catalog, "first")
	if info.ServerHostname != "first.example.test" {
		t.Fatalf("first-precedence context = %#v", info)
	}
}

func discoverExplicit(t *testing.T, path string) *Catalog {
	t.Helper()
	rules := clientcmd.NewDefaultClientConfigLoadingRules()
	rules.ExplicitPath = path
	catalog, err := DiscoverWithRules(rules)
	if err != nil {
		t.Fatalf("DiscoverWithRules(%q) error = %v", path, err)
	}
	return catalog
}

func contextNames(contexts []ContextInfo) []string {
	names := make([]string, len(contexts))
	for index, contextInfo := range contexts {
		names[index] = contextInfo.Name
	}
	return names
}

func requireContextNamed(t *testing.T, catalog *Catalog, name string) ContextInfo {
	t.Helper()
	var matches []ContextInfo
	for _, info := range catalog.Contexts() {
		if info.Name == name {
			matches = append(matches, info)
		}
	}
	if len(matches) != 1 {
		t.Fatalf("contexts named %q = %d, want exactly one", name, len(matches))
	}
	info, ok := catalog.Context(matches[0].ID)
	if !ok {
		t.Fatalf("context ID %q for %q was not found", matches[0].ID, name)
	}
	return info
}

func requireContextNamedFrom(t *testing.T, catalog *Catalog, name, sourcePath string) ContextInfo {
	t.Helper()
	var matches []ContextInfo
	for _, info := range catalog.Contexts() {
		if info.Name == name && filepath.Clean(info.ContextSourcePath) == filepath.Clean(sourcePath) {
			matches = append(matches, info)
		}
	}
	if len(matches) != 1 {
		t.Fatalf("contexts named %q from %q = %d, want exactly one", name, sourcePath, len(matches))
	}
	info, ok := catalog.Context(matches[0].ID)
	if !ok {
		t.Fatalf("context ID %q for %q from %q was not found", matches[0].ID, name, sourcePath)
	}
	return info
}

func hasContextNamed(catalog *Catalog, name string) bool {
	for _, info := range catalog.Contexts() {
		if info.Name == name {
			return true
		}
	}
	return false
}

func writeFile(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll(%q) error = %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatalf("WriteFile(%q) error = %v", path, err)
	}
}

func writeExecutable(t *testing.T, path, contents string) {
	t.Helper()
	writeFile(t, path, contents)
	if err := os.Chmod(path, 0o700); err != nil {
		t.Fatalf("Chmod(%q) error = %v", path, err)
	}
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func kubeconfigForContext(contextName, clusterName, server string) string {
	return fmt.Sprintf(`
apiVersion: v1
kind: Config
clusters:
- name: %s
  cluster: {server: %s}
contexts:
- name: %s
  context: {cluster: %s}
current-context: %s
`, clusterName, server, contextName, clusterName, contextName)
}

func kubeconfigWithSharedNames(
	contextName, clusterName, server, certificate, key string,
) string {
	return fmt.Sprintf(`
apiVersion: v1
kind: Config
clusters:
- name: %s
  cluster: {server: %s}
users:
- name: kubernetes-admin
  user:
    client-certificate-data: %s
    client-key-data: %s
contexts:
- name: %s
  context: {cluster: %s, user: kubernetes-admin}
current-context: %s
`, clusterName, server,
		base64.StdEncoding.EncodeToString([]byte(certificate)),
		base64.StdEncoding.EncodeToString([]byte(key)),
		contextName, clusterName, contextName)
}

func withRecommendedHomeFile(t *testing.T, path string) {
	t.Helper()
	previousDirectory := clientcmd.RecommendedConfigDir
	previousFile := clientcmd.RecommendedHomeFile
	clientcmd.RecommendedConfigDir = filepath.Dir(path)
	clientcmd.RecommendedHomeFile = path
	t.Cleanup(func() {
		clientcmd.RecommendedConfigDir = previousDirectory
		clientcmd.RecommendedHomeFile = previousFile
	})
}
