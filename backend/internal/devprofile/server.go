// Package devprofile exposes a deliberately small local pprof server for
// development builds. Production code must import it only behind the kmgr_dev
// build tag.
package devprofile

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	httppprof "net/http/pprof"
	runtimepprof "runtime/pprof"
	"strings"
	"sync"
	"time"
)

const shutdownTimeout = time.Second

// Server is an opt-in, loopback-only pprof HTTP server.
type Server struct {
	listener net.Listener
	server   *http.Server
	done     chan error

	closeOnce sync.Once
	closeErr  error
}

// Start begins serving a restricted pprof handler set. address must contain an
// explicit loopback IP and port, for example 127.0.0.1:6060 or [::1]:6060.
// Hostnames and wildcard addresses are rejected rather than resolved.
func Start(address string, logger *slog.Logger) (*Server, error) {
	if err := validateLoopbackAddress(address); err != nil {
		return nil, err
	}
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return nil, fmt.Errorf("listen for development profiler: %w", err)
	}
	tcpAddress, ok := listener.Addr().(*net.TCPAddr)
	if !ok || !tcpAddress.IP.IsLoopback() {
		_ = listener.Close()
		return nil, errors.New("development profiler resolved outside loopback")
	}

	server := &Server{
		listener: listener,
		server: &http.Server{
			Handler:           restrictedMux(),
			ReadHeaderTimeout: 5 * time.Second,
			IdleTimeout:       30 * time.Second,
			MaxHeaderBytes:    8 << 10,
		},
		done: make(chan error, 1),
	}
	go func() {
		err := server.server.Serve(listener)
		server.done <- err
		if err != nil && !errors.Is(err, http.ErrServerClosed) && logger != nil {
			logger.Warn("development profiler stopped unexpectedly", "error_kind", "pprof-serve")
		}
	}()
	if logger != nil {
		logger.Info("development profiler ready", "address", listener.Addr().String())
	}
	return server, nil
}

// Address returns the listener's resolved loopback address.
func (s *Server) Address() string {
	if s == nil || s.listener == nil {
		return ""
	}
	return s.listener.Addr().String()
}

// Close stops the profiler and waits for its serving goroutine. It is safe to
// call more than once.
func (s *Server) Close() error {
	if s == nil {
		return nil
	}
	s.closeOnce.Do(func() {
		ctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()
		shutdownErr := s.server.Shutdown(ctx)
		if shutdownErr != nil {
			_ = s.server.Close()
		}
		serveErr := <-s.done
		if errors.Is(serveErr, http.ErrServerClosed) {
			serveErr = nil
		}
		s.closeErr = errors.Join(shutdownErr, serveErr)
	})
	return s.closeErr
}

func validateLoopbackAddress(address string) error {
	host, port, err := net.SplitHostPort(strings.TrimSpace(address))
	if err != nil || host == "" || port == "" {
		return errors.New("development profiler address must contain an explicit loopback IP and port")
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return errors.New("development profiler address must use an explicit loopback IP")
	}
	return nil
}

func restrictedMux() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /debug/pprof/", func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/debug/pprof/" {
			http.NotFound(response, request)
			return
		}
		response.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = fmt.Fprintln(response, "kmgr development profiles:")
		_, _ = fmt.Fprintln(response, "/debug/pprof/profile")
		_, _ = fmt.Fprintln(response, "/debug/pprof/trace")
		for _, profile := range runtimepprof.Profiles() {
			_, _ = fmt.Fprintln(response, "/debug/pprof/"+profile.Name())
		}
	})
	mux.HandleFunc("GET /debug/pprof/profile", httppprof.Profile)
	mux.HandleFunc("GET /debug/pprof/trace", httppprof.Trace)
	for _, profile := range runtimepprof.Profiles() {
		mux.Handle("GET /debug/pprof/"+profile.Name(), httppprof.Handler(profile.Name()))
	}
	return mux
}
