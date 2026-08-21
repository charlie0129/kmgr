package credentialexec

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"k8s.io/client-go/rest"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
)

const (
	DefaultPluginTimeout    = 10 * time.Second
	MaximumPluginTimeout    = 10 * time.Minute
	DefaultPathProbeTimeout = 2 * time.Second
	maximumPathProbeOutput  = 256 << 10
	maximumResolvedPathSize = 64 << 10
)

var defaultSearchDirectories = []string{
	"/opt/homebrew/bin",
	"/usr/local/bin",
	"/usr/bin",
	"/bin",
	"/usr/sbin",
	"/sbin",
}

type InteractiveModeUnsupportedError struct {
	Mode clientcmdapi.ExecInteractiveMode
}

func (e *InteractiveModeUnsupportedError) Error() string {
	return fmt.Sprintf("exec credential plugin interactive mode %q is unsupported", e.Mode)
}

type ExecutableNotFoundError struct {
	Command string
}

func (e *ExecutableNotFoundError) Error() string {
	return fmt.Sprintf("exec credential plugin %q was not found", e.Command)
}

type PreparerConfig struct {
	ProxyExecutable        string
	PluginTimeout          time.Duration
	LoginShell             string
	PathProbeTimeout       time.Duration
	Environment            []string
	ConventionalSearchPath []string
}

// Preparer resolves an exec plugin once per REST configuration and rewrites it
// through kmgr-engine's bounded proxy mode. Its shell PATH probe is shared by
// every context opened through the same session registry.
type Preparer struct {
	proxyExecutable string
	pluginTimeout   time.Duration
	loginShell      string
	probeTimeout    time.Duration
	environment     []string
	conventional    []string

	pathOnce sync.Once
	path     string
}

func NewPreparer(configuration PreparerConfig) *Preparer {
	pluginTimeout := configuration.PluginTimeout
	if pluginTimeout <= 0 {
		pluginTimeout = DefaultPluginTimeout
	}
	probeTimeout := configuration.PathProbeTimeout
	if probeTimeout <= 0 {
		probeTimeout = DefaultPathProbeTimeout
	}
	proxyExecutable := configuration.ProxyExecutable
	if proxyExecutable == "" {
		proxyExecutable, _ = os.Executable()
	}
	if absolute, err := filepath.Abs(proxyExecutable); err == nil {
		proxyExecutable = absolute
	}
	loginShell := configuration.LoginShell
	if loginShell == "" && runtime.GOOS == "darwin" {
		loginShell = "/bin/zsh"
	}
	environment := configuration.Environment
	if environment == nil {
		environment = os.Environ()
	}
	conventional := configuration.ConventionalSearchPath
	if conventional == nil {
		conventional = defaultSearchDirectories
	}
	return &Preparer{
		proxyExecutable: filepath.Clean(proxyExecutable),
		pluginTimeout:   pluginTimeout,
		loginShell:      loginShell,
		probeTimeout:    probeTimeout,
		environment:     append([]string(nil), environment...),
		conventional:    append([]string(nil), conventional...),
	}
}

func (p *Preparer) Prepare(configuration *rest.Config) error {
	if configuration == nil || configuration.ExecProvider == nil {
		return nil
	}
	if p == nil {
		return errors.New("exec credential preparer is unavailable")
	}
	if p.pluginTimeout <= 0 || p.pluginTimeout > MaximumPluginTimeout {
		return fmt.Errorf("exec credential plugin timeout must be between 1ns and %s", MaximumPluginTimeout)
	}

	provider := configuration.ExecProvider.DeepCopy()
	switch provider.InteractiveMode {
	case clientcmdapi.NeverExecInteractiveMode, clientcmdapi.IfAvailableExecInteractiveMode:
	case clientcmdapi.AlwaysExecInteractiveMode:
		return &InteractiveModeUnsupportedError{Mode: provider.InteractiveMode}
	default:
		return fmt.Errorf("invalid exec credential plugin interactive mode %q", provider.InteractiveMode)
	}

	effectivePath, hasExplicitPath := execEnvironmentValue(provider.Env, "PATH")
	if !hasExplicitPath {
		effectivePath = p.effectivePath()
		provider.Env = append(provider.Env, clientcmdapi.ExecEnvVar{Name: "PATH", Value: effectivePath})
	}
	resolvedCommand, err := resolveExecutable(provider.Command, effectivePath)
	if err != nil {
		return err
	}
	originalArguments := append([]string(nil), provider.Args...)
	provider.Command = p.proxyExecutable
	provider.Args = []string{
		ProxySubcommand,
		"--timeout", p.pluginTimeout.String(),
		"--command", resolvedCommand,
		"--",
	}
	provider.Args = append(provider.Args, originalArguments...)
	provider.StdinUnavailable = true
	provider.StdinUnavailableMessage = "kmgr runs credential plugins without terminal input"
	provider.PluginPolicy = clientcmdapi.PluginPolicy{
		PolicyType: clientcmdapi.PluginPolicyAllowlist,
		Allowlist:  []clientcmdapi.AllowlistEntry{{Command: p.proxyExecutable}},
	}
	configuration.ExecProvider = provider
	return nil
}

