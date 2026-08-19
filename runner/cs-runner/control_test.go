package main

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// shortSocketDir returns a short-path temp directory suitable for a Unix
// domain socket. t.TempDir() nests under a path that includes the full test
// name, which routinely exceeds macOS's ~104-byte sockaddr_un.sun_path
// limit and fails bind() with "invalid argument" -- a real OS constraint,
// not a test bug, and the same constraint production code must respect by
// keeping the runtime directory short (docs/protocols/runner.md's
// /var/run/csd/attempts/<attempt_id>/ is deliberately short for this reason).
func shortSocketDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "cs")
	if err != nil {
		t.Fatalf("create short socket dir: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func TestControlChannel_AcceptsOneClientAndExchangesNDJSON(t *testing.T) {
	socketPath := filepath.Join(shortSocketDir(t), "control.sock")
	cc, err := NewControlChannel(socketPath)
	if err != nil {
		t.Fatalf("NewControlChannel: %v", err)
	}
	defer cc.Close()

	acceptErrCh := make(chan error, 1)
	go func() { acceptErrCh <- cc.AcceptOnce(2 * time.Second) }()

	conn, err := net.DialTimeout("unix", socketPath, 2*time.Second)
	if err != nil {
		t.Fatalf("client dial: %v", err)
	}
	defer conn.Close()

	if err := <-acceptErrCh; err != nil {
		t.Fatalf("AcceptOnce: %v", err)
	}

	if err := cc.Send(map[string]any{"type": "runner_started", "attempt_id": "a1"}); err != nil {
		t.Fatalf("Send: %v", err)
	}

	reader := bufio.NewReader(conn)
	line, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("client read: %v", err)
	}

	var msg map[string]any
	if err := json.Unmarshal([]byte(line), &msg); err != nil {
		t.Fatalf("unmarshal received line %q: %v", line, err)
	}
	if msg["type"] != "runner_started" || msg["attempt_id"] != "a1" {
		t.Fatalf("unexpected message: %+v", msg)
	}
}

