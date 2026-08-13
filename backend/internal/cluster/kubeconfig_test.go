package cluster

import (
	"encoding/base64"
	"errors"
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

	alpha, ok := catalog.Context("alpha")
	if !ok {
		t.Fatal("alpha context was not found")
	}
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

	beta, ok := catalog.Context("beta")
	if !ok {
		t.Fatal("beta context was not found")
	}
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
	filesInfo, ok := catalog.Context("files")
	if !ok {
		t.Fatal("files context was not found")
	}
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

	embeddedConfig, err := catalog.RESTConfig("embedded")
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
	basicConfig, err := catalog.RESTConfig("basic")
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
		contextInfo, ok := catalog.Context(contextName)
		if !ok {
			t.Fatalf("context %q was not found", contextName)
		}
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
	info, ok := catalog.Context("first")
	if !ok || info.ServerHostname != "first.example.test" {
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
