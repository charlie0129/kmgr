package execstream

import (
	"context"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/podidentity"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	apihttpstream "k8s.io/apimachinery/pkg/util/httpstream"
	"k8s.io/apimachinery/pkg/util/wait"
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
	if r.Core == nil || r.Config == nil || (request.Pod != nil && r.PodUIDs == nil) {
		return ErrExecutorUnavailable
	}
	if request.NodeShell != nil {
		return r.runNodeShell(ctx, request, options)
	}
	return r.runPodExec(ctx, request, options)
}

func (r ClientGoRunner) runPodExec(
	ctx context.Context,
	request StartRequest,
	options RunOptions,
) error {
	if request.Pod == nil {
		return ErrInvalidRequest
	}
	pod := request.Pod.Pod
	uid, err := r.PodUIDs.PodUID(ctx, pod.Namespace, pod.Name)
	if err != nil {
		return err
	}
	if string(uid) != pod.UID {
		return &UIDMismatchError{
			Namespace: pod.Namespace, Name: pod.Name,
			Expected: pod.UID, Actual: string(uid),
		}
	}

	restClient := r.Core.RESTClient()
	if restClient == nil {
		return ErrExecutorUnavailable
	}
	requestURL := restClient.Post().
		Namespace(pod.Namespace).
		Resource("pods").
		Name(pod.Name).
		SubResource("exec").
		VersionedParams(&corev1.PodExecOptions{
			Container: request.Pod.Container, Command: append([]string(nil), request.Command...),
			Stdin: request.Stdin, Stdout: true, Stderr: !request.TTY, TTY: request.TTY,
		}, scheme.ParameterCodec).
		URL().String()
	return r.streamRemoteCommand(ctx, requestURL, options)
}

func (r ClientGoRunner) runNodeShell(
	ctx context.Context,
	request StartRequest,
	options RunOptions,
) error {
	target := request.NodeShell
	if target == nil {
		return ErrInvalidRequest
	}
	node, err := r.Core.Nodes().Get(ctx, target.Node.Name, metav1.GetOptions{})
	if err != nil {
		return err
	}
	if string(node.UID) != target.Node.UID {
		return &NodeUIDMismatchError{
			Name: target.Node.Name, Expected: target.Node.UID, Actual: string(node.UID),
		}
	}
	if node.Labels[corev1.LabelOSStable] == "windows" {
		return ErrWindowsNodeShellUnsupported
	}

	pods := r.Core.Pods(target.Namespace)
	helper, err := pods.Create(ctx, nodeShellPod(request), metav1.CreateOptions{})
	if err != nil {
		return err
	}
	defer deleteNodeShellPod(pods, helper.Name)
	if err := waitForNodeShellPod(ctx, pods, helper.Name, helper.UID); err != nil {
		return err
	}

	restClient := r.Core.RESTClient()
	if restClient == nil {
		return ErrExecutorUnavailable
	}
	requestURL := restClient.Post().
		Namespace(target.Namespace).
		Resource("pods").
		Name(helper.Name).
		SubResource("attach").
		VersionedParams(&corev1.PodAttachOptions{
			Container: nodeShellContainerName,
			Stdin:     request.Stdin, Stdout: true, Stderr: !request.TTY, TTY: request.TTY,
		}, scheme.ParameterCodec).
		URL().String()
	return r.streamRemoteCommand(ctx, requestURL, options)
}

func (r ClientGoRunner) streamRemoteCommand(
	ctx context.Context,
	requestURL string,
	options RunOptions,
) error {
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

const (
	nodeShellContainerName = "nsenter"
	nodeShellPodTimeout    = time.Minute
)

func nodeShellPod(request StartRequest) *corev1.Pod {
	target := request.NodeShell
	privileged := true
	automountToken := false
	zero := int64(0)
	command := []string{
		"nsenter", "--target", "1", "--mount", "--uts", "--ipc", "--net", "--pid", "--",
	}
	command = append(command, request.Command...)
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			GenerateName: "kmgr-node-shell-",
			Namespace:    target.Namespace,
			Labels: map[string]string{
				"app.kubernetes.io/managed-by": "kmgr",
				"app.kubernetes.io/component":  "node-shell",
			},
		},
		Spec: corev1.PodSpec{
			NodeName:                      target.Node.Name,
			HostPID:                       true,
			HostNetwork:                   true,
			DNSPolicy:                     corev1.DNSClusterFirstWithHostNet,
			RestartPolicy:                 corev1.RestartPolicyNever,
			TerminationGracePeriodSeconds: &zero,
			AutomountServiceAccountToken:  &automountToken,
			Tolerations: []corev1.Toleration{
				{Key: "CriticalAddonsOnly", Operator: corev1.TolerationOpExists},
				{Operator: corev1.TolerationOpExists, Effect: corev1.TaintEffectNoExecute},
			},
			Containers: []corev1.Container{{
				Name:      nodeShellContainerName,
				Image:     target.Image,
				Command:   command,
				Stdin:     request.Stdin,
				StdinOnce: request.Stdin,
				TTY:       request.TTY,
				SecurityContext: &corev1.SecurityContext{
					Privileged: &privileged,
				},
				Resources: corev1.ResourceRequirements{
					Requests: corev1.ResourceList{
						corev1.ResourceCPU:    resource.MustParse("100m"),
						corev1.ResourceMemory: resource.MustParse("256Mi"),
					},
					Limits: corev1.ResourceList{
						corev1.ResourceCPU:    resource.MustParse("100m"),
						corev1.ResourceMemory: resource.MustParse("256Mi"),
					},
				},
			}},
		},
	}
}

func waitForNodeShellPod(
	ctx context.Context,
	pods coreclient.PodInterface,
	name string,
	uid types.UID,
) error {
	return wait.PollUntilContextTimeout(ctx, 500*time.Millisecond, nodeShellPodTimeout, true,
		func(ctx context.Context) (bool, error) {
			pod, err := pods.Get(ctx, name, metav1.GetOptions{})
			if err != nil {
				return false, err
			}
			if pod.UID != uid {
				return false, &NodeShellPodReplacedError{Name: name}
			}
			for _, status := range pod.Status.ContainerStatuses {
				if status.State.Waiting != nil && terminalNodeShellWaitingReason(
					status.State.Waiting.Reason,
				) {
					return false, &NodeShellPodStartError{Reason: status.State.Waiting.Reason}
				}
			}
			switch pod.Status.Phase {
			case corev1.PodRunning:
				return true, nil
			case corev1.PodFailed, corev1.PodSucceeded:
				return false, &NodeShellPodStartError{Reason: string(pod.Status.Phase)}
			default:
				return false, nil
			}
		})
}

func terminalNodeShellWaitingReason(reason string) bool {
	switch reason {
	case "ErrImagePull", "ImagePullBackOff", "InvalidImageName", "CreateContainerConfigError",
		"CreateContainerError", "RunContainerError":
		return true
	default:
		return false
	}
}

func deleteNodeShellPod(pods coreclient.PodInterface, name string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	zero := int64(0)
	policy := metav1.DeletePropagationBackground
	_ = pods.Delete(ctx, name, metav1.DeleteOptions{
		GracePeriodSeconds: &zero,
		PropagationPolicy:  &policy,
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