func TestControlChannel_ReadLoopDeliversMessagesAndDetectsEOF(t *testing.T) {
	socketPath := filepath.Join(shortSocketDir(t), "control.sock")
	cc, err := NewControlChannel(socketPath)
	if err != nil {
		t.Fatalf("NewControlChannel: %v", err)
	}
	defer cc.Close()

	acceptErrCh := make(chan error, 1)
	go func() { acceptErrCh <- cc.AcceptOnce(2 * time.Second) }()

	conn, err := net.DialTimeout("unix", socketPath, 2*time.Second)
	if err != nil {
		t.Fatalf("client dial: %v", err)
	}

	if err := <-acceptErrCh; err != nil {
		t.Fatalf("AcceptOnce: %v", err)
	}

	received := make(chan map[string]any, 4)
	eofDetected := make(chan struct{})

	go cc.ReadLoop(
		func(msg map[string]any) { received <- msg },
		func() { close(eofDetected) },
	)

	if _, err := conn.Write([]byte(`{"type":"ping","attempt_id":"a1"}` + "\n")); err != nil {
		t.Fatalf("client write: %v", err)
	}

	select {
	case msg := <-received:
		if msg["type"] != "ping" {
			t.Fatalf("unexpected message: %+v", msg)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for ping message to be delivered")
	}

	conn.Close()

	select {
	case <-eofDetected:
	case <-time.After(2 * time.Second):
		t.Fatalf("EOF callback was never invoked after client disconnected")
	}
}

// TestControlChannel_ReadLoopHandlesOversizedSingleLineMessage proves a
// large-but-valid single NDJSON line (larger than bufio.Scanner's default
// 64KiB token limit) is delivered intact rather than being misread as a
// scan error and reported as onEOF -- conflating "message too big" with
// "the daemon is gone" would make ReadLoop kill a perfectly live Attempt's
// harness the first time a large stdout/stderr chunk crossed the channel.
func TestControlChannel_ReadLoopHandlesOversizedSingleLineMessage(t *testing.T) {
	socketPath := filepath.Join(shortSocketDir(t), "control.sock")
	cc, err := NewControlChannel(socketPath)
	if err != nil {
		t.Fatalf("NewControlChannel: %v", err)
	}
	defer cc.Close()

	acceptErrCh := make(chan error, 1)
	go func() { acceptErrCh <- cc.AcceptOnce(2 * time.Second) }()

	conn, err := net.DialTimeout("unix", socketPath, 2*time.Second)
	if err != nil {
		t.Fatalf("client dial: %v", err)
	}
	defer conn.Close()

	if err := <-acceptErrCh; err != nil {
		t.Fatalf("AcceptOnce: %v", err)
	}

	received := make(chan map[string]any, 1)
	eofDetected := make(chan struct{})
	go cc.ReadLoop(
		func(msg map[string]any) { received <- msg },
		func() { close(eofDetected) },
	)

	bigPayload := strings.Repeat("x", 70000)
	msg := map[string]any{"type": "stdout_chunk", "attempt_id": "a1", "data": bigPayload}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if _, err := conn.Write(append(data, '\n')); err != nil {
		t.Fatalf("client write: %v", err)
	}

	select {
	case got := <-received:
		if got["type"] != "stdout_chunk" || got["data"] != bigPayload {
			t.Fatalf("oversized message was not delivered intact")
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("oversized message was never delivered (likely misread as a scanner error / false EOF)")
	}

	select {
	case <-eofDetected:
		t.Fatalf("ReadLoop incorrectly reported EOF for an oversized-but-valid single line while the connection was still open")
	case <-time.After(300 * time.Millisecond):
	}
}

// TestControlChannel_ReadLoopBoundsLineSizeAndNeverTreatsATooLongLineAsEOF
// proves ReadLoop's line size is bounded (unlike a raw bufio.Reader.
// ReadString, which has no cap and lets an unterminated write grow memory
// without limit) and that exceeding the bound drops the line rather than
// ever firing onEOF -- a too-long frame must not be conflated with the
// daemon actually disconnecting.
func TestControlChannel_ReadLoopBoundsLineSizeAndNeverTreatsATooLongLineAsEOF(t *testing.T) {
	socketPath := filepath.Join(shortSocketDir(t), "control.sock")
	cc, err := NewControlChannel(socketPath)
	if err != nil {
		t.Fatalf("NewControlChannel: %v", err)
	}
	defer cc.Close()

	acceptErrCh := make(chan error, 1)
	go func() { acceptErrCh <- cc.AcceptOnce(2 * time.Second) }()

	conn, err := net.DialTimeout("unix", socketPath, 2*time.Second)
	if err != nil {
		t.Fatalf("client dial: %v", err)
	}
	defer conn.Close()

	if err := <-acceptErrCh; err != nil {
		t.Fatalf("AcceptOnce: %v", err)
	}

	received := make(chan map[string]any, 1)
	eofDetected := make(chan struct{})
	go cc.ReadLoop(
		func(msg map[string]any) { received <- msg },
		func() { close(eofDetected) },
	)

	tooLong := strings.Repeat("y", maxControlLineBytes+1024)
	if _, err := conn.Write([]byte(tooLong + "\n")); err != nil {
		t.Fatalf("client write: %v", err)
	}

	select {
	case got := <-received:
		t.Fatalf("expected the too-long line to be dropped, not delivered: %+v", got)
	case <-eofDetected:
		t.Fatalf("expected the too-long line to be dropped, not treated as EOF/disconnection")
	case <-time.After(500 * time.Millisecond):
	}

	// The channel must still be alive after the too-long line: a valid
	// message sent afterward on the same connection must still be
	// delivered, not silently lost because the read loop gave up.
	if _, err := conn.Write([]byte(`{"type":"cancel"}` + "\n")); err != nil {
		t.Fatalf("client write after too-long line: %v", err)
	}
	select {
	case got := <-received:
		if got["type"] != "cancel" {
			t.Fatalf("unexpected message: %+v", got)
		}
	case <-eofDetected:
		t.Fatalf("expected the valid cancel to be delivered, not treated as EOF")
	case <-time.After(2 * time.Second):
		t.Fatalf("cancel sent after a too-long line was never delivered -- the read loop stopped listening")
	}
}

// TestControlChannel_ReadLoopStillDetectsRealDisconnectAfterATooLongLine
// proves a too-long line does not leave ReadLoop permanently unable to
// detect the connection actually closing afterward -- the daemon dying for
// real, right after having sent one oversized frame, must still be
// detected.
func TestControlChannel_ReadLoopStillDetectsRealDisconnectAfterATooLongLine(t *testing.T) {
	socketPath := filepath.Join(shortSocketDir(t), "control.sock")
	cc, err := NewControlChannel(socketPath)
	if err != nil {
		t.Fatalf("NewControlChannel: %v", err)
	}
	defer cc.Close()

	acceptErrCh := make(chan error, 1)
	go func() { acceptErrCh <- cc.AcceptOnce(2 * time.Second) }()

	conn, err := net.DialTimeout("unix", socketPath, 2*time.Second)
	if err != nil {
		t.Fatalf("client dial: %v", err)
	}

	if err := <-acceptErrCh; err != nil {
		t.Fatalf("AcceptOnce: %v", err)
	}

	eofDetected := make(chan struct{})
	go cc.ReadLoop(
		func(map[string]any) {},
		func() { close(eofDetected) },
	)

	tooLong := strings.Repeat("z", maxControlLineBytes+1024)
	if _, err := conn.Write([]byte(tooLong + "\n")); err != nil {
		t.Fatalf("client write: %v", err)
	}

	select {
	case <-eofDetected:
		t.Fatalf("expected the too-long line alone not to trigger EOF")
	case <-time.After(300 * time.Millisecond):
	}

	conn.Close()

	select {
	case <-eofDetected:
	case <-time.After(2 * time.Second):
		t.Fatalf("real disconnect after a too-long line was never detected -- the read loop is permanently deaf")
	}
}

func TestControlChannel_AcceptOnceTimesOutIfNoClientConnects(t *testing.T) {
	socketPath := filepath.Join(shortSocketDir(t), "control.sock")
	cc, err := NewControlChannel(socketPath)
	if err != nil {
		t.Fatalf("NewControlChannel: %v", err)
	}
	defer cc.Close()

	start := time.Now()
	err = cc.AcceptOnce(200 * time.Millisecond)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatalf("expected AcceptOnce to time out, got nil error")
	}
	if elapsed > 2*time.Second {
		t.Fatalf("AcceptOnce took %v to time out, expected close to the 200ms bound", elapsed)
	}
}
