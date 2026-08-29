package main

import (
	"io"
	"sync"
	"sync/atomic"
	"time"
)

const streamChunkBuf = 32 * 1024
const streamQueueSize = 256

// streamForwarder drains the harness stdout/stderr pipes from the moment
// of spawn (so a chatty harness cannot fill the kernel pipe and block)
// and, once Attach is called, writes each read as a stdout_chunk /
// stderr_chunk control message. Chunks produced before Attach sit in a
// bounded queue so a short-lived harness that prints and exits before
// the daemon connects does not lose its output. A full queue drops
// rather than blocking the harness indefinitely.
type streamForwarder struct {
	chunks chan map[string]any
	wg     sync.WaitGroup
	done   chan struct{}
}

func startStreamForwarder(stdout, stderr io.Reader, attemptID, fencingToken string) *streamForwarder {
	f := &streamForwarder{chunks: make(chan map[string]any, streamQueueSize), done: make(chan struct{})}
	var stdoutSeq, stderrSeq atomic.Int64
	f.wg.Add(2)
	go f.pump(stdout, "stdout_chunk", attemptID, fencingToken, &stdoutSeq)
	go f.pump(stderr, "stderr_chunk", attemptID, fencingToken, &stderrSeq)
	go func() {
		f.wg.Wait()
		close(f.chunks)
	}()
	return f
}

func (f *streamForwarder) pump(r io.Reader, msgType, attemptID, fencingToken string, seq *atomic.Int64) {
	defer f.wg.Done()
	if r == nil {
		return
	}
	buf := make([]byte, streamChunkBuf)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			msg := map[string]any{
				"type":            msgType,
				"attempt_id":      attemptID,
				"fencing_token":   fencingToken,
				"native_sequence": seq.Add(1),
				"data":            string(buf[:n]),
			}
			select {
			case f.chunks <- msg:
			default:
			}
		}
		if err != nil {
			return
		}
	}
}

// Attach starts sending queued then live chunks on cc. Must be called
// after runner_started has been written; otherwise launch() would read a
// stdout_chunk as its first message and treat it as a protocol error.
func (f *streamForwarder) Attach(cc *ControlChannel) {
	go func() {
		defer close(f.done)
		for msg := range f.chunks {
			if err := cc.SendFrame(msg); err != nil {
				for range f.chunks {
				}
				return
			}
		}
	}()
}

func (f *streamForwarder) Wait(timeout time.Duration) {
	select {
	case <-f.done:
	case <-time.After(timeout):
	}
}
