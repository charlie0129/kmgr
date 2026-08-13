package portforward

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"sync"

	"k8s.io/apimachinery/pkg/util/httpstream"
	"k8s.io/client-go/rest"
	clientportforward "k8s.io/client-go/tools/portforward"
	"k8s.io/client-go/transport/spdy"
)

type ClientGoForwarder struct {
	Config     *rest.Config
	RESTClient rest.Interface
}

func (f ClientGoForwarder) Start(ctx context.Context, request ForwardRequest) (RunningForward, error) {
	if f.Config == nil || f.RESTClient == nil {
		return nil, errors.New("Kubernetes port-forward transport is unavailable")
	}
	if !request.Pod.IsPod() || request.Pod.Namespace == "" || request.Pod.Name == "" || request.RemotePort == 0 {
		return nil, ErrInvalidRequest
	}
	url := f.RESTClient.Post().
		Resource("pods").Namespace(request.Pod.Namespace).Name(request.Pod.Name).
		SubResource("portforward").URL()
	transport, upgrader, err := spdy.RoundTripperFor(f.Config)
	if err != nil {
		return nil, fmt.Errorf("construct port-forward transport: %w", err)
	}
	spdyDialer := spdy.NewDialer(upgrader, &http.Client{Transport: transport}, http.MethodPost, url)
	tunnelDialer, err := clientportforward.NewSPDYOverWebsocketDialer(url, f.Config)
	if err != nil {
		return nil, fmt.Errorf("construct websocket port-forward transport: %w", err)
	}
	dialer := clientportforward.NewFallbackDialer(tunnelDialer, spdyDialer, func(err error) bool {
		return httpstream.IsUpgradeFailure(err) || httpstream.IsHTTPSProxyError(err)
	})
	return startClientGoForward(ctx, dialer, request)
}

func startClientGoForward(
	ctx context.Context,
	dialer httpstream.Dialer,
	request ForwardRequest,
) (RunningForward, error) {
	stop := make(chan struct{})
	ready := make(chan struct{})
	forwarder, err := clientportforward.NewOnAddresses(
		dialer, []string{request.BindAddress},
		[]string{strconv.Itoa(int(request.LocalPort)) + ":" + strconv.Itoa(int(request.RemotePort))},
		stop, ready, io.Discard, io.Discard,
	)
	if err != nil {
		return nil, fmt.Errorf("configure port-forward listener: %w", err)
	}
	running := &clientGoRunning{forwarder: forwarder, stop: stop, done: make(chan error, 1)}
	go func() { running.done <- forwarder.ForwardPorts() }()
	select {
	case <-ctx.Done():
		_ = running.Close()
		return nil, ctx.Err()
	case err := <-running.done:
		return nil, err
	case <-ready:
		ports, err := forwarder.GetPorts()
		if err != nil || len(ports) != 1 {
			_ = running.Close()
			<-running.done
			return nil, fmt.Errorf("read bound local port: %w", err)
		}
		running.localPort = ports[0].Local
		return running, nil
	}
}

type clientGoRunning struct {
	forwarder *clientportforward.PortForwarder
	localPort uint16
	stop      chan struct{}
	done      chan error
	closeOnce sync.Once
}

func (f *clientGoRunning) LocalPort() uint16 { return f.localPort }
func (f *clientGoRunning) Wait() error       { return <-f.done }
func (f *clientGoRunning) Close() error {
	f.closeOnce.Do(func() { close(f.stop) })
	return nil
}

var _ Forwarder = ClientGoForwarder{}
