package main

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// slowConn is a net.Conn stand-in whose Write splits its payload into two
// chunks with a deliberate delay between them, widening the interleaving
// window deterministically -- a real Unix domain socket's Write on this
// platform turns out to already be atomic against concurrent writers at
// the sizes practical for a test (verified empirically before writing
// this), so a real-socket test alone cannot reliably distinguish
// Send holding its lock across the whole write from releasing it early.
type slowConn struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (s *slowConn) Write(p []byte) (int, error) {
	mid := len(p) / 2
	s.mu.Lock()
	s.buf.Write(p[:mid])
	s.mu.Unlock()

	time.Sleep(20 * time.Millisecond)

	s.mu.Lock()
	s.buf.Write(p[mid:])
	s.mu.Unlock()

	return len(p), nil
}

func (s *slowConn) Read([]byte) (int, error)         { return 0, fmt.Errorf("slowConn: read unsupported") }
func (s *slowConn) Close() error                     { return nil }
func (s *slowConn) LocalAddr() net.Addr              { return nil }
func (s *slowConn) RemoteAddr() net.Addr             { return nil }
func (s *slowConn) SetDeadline(time.Time) error      { return nil }
func (s *slowConn) SetReadDeadline(time.Time) error  { return nil }
func (s *slowConn) SetWriteDeadline(time.Time) error { return nil }

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

// TestControlChannel_SendSerializesAcrossTheWholeWrite proves Send holds
// its lock across the entire write, not just the conn field read, using a
// deliberately slow net.Conn stand-in to force a real interleaving window
// deterministically -- two concurrent Send calls must never produce a
// corrupted/interleaved byte stream, mirroring the real hazard of the main
// goroutine (runner_started/harness_exited/termination_complete) and the
// ReadLoop goroutine (pong) both calling Send at once.
func TestControlChannel_SendSerializesAcrossTheWholeWrite(t *testing.T) {
	fake := &slowConn{}
	cc := &ControlChannel{conn: fake}

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		cc.Send(map[string]any{"type": "pong", "marker": strings.Repeat("A", 2000)})
	}()
	go func() {
		defer wg.Done()
		cc.Send(map[string]any{"type": "pong", "marker": strings.Repeat("B", 2000)})
	}()
	wg.Wait()

	fake.mu.Lock()
	data := fake.buf.Bytes()
	fake.mu.Unlock()

	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("expected exactly 2 complete lines from 2 serialized sends, got %d (interleaved write): %q", len(lines), data)
	}
	for i, line := range lines {
		var msg map[string]any
		if err := json.Unmarshal([]byte(line), &msg); err != nil {
			t.Fatalf("line %d is not valid complete JSON (interleaved write): %q: %v", i, line, err)
		}
	}
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

func TestControlChannel_RejectsUnauthenticatedFirstClient(t *testing.T) {
	socketPath := filepath.Join(shortSocketDir(t), "control.sock")
	cc, err := NewControlChannel(socketPath)
	if err != nil {
		t.Fatalf("NewControlChannel: %v", err)
	}
	defer cc.Close()

	identity := secureTestIdentity()
	bootstrap := secureTestBootstrap(identity)
	runner := secureTestRunner(identity)
	acceptErrCh := make(chan error, 1)
	go func() { acceptErrCh <- cc.AcceptHandshake(bootstrap, runner, 3*time.Second) }()

	thief, err := net.DialTimeout("unix", socketPath, 2*time.Second)
	if err != nil {
		t.Fatalf("thief dial: %v", err)
	}
	if _, err := thief.Write([]byte(`{"type":"unsupported"}` + "\n")); err != nil {
		t.Fatalf("thief write: %v", err)
	}

	buf := make([]byte, 8)
	thief.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, _ = thief.Read(buf)
	thief.Close()

	daemon, err := net.DialTimeout("unix", socketPath, 2*time.Second)
	if err != nil {
		t.Fatalf("daemon dial: %v", err)
	}
	defer daemon.Close()
	performSecureTestClient(t, daemon, bootstrap, runner)

	if err := <-acceptErrCh; err != nil {
		t.Fatalf("AcceptHandshake: %v", err)
	}

	if err := cc.Send(map[string]any{"type": "runner_started"}); err != nil {
		t.Fatalf("Send: %v", err)
	}
	line, err := bufio.NewReader(daemon).ReadString('\n')
	if err != nil {
		t.Fatalf("daemon read: %v", err)
	}
	if !strings.Contains(line, "runner_started") {
		t.Fatalf("daemon did not receive runner_started: %q", line)
	}
}

