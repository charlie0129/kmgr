// kmgr-engine is the out-of-process Kubernetes authority for Kmgr.app.
package main

import (
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	"github.com/charlie0129/kmgr/backend/internal/transport"
)

var version = "dev"

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(arguments []string) int {
	flags := flag.NewFlagSet("kmgr-engine", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	showVersion := flags.Bool("version", false, "print the engine version")
	socketPath := flags.String("socket", "", "absolute path to the private Unix-domain socket")
	launchToken := flags.String("token", "", "per-launch bearer token (at least 32 bytes)")
	columnsPath := flags.String("columns", "", "path to the versioned programmable-columns configuration")
	metricsRefresh := flags.Duration(
		"metrics-refresh", metrics.DefaultRefreshInterval,
		"refresh interval for active Metrics API consumers",
	)
	logLevel := flags.String("log-level", "info", "stderr log level: debug, info, warn, or error")
	startDevelopmentProfiler := registerDevelopmentProfiler(flags)
	if err := flags.Parse(arguments); err != nil {
		return 2
	}

	if flags.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "kmgr-engine: unexpected positional arguments")
		return 2
	}
	if *metricsRefresh <= 0 {
		fmt.Fprintln(os.Stderr, "kmgr-engine: --metrics-refresh must be positive")
		return 2
	}
	if *showVersion {
		fmt.Printf("kmgr-engine %s\n", version)
		return 0
	}
	if *socketPath == "" {
		fmt.Fprintln(os.Stderr, "kmgr-engine: --socket is required")
		return 2
	}
	if *launchToken == "" {
		fmt.Fprintln(os.Stderr, "kmgr-engine: --token is required")
		return 2
	}
	level, err := parseLogLevel(*logLevel)
	if err != nil {
		fmt.Fprintln(os.Stderr, "kmgr-engine:", err)
		return 2
	}
	logger := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
	stopDevelopmentProfiler, err := startDevelopmentProfiler(logger)
	if err != nil {
		logger.Error("failed to start development profiler", "error_kind", "pprof")
		return 1
	}
	defer stopDevelopmentProfiler()

	endpoint, err := transport.ListenPrivateUnixPath(*socketPath)
	if err != nil {
		logger.Error("failed to create private engine endpoint", "error_kind", "endpoint")
		return 1
	}
	defer func() {
		if err := endpoint.Close(); err != nil {
			logger.Warn("failed to fully clean private engine endpoint", "error_kind", "cleanup")
		}
	}()

	server, err := transport.NewServer(*launchToken, transport.ServerOptions{
		Version:                version,
		Logger:                 logger,
		ColumnsPath:            *columnsPath,
		MetricsRefreshInterval: *metricsRefresh,
	})
	if err != nil {
		logger.Error("failed to initialize engine server", "error_kind", "configuration")
		return 1
	}

	serveResult := make(chan error, 1)
	go func() { serveResult <- server.Serve(endpoint.Listener()) }()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(signals)

	logger.Info("engine ready", "engine_version", version)
	var serveErr error
	serveCompleted := false
	select {
	case serveErr = <-serveResult:
		serveCompleted = true
		if serveErr != nil {
			logger.Error("engine server stopped unexpectedly", "error_kind", "serve")
		}
	case received := <-signals:
		logger.Info("engine stopping", "cause", received.String())
		server.RequestStop()
	case <-server.Done():
		logger.Info("engine stopping", "cause", "rpc")
	}

	server.Shutdown(transport.DefaultGracefulStopTimeout)
	if !serveCompleted {
		select {
		case serveErr = <-serveResult:
		case <-time.After(transport.DefaultGracefulStopTimeout + time.Second):
			logger.Error("engine server did not terminate after shutdown", "error_kind", "shutdown-timeout")
			return 1
		}
	}
	if serveErr != nil {
		return 1
	}
	return 0
}

func parseLogLevel(value string) (slog.Level, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "debug":
		return slog.LevelDebug, nil
	case "info", "":
		return slog.LevelInfo, nil
	case "warn", "warning":
		return slog.LevelWarn, nil
	case "error":
		return slog.LevelError, nil
	default:
		return 0, fmt.Errorf("invalid --log-level %q", value)
	}
}
