package transport

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"syscall"
)

const maxUnixSocketPath = 103

// PrivateEndpoint owns a short-lived, user-only Unix-domain socket and its
// parent directory. Close removes both after closing the listener.
type PrivateEndpoint struct {
	mu       sync.Mutex
	socket   string
	listener net.Listener
}

// ListenPrivateUnixPath listens at a GUI-created path. The parent directory
// must be an absolute, non-symlinked directory owned by the current user with
// mode 0700. Close removes the socket but leaves that directory for its creator
// to remove.
func ListenPrivateUnixPath(socket string) (*PrivateEndpoint, error) {
	if socket == "" || !filepath.IsAbs(socket) {
		return nil, errors.New("Unix socket path must be absolute")
	}
	socket = filepath.Clean(socket)
	if len(socket) > maxUnixSocketPath {
		return nil, fmt.Errorf("Unix socket path is too long (%d bytes)", len(socket))
	}

	directory := filepath.Dir(socket)
	info, err := os.Lstat(directory)
	if err != nil {
		return nil, fmt.Errorf("inspect private endpoint directory: %w", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("private endpoint parent must be a directory, not a symlink")
	}
	if info.Mode().Perm() != 0o700 {
		return nil, fmt.Errorf("private endpoint directory mode is %04o, want 0700", info.Mode().Perm())
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) {
		return nil, errors.New("private endpoint directory is not owned by the current user")
	}
	if _, err := os.Lstat(socket); !os.IsNotExist(err) {
		if err != nil {
			return nil, fmt.Errorf("inspect Unix socket path: %w", err)
		}
		return nil, errors.New("Unix socket path already exists")
	}

	listener, err := net.Listen("unix", socket)
	if err != nil {
		return nil, fmt.Errorf("listen on private Unix socket: %w", err)
	}
	if err := os.Chmod(socket, 0o600); err != nil {
		_ = listener.Close()
		_ = os.Remove(socket)
		return nil, fmt.Errorf("protect private Unix socket: %w", err)
	}

	return &PrivateEndpoint{
		socket: socket, listener: listener,
	}, nil
}

func (e *PrivateEndpoint) Listener() net.Listener {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.listener
}

func (e *PrivateEndpoint) Close() error {
	e.mu.Lock()
	defer e.mu.Unlock()

	var closeErr error
	if e.listener != nil {
		closeErr = e.listener.Close()
		if errors.Is(closeErr, net.ErrClosed) {
			closeErr = nil
		}
		e.listener = nil
	}
	var removeErr error
	if e.socket != "" {
		removeErr = os.Remove(e.socket)
		if os.IsNotExist(removeErr) {
			removeErr = nil
		}
	}
	return errors.Join(closeErr, removeErr)
}
