package execstream

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"testing"

	"github.com/charlie0129/kmgr/backend/internal/podidentity"
	coreclient "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/client-go/metadata"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"
	"k8s.io/client-go/util/flowcontrol"
)

type executorFunc func(context.Context, remotecommand.StreamOptions) error

func (f executorFunc) Stream(options remotecommand.StreamOptions) error {
	return f(context.Background(), options)
}

func (f executorFunc) StreamWithContext(ctx context.Context, options remotecommand.StreamOptions) error {
	return f(ctx, options)
}

func TestClientGoRunnerVerifiesPodAndBuildsExecRequest(t *testing.T) {
	t.Parallel()

	type observedRequest struct {
		method        string
		path          string
		authorization string
	}
	requests := make(chan observedRequest, 1)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requests <- observedRequest{
			method: request.Method, path: request.URL.Path,
			authorization: request.Header.Get("Authorization"),
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(writer, `{"apiVersion":"meta.k8s.io/v1","kind":"PartialObjectMetadata","metadata":{"namespace":"default","name":"api-0","uid":"pod-uid"}}`)
	}))
	defer server.Close()

	limiter := flowcontrol.NewTokenBucketRateLimiter(12.5, 37)
	config := &rest.Config{
		Host: server.URL, BearerToken: "test-bearer-token", RateLimiter: limiter,
	}
	core, err := coreclient.NewForConfig(config)
	if err != nil {
		t.Fatalf("NewForConfig: %v", err)
	}
	metadataClient, err := metadata.NewForConfig(config)
	if err != nil {
		t.Fatalf("metadata NewForConfig: %v", err)
	}
	var execURL string
	var factoryConfig *rest.Config
	stdout := new(bytes.Buffer)
	stderr := new(bytes.Buffer)
	stdin := bytes.NewBufferString("input")
	resize := newResizeQueue(nil)
	started := false
	executed := false
	runner := ClientGoRunner{
		Core: core, PodUIDs: podidentity.MetadataGetter{Client: metadataClient}, Config: config,
		ExecutorFactory: ExecutorFactoryFunc(func(receivedConfig *rest.Config, requestURL string, ready func()) (remotecommand.Executor, error) {
			factoryConfig = receivedConfig
			execURL = requestURL
			return executorFunc(func(ctx context.Context, options remotecommand.StreamOptions) error {
				executed = true
				if started {
					t.Error("runner reported Running before the executor established its transport")
				}
				ready()
				if ctx == nil || options.Stdin != stdin || options.Stdout != stdout || options.Stderr != stderr ||
					options.Tty || options.TerminalSizeQueue != resize {
					t.Errorf("stream options were not forwarded: %#v", options)
				}
				return nil
			}), nil
		}),
	}
	request := testStart(1)
	request.TTY = false
	request.InitialSize = nil
	request.Command = []string{"/bin/sh", "-lc", "printf hello"}
	err = runner.Run(context.Background(), request, RunOptions{
		Stdin: stdin, Stdout: stdout, Stderr: stderr, Resizes: resize,
		Started: func() { started = true },
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !started || !executed {
		t.Fatalf("started = %t, executed = %t", started, executed)
	}
	if factoryConfig == config || factoryConfig.Host != config.Host || factoryConfig.BearerToken != config.BearerToken {
		t.Fatalf("executor config was not a faithful copy: %#v", factoryConfig)
	}
	if factoryConfig.RateLimiter != limiter {
		t.Fatal("exec transport copy replaced the authority-wide limiter")
	}

	parsed, err := url.Parse(execURL)
	if err != nil {
		t.Fatalf("parse exec URL: %v", err)
	}
	if parsed.Path != "/api/v1/namespaces/default/pods/api-0/exec" {
		t.Fatalf("exec path = %q", parsed.Path)
	}
	wantQuery := url.Values{
		"command":   {"/bin/sh", "-lc", "printf hello"},
		"container": {"main"},
		"stderr":    {"true"},
		"stdin":     {"true"},
		"stdout":    {"true"},
	}
	if got := parsed.Query(); !reflect.DeepEqual(got, wantQuery) {
		t.Fatalf("exec query = %#v, want %#v", got, wantQuery)
	}
	select {
	case observed := <-requests:
		if observed.method != http.MethodGet || observed.path != "/api/v1/namespaces/default/pods/api-0" ||
			observed.authorization != "Bearer test-bearer-token" {
			t.Fatalf("Pod verification request = %#v", observed)
		}
	default:
		t.Fatal("Pod verification request was not observed")
	}
}

func TestClientGoRunnerRejectsRecreatedPodBeforeExec(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(writer, `{"apiVersion":"meta.k8s.io/v1","kind":"PartialObjectMetadata","metadata":{"namespace":"default","name":"api-0","uid":"replacement-uid"}}`)
	}))
	defer server.Close()
	config := &rest.Config{Host: server.URL}
	core, err := coreclient.NewForConfig(config)
	if err != nil {
		t.Fatalf("NewForConfig: %v", err)
	}
	metadataClient, err := metadata.NewForConfig(config)
	if err != nil {
		t.Fatalf("metadata NewForConfig: %v", err)
	}
	factoryCalled := false
	runner := ClientGoRunner{
		Core: core, PodUIDs: podidentity.MetadataGetter{Client: metadataClient}, Config: config,
		ExecutorFactory: ExecutorFactoryFunc(func(*rest.Config, string, func()) (remotecommand.Executor, error) {
			factoryCalled = true
			return nil, errors.New("must not construct an executor")
		}),
	}
	err = runner.Run(context.Background(), testStart(1), RunOptions{})
	var mismatch *UIDMismatchError
	if !errors.As(err, &mismatch) || mismatch.Expected != "pod-uid" || mismatch.Actual != "replacement-uid" {
		t.Fatalf("UID mismatch error = %#v", err)
	}
	if factoryCalled {
		t.Fatal("executor factory was called for a recreated Pod")
	}
}

func TestClientGoRunnerDoesNotReportRunningWhenTransportUpgradeFails(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(writer, `{"apiVersion":"meta.k8s.io/v1","kind":"PartialObjectMetadata","metadata":{"namespace":"default","name":"api-0","uid":"pod-uid"}}`)
	}))
	defer server.Close()
	config := &rest.Config{Host: server.URL}
	core, err := coreclient.NewForConfig(config)
	if err != nil {
		t.Fatalf("NewForConfig: %v", err)
	}
	metadataClient, err := metadata.NewForConfig(config)
	if err != nil {
		t.Fatalf("metadata NewForConfig: %v", err)
	}
	upgradeErr := errors.New("upgrade rejected")
	started := false
	runner := ClientGoRunner{
		Core: core, PodUIDs: podidentity.MetadataGetter{Client: metadataClient}, Config: config,
		ExecutorFactory: ExecutorFactoryFunc(func(*rest.Config, string, func()) (remotecommand.Executor, error) {
			return executorFunc(func(context.Context, remotecommand.StreamOptions) error {
				return upgradeErr
			}), nil
		}),
	}
	err = runner.Run(context.Background(), testStart(1), RunOptions{Started: func() { started = true }})
	if !errors.Is(err, upgradeErr) {
		t.Fatalf("Run error = %v, want %v", err, upgradeErr)
	}
	if started {
		t.Fatal("transport upgrade failure was reported as Running")
	}
}
