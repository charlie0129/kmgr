package execstream

import (
	"context"
	"net/http"
	"net/url"
	"sync"

	"github.com/charlie0129/kmgr/backend/internal/podidentity"
	corev1 "k8s.io/api/core/v1"
	apihttpstream "k8s.io/apimachinery/pkg/util/httpstream"
	"k8s.io/client-go/kubernetes/scheme"
	coreclient "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"
	clientgospdy "k8s.io/client-go/transport/spdy"
	streamhttp "k8s.io/streaming/pkg/httpstream"
)

type ClientGoRunner struct {
	Core            coreclient.CoreV1Interface
	PodUIDs         podidentity.Getter
	Config          *rest.Config
	ExecutorFactory ExecutorFactory
}

func (r ClientGoRunner) Run(ctx context.Context, request StartRequest, options RunOptions) error {
	if r.Core == nil || r.PodUIDs == nil || r.Config == nil {
		return ErrExecutorUnavailable
	}
	uid, err := r.PodUIDs.PodUID(ctx, request.Pod.Namespace, request.Pod.Name)
	if err != nil {
		return err
	}
	if string(uid) != request.Pod.UID {
		return &UIDMismatchError{
			Namespace: request.Pod.Namespace, Name: request.Pod.Name,
			Expected: request.Pod.UID, Actual: string(uid),
		}
	}

	restClient := r.Core.RESTClient()
	if restClient == nil {
		return ErrExecutorUnavailable
	}
	requestURL := restClient.Post().
		Namespace(request.Pod.Namespace).
		Resource("pods").
		Name(request.Pod.Name).
		SubResource("exec").
		VersionedParams(&corev1.PodExecOptions{
			Container: request.Container, Command: append([]string(nil), request.Command...),
			Stdin: request.Stdin, Stdout: true, Stderr: !request.TTY, TTY: request.TTY,
		}, scheme.ParameterCodec).
		URL().String()
	factory := r.ExecutorFactory
	if factory == nil {
		factory = DefaultExecutorFactory{}
	}
	var readyOnce sync.Once
	ready := func() {
		if options.Started != nil {
			readyOnce.Do(options.Started)
		}
	}
	executor, err := factory.New(rest.CopyConfig(r.Config), requestURL, ready)
	if err != nil {
		return err
	}
	return executor.StreamWithContext(ctx, remotecommand.StreamOptions{
		Stdin: options.Stdin, Stdout: options.Stdout, Stderr: options.Stderr,
		Tty: options.TTY, TerminalSizeQueue: options.Resizes,
	})
}

type DefaultExecutorFactory struct{}

func (DefaultExecutorFactory) New(
	config *rest.Config,
	requestURL string,
	ready func(),
) (remotecommand.Executor, error) {
	parsedURL, err := url.Parse(requestURL)
	if err != nil {
		return nil, err
	}
	spdyTransport, spdyUpgrader, err := clientgospdy.RoundTripperFor(config)
	if err != nil {
		return nil, err
	}
	spdyExecutor, err := remotecommand.NewSPDYExecutorForTransports(
		spdyTransport,
		readySPDYUpgrader{delegate: spdyUpgrader, ready: ready},
		http.MethodPost,
		parsedURL,
	)
	if err != nil {
		return nil, err
	}
	webSocketExecutor, err := remotecommand.NewWebSocketExecutor(
		configWithReadyTransport(config, ready),
		http.MethodGet,
		requestURL,
	)
	if err != nil {
		return nil, err
	}
	return remotecommand.NewFallbackExecutor(webSocketExecutor, spdyExecutor, func(err error) bool {
		return streamhttp.IsUpgradeFailure(err) || streamhttp.IsHTTPSProxyError(err)
	})
}

// The client-go Executor API does not expose a ready callback. These two
// adapters signal only after the underlying WebSocket or SPDY upgrade has
// succeeded, so a rejected upgrade cannot be presented as a running shell.
type readyRoundTripper struct {
	delegate http.RoundTripper
	ready    func()
}

func (r readyRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	response, err := r.delegate.RoundTrip(request)
	if err == nil && response != nil && r.ready != nil {
		r.ready()
	}
	return response, err
}

type readySPDYUpgrader struct {
	delegate clientgospdy.Upgrader
	ready    func()
}

func (u readySPDYUpgrader) NewConnection(response *http.Response) (apihttpstream.Connection, error) {
	connection, err := u.delegate.NewConnection(response)
	if err == nil && u.ready != nil {
		u.ready()
	}
	return connection, err
}

func configWithReadyTransport(config *rest.Config, ready func()) *rest.Config {
	copy := rest.CopyConfig(config)
	wrapped := copy.WrapTransport
	copy.WrapTransport = func(roundTripper http.RoundTripper) http.RoundTripper {
		if wrapped != nil {
			roundTripper = wrapped(roundTripper)
		}
		return readyRoundTripper{delegate: roundTripper, ready: ready}
	}
	return copy
}
