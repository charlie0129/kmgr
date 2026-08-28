package portforward

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"slices"
	"strconv"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/httpstream"
	"k8s.io/client-go/kubernetes/fake"
	streamhttp "k8s.io/streaming/pkg/httpstream"
)

func TestPortForwardFallbackRecognizesBothClientGoUpgradeErrorFamilies(t *testing.T) {
	t.Parallel()
	for name, err := range map[string]error{
		"legacy":    &httpstream.UpgradeFailureError{Cause: errors.New("legacy upgrade rejected")},
		"streaming": &streamhttp.UpgradeFailureError{Cause: errors.New("streaming upgrade rejected")},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if !shouldFallbackPortForward(err) {
				t.Fatalf("upgrade error %T did not enable SPDY fallback", err)
			}
		})
	}
	if shouldFallbackPortForward(errors.New("unrelated failure")) {
		t.Fatal("unrelated error enabled SPDY fallback")
	}
}

func TestLocalPortCandidatesUseBoundedTenThousandFallbacks(t *testing.T) {
	t.Parallel()
	tests := []struct {
		requested uint16
		want      []uint16
	}{
		{requested: 0, want: []uint16{0}},
		{requested: 8_080, want: []uint16{8_080, 18_080, 28_080, 38_080, 48_080, 58_080, 0}},
		{requested: 60_000, want: []uint16{60_000, 0}},
	}
	for _, test := range tests {
		if got := localPortCandidates(test.requested); !slices.Equal(got, test.want) {
			t.Errorf("localPortCandidates(%d) = %v, want %v", test.requested, got, test.want)
		}
	}
}

func TestLocalPortFallbackUsesFirstAvailableCandidateAndThenRandom(t *testing.T) {
	t.Parallel()
	bindErr := fmt.Errorf("%w: unable to listen on any of the requested ports", errLocalPortUnavailable)
	request := ForwardRequest{RemotePort: 8_080, LocalPort: 8_080}
	var attempts []uint16
	running, err := startWithLocalPortFallback(
		context.Background(), request,
		func(attempt ForwardRequest) (RunningForward, error) {
			attempts = append(attempts, attempt.LocalPort)
			if attempt.LocalPort != 28_080 {
				return nil, bindErr
			}
			return &fakeRunning{port: attempt.LocalPort}, nil
		},
	)
	if err != nil || running == nil || running.LocalPort() != 28_080 {
		t.Fatalf("fallback result = (%v, %v), want listening on 28080", running, err)
	}
	if !slices.Equal(attempts, []uint16{8_080, 18_080, 28_080}) {
		t.Fatalf("fallback attempts = %v", attempts)
	}

	attempts = nil
	running, err = startWithLocalPortFallback(
		context.Background(), request,
		func(attempt ForwardRequest) (RunningForward, error) {
			attempts = append(attempts, attempt.LocalPort)
			return nil, bindErr
		},
	)
	if err == nil || running != nil {
		t.Fatalf("all-port result = (%v, %v), want the final bind error", running, err)
	}
	if got := attempts[len(attempts)-1]; got != 0 {
		t.Fatalf("final fallback port = %d, want random allocation (0)", got)
	}
}

func TestLocalPortFallbackDoesNotRetryRemoteFailures(t *testing.T) {
	t.Parallel()
	request := ForwardRequest{RemotePort: 8_080, LocalPort: 8_080}
	remoteErr := errors.New("error upgrading connection")
	var attempts []uint16
	_, err := startWithLocalPortFallback(
		context.Background(), request,
		func(attempt ForwardRequest) (RunningForward, error) {
			attempts = append(attempts, attempt.LocalPort)
			return nil, remoteErr
		},
	)
	if !errors.Is(err, remoteErr) {
		t.Fatalf("remote error = %v, want %v", err, remoteErr)
	}
	if !slices.Equal(attempts, []uint16{8_080}) {
		t.Fatalf("remote failure attempts = %v", attempts)
	}
}

func TestClientGoForwardReportsAddressInUseAsLocalPortFailure(t *testing.T) {
	t.Parallel()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	_, portText, _ := net.SplitHostPort(listener.Addr().String())
	port, err := strconv.ParseUint(portText, 10, 16)
	if err != nil {
		t.Fatal(err)
	}
	_, err = startClientGoForward(
		context.Background(),
		fakeDialer{connection: &blockingConnection{closed: make(chan bool)}},
		ForwardRequest{RemotePort: 8080, LocalPort: uint16(port), BindAddress: "127.0.0.1"},
	)
	if !errors.Is(err, errLocalPortUnavailable) {
		t.Fatalf("bind error = %v, want errLocalPortUnavailable", err)
	}
}

