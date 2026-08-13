package execstream

import (
	"sync"

	"k8s.io/client-go/tools/remotecommand"
)

// resizeQueue coalesces resize events to the newest dimensions. A process
// consuming slowly never creates an unbounded backlog of obsolete sizes.
type resizeQueue struct {
	mu     sync.Mutex
	latest *remotecommand.TerminalSize
	closed bool
	notify chan struct{}
}

func newResizeQueue(initial *TerminalSize) *resizeQueue {
	queue := &resizeQueue{notify: make(chan struct{}, 1)}
	if initial != nil {
		queue.latest = &remotecommand.TerminalSize{Width: uint16(initial.Columns), Height: uint16(initial.Rows)}
		queue.notify <- struct{}{}
	}
	return queue
}

func (q *resizeQueue) Send(size TerminalSize) error {
	if size.Columns == 0 || size.Rows == 0 || size.Columns > 65535 || size.Rows > 65535 {
		return ErrInvalidRequest
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return ErrSessionClosed
	}
	q.latest = &remotecommand.TerminalSize{Width: uint16(size.Columns), Height: uint16(size.Rows)}
	select {
	case q.notify <- struct{}{}:
	default:
	}
	return nil
}

func (q *resizeQueue) Next() *remotecommand.TerminalSize {
	for range q.notify {
		q.mu.Lock()
		size := q.latest
		q.latest = nil
		closed := q.closed
		q.mu.Unlock()
		if size != nil {
			return size
		}
		if closed {
			return nil
		}
	}
	return nil
}

func (q *resizeQueue) Close() {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return
	}
	q.closed = true
	close(q.notify)
}