func (p *Preparer) effectivePath() string {
	p.pathOnce.Do(func() {
		var directories []string
		if shellPath, ok := probeLoginShellPath(
			p.loginShell,
			p.environment,
			p.probeTimeout,
		); ok {
			directories = uniqueAbsoluteDirectories(filepath.SplitList(shellPath))
		}
		if len(directories) == 0 {
			var fallback []string
			if inherited := environmentValue(p.environment, "PATH"); inherited != "" {
				fallback = append(fallback, filepath.SplitList(inherited)...)
			}
			fallback = append(fallback, p.conventional...)
			directories = uniqueAbsoluteDirectories(fallback)
		}
		p.path = strings.Join(directories, string(os.PathListSeparator))
	})
	return p.path
}

func probeLoginShellPath(shell string, environment []string, timeout time.Duration) (string, bool) {
	if shell == "" || !filepath.IsAbs(shell) || !regularExecutable(shell) || timeout <= 0 {
		return "", false
	}
	const marker = "\x1ekmgr-path\x1f"
	const terminator = "\x1e"
	result := runSupervised(supervisedCommand{
		command:     shell,
		arguments:   []string{"-lic", `builtin printf '\036kmgr-path\037%s\036' "$PATH"`},
		environment: append([]string(nil), environment...),
		timeout:     timeout,
		outputLimit: maximumPathProbeOutput,
	})
	if result.err != nil || result.timedOut || result.outputTooLarge {
		return "", false
	}
	start := bytes.LastIndex(result.stdout, []byte(marker))
	if start < 0 {
		return "", false
	}
	start += len(marker)
	end := bytes.Index(result.stdout[start:], []byte(terminator))
	if end < 0 || end > maximumResolvedPathSize {
		return "", false
	}
	value := string(result.stdout[start : start+end])
	if value == "" || strings.ContainsRune(value, 0) {
		return "", false
	}
	return value, true
}

func resolveExecutable(command, searchPath string) (string, error) {
	if command == "" {
		return "", &ExecutableNotFoundError{Command: command}
	}
	if filepath.IsAbs(command) || strings.ContainsRune(command, filepath.Separator) {
		absolute, err := filepath.Abs(command)
		if err == nil && regularExecutable(absolute) {
			return filepath.Clean(absolute), nil
		}
		return "", &ExecutableNotFoundError{Command: filepath.Base(command)}
	}
	for _, directory := range filepath.SplitList(searchPath) {
		if !filepath.IsAbs(directory) {
			continue
		}
		candidate := filepath.Join(directory, command)
		if regularExecutable(candidate) {
			return filepath.Clean(candidate), nil
		}
	}
	return "", &ExecutableNotFoundError{Command: command}
}

func regularExecutable(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0
}

func uniqueAbsoluteDirectories(paths []string) []string {
	seen := make(map[string]struct{}, len(paths))
	result := make([]string, 0, len(paths))
	for _, path := range paths {
		if path == "" || !filepath.IsAbs(path) {
			continue
		}
		cleaned := filepath.Clean(path)
		if _, ok := seen[cleaned]; ok {
			continue
		}
		seen[cleaned] = struct{}{}
		result = append(result, cleaned)
	}
	return result
}

func execEnvironmentValue(environment []clientcmdapi.ExecEnvVar, name string) (string, bool) {
	value := ""
	found := false
	for _, entry := range environment {
		if entry.Name == name {
			value = entry.Value
			found = true
		}
	}
	return value, found
}

func environmentValue(environment []string, name string) string {
	prefix := name + "="
	value := ""
	for _, entry := range environment {
		if strings.HasPrefix(entry, prefix) {
			value = strings.TrimPrefix(entry, prefix)
		}
	}
	return value
}