func TestClientGoForwarderAllocatesPortZeroInsideListener(t *testing.T) {
	t.Parallel()
	connection := &blockingConnection{closed: make(chan bool)}
	running, err := startClientGoForward(context.Background(), fakeDialer{connection: connection}, ForwardRequest{
		Pod: podIdentity("pod", "uid"), RemotePort: 8080, LocalPort: 0, BindAddress: "127.0.0.1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if running.LocalPort() == 0 {
		t.Fatal("client-go listener did not publish its allocated port")
	}
	if err := running.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-waitForward(running):
		if err != nil {
			t.Fatalf("Wait error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("client-go forward did not stop")
	}
}

func TestUIDPinnedForwardRejectsReplacementAfterUpgradeBeforeLocalListener(t *testing.T) {
	t.Parallel()
	oldPod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{
		Namespace: "ns", Name: "pod", UID: types.UID("old-uid"),
	}}
	replacement := oldPod.DeepCopy()
	replacement.UID = types.UID("new-uid")
	client := fake.NewSimpleClientset(oldPod)
	connection := &blockingConnection{closed: make(chan bool)}
	dialer := callbackDialer{dial: func() (httpstream.Connection, string, error) {
		pods := client.CoreV1().Pods(oldPod.Namespace)
		if err := pods.Delete(context.Background(), oldPod.Name, metav1.DeleteOptions{}); err != nil {
			return nil, "", err
		}
		if _, err := pods.Create(context.Background(), replacement, metav1.CreateOptions{}); err != nil {
			return nil, "", err
		}
		return connection, "portforward.k8s.io", nil
	}}

	running, err := startUIDPinnedClientGoForward(
		context.Background(), dialer, podUIDGetterFunc(func(
			ctx context.Context, namespace, name string,
		) (types.UID, error) {
			pod, err := client.CoreV1().Pods(namespace).Get(ctx, name, metav1.GetOptions{})
			if err != nil {
				return "", err
			}
			return pod.UID, nil
		}),
		ForwardRequest{
			Pod: podIdentity("pod", "old-uid"), RemotePort: 8080,
			LocalPort: 0, BindAddress: "127.0.0.1",
		},
	)
	if running != nil {
		t.Fatal("same-name replacement unexpectedly received a running forward")
	}
	if !errors.Is(err, ErrPodRecreated) {
		t.Fatalf("Start error = %v, want ErrPodRecreated", err)
	}
	select {
	case <-connection.closed:
	case <-time.After(time.Second):
		t.Fatal("upgraded connection to replacement Pod was not closed")
	}
}

func waitForward(running RunningForward) <-chan error {
	result := make(chan error, 1)
	go func() { result <- running.Wait() }()
	return result
}

type fakeDialer struct{ connection httpstream.Connection }

func (d fakeDialer) Dial(...string) (httpstream.Connection, string, error) {
	return d.connection, "portforward.k8s.io", nil
}

type callbackDialer struct {
	dial func() (httpstream.Connection, string, error)
}

func (d callbackDialer) Dial(...string) (httpstream.Connection, string, error) {
	return d.dial()
}

type blockingConnection struct {
	mu     sync.Mutex
	closed chan bool
	once   sync.Once
}

func (*blockingConnection) CreateStream(http.Header) (httpstream.Stream, error) {
	return discardStream{}, nil
}
func (c *blockingConnection) Close() error {
	c.once.Do(func() { close(c.closed) })
	return nil
}
func (c *blockingConnection) CloseChan() <-chan bool           { return c.closed }
func (*blockingConnection) SetIdleTimeout(time.Duration)       {}
func (*blockingConnection) RemoveStreams(...httpstream.Stream) {}

type discardStream struct{ io.ReadWriteCloser }

func (discardStream) Read([]byte) (int, error)        { return 0, io.EOF }
func (discardStream) Write(value []byte) (int, error) { return len(value), nil }
func (discardStream) Close() error                    { return nil }
func (discardStream) Reset() error                    { return nil }
func (discardStream) Headers() http.Header            { return make(http.Header) }
func (discardStream) Identifier() uint32              { return 1 }

var _ httpstream.Connection = (*blockingConnection)(nil)
var _ httpstream.Stream = discardStream{}
