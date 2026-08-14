//go:build !kmgr_dev

package main

import (
	"flag"
	"testing"
)

func TestReleaseBuildOmitsProfilerFlag(t *testing.T) {
	flags := flag.NewFlagSet("test", flag.ContinueOnError)
	_ = registerDevelopmentProfiler(flags)
	if flags.Lookup("pprof-address") != nil {
		t.Fatal("non-development build exposed --pprof-address")
	}
}
