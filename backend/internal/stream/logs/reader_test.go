package logs

import (
	"bytes"
	"context"
	"io"
	"testing"
	"time"
)

func TestHugeBinaryRecordIsFragmentedWithoutDataLoss(t *testing.T) {
	t.Parallel()
	const maxRecordBytes = 64 << 10
	payload := make([]byte, (3<<20)+17)
	for index := range payload {
		payload[index] = byte(index % 251)
		if payload[index] == '\n' {
			payload[index] = 0x7f
		}
	}
	payload[3] = 0xff
	payload[4] = 0xfe
	if payload[len(payload)-1] == '\n' {
		payload[len(payload)-1] = 0x7f
	}
	input := append(append([]byte(nil), payload...), '\n')
	var records []Record
	err := readRecords(
		context.Background(), io.NopCloser(bytes.NewReader(input)), "huge", false, maxRecordBytes,
		func(record Record) {
			record.Data = bytes.Clone(record.Data)
			records = append(records, record)
		},
	)
	if err != nil {
		t.Fatalf("readRecords: %v", err)
	}
	if len(records) < 40 {
		t.Fatalf("huge record fragments = %d, want many bounded fragments", len(records))
	}
	for index, record := range records {
		if len(record.Data) > maxRecordBytes {
			t.Fatalf("fragment %d is %d bytes", index, len(record.Data))
		}
		if record.SourceID != "huge" {
			t.Fatalf("fragment source = %q", record.SourceID)
		}
		if record.EndsWithNewline != (index == len(records)-1) {
			t.Fatalf("fragment %d newline = %v", index, record.EndsWithNewline)
		}
		if record.StartsLine != (index == 0) {
			t.Fatalf("fragment %d starts-line = %v", index, record.StartsLine)
		}
	}
	if got := joinRecords(records); !bytes.Equal(got, payload) {
		t.Fatalf("reassembled payload differs: got %d bytes, want %d", len(got), len(payload))
	}
}

func TestTimestampPrefixIsParsedOffThePayload(t *testing.T) {
	t.Parallel()
	wantTimestamp := time.Date(2026, 8, 13, 4, 5, 6, 123456789, time.UTC)
	wantData := []byte{0xff, 0x00, 'x'}
	input := append([]byte(wantTimestamp.Format(time.RFC3339Nano)+" "), wantData...)
	input = append(input, '\n')
	var records []Record
	if err := readRecords(
		context.Background(), io.NopCloser(bytes.NewReader(input)), "pod", true, 1024,
		func(record Record) {
			record.Data = bytes.Clone(record.Data)
			records = append(records, record)
		},
	); err != nil {
		t.Fatalf("readRecords: %v", err)
	}
	if len(records) != 1 {
		t.Fatalf("records = %d, want 1", len(records))
	}
	if !records[0].Timestamp.Equal(wantTimestamp) || !bytes.Equal(records[0].Data, wantData) ||
		!records[0].StartsLine || !records[0].EndsWithNewline {
		t.Fatalf("record = %#v", records[0])
	}
}

func TestReadRecordsCancellationClosesBlockedReader(t *testing.T) {
	t.Parallel()
	reader := newBlockingReadCloser()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- readRecords(ctx, reader, "pod", false, 1024, func(Record) {})
	}()
	cancel()
	select {
	case err := <-done:
		if !errorsIsCancelledOrClosed(err) {
			t.Fatalf("readRecords error = %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("readRecords did not unblock after cancellation")
	}
}

func errorsIsCancelledOrClosed(err error) bool {
	return err == context.Canceled || err == io.ErrClosedPipe
}
