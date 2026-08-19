package portforward

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"sync"

	"github.com/charlie0129/kmgr/backend/internal/podidentity"
	"k8s.io/apimachinery/pkg/util/httpstream"
	"k8s.io/client-go/rest"
	clientportforward "k8s.io/client-go/tools/portforward"
	"k8s.io/client-go/transport/spdy"
	streamhttp "k8s.io/streaming/pkg/httpstream"
)

type ClientGoForwarder struct {
	Config     *rest.Config
	RESTClient rest.Interface
	PodUIDs    podidentity.Getter
}

func (f ClientGoForwarder) Start(ctx context.Context, request ForwardRequest) (RunningForward, error) {
	if f.Config == nil || f.RESTClient == nil || f.PodUIDs == nil {
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
	dialer := clientportforward.NewFallbackDialer(
		tunnelDialer, spdyDialer, shouldFallbackPortForward,
	)
	return startUIDPinnedClientGoForward(ctx, dialer, f.PodUIDs, request)
}

// client-go's legacy port-forward Dialer currently returns upgrade errors
// emitted by both the apimachinery and newer streaming httpstream packages.
// Recognize both so a rejected WebSocket tunnel still reaches the SPDY
// fallback while client-go completes that compatibility transition.
func shouldFallbackPortForward(err error) bool {
	return httpstream.IsUpgradeFailure(err) || httpstream.IsHTTPSProxyError(err) ||
		streamhttp.IsUpgradeFailure(err) || streamhttp.IsHTTPSProxyError(err)
}

// startUIDPinnedClientGoForward performs the final identity check after the
// Kubernetes streaming upgrade succeeds and before client-go binds a local
// listener. The API's port-forward URL contains only namespace/name, so the
// earlier resolver GET alone cannot prevent a same-name replacement from
// winning the race between resolution and transport upgrade.
func startUIDPinnedClientGoForward(
	ctx context.Context,
	dialer httpstream.Dialer,
	podUIDs podidentity.Getter,
	request ForwardRequest,
) (RunningForward, error) {
	pinned := &podUIDValidatingDialer{
		delegate: dialer,
		validate: func() error {
			uid, err := podUIDs.PodUID(ctx, request.Pod.Namespace, request.Pod.Name)
			if err != nil {
				return fmt.Errorf("verify upgraded port-forward Pod identity: %w", err)
			}
			if uid != request.Pod.UID {
				return fmt.Errorf(
					"%w: expected UID %q, found %q after transport upgrade",
					ErrPodRecreated, request.Pod.UID, uid,
				)
			}
			return nil
		},
	}
	running, err := startClientGoForward(ctx, pinned, request)
	if err != nil {
		// client-go stringifies Dial errors. Restore the original typed error so
		// the manager can make a direct-Pod UID mismatch terminal immediately.
		if validationErr := pinned.validationError(); validationErr != nil {
			return nil, validationErr
		}
	}
	return running, err
}

type podUIDValidatingDialer struct {
	delegate httpstream.Dialer
	validate func() error

	mu  sync.Mutex
	err error
}

func (d *podUIDValidatingDialer) Dial(protocols ...string) (httpstream.Connection, string, error) {
	connection, protocol, err := d.delegate.Dial(protocols...)
	if err != nil {
		return nil, protocol, err
	}
	if err := d.validate(); err != nil {
		_ = connection.Close()
		d.mu.Lock()
		d.err = err
		d.mu.Unlock()
		return nil, protocol, err
	}
	return connection, protocol, nil
}

func (d *podUIDValidatingDialer) validationError() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.err
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
