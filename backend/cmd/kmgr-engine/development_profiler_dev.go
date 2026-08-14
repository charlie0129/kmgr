//go:build kmgr_dev

package main

import (
	"flag"
	"log/slog"
	"os"
	"strings"

	"github.com/charlie0129/kmgr/backend/internal/devprofile"
)

const developmentProfilerEnvironment = "KMGR_PPROF_ADDRESS"

func registerDevelopmentProfiler(flags *flag.FlagSet) func(*slog.Logger) (func(), error) {
	defaultAddress := strings.TrimSpace(os.Getenv(developmentProfilerEnvironment))
	address := flags.String(
		"pprof-address",
		defaultAddress,
		"development-only pprof listener on an explicit loopback IP and port",
	)
	return func(logger *slog.Logger) (func(), error) {
		if strings.TrimSpace(*address) == "" {
			return func() {}, nil
		}
		server, err := devprofile.Start(*address, logger)
		if err != nil {
			return nil, err
		}
		return func() {
			if err := server.Close(); err != nil && logger != nil {
				logger.Warn("failed to stop development profiler", "error_kind", "pprof-shutdown")
			}
		}, nil
	}
}
