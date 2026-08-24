//go:build darwin || linux || freebsd || openbsd || netbsd || dragonfly

package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

const (
	parentLivenessHelperRole = "KMGR_TEST_PARENT_LIVENESS_ROLE"
	parentLivenessSocket     = "KMGR_TEST_PARENT_LIVENESS_SOCKET"
	parentLivenessEnabled    = "KMGR_TEST_PARENT_LIVENESS_ENABLED"
)

func TestEngineStopsAfterParentProcessIsKilled(t *testing.T) {
	directory, socket := newParentLivenessFixture(t)
	launcher := parentLivenessHelperCommand("launcher", socket, false)
	stdout, err := launcher.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var diagnostics synchronizedBuffer
	launcher.Stderr = &diagnostics
	if err := launcher.Start(); err != nil {
		t.Fatal(err)
	}
	launcherWaited := false
	defer func() {
		if !launcherWaited {
			_ = launcher.Process.Kill()
			_ = launcher.Wait()
		}
	}()

	type pidResult struct {
		pid int
		err error
	}
	pidRead := make(chan pidResult, 1)
	go func() {
		var processID int
		_, err := fmt.Fscan(stdout, &processID)
		pidRead <- pidResult{pid: processID, err: err}
	}()
	var enginePID int
	select {
	case result := <-pidRead:
		if result.err != nil || result.pid <= 1 {
			t.Fatalf("read engine PID: %v (pid %d, diagnostics %q)", result.err, result.pid, diagnostics.String())
		}
		enginePID = result.pid
	case <-time.After(5 * time.Second):
		t.Fatalf("parent helper did not publish its engine PID (diagnostics %q)", diagnostics.String())
	}
	engineStopped := false
	defer func() {
		if !engineStopped && processExists(enginePID) {
			_ = syscall.Kill(enginePID, syscall.SIGKILL)
		}
	}()

	waitForSocket(t, socket, 10*time.Second, diagnostics.String)
	if err := launcher.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	if err := launcher.Wait(); err == nil {
		t.Fatal("parent helper exited successfully after SIGKILL")
	}
	launcherWaited = true

	deadline := time.Now().Add(10 * time.Second)
	for processExists(enginePID) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if processExists(enginePID) {
		t.Fatalf("engine %d survived its parent (diagnostics %q)", enginePID, diagnostics.String())
	}
	engineStopped = true
	if _, err := os.Lstat(socket); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("engine socket remained after parent loss: %v", err)
	}
	if entries, err := os.ReadDir(directory); err != nil || len(entries) != 0 {
		t.Fatalf("engine launch directory contents after parent loss = %v, %v", entries, err)
	}
}

func TestStandaloneEngineIgnoresStdinEOFWithoutLivenessFlag(t *testing.T) {
	_, socket := newParentLivenessFixture(t)
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	command := parentLivenessHelperCommand("engine", socket, false)
	command.Stdin = reader
	var diagnostics synchronizedBuffer
	command.Stdout = &diagnostics
	command.Stderr = &diagnostics
	if err := command.Start(); err != nil {
		_ = reader.Close()
		_ = writer.Close()
		t.Fatal(err)
	}
	_ = reader.Close()
	_ = writer.Close()
	commandWaited := false
	defer func() {
		if !commandWaited {
			_ = command.Process.Kill()
			_ = command.Wait()
		}
	}()

	waitForSocket(t, socket, 10*time.Second, diagnostics.String)
	time.Sleep(100 * time.Millisecond)
	if !processExists(command.Process.Pid) {
		t.Fatalf("standalone engine exited on stdin EOF without opt-in (diagnostics %q)", diagnostics.String())
	}
	if err := command.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	waited := make(chan error, 1)
	go func() { waited <- command.Wait() }()
	select {
	case err := <-waited:
		commandWaited = true
		if err != nil {
			t.Fatalf("standalone engine shutdown: %v (diagnostics %q)", err, diagnostics.String())
		}
	case <-time.After(10 * time.Second):
		_ = command.Process.Kill()
		_ = <-waited
		commandWaited = true
		t.Fatalf("standalone engine did not stop after SIGTERM (diagnostics %q)", diagnostics.String())
	}
}

