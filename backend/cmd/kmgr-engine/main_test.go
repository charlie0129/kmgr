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
		{"--version", "--kubernetes-burst", "not-an-integer"},
	} {
		if code := run(arguments); code != 2 {
			t.Errorf("run(%q) = %d, want usage error", arguments, code)
		}
	}
}
