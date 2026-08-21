package main

import (
	"log/slog"
	"testing"
)

func TestRunRejectsMissingLaunchConfiguration(t *testing.T) {
	if code := run(nil); code != 2 {
		t.Fatalf("run(nil) = %d, want usage error", code)
	}
	if code := run([]string{"--socket", "/tmp/e.sock"}); code != 2 {
		t.Fatalf("run(missing token) = %d, want usage error", code)
	}
}

func TestParseLogLevel(t *testing.T) {
	checks := map[string]slog.Level{
		"debug": slog.LevelDebug,
		"INFO":  slog.LevelInfo,
		"warn":  slog.LevelWarn,
		"error": slog.LevelError,
	}
	for input, want := range checks {
		got, err := parseLogLevel(input)
		if err != nil || got != want {
			t.Errorf("parseLogLevel(%q) = %v, %v; want %v", input, got, err, want)
		}
	}
	if _, err := parseLogLevel("verbose"); err == nil {
		t.Fatal("invalid log level was accepted")
	}
}

func TestColumnsFlagIsAccepted(t *testing.T) {
	if code := run([]string{
		"--version", "--columns", "/definitely/missing/columns.yaml",
	}); code != 0 {
		t.Fatalf("run(--version --columns) = %d, want success", code)
	}
}

func TestMetricsRefreshFlagIsValidated(t *testing.T) {
	if code := run([]string{"--version", "--metrics-refresh", "45s"}); code != 0 {
		t.Fatalf("run(valid --metrics-refresh) = %d, want success", code)
	}
	if code := run([]string{"--version", "--metrics-refresh", "0s"}); code != 2 {
		t.Fatalf("run(zero --metrics-refresh) = %d, want usage error", code)
	}
	if code := run([]string{"--version", "--metrics-refresh", "not-a-duration"}); code != 2 {
		t.Fatalf("run(invalid --metrics-refresh) = %d, want usage error", code)
	}
}

func TestViewReleaseDelayFlagIsValidated(t *testing.T) {
	if code := run([]string{"--version", "--view-release-delay", "45s"}); code != 0 {
		t.Fatalf("run(valid --view-release-delay) = %d, want success", code)
	}
	for _, value := range []string{"0s", "999ms", "-1s", "301s", "not-a-duration"} {
		if code := run([]string{"--version", "--view-release-delay", value}); code != 2 {
			t.Errorf("run(--view-release-delay %q) = %d, want usage error", value, code)
		}
	}
}

func TestKubernetesRateLimitFlagsAreValidated(t *testing.T) {
	if code := run([]string{
		"--version", "--kubernetes-qps", "12.5", "--kubernetes-burst", "37",
	}); code != 0 {
		t.Fatalf("run(valid fractional Kubernetes rate limit) = %d, want success", code)
	}
	for _, arguments := range [][]string{
		{"--version", "--kubernetes-qps", "0"},
		{"--version", "--kubernetes-qps", "NaN"},
		{"--version", "--kubernetes-qps", "+Inf"},
		{"--version", "--kubernetes-qps", "3.5e38"},
		{"--version", "--kubernetes-qps", "1e-50"},
		{"--version", "--kubernetes-burst", "0"},
		{"--version", "--kubernetes-burst", "2147483648"},
		{"--version", "--kubernetes-burst", "not-an-integer"},
	} {
		if code := run(arguments); code != 2 {
			t.Errorf("run(%q) = %d, want usage error", arguments, code)
		}
	}
}

func TestKubernetesListPageSizeFlagIsValidated(t *testing.T) {
	if code := run([]string{
		"--version", "--kubernetes-list-page-size", "750",
	}); code != 0 {
		t.Fatalf("run(valid Kubernetes LIST page size) = %d, want success", code)
	}
	for _, value := range []string{"0", "-1", "10001", "not-an-integer"} {
		if code := run([]string{
			"--version", "--kubernetes-list-page-size", value,
		}); code != 2 {
			t.Errorf("run(--kubernetes-list-page-size %q) = %d, want usage error", value, code)
		}
	}
}

func TestClusterConnectionTimeoutFlagIsValidated(t *testing.T) {
	if code := run([]string{
		"--version", "--cluster-connection-timeout", "45s",
	}); code != 0 {
		t.Fatalf("run(valid cluster connection timeout) = %d, want success", code)
	}
	for _, value := range []string{"0s", "999ms", "601s", "not-a-duration"} {
		if code := run([]string{
			"--version", "--cluster-connection-timeout", value,
		}); code != 2 {
			t.Errorf("run(--cluster-connection-timeout %q) = %d, want usage error", value, code)
		}
	}
}

