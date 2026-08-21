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
	droppedItems      uint64
	droppedBytes      uint64
	statuses          []Status
	latestStatus      Status
	hasLatestStatus   bool
	terminal          *Status
	terminalDelivered bool
	closed            bool
	notify            chan struct{}
}

type OutputStats struct {
	QueuedItems  int
	QueuedBytes  int
	PeakItems    int
	PeakBytes    int
	DroppedItems uint64
	DroppedBytes uint64
}

func newOutputQueue(maxItems, maxBytes, maxChunkBytes int) *outputQueue {
	maxChunkBytes = min(maxChunkBytes, maxBytes)
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
// Exhaustion evicts the oldest chunks and reports cumulative loss through
// status deliveries. The remote process must never deadlock or terminate just
// because a hidden or stalled GUI is not consuming output quickly enough.
func (q *outputQueue) write(kind StreamKind, data []byte) (int, error) {
	if len(data) == 0 {
		return 0, nil
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return 0, ErrSessionClosed
	}
	dropped := false
	for offset := 0; offset < len(data); {
		end := min(offset+q.maxChunkBytes, len(data))
		chunkBytes := end - offset
		for q.size == len(q.items) || q.bytes+chunkBytes > q.maxBytes {
			q.dropOldestLocked()
			dropped = true
		}
		output := Output{Kind: kind, Data: append([]byte(nil), data[offset:end]...)}
		index := (q.head + q.size) % len(q.items)
		q.items[index] = output
		q.size++
		q.bytes += len(output.Data)
		offset = end
	}
	q.peakItems = max(q.peakItems, q.size)
	q.peakBytes = max(q.peakBytes, q.bytes)
	if dropped {
		q.enqueueDropStatusLocked()
	}
	q.signalLocked()
	return len(data), nil
}

func (q *outputQueue) dropOldestLocked() {
	output := q.items[q.head]
	q.items[q.head] = Output{}
	q.head = (q.head + 1) % len(q.items)
	q.size--
	q.bytes -= len(output.Data)
	q.droppedItems++
	q.droppedBytes += uint64(len(output.Data))
}

func (q *outputQueue) enqueueDropStatusLocked() {
	if !q.hasLatestStatus {
		return
	}
	status := q.latestStatus
	q.attachDropStatsLocked(&status)
	q.enqueueStatusLocked(status)
}

func (q *outputQueue) finish(status Status) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return
	}
	q.closed = true
	copyStatus := status
	q.attachDropStatsLocked(&copyStatus)
	q.terminal = &copyStatus
	q.signalLocked()
}

func (q *outputQueue) setStatus(status Status) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return
	}
	q.attachDropStatsLocked(&status)
	q.latestStatus = status
	q.hasLatestStatus = true
	q.enqueueStatusLocked(status)
	q.signalLocked()
}

func (q *outputQueue) enqueueStatusLocked(status Status) {
	if len(q.statuses) == 2 {
		q.statuses[1] = status
	} else {
		q.statuses = append(q.statuses, status)
	}
}

func (q *outputQueue) attachDropStatsLocked(status *Status) {
	status.DroppedOutputItems = q.droppedItems
	status.DroppedOutputBytes = q.droppedBytes
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
		DroppedItems: q.droppedItems, DroppedBytes: q.droppedBytes,
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
