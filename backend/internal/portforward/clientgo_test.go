package portforward

import (
	"context"
	"errors"
	"io"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/podidentity"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/httpstream"
	"k8s.io/client-go/kubernetes/fake"
)

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
		context.Background(), dialer, podidentity.GetterFunc(func(
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
