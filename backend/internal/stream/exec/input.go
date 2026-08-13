package execstream

import (
	"context"
	"io"
	"sync"
)

// inputPipe is an explicitly bounded stdin queue. Send never waits on a
// remote process; callers get ErrInputBackpressure and may surface it instead
// of accumulating unbounded terminal input.
type inputPipe struct {
	mu       sync.Mutex
	chunks   [][]byte
	head     int
	size     int
	bytes    int
	maxBytes int
	closed   bool
	err      error
	notify   chan struct{}
}

func newInputPipe(maxChunks, maxBytes int) *inputPipe {
	return &inputPipe{
		chunks: make([][]byte, maxChunks), maxBytes: maxBytes,
		notify: make(chan struct{}, 1),
	}
}

func (p *inputPipe) Send(data []byte) error {
	if len(data) == 0 {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		if p.err != nil {
			return p.err
		}
		return ErrInputClosed
	}
	if p.size == len(p.chunks) || p.bytes+len(data) > p.maxBytes {
		return ErrInputBackpressure
	}
	copyData := append([]byte(nil), data...)
	index := (p.head + p.size) % len(p.chunks)
	p.chunks[index] = copyData
	p.size++
	p.bytes += len(copyData)
	p.signalLocked()
	return nil
}

func (p *inputPipe) Close() {
	p.closeWithError(nil)
}

func (p *inputPipe) Abort(err error) {
	p.closeWithError(err)
}

func (p *inputPipe) closeWithError(err error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return
	}
	p.closed = true
	p.err = err
	if err != nil {
		p.clearLocked()
	}
	p.signalLocked()
}

func (p *inputPipe) Read(destination []byte) (int, error) {
	if len(destination) == 0 {
		return 0, nil
	}
	for {
		p.mu.Lock()
		if p.size > 0 {
			chunk := p.chunks[p.head]
			count := copy(destination, chunk)
			p.bytes -= count
			if count == len(chunk) {
				p.chunks[p.head] = nil
				p.head = (p.head + 1) % len(p.chunks)
				p.size--
			} else {
				p.chunks[p.head] = chunk[count:]
			}
			p.mu.Unlock()
			return count, nil
		}
		if p.closed {
			err := p.err
			p.mu.Unlock()
			if err != nil {
				return 0, err
			}
			return 0, io.EOF
		}
		p.mu.Unlock()
		<-p.notify
	}
}

func (p *inputPipe) signalLocked() {
	select {
	case p.notify <- struct{}{}:
	default:
	}
}

func (p *inputPipe) clearLocked() {
	clear(p.chunks)
	p.head = 0
	p.size = 0
	p.bytes = 0
}

func (p *inputPipe) CloseOnContext(ctx context.Context) func() bool {
	return context.AfterFunc(ctx, func() { p.Abort(ctx.Err()) })
}
