package transport

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPrivateEndpointPermissionsAndCleanup(t *testing.T) {
	t.Parallel()
	base, err := os.MkdirTemp("/tmp", "kmgr-test.")
	if err != nil {
		t.Fatalf("MkdirTemp: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(base) })
	endpoint, err := ListenPrivateUnix(base)
	if err != nil {
		t.Fatalf("ListenPrivateUnix: %v", err)
	}
	directory := endpoint.Directory()

	directoryInfo, err := os.Stat(directory)
	if err != nil {
		t.Fatalf("stat directory: %v", err)
	}
	if got := directoryInfo.Mode().Perm(); got != 0o700 {
		t.Fatalf("directory mode = %o, want 700", got)
	}

	socketInfo, err := os.Stat(endpoint.SocketPath())
	if err != nil {
		t.Fatalf("stat socket: %v", err)
	}
	if got := socketInfo.Mode().Perm(); got != 0o600 {
		t.Fatalf("socket mode = %o, want 600", got)
	}

	if err := endpoint.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if _, err := os.Stat(directory); !os.IsNotExist(err) {
		t.Fatalf("private directory remains after Close: %v", err)
	}
}

func TestPrivateEndpointRejectsLongPath(t *testing.T) {
	t.Parallel()
	base := t.TempDir()
	longBase := filepath.Join(base, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	if err := os.Mkdir(longBase, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if _, err := ListenPrivateUnix(longBase); err == nil {
		t.Fatal("ListenPrivateUnix accepted an overlong socket path")
	}
}
