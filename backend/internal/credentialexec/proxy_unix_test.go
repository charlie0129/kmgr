//go:build darwin || linux || freebsd || openbsd || netbsd || dragonfly

package credentialexec

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestProxyTimeoutTerminatesPluginProcessGroup(t *testing.T) {
	directory := t.TempDir()
	plugin := filepath.Join(directory, "plugin")
	pidFile := filepath.Join(directory, "child.pid")
	writeExecutable(t, plugin, `#!/bin/sh
trap '' TERM
sleep 30 &
child=$!
printf '%s\n' "$child" > "$1"
wait "$child"
`)
	var stderr bytes.Buffer
	code := RunProxy([]string{
		"--timeout", "100ms", "--command", plugin, "--", pidFile,
	}, bytes.NewReader(nil), &bytes.Buffer{}, &stderr)
	if code != ProxyExitTimedOut {
		t.Fatalf("RunProxy code = %d, stderr = %q", code, stderr.String())
	}
	contents, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	processID, err := strconv.Atoi(strings.TrimSpace(string(contents)))
	if err != nil {
		t.Fatal(err)
	}
	assertProcessExited(t, processID)
}

func TestProxySuccessTerminatesBackgroundPluginDescendants(t *testing.T) {
	directory := t.TempDir()
	plugin := filepath.Join(directory, "plugin")
	pidFile := filepath.Join(directory, "child.pid")
	writeExecutable(t, plugin, `#!/bin/sh
sleep 30 >/dev/null 2>&1 &
printf '%s\n' "$!" > "$1"
printf '%s' '{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential"}'
`)
	var stdout, stderr bytes.Buffer
	code := RunProxy([]string{
		"--timeout", "2s", "--command", plugin, "--", pidFile,
	}, bytes.NewReader(nil), &stdout, &stderr)
	if code != 0 {
		t.Fatalf("RunProxy code = %d, stderr = %q", code, stderr.String())
	}
	contents, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	processID, err := strconv.Atoi(strings.TrimSpace(string(contents)))
	if err != nil {
		t.Fatal(err)
	}
	assertProcessExited(t, processID)
}

func TestSupervisorInterruptionTerminatesPluginProcessGroup(t *testing.T) {
	directory := t.TempDir()
	plugin := filepath.Join(directory, "plugin")
	pidFile := filepath.Join(directory, "child.pid")
	writeExecutable(t, plugin, `#!/bin/sh
trap '' TERM
sleep 30 &
printf '%s\n' "$!" > "$1"
wait
`)
	interrupts := make(chan os.Signal, 1)
	go func() {
		deadline := time.Now().Add(time.Second)
		for time.Now().Before(deadline) {
			contents, err := os.ReadFile(pidFile)
			if err == nil && strings.TrimSpace(string(contents)) != "" {
				interrupts <- syscall.SIGTERM
				return
			}
			time.Sleep(time.Millisecond)
		}
	}()

	result := runSupervised(supervisedCommand{
		command: plugin, arguments: []string{pidFile}, environment: os.Environ(),
		timeout: 2 * time.Second, outputLimit: 1024, interrupt: interrupts,
	})
	if !result.interrupted {
		t.Fatalf("supervised result = %#v", result)
	}
	contents, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	processID, err := strconv.Atoi(strings.TrimSpace(string(contents)))
	if err != nil {
		t.Fatal(err)
	}
	assertProcessExited(t, processID)
}

func assertProcessExited(t *testing.T, processID int) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for {
		err := syscall.Kill(processID, 0)
		if errors.Is(err, syscall.ESRCH) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("credential plugin child process %d survived group termination: %v", processID, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
