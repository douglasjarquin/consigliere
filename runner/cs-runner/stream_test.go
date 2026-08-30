package main

import (
	"io"
	"sync/atomic"
	"testing"
	"time"
)

type fixedChunkReader struct {
	remaining int
}

func (r *fixedChunkReader) Read(buffer []byte) (int, error) {
	if r.remaining == 0 {
		return 0, io.EOF
	}
	r.remaining--
	buffer[0] = 'x'
	return 1, nil
}

func TestStreamForwarder_deliversEveryChunkWhenQueueIsFull(t *testing.T) {
	// Given
	forwarder := &streamForwarder{chunks: make(chan map[string]any, streamQueueSize)}
	reader := &fixedChunkReader{remaining: streamQueueSize + 1}
	var sequence atomic.Int64
	pumpDone := make(chan struct{})
	forwarder.wg.Add(1)

	// When
	go func() {
		forwarder.pump(reader, "stdout_chunk", "attempt", "fence", &sequence)
		close(pumpDone)
	}()

	// Then
	select {
	case <-pumpDone:
		t.Fatal("pump completed before a consumer drained the full queue")
	case <-time.After(100 * time.Millisecond):
	}

	for range streamQueueSize {
		<-forwarder.chunks
	}

	select {
	case <-pumpDone:
	case <-time.After(time.Second):
		t.Fatal("pump did not finish after the queue was drained")
	}

	last := <-forwarder.chunks
	if got := last["native_sequence"]; got != int64(streamQueueSize+1) {
		t.Fatalf("last native sequence = %v, want %d", got, streamQueueSize+1)
	}
}

func TestStreamForwarder_reportsDeliveryFailure(t *testing.T) {
	forwarder := &streamForwarder{
		chunks: make(chan map[string]any, 1),
		done:   make(chan struct{}),
	}
	forwarder.chunks <- map[string]any{
		"type":            "stdout_chunk",
		"attempt_id":      "attempt",
		"fencing_token":   "fence",
		"native_sequence": int64(1),
		"data":            "output",
	}
	close(forwarder.chunks)

	forwarder.Attach(&ControlChannel{})
	if err := forwarder.Wait(time.Second); err == nil {
		t.Fatal("expected unauthenticated control channel delivery to fail")
	}
}
