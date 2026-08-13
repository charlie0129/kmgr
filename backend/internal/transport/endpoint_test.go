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

func TestListenPrivateUnixPathUsesCallerDirectoryAndRemovesOnlySocket(t *testing.T) {
	t.Parallel()
	directory, err := os.MkdirTemp("/tmp", "kmgr-ep.")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	if err := os.Chmod(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(directory, "engine.sock")
	endpoint, err := ListenPrivateUnixPath(socket)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(socket)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode = %04o", info.Mode().Perm())
	}
	if err := endpoint.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(socket); !os.IsNotExist(err) {
		t.Fatalf("socket remains: %v", err)
	}
	if _, err := os.Stat(directory); err != nil {
		t.Fatalf("caller directory was removed: %v", err)
	}
}

func TestListenPrivateUnixPathRejectsWeakDirectoryAndExistingPath(t *testing.T) {
	t.Parallel()
	directory, err := os.MkdirTemp("/tmp", "kmgr-ep.")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	if err := os.Chmod(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(directory, "engine.sock")
	if _, err := ListenPrivateUnixPath(socket); err == nil {
		t.Fatal("weak private directory was accepted")
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(socket, []byte("do not replace"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ListenPrivateUnixPath(socket); err == nil {
		t.Fatal("existing socket path was replaced")
	}
}
