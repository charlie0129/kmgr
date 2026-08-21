package execstream

import (
	"context"
	"testing"
)

func TestOutputQueueFragmentsAndOwnsWrittenBytes(t *testing.T) {
	t.Parallel()
	queue := newOutputQueue(3, 10, 4)
	source := []byte("abcdefghij")
	written, err := queue.writer(StreamStdout).Write(source)
	if err != nil || written != len(source) {
		t.Fatalf("Write = %d, %v", written, err)
	}
	for index := range source {
		source[index] = 'x'
	}
	want := []string{"abcd", "efgh", "ij"}
	for index, expected := range want {
		delivery, err := queue.next(context.Background())
		if err != nil || delivery.Output == nil || delivery.Output.Kind != StreamStdout ||
			string(delivery.Output.Data) != expected {
			t.Fatalf("fragment %d = %#v, %v", index, delivery, err)
		}
	}
	stats := queue.stats()
	if stats.PeakItems != 3 || stats.PeakBytes != 10 || stats.QueuedItems != 0 || stats.QueuedBytes != 0 {
		t.Fatalf("queue stats = %#v", stats)
	}
}

func TestOutputQueueItemPressureDropsOldestAndPreservesOrder(t *testing.T) {
	t.Parallel()
	queue := newOutputQueue(2, 100, 4)
	queue.setStatus(Status{State: StateRunning, StatusReason: "Running"})
	if _, err := queue.next(context.Background()); err != nil {
		t.Fatal(err)
	}
	if written, err := queue.writer(StreamStdout).Write([]byte("abcdefghijkl")); err != nil || written != 12 {
		t.Fatalf("Write = %d, %v", written, err)
	}
	status, err := queue.next(context.Background())
	if err != nil || status.Status == nil || status.Status.DroppedOutputItems != 1 ||
		status.Status.DroppedOutputBytes != 4 {
		t.Fatalf("drop status = %#v, %v", status, err)
	}
	for index, expected := range []string{"efgh", "ijkl"} {
		delivery, nextErr := queue.next(context.Background())
		if nextErr != nil || delivery.Output == nil || string(delivery.Output.Data) != expected {
			t.Fatalf("retained output %d = %#v, %v", index, delivery, nextErr)
		}
	}
	stats := queue.stats()
	if stats.DroppedItems != 1 || stats.DroppedBytes != 4 ||
		stats.PeakItems > 2 || stats.PeakBytes > 100 {
		t.Fatalf("queue stats = %#v", stats)
	}
}

func TestOutputQueueBytePressureDropsWholeOldestChunks(t *testing.T) {
	t.Parallel()
	queue := newOutputQueue(4, 5, 4)
	stdout := queue.writer(StreamStdout)
	if _, err := stdout.Write([]byte("abcd")); err != nil {
		t.Fatal(err)
	}
	if _, err := stdout.Write([]byte("ef")); err != nil {
		t.Fatal(err)
	}
	if _, err := stdout.Write([]byte("ghi")); err != nil {
		t.Fatal(err)
	}
	for index, expected := range []string{"ef", "ghi"} {
		delivery, err := queue.next(context.Background())
		if err != nil || delivery.Output == nil || string(delivery.Output.Data) != expected {
			t.Fatalf("retained output %d = %#v, %v", index, delivery, err)
		}
	}
	stats := queue.stats()
	if stats.DroppedItems != 1 || stats.DroppedBytes != 4 || stats.PeakBytes > 5 {
		t.Fatalf("queue stats = %#v", stats)
	}
}

func TestOutputQueueOversizedWriteKeepsNewestTail(t *testing.T) {
	t.Parallel()
	queue := newOutputQueue(3, 10, 4)
	data := []byte("abcdefghijklmnopqr")
	written, err := queue.writer(StreamStderr).Write(data)
	if err != nil || written != len(data) {
		t.Fatalf("Write = %d, %v", written, err)
	}
	var retained []byte
	for range 3 {
		delivery, nextErr := queue.next(context.Background())
		if nextErr != nil || delivery.Output == nil || delivery.Output.Kind != StreamStderr {
			t.Fatalf("retained output = %#v, %v", delivery, nextErr)
		}
		retained = append(retained, delivery.Output.Data...)
	}
	if string(retained) != "ijklmnopqr" {
		t.Fatalf("retained output = %q, want newest bounded tail", retained)
	}
	stats := queue.stats()
	if stats.DroppedItems != 2 || stats.DroppedBytes != 8 ||
		stats.PeakItems > 3 || stats.PeakBytes > 10 {
		t.Fatalf("queue stats = %#v", stats)
	}
}
