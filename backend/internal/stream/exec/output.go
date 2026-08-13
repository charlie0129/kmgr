package execstream

import (
	"context"
	"sync"
)

type outputQueue struct {
	mu                sync.Mutex
	items             []Output
	head              int
	size              int
	bytes             int
	maxBytes          int
	maxChunkBytes     int
	peakItems         int
	peakBytes         int
	statuses          []Status
	terminal          *Status
	terminalDelivered bool
	closed            bool
	notify            chan struct{}
}

type OutputStats struct {
	QueuedItems int
	QueuedBytes int
	PeakItems   int
	PeakBytes   int
}

func newOutputQueue(maxItems, maxBytes, maxChunkBytes int) *outputQueue {
	return &outputQueue{
		items: make([]Output, maxItems), maxBytes: maxBytes, maxChunkBytes: maxChunkBytes,
		notify: make(chan struct{}, 1),
	}
}

func (q *outputQueue) writer(kind StreamKind) *queueWriter {
	return &queueWriter{queue: q, kind: kind}
}

// write is intentionally non-blocking. Allowing remotecommand's protocol
// goroutines to wait on a hidden or stalled GUI can deadlock a TTY session.
// Exhaustion cancels the exec instead of silently losing terminal bytes.
func (q *outputQueue) write(kind StreamKind, data []byte) (int, error) {
	if len(data) == 0 {
		return 0, nil
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return 0, ErrSessionClosed
	}
	neededItems := (len(data) + q.maxChunkBytes - 1) / q.maxChunkBytes
	if q.size+neededItems > len(q.items) || q.bytes+len(data) > q.maxBytes {
		return 0, ErrOutputBackpressure
	}
	for offset := 0; offset < len(data); {
		end := min(offset+q.maxChunkBytes, len(data))
		output := Output{Kind: kind, Data: append([]byte(nil), data[offset:end]...)}
		index := (q.head + q.size) % len(q.items)
		q.items[index] = output
		q.size++
		q.bytes += len(output.Data)
		offset = end
	}
	q.peakItems = max(q.peakItems, q.size)
	q.peakBytes = max(q.peakBytes, q.bytes)
	q.signalLocked()
	return len(data), nil
}

func (q *outputQueue) finish(status Status) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return
	}
	q.closed = true
	copyStatus := status
	q.terminal = &copyStatus
	q.signalLocked()
}

func (q *outputQueue) setStatus(status Status) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return
	}
	if len(q.statuses) == 2 {
		q.statuses[1] = status
	} else {
		q.statuses = append(q.statuses, status)
	}
	q.signalLocked()
}

func (q *outputQueue) next(ctx context.Context) (Delivery, error) {
	for {
		q.mu.Lock()
		if len(q.statuses) > 0 {
			status := q.statuses[0]
			q.statuses = q.statuses[1:]
			q.mu.Unlock()
			return Delivery{Status: &status}, nil
		}
		if q.size > 0 {
			output := q.items[q.head]
			q.items[q.head] = Output{}
			q.head = (q.head + 1) % len(q.items)
			q.size--
			q.bytes -= len(output.Data)
			q.mu.Unlock()
			return Delivery{Output: &output}, nil
		}
		if q.terminal != nil && !q.terminalDelivered {
			status := *q.terminal
			q.terminalDelivered = true
			q.mu.Unlock()
			return Delivery{Status: &status}, nil
		}
		if q.closed {
			q.mu.Unlock()
			return Delivery{}, ErrSessionClosed
		}
		q.mu.Unlock()
		select {
		case <-ctx.Done():
			return Delivery{}, ctx.Err()
		case <-q.notify:
		}
	}
}

func (q *outputQueue) stats() OutputStats {
	q.mu.Lock()
	defer q.mu.Unlock()
	return OutputStats{
		QueuedItems: q.size, QueuedBytes: q.bytes,
		PeakItems: q.peakItems, PeakBytes: q.peakBytes,
	}
}

func (q *outputQueue) signalLocked() {
	select {
	case q.notify <- struct{}{}:
	default:
	}
}

type queueWriter struct {
	queue *outputQueue
	kind  StreamKind
}

func (w *queueWriter) Write(data []byte) (int, error) {
	return w.queue.write(w.kind, data)
}
