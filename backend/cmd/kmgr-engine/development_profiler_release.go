//go:build !kmgr_dev

package main

import (
	"flag"
	"log/slog"
)

func registerDevelopmentProfiler(_ *flag.FlagSet) func(*slog.Logger) (func(), error) {
	return func(_ *slog.Logger) (func(), error) { return func() {}, nil }
}