func TestControlChannel_AuthPreservesFollowingFrame(t *testing.T) {
	socketPath := filepath.Join(shortSocketDir(t), "control.sock")
	cc, err := NewControlChannel(socketPath)
	if err != nil {
		t.Fatalf("NewControlChannel: %v", err)
	}
	defer cc.Close()

	identity := secureTestIdentity()
	bootstrap := secureTestBootstrap(identity)
	runner := secureTestRunner(identity)
	acceptErrCh := make(chan error, 1)
	go func() { acceptErrCh <- cc.AcceptHandshake(bootstrap, runner, 3*time.Second) }()

	conn, err := net.DialTimeout("unix", socketPath, 2*time.Second)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	performSecureTestClient(t, conn, bootstrap, runner)
	if err := <-acceptErrCh; err != nil {
		t.Fatalf("AcceptHandshake: %v", err)
	}
	secret, _ := hex.DecodeString(bootstrap.SecretHex)
	writeSecureTestMessage(t, conn, frameMessage(identity, 1, map[string]any{"type": "cancel"}, secret))

	received := make(chan map[string]any, 1)
	go cc.ReadLoop(func(msg map[string]any) { received <- msg }, func() {})

	select {
	case msg := <-received:
		if msg["type"] != "cancel" {
			t.Fatalf("unexpected frame: %+v", msg)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("frame following auth was not delivered")
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

// TestControlChannel_ConcurrentSendsNeverInterleaveOnTheWire proves Send
// serializes concurrent callers across the entire write, not just the conn
// field read -- two goroutines (mirroring the real main-goroutine vs.
// ReadLoop-goroutine pong sender) writing large-ish payloads at the same
// time must never interleave mid-syscall and corrupt NDJSON framing on the
// wire.
func TestControlChannel_ConcurrentSendsNeverInterleaveOnTheWire(t *testing.T) {
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

	const perGoroutine = 20
	const goroutines = 4
	const total = goroutines * perGoroutine
	// This is a real-world smoke/regression test, not the primary proof of
	// serialization: measured directly, a real Unix domain socket's Write
	// on this platform stays atomic against concurrent writers even at
	// these sizes (and larger, up to at least several MB), because Go's
	// runtime already serializes concurrent Write calls on the same fd
	// internally. That means this test alone cannot distinguish Send
	// holding its lock across the whole write from releasing it early --
	// TestControlChannel_SendSerializesAcrossTheWholeWrite (the slowConn
	// test above) is the test that actually forces and proves the
	// distinction. This test still exercises the real, large-payload path
	// end to end under load.
	const payloadSize = 500_000

	// The reader must drain concurrently with the writers, not after
	// wg.Wait(): the total payload volume here comfortably exceeds a Unix
	// domain socket's send buffer, so waiting for all sends to finish
	// before reading anything would deadlock every writer on a full
	// buffer -- an artifact of this test's own design, unrelated to
	// whatever Send itself does or doesn't serialize.
	conn.SetReadDeadline(time.Now().Add(30 * time.Second))
	reader := bufio.NewReader(conn)
	readErrCh := make(chan error, 1)
	go func() {
		for i := 0; i < total; i++ {
			line, err := reader.ReadString('\n')
			if err != nil {
				readErrCh <- fmt.Errorf("reading line %d: %w", i, err)
				return
			}
			var msg map[string]any
			if err := json.Unmarshal([]byte(line), &msg); err != nil {
				readErrCh <- fmt.Errorf("line %d is not valid complete JSON (interleaved write): %q: %w", i, line, err)
				return
			}
			if msg["type"] != "pong" {
				readErrCh <- fmt.Errorf("line %d has unexpected content, framing likely corrupted: %+v", i, msg)
				return
			}
			g, ok := msg["goroutine"].(float64)
			if !ok {
				readErrCh <- fmt.Errorf("line %d has no goroutine field: %+v", i, msg)
				return
			}
			payload, _ := msg["payload"].(string)
			marker := fmt.Sprintf("g%d", int(g))
			if len(payload) != payloadSize || strings.Count(payload, marker)*len(marker) != len(payload) {
				readErrCh <- fmt.Errorf("line %d payload is not homogeneous marker %q (len=%d, want=%d) -- bytes from a different concurrent Send leaked in", i, marker, len(payload), payloadSize)
				return
			}
		}
		readErrCh <- nil
	}()

	var wg sync.WaitGroup
	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			marker := fmt.Sprintf("g%d", g)
			payload := strings.Repeat(marker, payloadSize/len(marker))
			for i := 0; i < perGoroutine; i++ {
				cc.Send(map[string]any{"type": "pong", "goroutine": g, "seq": i, "payload": payload})
			}
		}(g)
	}
	wg.Wait()

	if err := <-readErrCh; err != nil {
		t.Fatal(err)
	}
}