func TestNodeShellStartupTimeoutFlagIsValidated(t *testing.T) {
	if code := run([]string{
		"--version", "--node-shell-startup-timeout", "90s",
	}); code != 0 {
		t.Fatalf("run(valid node-shell startup timeout) = %d, want success", code)
	}
	for _, value := range []string{"0s", "999ms", "3601s", "not-a-duration"} {
		if code := run([]string{
			"--version", "--node-shell-startup-timeout", value,
		}); code != 2 {
			t.Errorf("run(--node-shell-startup-timeout %q) = %d, want usage error", value, code)
		}
	}
}

func TestWarmCacheFlagsAreValidated(t *testing.T) {
	if code := run([]string{
		"--version",
		"--warm-cache-global-views", "48",
		"--warm-cache-global-objects", "500000",
		"--warm-cache-global-memory-percent", "30",
		"--warm-cache-authority-views", "12",
		"--warm-cache-authority-objects", "150000",
		"--warm-cache-authority-memory-percent", "10",
	}); code != 0 {
		t.Fatalf("run(valid warm-cache flags) = %d, want success", code)
	}
	for _, arguments := range [][]string{
		{"--version", "--warm-cache-global-views", "0"},
		{"--version", "--warm-cache-global-views", "2147483648"},
		{"--version", "--warm-cache-global-objects", "-1"},
		{"--version", "--warm-cache-global-memory-percent", "0"},
		{"--version", "--warm-cache-global-memory-percent", "101"},
		{"--version", "--warm-cache-authority-views", "0"},
		{"--version", "--warm-cache-authority-objects", "-1"},
		{"--version", "--warm-cache-authority-memory-percent", "0"},
		{"--version", "--warm-cache-authority-memory-percent", "101"},
	} {
		if code := run(arguments); code != 2 {
			t.Errorf("run(%q) = %d, want usage error", arguments, code)
		}
	}
}

func TestMetricCacheAndLogConcurrencyFlagsAreValidated(t *testing.T) {
	if code := run([]string{
		"--version",
		"--metrics-idle-provider-limit", "5",
		"--metrics-idle-sample-limit", "75000",
		"--pod-metrics-cache-entry-limit", "80000",
		"--pod-metrics-positive-sample-limit", "70000",
		"--pod-metrics-detail-entry-limit", "128",
		"--pod-metrics-get-concurrency", "12",
		"--log-queue-records", "8192",
		"--log-queue-bytes", "12582912",
		"--log-source-open-concurrency", "9",
	}); code != 0 {
		t.Fatalf("run(valid metric/log limits) = %d, want success", code)
	}
	for _, arguments := range [][]string{
		{"--version", "--metrics-idle-provider-limit", "0"},
		{"--version", "--metrics-idle-sample-limit", "-1"},
		{"--version", "--pod-metrics-cache-entry-limit", "0"},
		{"--version", "--pod-metrics-positive-sample-limit", "-1"},
		{"--version", "--pod-metrics-detail-entry-limit", "0"},
		{"--version", "--pod-metrics-get-concurrency", "-1"},
		{"--version", "--pod-metrics-get-concurrency", "2147483648"},
		{"--version", "--log-queue-records", "0"},
		{"--version", "--log-queue-records", "262145"},
		{"--version", "--log-queue-bytes", "1048575"},
		{"--version", "--log-queue-bytes", "536870913"},
		{"--version", "--log-source-open-concurrency", "0"},
		{"--version", "--log-source-open-concurrency", "2147483648"},
	} {
		if code := run(arguments); code != 2 {
			t.Errorf("run(%q) = %d, want usage error", arguments, code)
		}
	}
}

func TestWarmCacheMemoryPercentagesResolveIndependently(t *testing.T) {
	global, authority, err := resolveWarmCacheByteLimits(10_000, 20, 7)
	if err != nil {
		t.Fatal(err)
	}
	if global != 2_000 || authority != 700 {
		t.Fatalf("resolved warm-cache bytes = %d/%d, want 2000/700", global, authority)
	}

	if _, _, err := resolveWarmCacheByteLimits(0, 20, 20); err == nil {
		t.Fatal("zero physical memory was accepted")
	}
}
