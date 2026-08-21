//go:build !(darwin || linux || freebsd || openbsd || netbsd || dragonfly)

package credentialexec

import (
	"os"
	"os/exec"
)

func proxyTerminationSignals() []os.Signal {
	return []os.Signal{os.Interrupt}
}

func configureProcessGroup(_ *exec.Cmd) {}

func terminateProcessGroup(processID int) error {
	process, err := os.FindProcess(processID)
	if err != nil {
		return err
	}
	return process.Kill()
}

func killProcessGroup(processID int) error {
	return terminateProcessGroup(processID)
}
