package credentialexec

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestProxyForwardsSuccessfulCredentialOutput(t *testing.T) {
	plugin := filepath.Join(t.TempDir(), "plugin")
	writeExecutable(t, plugin, "#!/bin/sh\nprintf '%s' \"$KUBERNETES_EXEC_INFO\"\n")
	t.Setenv("KUBERNETES_EXEC_INFO", `{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential"}`)
	var stdout, stderr bytes.Buffer
	code := RunProxy([]string{
		"--timeout", "2s", "--command", plugin, "--",
	}, bytes.NewReader(nil), &stdout, &stderr)
	if code != 0 {
		t.Fatalf("RunProxy code = %d, stderr = %q", code, stderr.String())
	}
	if stdout.String() != os.Getenv("KUBERNETES_EXEC_INFO") || stderr.Len() != 0 {
		t.Fatalf("proxy output = %q / %q", stdout.String(), stderr.String())
	}
}

func TestProxyTimesOutAndDiscardsRawStderr(t *testing.T) {
	plugin := filepath.Join(t.TempDir(), "plugin")
	writeExecutable(t, plugin, "#!/bin/sh\ntrap '' TERM\necho must-not-leak >&2\nsleep 30\n")
	var stdout, stderr bytes.Buffer
	started := time.Now()
	code := RunProxy([]string{
		"--timeout", "50ms", "--command", plugin, "--",
	}, bytes.NewReader(nil), &stdout, &stderr)
	if code != ProxyExitTimedOut {
		t.Fatalf("RunProxy code = %d, stderr = %q", code, stderr.String())
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("proxy timeout took %s", elapsed)
	}
	if stdout.Len() != 0 || strings.Contains(stderr.String(), "must-not-leak") ||
		!strings.Contains(stderr.String(), "timed out") {
		t.Fatalf("proxy output = %q / %q", stdout.String(), stderr.String())
	}
}

func TestProxyRejectsOversizedSuccessfulOutput(t *testing.T) {
	plugin := filepath.Join(t.TempDir(), "plugin")
	writeExecutable(t, plugin, "#!/bin/sh\nyes x | head -c 1100000\n")
	var stdout, stderr bytes.Buffer
	code := RunProxy([]string{
		"--timeout", "2s", "--command", plugin, "--",
	}, bytes.NewReader(nil), &stdout, &stderr)
	if code != ProxyExitPluginFailed || stdout.Len() != 0 ||
		!strings.Contains(stderr.String(), "exceeded") {
		t.Fatalf("proxy result = %d, %d bytes, %q", code, stdout.Len(), stderr.String())
	}
}
