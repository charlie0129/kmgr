package execstream

import (
	"context"
	"net/http"
	"net/url"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/scheme"
	coreclient "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"
	httpstream "k8s.io/streaming/pkg/httpstream"
)

type ClientGoRunner struct {
	Core            coreclient.CoreV1Interface
	Config          *rest.Config
	ExecutorFactory ExecutorFactory
}

func (r ClientGoRunner) Run(ctx context.Context, request StartRequest, options RunOptions) error {
	if r.Core == nil || r.Config == nil {
		return ErrExecutorUnavailable
	}
	pods := r.Core.Pods(request.Pod.Namespace)
	pod, err := pods.Get(ctx, request.Pod.Name, metav1.GetOptions{})
	if err != nil {
		return err
	}
	if string(pod.UID) != request.Pod.UID {
		return &UIDMismatchError{
			Namespace: request.Pod.Namespace, Name: request.Pod.Name,
			Expected: request.Pod.UID, Actual: string(pod.UID),
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
	executor, err := factory.New(rest.CopyConfig(r.Config), requestURL)
	if err != nil {
		return err
	}
	if options.Started != nil {
		options.Started()
	}
	return executor.StreamWithContext(ctx, remotecommand.StreamOptions{
		Stdin: options.Stdin, Stdout: options.Stdout, Stderr: options.Stderr,
		Tty: options.TTY, TerminalSizeQueue: options.Resizes,
	})
}

type DefaultExecutorFactory struct{}

func (DefaultExecutorFactory) New(config *rest.Config, requestURL string) (remotecommand.Executor, error) {
	parsedURL, err := url.Parse(requestURL)
	if err != nil {
		return nil, err
	}
	spdyExecutor, err := remotecommand.NewSPDYExecutor(config, http.MethodPost, parsedURL)
	if err != nil {
		return nil, err
	}
	webSocketExecutor, err := remotecommand.NewWebSocketExecutor(config, http.MethodGet, requestURL)
	if err != nil {
		return nil, err
	}
	return remotecommand.NewFallbackExecutor(webSocketExecutor, spdyExecutor, func(err error) bool {
		return httpstream.IsUpgradeFailure(err) || httpstream.IsHTTPSProxyError(err)
	})
}
