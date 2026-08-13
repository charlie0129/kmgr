package logs

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"sync"
	"time"
)

// readRecords fragments input at either a newline or maxRecordBytes. It never
// accumulates a complete line, and it treats payload bytes as opaque.
func readRecords(
	ctx context.Context,
	reader io.ReadCloser,
	sourceID string,
	timestamps bool,
	maxRecordBytes int,
	emit func(Record),
) error {
	var closeOnce sync.Once
	closeReader := func() { closeOnce.Do(func() { _ = reader.Close() }) }
	stopClose := context.AfterFunc(ctx, closeReader)
	defer func() {
		stopClose()
		closeReader()
	}()

	buffered := bufio.NewReaderSize(reader, maxRecordBytes)
	atLineStart := true
	var lineTimestamp time.Time
	for {
		fragment, err := buffered.ReadSlice('\n')
		endsWithNewline := len(fragment) > 0 && fragment[len(fragment)-1] == '\n'
		if endsWithNewline {
			fragment = fragment[:len(fragment)-1]
		}
		if len(fragment) > 0 || endsWithNewline {
			if timestamps && atLineStart {
				if parsed, rest, ok := parseTimestampPrefix(fragment); ok {
					lineTimestamp = parsed
					fragment = rest
				} else {
					lineTimestamp = time.Time{}
				}
			}
			emit(Record{
				SourceID: sourceID, Data: fragment, Timestamp: lineTimestamp,
				EndsWithNewline: endsWithNewline,
			})
			atLineStart = endsWithNewline
			if endsWithNewline {
				lineTimestamp = time.Time{}
			}
		}
		switch {
		case err == nil:
			continue
		case errors.Is(err, bufio.ErrBufferFull):
			atLineStart = false
			continue
		case errors.Is(err, io.EOF):
			return nil
		default:
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return err
		}
	}
}

func parseTimestampPrefix(fragment []byte) (time.Time, []byte, bool) {
	space := bytes.IndexByte(fragment, ' ')
	if space <= 0 || space > len(time.RFC3339Nano)+10 {
		return time.Time{}, fragment, false
	}
	parsed, err := time.Parse(time.RFC3339Nano, string(fragment[:space]))
	if err != nil {
		return time.Time{}, fragment, false
	}
	return parsed, fragment[space+1:], true
}
