//go:build kmgr_dev

package main

import (
	"flag"
	"io"
	"log/slog"
	"testing"
)

func TestDevelopmentBuildRegistersOptionalProfiler(t *testing.T) {
	t.Setenv(developmentProfilerEnvironment, "")
	flags := flag.NewFlagSet("test", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	start := registerDevelopmentProfiler(flags)
	if flags.Lookup("pprof-address") == nil {
		t.Fatal("development build omitted --pprof-address")
	}
	if err := flags.Parse(nil); err != nil {
		t.Fatal(err)
	}
	stop, err := start(slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	stop()
}
