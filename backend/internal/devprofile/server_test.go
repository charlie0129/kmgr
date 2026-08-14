package devprofile

import (
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestStartRejectsAddressesThatAreNotExplicitLoopbackIPs(t *testing.T) {
	t.Parallel()
	for _, address := range []string{
		"", ":0", "0.0.0.0:0", "[::]:0", "localhost:6060", "example.com:6060", "invalid",
	} {
		address := address
		t.Run(address, func(t *testing.T) {
			t.Parallel()
			if server, err := Start(address, nil); err == nil {
				_ = server.Close()
				t.Fatalf("Start(%q) accepted a non-loopback address", address)
			}
		})
	}
}

func TestServerExposesProfilesWithoutCommandLineOrUnrelatedHandlers(t *testing.T) {
	t.Parallel()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server, err := Start("127.0.0.1:0", logger)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := server.Close(); err != nil {
			t.Errorf("close profiler: %v", err)
		}
	})
	client := &http.Client{Timeout: time.Second}
	baseURL := "http://" + server.Address()

	response, err := client.Get(baseURL + "/debug/pprof/")
	if err != nil {
		t.Fatal(err)
	}
	body, readErr := io.ReadAll(io.LimitReader(response.Body, 16<<10))
	closeErr := response.Body.Close()
	if readErr != nil || closeErr != nil {
		t.Fatalf("read index: %v; close: %v", readErr, closeErr)
	}
	if response.StatusCode != http.StatusOK || !strings.Contains(string(body), "/debug/pprof/heap") {
		t.Fatalf("profile index status = %d, body = %q", response.StatusCode, body)
	}
	response, err = client.Get(baseURL + "/debug/pprof/goroutine?debug=1")
	if err != nil {
		t.Fatal(err)
	}
	body, readErr = io.ReadAll(io.LimitReader(response.Body, 64<<10))
	closeErr = response.Body.Close()
	if readErr != nil || closeErr != nil {
		t.Fatalf("read goroutine profile: %v; close: %v", readErr, closeErr)
	}
	if response.StatusCode != http.StatusOK || !strings.Contains(string(body), "goroutine profile") {
		t.Fatalf("goroutine profile status = %d, body = %q", response.StatusCode, body)
	}

	for _, path := range []string{"/debug/pprof/cmdline", "/debug/pprof/symbol", "/unrelated"} {
		response, err := client.Get(baseURL + path)
		if err != nil {
			t.Fatal(err)
		}
		_ = response.Body.Close()
		if response.StatusCode != http.StatusNotFound {
			t.Fatalf("GET %s status = %d, want 404", path, response.StatusCode)
		}
	}
}

func TestServerCloseIsIdempotent(t *testing.T) {
	t.Parallel()
	server, err := Start("127.0.0.1:0", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
}
