//go:build darwin || linux || freebsd || openbsd || netbsd || dragonfly

package credentialexec

import (
	"os"
	"os/exec"
	"syscall"
)

func proxyTerminationSignals() []os.Signal {
	return []os.Signal{os.Interrupt, syscall.SIGTERM}
}

func configureProcessGroup(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

func terminateProcessGroup(processID int) error {
	return syscall.Kill(-processID, syscall.SIGTERM)
}

func killProcessGroup(processID int) error {
	return syscall.Kill(-processID, syscall.SIGKILL)
}
