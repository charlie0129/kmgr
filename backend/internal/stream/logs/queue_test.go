package logs

import (
	"context"
	"testing"
)

func TestRecordQueueFragmentsHugeRecordsBeforeEnforcingBounds(t *testing.T) {
	t.Parallel()
	queue := newRecordQueue(queueConfig{
		maxRecords: 2, maxBytes: 8, maxRecordBytes: 4,
		batchRecords: 2, batchBytes: 8,
	})
	queue.enqueue(Record{SourceID: "pod", Data: []byte("abcdefghijklmnopq"), EndsWithNewline: true})
	stats := queue.stats()
	if stats.QueuedRecords != 2 || stats.QueuedBytes != 5 || stats.PeakQueuedRecords > 2 || stats.PeakQueuedBytes > 8 {
		t.Fatalf("queue stats = %#v", stats)
	}
	if stats.DroppedRecords != 3 || stats.DroppedBytes != 12 {
		t.Fatalf("drops = %d records/%d bytes, want 3/12", stats.DroppedRecords, stats.DroppedBytes)
	}

	statusDelivery, err := queue.next(context.Background())
	if err != nil || statusDelivery.Status == nil {
		t.Fatalf("drop status = %#v, %v", statusDelivery, err)
	}
	if statusDelivery.Status.DroppedRecords != 3 || statusDelivery.Status.DroppedBytes != 12 {
		t.Fatalf("reported drops = %#v", statusDelivery.Status)
	}
	delivery, err := queue.next(context.Background())
	if err != nil {
		t.Fatalf("Next records: %v", err)
	}
	if got := string(joinRecords(delivery.Records)); got != "mnopq" {
		t.Fatalf("retained newest data = %q, want %q", got, "mnopq")
	}
	if delivery.Records[0].EndsWithNewline || !delivery.Records[1].EndsWithNewline {
		t.Fatalf("newline markers = %#v", delivery.Records)
	}
}
