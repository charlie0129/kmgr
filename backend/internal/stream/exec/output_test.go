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
