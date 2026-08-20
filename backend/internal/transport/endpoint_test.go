package transport

import (
	"os"
	"path/filepath"
	"testing"
)

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

func TestPrivateEndpointCloseToleratesListenerAlreadyClosed(t *testing.T) {
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
	if err := endpoint.Listener().Close(); err != nil {
		t.Fatal(err)
	}
	if err := endpoint.Close(); err != nil {
		t.Fatalf("Close after listener ownership transfer = %v", err)
	}
	if _, err := os.Stat(socket); !os.IsNotExist(err) {
		t.Fatalf("socket remains after repeated close: %v", err)
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