// TestParentLivenessProcessHelper is invoked in subprocesses so one process
// can own the liveness writer and be killed without terminating the test
// runner. An ordinary test invocation returns immediately.
func TestParentLivenessProcessHelper(t *testing.T) {
	role := os.Getenv(parentLivenessHelperRole)
	if role == "" {
		return
	}
	socket := os.Getenv(parentLivenessSocket)
	switch role {
	case "engine":
		arguments := []string{
			"--socket", socket,
			"--token", strings.Repeat("a", 64),
			"--columns", filepath.Join(filepath.Dir(socket), "columns.yaml"),
			"--log-level", "error",
		}
		if os.Getenv(parentLivenessEnabled) == "1" {
			arguments = append(arguments, "--parent-liveness-stdin")
		}
		if code := run(arguments); code != 0 {
			t.Fatalf("engine run code = %d", code)
		}
	case "launcher":
		reader, writer, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		engine := parentLivenessHelperCommand("engine", socket, true)
		engine.Stdin = reader
		engine.Stdout = os.Stderr
		engine.Stderr = os.Stderr
		if err := engine.Start(); err != nil {
			_ = reader.Close()
			_ = writer.Close()
			t.Fatal(err)
		}
		_ = reader.Close()
		if _, err := fmt.Fprintln(os.Stdout, engine.Process.Pid); err != nil {
			t.Fatal(err)
		}
		for {
			time.Sleep(time.Second)
			runtime.KeepAlive(writer)
		}
	default:
		t.Fatalf("unknown helper role %q", role)
	}
}

func newParentLivenessFixture(t *testing.T) (string, string) {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "kmgr-parent-liveness.")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		_ = os.RemoveAll(directory)
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	return directory, filepath.Join(directory, "e.sock")
}

func parentLivenessHelperCommand(role, socket string, enabled bool) *exec.Cmd {
	command := exec.Command(os.Args[0], "-test.run=^TestParentLivenessProcessHelper$")
	command.Env = parentLivenessHelperEnvironment(role, socket, enabled)
	return command
}

func parentLivenessHelperEnvironment(role, socket string, enabled bool) []string {
	names := []string{
		parentLivenessHelperRole,
		parentLivenessSocket,
		parentLivenessEnabled,
		"KUBECONFIG",
		"KMGR_PPROF_ADDRESS",
	}
	environment := make([]string, 0, len(os.Environ())+len(names))
	for _, entry := range os.Environ() {
		keep := true
		for _, name := range names {
			if strings.HasPrefix(entry, name+"=") {
				keep = false
				break
			}
		}
		if keep {
			environment = append(environment, entry)
		}
	}
	enabledValue := "0"
	if enabled {
		enabledValue = "1"
	}
	return append(environment,
		parentLivenessHelperRole+"="+role,
		parentLivenessSocket+"="+socket,
		parentLivenessEnabled+"="+enabledValue,
		"KUBECONFIG="+filepath.Join(filepath.Dir(socket), "no-kubeconfig"),
		"KMGR_PPROF_ADDRESS=",
	)
}

func waitForSocket(t *testing.T, socket string, timeout time.Duration, diagnostics func() string) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		info, err := os.Lstat(socket)
		if err == nil && info.Mode()&os.ModeSocket != 0 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("engine socket did not become ready (diagnostics %q)", diagnostics())
}

func processExists(processID int) bool {
	if processID <= 1 {
		return false
	}
	err := syscall.Kill(processID, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

type synchronizedBuffer struct {
	mu sync.Mutex
	bytes.Buffer
}

func (b *synchronizedBuffer) Write(data []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.Buffer.Write(data)
}

func (b *synchronizedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.Buffer.String()
}
