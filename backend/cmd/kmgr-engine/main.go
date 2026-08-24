// kmgr-engine is the out-of-process Kubernetes authority for Kmgr.app.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"math"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/credentialexec"
	"github.com/charlie0129/kmgr/backend/internal/metrics"
	execstream "github.com/charlie0129/kmgr/backend/internal/stream/exec"
	streamlogs "github.com/charlie0129/kmgr/backend/internal/stream/logs"
	"github.com/charlie0129/kmgr/backend/internal/systemmemory"
	"github.com/charlie0129/kmgr/backend/internal/transport"
	"github.com/charlie0129/kmgr/backend/internal/view"
)

var version = "dev"

const maximumViewReleaseDelay = 5 * time.Minute

type warmCacheConfiguration struct {
	globalViews            int
	globalObjects          int
	globalMemoryPercent    int
	authorityViews         int
	authorityObjects       int
	authorityMemoryPercent int
}

type metricCacheConfiguration struct {
	idleProviders    int
	idleSamples      int
	exactEntries     int
	exactSamples     int
	exactDetails     int
	exactConcurrency int
}

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(arguments []string) int {
	if len(arguments) > 0 && arguments[0] == credentialexec.ProxySubcommand {
		return credentialexec.RunProxy(arguments[1:], os.Stdin, os.Stdout, os.Stderr)
	}

	flags := flag.NewFlagSet("kmgr-engine", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	showVersion := flags.Bool("version", false, "print the engine version")
	socketPath := flags.String("socket", "", "absolute path to the private Unix-domain socket")
	launchToken := flags.String("token", "", "per-launch bearer token (at least 32 bytes)")
	parentLivenessStdin := flags.Bool(
		"parent-liveness-stdin", false,
		"stop when the parent-owned standard-input pipe closes",
	)
	columnsPath := flags.String("columns", "", "path to the versioned programmable-columns configuration")
	metricsRefresh := flags.Duration(
		"metrics-refresh", metrics.DefaultRefreshInterval,
		"refresh interval for active Metrics API consumers",
	)
	viewReleaseDelay := flags.Duration(
		"view-release-delay", view.DefaultViewReleaseDelay,
		"grace period before releasing an unsubscribed resource pipeline",
	)
	projectionWorkers := flags.Int(
		"projection-workers", view.DefaultProjectionWorkerLimit(),
		"maximum concurrent resource-row projection workers process-wide",
	)
	kubernetesQPS := flags.Float64(
		"kubernetes-qps", cluster.DefaultClientQPS,
		"aggregate Kubernetes client requests per second for each authority",
	)
	kubernetesBurst := flags.Int(
		"kubernetes-burst", cluster.DefaultClientBurst,
		"aggregate Kubernetes client burst for each authority",
	)
	kubernetesListPageSize := flags.Int64(
		"kubernetes-list-page-size", view.DefaultPipelinePageSize,
		"maximum objects requested in each conventional Kubernetes LIST page",
	)
	clusterConnectionTimeout := flags.Duration(
		"cluster-connection-timeout",
		transport.DefaultConnectionProbeTimeout,
		"timeout for the Kubernetes connection probe while opening a cluster",
	)
	nodeShellStartupTimeout := flags.Duration(
		"node-shell-startup-timeout",
		execstream.DefaultNodeShellStartupTimeout,
		"timeout for a temporary node-shell helper Pod to become running",
	)
	warmCache := warmCacheConfiguration{}
	metricCache := metricCacheConfiguration{}
	flags.IntVar(
		&warmCache.globalViews,
		"warm-cache-global-views",
		view.DefaultWarmViewLimit,
		"maximum warm resource queries retained across all authorities",
	)
	flags.IntVar(
		&warmCache.globalObjects,
		"warm-cache-global-objects",
		view.DefaultWarmObjectLimit,
		"maximum warm Kubernetes objects retained across all authorities",
	)
	flags.IntVar(
		&warmCache.globalMemoryPercent,
		"warm-cache-global-memory-percent",
		view.DefaultWarmMemoryPercent,
		"maximum warm-cache retained bytes as a percentage of physical memory",
	)
	flags.IntVar(
		&warmCache.authorityViews,
		"warm-cache-authority-views",
		view.DefaultWarmViewLimitPerAuthority,
		"maximum warm resource queries retained for one authority",
	)
	flags.IntVar(
		&warmCache.authorityObjects,
		"warm-cache-authority-objects",
		view.DefaultWarmObjectLimitPerAuthority,
		"maximum warm Kubernetes objects retained for one authority",
	)
	flags.IntVar(
		&warmCache.authorityMemoryPercent,
		"warm-cache-authority-memory-percent",
		view.DefaultWarmMemoryPercent,
		"maximum warm-cache retained bytes for one authority as a percentage of physical memory",
	)
	flags.IntVar(
		&metricCache.idleProviders,
		"metrics-idle-provider-limit",
		view.DefaultIdleMetricProviderLimit,
		"maximum idle Metrics API LIST providers retained process-wide",
	)
	flags.IntVar(
		&metricCache.idleSamples,
		"metrics-idle-sample-limit",
		view.DefaultIdleMetricSampleLimit,
		"maximum samples retained by idle Metrics API LIST providers process-wide",
	)
	flags.IntVar(
		&metricCache.exactEntries,
		"pod-metrics-cache-entry-limit",
		metrics.DefaultPodSampleEntryLimit,
		"maximum exact PodMetrics result entries retained for one authority",
	)
	flags.IntVar(
		&metricCache.exactSamples,
		"pod-metrics-positive-sample-limit",
		metrics.DefaultPodSampleLimit,
		"maximum positive exact PodMetrics samples retained for one authority",
	)
	flags.IntVar(
		&metricCache.exactDetails,
		"pod-metrics-detail-entry-limit",
		metrics.DefaultPodDetailEntryLimit,
		"maximum raw exact PodMetrics detail entries retained for one authority",
	)
	flags.IntVar(
		&metricCache.exactConcurrency,
		"pod-metrics-get-concurrency",
		metrics.DefaultPodSampleMaxConcurrentGETs,
		"maximum concurrent exact PodMetrics GETs for one authority",
	)
	logSourceOpenConcurrency := flags.Int(
		"log-source-open-concurrency",
		streamlogs.DefaultMaxConcurrentOpens,
		"maximum concurrent Kubernetes log-source opens process-wide",
	)
	logQueueRecords := flags.Int(
		"log-queue-records",
		streamlogs.DefaultQueueRecords,
		"maximum queued log records for one stream",
	)
	logQueueBytes := flags.Int(
		"log-queue-bytes",
		streamlogs.DefaultQueueBytes,
		"maximum queued log payload bytes for one stream",
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
	if *viewReleaseDelay < time.Second || *viewReleaseDelay > maximumViewReleaseDelay {
		fmt.Fprintln(os.Stderr, "kmgr-engine: --view-release-delay must be between 1s and 5m")
		return 2
	}
	if *projectionWorkers < 1 || *projectionWorkers > view.MaxProjectionWorkerLimit {
		fmt.Fprintf(
			os.Stderr,
			"kmgr-engine: --projection-workers must be between 1 and %d\n",
			view.MaxProjectionWorkerLimit,
		)
		return 2
	}
	validatedQPS, err := validateKubernetesRateLimit(*kubernetesQPS, *kubernetesBurst)
	if err != nil {
		fmt.Fprintln(os.Stderr, "kmgr-engine:", err)
		return 2
	}
	if *kubernetesListPageSize < 1 ||
		*kubernetesListPageSize > view.MaximumPipelinePageSize {
		fmt.Fprintf(
			os.Stderr,
			"kmgr-engine: --kubernetes-list-page-size must be between 1 and %d\n",
			view.MaximumPipelinePageSize,
		)
		return 2
	}
	if *clusterConnectionTimeout < time.Second ||
		*clusterConnectionTimeout > transport.MaximumConnectionProbeTimeout {
		fmt.Fprintln(
			os.Stderr,
			"kmgr-engine: --cluster-connection-timeout must be between 1s and 10m",
		)
		return 2
	}
	if *nodeShellStartupTimeout < time.Second ||
		*nodeShellStartupTimeout > execstream.MaximumNodeShellStartupTimeout {
		fmt.Fprintln(
			os.Stderr,
			"kmgr-engine: --node-shell-startup-timeout must be between 1s and 1h",
		)
		return 2
	}
	if err := validateWarmCacheConfiguration(warmCache); err != nil {
		fmt.Fprintln(os.Stderr, "kmgr-engine:", err)
		return 2
	}
	if err := validateMetricCacheConfiguration(metricCache); err != nil {
		fmt.Fprintln(os.Stderr, "kmgr-engine:", err)
		return 2
	}
	if err := validatePositiveCrossPlatformCount(
		*logSourceOpenConcurrency,
		"--log-source-open-concurrency",
	); err != nil {
		fmt.Fprintln(os.Stderr, "kmgr-engine:", err)
		return 2
	}
	if err := validatePositiveCrossPlatformCount(*logQueueRecords, "--log-queue-records"); err != nil || *logQueueRecords > streamlogs.MaximumQueueRecords {
		if err != nil {
			fmt.Fprintln(os.Stderr, "kmgr-engine:", err)
		} else {
			fmt.Fprintf(
				os.Stderr,
				"kmgr-engine: --log-queue-records must not exceed %d\n",
				streamlogs.MaximumQueueRecords,
			)
		}
		return 2
	}
	if *logQueueBytes < 1<<20 || *logQueueBytes > streamlogs.MaximumQueueBytes {
		fmt.Fprintf(
			os.Stderr,
			"kmgr-engine: --log-queue-bytes must be between %d and %d\n",
			1<<20,
			streamlogs.MaximumQueueBytes,
		)
		return 2
	}
	if *showVersion {
		fmt.Printf("kmgr-engine %s\n", version)
		return 0
	}
	if *parentLivenessStdin {
		if err := validateParentLivenessInput(os.Stdin); err != nil {
			fmt.Fprintln(os.Stderr, "kmgr-engine:", err)
			return 2
		}
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
	physicalMemory, err := systemmemory.Bytes()
	if err != nil {
		fmt.Fprintln(os.Stderr, "kmgr-engine: resolve warm-cache memory budget:", err)
		return 1
	}
	globalWarmBytes, authorityWarmBytes, err := resolveWarmCacheByteLimits(
		physicalMemory,
		warmCache.globalMemoryPercent,
		warmCache.authorityMemoryPercent,
	)
	if err != nil {
		fmt.Fprintln(os.Stderr, "kmgr-engine: resolve warm-cache memory budget:", err)
		return 1
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
			logger.Warn(
				"failed to fully clean private engine endpoint",
				"error_kind", "cleanup",
				"error", err,
			)
		}
	}()

	server, err := transport.NewServer(*launchToken, transport.ServerOptions{
		Version:                     version,
		Logger:                      logger,
		ProbeTimeout:                *clusterConnectionTimeout,
		ColumnsPath:                 *columnsPath,
		MetricsRefreshInterval:      *metricsRefresh,
		ViewReleaseDelay:            *viewReleaseDelay,
		ProjectionWorkerLimit:       *projectionWorkers,
		IdleMetricProviderLimit:     metricCache.idleProviders,
		IdleMetricSampleLimit:       metricCache.idleSamples,
		PodMetricsEntryLimit:        metricCache.exactEntries,
		PodMetricsSampleLimit:       metricCache.exactSamples,
		PodMetricsDetailEntryLimit:  metricCache.exactDetails,
		PodMetricsGETConcurrency:    metricCache.exactConcurrency,
		LogQueueRecordLimit:         *logQueueRecords,
		LogQueueByteLimit:           *logQueueBytes,
		LogSourceOpenConcurrency:    *logSourceOpenConcurrency,
		NodeShellStartupTimeout:     *nodeShellStartupTimeout,
		KubernetesQPS:               validatedQPS,
		KubernetesBurst:             *kubernetesBurst,
		KubernetesListPageSize:      *kubernetesListPageSize,
		WarmViewLimit:               warmCache.globalViews,
		WarmObjectLimit:             warmCache.globalObjects,
		WarmByteLimit:               globalWarmBytes,
		WarmViewLimitPerAuthority:   warmCache.authorityViews,
		WarmObjectLimitPerAuthority: warmCache.authorityObjects,
		WarmByteLimitPerAuthority:   authorityWarmBytes,
	})
	if err != nil {
		logger.Error("failed to initialize engine server", "error_kind", "configuration")
		return 1
	}

	serveResult := make(chan error, 1)
	go func() { serveResult <- server.Serve(endpoint.Listener()) }()
	var parentExited <-chan struct{}
	if *parentLivenessStdin {
		parentExited = watchParentLiveness(os.Stdin)
	}
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
	case <-parentExited:
		logger.Info("engine stopping", "cause", "parent-exit")
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

func watchParentLiveness(input io.Reader) <-chan struct{} {
	lost := make(chan struct{})
	go func() {
		// Kmgr never writes payload bytes. Discarding any bytes keeps the
		// contract safe if a launcher does, while EOF or a read failure both
		// mean that the explicitly enabled liveness channel is gone.
		_, _ = io.Copy(io.Discard, input)
		close(lost)
	}()
	return lost
}

func validateParentLivenessInput(input *os.File) error {
	if input == nil {
		return errors.New("--parent-liveness-stdin requires standard input to be a pipe")
	}
	info, err := input.Stat()
	if err != nil {
		return fmt.Errorf("inspect parent liveness pipe: %w", err)
	}
	if info.Mode()&os.ModeNamedPipe == 0 {
		return errors.New("--parent-liveness-stdin requires standard input to be a pipe")
	}
	return nil
}

func validateKubernetesRateLimit(qps float64, burst int) (float32, error) {
	convertedQPS := float32(qps)
	if qps <= 0 || math.IsNaN(qps) || math.IsInf(qps, 0) ||
		convertedQPS <= 0 || math.IsInf(float64(convertedQPS), 0) {
		return 0, errors.New("--kubernetes-qps must be a finite positive 32-bit value")
	}
	if err := validatePositiveCrossPlatformCount(burst, "--kubernetes-burst"); err != nil {
		return 0, err
	}
	return convertedQPS, nil
}

func validateWarmCacheConfiguration(configuration warmCacheConfiguration) error {
	for _, limit := range []struct {
		value int
		name  string
	}{
		{configuration.globalViews, "--warm-cache-global-views"},
		{configuration.globalObjects, "--warm-cache-global-objects"},
		{configuration.authorityViews, "--warm-cache-authority-views"},
		{configuration.authorityObjects, "--warm-cache-authority-objects"},
	} {
		if err := validatePositiveCrossPlatformCount(limit.value, limit.name); err != nil {
			return err
		}
	}
	if configuration.globalMemoryPercent < 1 || configuration.globalMemoryPercent > 100 {
		return errors.New("--warm-cache-global-memory-percent must be between 1 and 100")
	}
	if configuration.authorityMemoryPercent < 1 || configuration.authorityMemoryPercent > 100 {
		return errors.New("--warm-cache-authority-memory-percent must be between 1 and 100")
	}
	return nil
}

func validateMetricCacheConfiguration(configuration metricCacheConfiguration) error {
	for _, limit := range []struct {
		value int
		name  string
	}{
		{configuration.idleProviders, "--metrics-idle-provider-limit"},
		{configuration.idleSamples, "--metrics-idle-sample-limit"},
		{configuration.exactEntries, "--pod-metrics-cache-entry-limit"},
		{configuration.exactSamples, "--pod-metrics-positive-sample-limit"},
		{configuration.exactDetails, "--pod-metrics-detail-entry-limit"},
		{configuration.exactConcurrency, "--pod-metrics-get-concurrency"},
	} {
		if err := validatePositiveCrossPlatformCount(limit.value, limit.name); err != nil {
			return err
		}
	}
	return nil
}

func validatePositiveCrossPlatformCount(value int, name string) error {
	if value <= 0 || uint64(value) > uint64(math.MaxInt32) {
		return fmt.Errorf("%s must be between 1 and %d", name, math.MaxInt32)
	}
	return nil
}

func resolveWarmCacheByteLimits(
	physicalMemory uint64,
	globalPercent, authorityPercent int,
) (int64, int64, error) {
	global, err := systemmemory.PercentageLimit(physicalMemory, globalPercent)
	if err != nil {
		return 0, 0, fmt.Errorf("global limit: %w", err)
	}
	authority, err := systemmemory.PercentageLimit(physicalMemory, authorityPercent)
	if err != nil {
		return 0, 0, fmt.Errorf("authority limit: %w", err)
	}
	return global, authority, nil
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
