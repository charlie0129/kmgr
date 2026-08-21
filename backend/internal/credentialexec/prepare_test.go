package credentialexec

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"k8s.io/client-go/rest"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
)

func TestPreparerUsesLoginShellPathAndRewritesThroughProxy(t *testing.T) {
	directory := t.TempDir()
	plugin := filepath.Join(directory, "cloud-login")
	writeExecutable(t, plugin, "#!/bin/sh\nexit 0\n")
	shell := filepath.Join(directory, "login-shell")
	writeExecutable(t, shell, "#!/bin/sh\nprintf '\\036kmgr-path\\037%s\\036' '"+directory+"'\n")
	proxy := filepath.Join(directory, "kmgr-engine")
	writeExecutable(t, proxy, "#!/bin/sh\nexit 0\n")

	preparer := NewPreparer(PreparerConfig{
		ProxyExecutable:        proxy,
		PluginTimeout:          7 * time.Second,
		LoginShell:             shell,
		Environment:            []string{"PATH=/usr/bin:/bin"},
		ConventionalSearchPath: []string{},
	})
	configuration := &rest.Config{ExecProvider: &clientcmdapi.ExecConfig{
		Command: "cloud-login", APIVersion: "client.authentication.k8s.io/v1",
		InteractiveMode: clientcmdapi.IfAvailableExecInteractiveMode,
		Args:            []string{"token", "--cluster", "dev"},
	}}
	if err := preparer.Prepare(configuration); err != nil {
		t.Fatal(err)
	}
	provider := configuration.ExecProvider
	if provider.Command != proxy || !provider.StdinUnavailable {
		t.Fatalf("prepared provider = %#v", provider)
	}
	wantArguments := []string{
		ProxySubcommand, "--timeout", "7s", "--command", filepath.Clean(plugin), "--",
		"token", "--cluster", "dev",
	}
	if !reflect.DeepEqual(provider.Args, wantArguments) {
		t.Fatalf("proxy arguments = %#v, want %#v", provider.Args, wantArguments)
	}
	if got, _ := execEnvironmentValue(provider.Env, "PATH"); got != directory {
		t.Fatalf("prepared PATH = %q", got)
	}
	if provider.PluginPolicy.PolicyType != clientcmdapi.PluginPolicyAllowlist ||
		len(provider.PluginPolicy.Allowlist) != 1 ||
		provider.PluginPolicy.Allowlist[0].Command != proxy {
		t.Fatalf("plugin policy = %#v", provider.PluginPolicy)
	}
}

func TestResolveExecutablePreservesStableSymlinkPath(t *testing.T) {
	directory := t.TempDir()
	target := filepath.Join(directory, "cloud-login-v1")
	writeExecutable(t, target, "#!/bin/sh\nexit 0\n")
	link := filepath.Join(directory, "cloud-login")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}

	resolved, err := resolveExecutable("cloud-login", directory)
	if err != nil {
		t.Fatal(err)
	}
	if resolved != filepath.Clean(link) {
		t.Fatalf("resolved executable = %q, want stable symlink %q", resolved, link)
	}
}

func TestPreparerFallsBackWhenLoginShellPathIsUnavailable(t *testing.T) {
	directory := t.TempDir()
	plugin := filepath.Join(directory, "cloud-login")
	writeExecutable(t, plugin, "#!/bin/sh\nexit 0\n")
	preparer := NewPreparer(PreparerConfig{
		ProxyExecutable:        filepath.Join(directory, "engine"),
		LoginShell:             "/definitely/missing/zsh",
		Environment:            []string{"PATH=/inherited/bin"},
		ConventionalSearchPath: []string{directory},
	})
	configuration := &rest.Config{ExecProvider: &clientcmdapi.ExecConfig{
		Command: "cloud-login", APIVersion: "client.authentication.k8s.io/v1",
		InteractiveMode: clientcmdapi.NeverExecInteractiveMode,
	}}

	if err := preparer.Prepare(configuration); err != nil {
		t.Fatal(err)
	}
	provider := configuration.ExecProvider
	if got, _ := execEnvironmentValue(provider.Env, "PATH"); got != "/inherited/bin"+string(os.PathListSeparator)+directory {
		t.Fatalf("fallback PATH = %q", got)
	}
	if provider.Args[4] != filepath.Clean(plugin) {
		t.Fatalf("resolved plugin path = %q", provider.Args[4])
	}
}

func TestPreparerPreservesExplicitPathAndRejectsInteractivePlugin(t *testing.T) {
	directory := t.TempDir()
	plugin := filepath.Join(directory, "cloud-login")
	writeExecutable(t, plugin, "#!/bin/sh\nexit 0\n")
	preparer := NewPreparer(PreparerConfig{
		ProxyExecutable: filepath.Join(directory, "engine"),
		LoginShell:      "/definitely/missing/zsh",
		Environment:     []string{"PATH=/usr/bin"},
	})
	configuration := &rest.Config{ExecProvider: &clientcmdapi.ExecConfig{
		Command: "cloud-login", APIVersion: "client.authentication.k8s.io/v1",
		InteractiveMode: clientcmdapi.NeverExecInteractiveMode,
		Env:             []clientcmdapi.ExecEnvVar{{Name: "PATH", Value: directory}},
	}}
	if err := preparer.Prepare(configuration); err != nil {
		t.Fatal(err)
	}
	if got, _ := execEnvironmentValue(configuration.ExecProvider.Env, "PATH"); got != directory {
		t.Fatalf("explicit PATH = %q", got)
	}

	configuration = &rest.Config{ExecProvider: &clientcmdapi.ExecConfig{
		Command: plugin, APIVersion: "client.authentication.k8s.io/v1",
		InteractiveMode: clientcmdapi.NeverExecInteractiveMode,
		Env:             []clientcmdapi.ExecEnvVar{{Name: "PATH", Value: ""}},
	}}
	if err := preparer.Prepare(configuration); err != nil {
		t.Fatal(err)
	}
	if got, found := execEnvironmentValue(configuration.ExecProvider.Env, "PATH"); !found || got != "" {
		t.Fatalf("explicit empty PATH = %q, found = %t", got, found)
	}

	configuration = &rest.Config{ExecProvider: &clientcmdapi.ExecConfig{
		Command: plugin, APIVersion: "client.authentication.k8s.io/v1",
		InteractiveMode: clientcmdapi.AlwaysExecInteractiveMode,
	}}
	err := preparer.Prepare(configuration)
	var unsupported *InteractiveModeUnsupportedError
	if !errors.As(err, &unsupported) {
		t.Fatalf("interactive error = %T %v", err, err)
	}
}

func TestPreparerReportsMissingExecutableWithoutLeakingArguments(t *testing.T) {
	preparer := NewPreparer(PreparerConfig{
		ProxyExecutable:        "/engine",
		LoginShell:             "/missing/zsh",
		Environment:            []string{"PATH=/usr/bin:/bin"},
		ConventionalSearchPath: []string{},
	})
	configuration := &rest.Config{ExecProvider: &clientcmdapi.ExecConfig{
		Command: "must-not-exist", Args: []string{"secret-argument"},
		InteractiveMode: clientcmdapi.NeverExecInteractiveMode,
	}}
	err := preparer.Prepare(configuration)
	var notFound *ExecutableNotFoundError
	if !errors.As(err, &notFound) || strings.Contains(err.Error(), "secret-argument") {
		t.Fatalf("missing executable error = %T %v", err, err)
	}
}

func writeExecutable(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o700); err != nil {
		t.Fatal(err)
	}
}
