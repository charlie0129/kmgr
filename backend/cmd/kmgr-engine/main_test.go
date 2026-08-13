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
