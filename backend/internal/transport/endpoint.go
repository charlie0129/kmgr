package transport

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
)

const maxUnixSocketPath = 103

// PrivateEndpoint owns a short-lived, user-only Unix-domain socket and its
// parent directory. Close removes both after closing the listener.
type PrivateEndpoint struct {
	directory string
	socket    string
	listener  net.Listener
}

func ListenPrivateUnix(baseDirectory string) (*PrivateEndpoint, error) {
	if baseDirectory == "" {
		baseDirectory = os.TempDir()
	}

	directory, err := os.MkdirTemp(baseDirectory, "kmgr.")
	if err != nil {
		return nil, fmt.Errorf("create private endpoint directory: %w", err)
	}
	cleanup := func() { _ = os.RemoveAll(directory) }

	if err := os.Chmod(directory, 0o700); err != nil {
		cleanup()
		return nil, fmt.Errorf("protect private endpoint directory: %w", err)
	}

	socket := filepath.Join(directory, "e.sock")
	if len(socket) > maxUnixSocketPath {
		cleanup()
		return nil, fmt.Errorf("Unix socket path is too long (%d bytes)", len(socket))
	}

	listener, err := net.Listen("unix", socket)
	if err != nil {
		cleanup()
		return nil, fmt.Errorf("listen on private Unix socket: %w", err)
	}
	if err := os.Chmod(socket, 0o600); err != nil {
		_ = listener.Close()
		cleanup()
		return nil, fmt.Errorf("protect private Unix socket: %w", err)
	}

	return &PrivateEndpoint{
		directory: directory,
		socket:    socket,
		listener:  listener,
	}, nil
}

func (e *PrivateEndpoint) Directory() string      { return e.directory }
func (e *PrivateEndpoint) SocketPath() string     { return e.socket }
func (e *PrivateEndpoint) Listener() net.Listener { return e.listener }

func (e *PrivateEndpoint) Close() error {
	var closeErr error
	if e.listener != nil {
		closeErr = e.listener.Close()
		e.listener = nil
	}
	removeErr := os.RemoveAll(e.directory)
	return errors.Join(closeErr, removeErr)
}
