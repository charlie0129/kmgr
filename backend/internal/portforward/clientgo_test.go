package portforward

import (
	"context"
	"io"
	"net/http"
	"sync"
	"testing"
	"time"

	"k8s.io/apimachinery/pkg/util/httpstream"
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

func waitForward(running RunningForward) <-chan error {
	result := make(chan error, 1)
	go func() { result <- running.Wait() }()
	return result
}

type fakeDialer struct{ connection httpstream.Connection }

func (d fakeDialer) Dial(...string) (httpstream.Connection, string, error) {
	return d.connection, "portforward.k8s.io", nil
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
