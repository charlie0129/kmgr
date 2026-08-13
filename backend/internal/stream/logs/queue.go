package logs

import (
	"context"
	"sync"
)

const globalStatusKey = "\x00global"

type queueConfig struct {
	maxRecords     int
	maxBytes       int
	maxRecordBytes int
	batchRecords   int
	batchBytes     int
}

type QueueStats struct {
	QueuedRecords     int
	QueuedBytes       int
	PeakQueuedRecords int
	PeakQueuedBytes   int
	DroppedRecords    uint64
	DroppedBytes      uint64
}

// recordQueue is a byte-and-record bounded ring. Status updates are coalesced
// by source, so slow receivers cannot make either payload or lifecycle state
// grow without bound.
type recordQueue struct {
	mu             sync.Mutex
	config         queueConfig
	slots          []Record
	head           int
	size           int
	bytes          int
	peakSize       int
	peakBytes      int
	droppedRecords uint64
	droppedBytes   uint64

	statuses          map[string]Status
	statusOrder       []string
	overallState      State
	terminal          *Status
	terminalFirst     bool
	terminalDelivered bool
	closed            bool
	notify            chan struct{}
}

func newRecordQueue(config queueConfig) *recordQueue {
	return &recordQueue{
		config:       config,
		slots:        make([]Record, config.maxRecords),
		statuses:     make(map[string]Status),
		overallState: StateConnecting,
		notify:       make(chan struct{}, 1),
	}
}

func (q *recordQueue) signalLocked() {
	select {
	case q.notify <- struct{}{}:
	default:
	}
}

func (q *recordQueue) setStatus(status Status) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return
	}
	key := globalStatusKey
	if status.SourceID != "" {
		key = status.SourceID
	} else {
		q.overallState = status.State
	}
	if _, exists := q.statuses[key]; !exists {
		q.statusOrder = append(q.statusOrder, key)
	}
	q.statuses[key] = status
	q.signalLocked()
}

func (q *recordQueue) enqueue(record Record) {
	if len(record.Data) == 0 {
		q.enqueueOne(record)
		return
	}
	for offset := 0; offset < len(record.Data); {
		end := min(offset+q.config.maxRecordBytes, len(record.Data))
		fragment := record
		fragment.Data = record.Data[offset:end]
		fragment.EndsWithNewline = record.EndsWithNewline && end == len(record.Data)
		q.enqueueOne(fragment)
		offset = end
	}
}

func (q *recordQueue) enqueueOne(record Record) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return
	}
	dataBytes := len(record.Data)
	if dataBytes > q.config.maxBytes {
		q.droppedRecords++
		q.droppedBytes += uint64(dataBytes)
		q.noteDropsLocked()
		return
	}
	for q.size > 0 && (q.size == q.config.maxRecords || q.bytes+dataBytes > q.config.maxBytes) {
		q.dropHeadLocked()
	}
	copyRecord := record
	copyRecord.Data = append([]byte(nil), record.Data...)
	index := (q.head + q.size) % len(q.slots)
	q.slots[index] = copyRecord
	q.size++
	q.bytes += dataBytes
	q.peakSize = max(q.peakSize, q.size)
	q.peakBytes = max(q.peakBytes, q.bytes)
	q.signalLocked()
}

func (q *recordQueue) dropHeadLocked() {
	record := q.slots[q.head]
	q.slots[q.head] = Record{}
	q.head = (q.head + 1) % len(q.slots)
	q.size--
	q.bytes -= len(record.Data)
	q.droppedRecords++
	q.droppedBytes += uint64(len(record.Data))
	q.noteDropsLocked()
}

func (q *recordQueue) noteDropsLocked() {
	status := q.statuses[globalStatusKey]
	status.State = q.overallState
	if _, exists := q.statuses[globalStatusKey]; !exists {
		q.statusOrder = append(q.statusOrder, globalStatusKey)
	}
	q.statuses[globalStatusKey] = status
}

func (q *recordQueue) finish(status Status, discard bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return
	}
	q.closed = true
	q.overallState = status.State
	if discard {
		for q.size > 0 {
			q.dropHeadLocked()
		}
		clear(q.statuses)
		q.statusOrder = q.statusOrder[:0]
		q.terminalFirst = true
	}
	copyStatus := status
	q.terminal = &copyStatus
	q.signalLocked()
}

func (q *recordQueue) next(ctx context.Context) (Delivery, error) {
	for {
		q.mu.Lock()
		if q.terminalFirst && q.terminal != nil && !q.terminalDelivered {
			delivery := q.terminalDeliveryLocked()
			q.mu.Unlock()
			return delivery, nil
		}
		if len(q.statusOrder) > 0 {
			key := q.statusOrder[0]
			q.statusOrder = q.statusOrder[1:]
			status := q.statuses[key]
			delete(q.statuses, key)
			status.DroppedRecords = q.droppedRecords
			status.DroppedBytes = q.droppedBytes
			q.mu.Unlock()
			return Delivery{Status: &status}, nil
		}
		if q.size > 0 {
			records := make([]Record, 0, min(q.size, q.config.batchRecords))
			totalBytes := 0
			for q.size > 0 && len(records) < q.config.batchRecords {
				record := q.slots[q.head]
				if len(records) > 0 && totalBytes+len(record.Data) > q.config.batchBytes {
					break
				}
				q.slots[q.head] = Record{}
				q.head = (q.head + 1) % len(q.slots)
				q.size--
				q.bytes -= len(record.Data)
				totalBytes += len(record.Data)
				records = append(records, record)
			}
			q.mu.Unlock()
			return Delivery{Records: records, TotalBytes: uint64(totalBytes)}, nil
		}
		if q.terminal != nil && !q.terminalDelivered {
			delivery := q.terminalDeliveryLocked()
			q.mu.Unlock()
			return delivery, nil
		}
		if q.closed {
			q.mu.Unlock()
			return Delivery{}, ErrStreamClosed
		}
		q.mu.Unlock()
		select {
		case <-ctx.Done():
			return Delivery{}, ctx.Err()
		case <-q.notify:
		}
	}
}

func (q *recordQueue) terminalDeliveryLocked() Delivery {
	status := *q.terminal
	status.DroppedRecords = q.droppedRecords
	status.DroppedBytes = q.droppedBytes
	q.terminalDelivered = true
	return Delivery{Status: &status}
}

func (q *recordQueue) stats() QueueStats {
	q.mu.Lock()
	defer q.mu.Unlock()
	return QueueStats{
		QueuedRecords: q.size, QueuedBytes: q.bytes,
		PeakQueuedRecords: q.peakSize, PeakQueuedBytes: q.peakBytes,
		DroppedRecords: q.droppedRecords, DroppedBytes: q.droppedBytes,
	}
}
