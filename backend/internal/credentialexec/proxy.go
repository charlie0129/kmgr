// Package credentialexec prepares and supervises external kubeconfig exec
// credential plugins without reimplementing client-go's credential protocol.
package credentialexec

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
)

const (
	// ProxySubcommand selects the short-lived credential proxy mode in the
	// kmgr-engine executable.
	ProxySubcommand = "credential-plugin-proxy"

	ProxyExitPluginFailed   = 70
	ProxyExitInternal       = 125
	ProxyExitCannotExecute  = 126
	ProxyExitPluginNotFound = 127
	ProxyExitTimedOut       = 124

	maximumCredentialOutputBytes = 1 << 20
)

// RunProxy executes one already-resolved credential plugin under a hard
// deadline. Raw plugin stderr is deliberately discarded and successful stdout
// is forwarded byte-for-byte for client-go to decode.
func RunProxy(arguments []string, stdin io.Reader, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet(ProxySubcommand, flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	command := flags.String("command", "", "absolute credential plugin path")
	timeout := flags.Duration("timeout", 0, "credential plugin deadline")
	if err := flags.Parse(arguments); err != nil || !filepath.IsAbs(*command) ||
		*timeout <= 0 || *timeout > MaximumPluginTimeout {
		writeSafeProxyError(stderr, "invalid credential plugin proxy request")
		return ProxyExitInternal
	}

	interrupts := make(chan os.Signal, 1)
	signal.Notify(interrupts, proxyTerminationSignals()...)
	defer signal.Stop(interrupts)

	result := runSupervised(supervisedCommand{
		command:     *command,
		arguments:   append([]string(nil), flags.Args()...),
		environment: os.Environ(),
		stdin:       stdin,
		timeout:     *timeout,
		outputLimit: maximumCredentialOutputBytes,
		parentPID:   os.Getppid(),
		interrupt:   interrupts,
	})
	switch {
	case result.interrupted:
		writeSafeProxyError(stderr, "credential plugin was interrupted")
		return ProxyExitInternal
	case result.parentExited:
		writeSafeProxyError(stderr, "credential plugin stopped because the engine exited")
		return ProxyExitInternal
	case result.timedOut:
		writeSafeProxyError(stderr, "credential plugin timed out")
		return ProxyExitTimedOut
	case result.startError && os.IsNotExist(result.err):
		writeSafeProxyError(stderr, "credential plugin executable was not found")
		return ProxyExitPluginNotFound
	case result.startError:
		writeSafeProxyError(stderr, "credential plugin could not be started")
		return ProxyExitCannotExecute
	case result.outputTooLarge:
		writeSafeProxyError(stderr, "credential plugin output exceeded the limit")
		return ProxyExitPluginFailed
	case result.err != nil:
		writeSafeProxyError(stderr, "credential plugin failed")
		return ProxyExitPluginFailed
	}
	if _, err := stdout.Write(result.stdout); err != nil {
		writeSafeProxyError(stderr, "credential plugin output could not be forwarded")
		return ProxyExitInternal
	}
	return 0
}

func writeSafeProxyError(destination io.Writer, message string) {
	if destination == nil {
		return
	}
	_, _ = fmt.Fprintf(destination, "kmgr-engine: %s\n", message)
}
