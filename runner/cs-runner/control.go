package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"strings"
	"sync"
	"time"
)

// maxControlLineBytes bounds a single NDJSON line: generous enough for any
// real stdout/stderr chunk or control message, small enough that a
// malformed or hostile peer cannot grow the runner's memory without limit.
const maxControlLineBytes = 16 * 1024 * 1024

// ControlChannel is the runner's side of the per-Attempt Unix domain socket
// control channel: the runner is the server, the daemon connects as the one
// client. Framing is NDJSON (one JSON object per line), per
// docs/protocols/runner.md.
type ControlChannel struct {
	listener net.Listener
	mu       sync.Mutex
	conn     net.Conn
}

func NewControlChannel(socketPath string) (*ControlChannel, error) {
	os.Remove(socketPath)
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return nil, fmt.Errorf("listen on control socket %s: %w", socketPath, err)
	}
	_ = os.Chmod(socketPath, 0o600)
	return &ControlChannel{listener: listener}, nil
}

func (c *ControlChannel) AcceptOnce(timeout time.Duration) error {
	type result struct {
		conn net.Conn
		err  error
	}
	resultCh := make(chan result, 1)

	go func() {
		conn, err := c.listener.Accept()
		resultCh <- result{conn, err}
	}()

	select {
	case r := <-resultCh:
		if r.err != nil {
			return fmt.Errorf("accept control connection: %w", r.err)
		}
		c.mu.Lock()
		c.conn = r.conn
		c.mu.Unlock()
		return nil
	case <-time.After(timeout):
		return fmt.Errorf("no client connected to control socket within %v", timeout)
	}
}

// AcceptAuthenticated accepts clients until one presents the expected
// control token as its first NDJSON frame. A thief that connects first
// without the token is dropped; the channel stays open for the real daemon.
func (c *ControlChannel) AcceptAuthenticated(token string, timeout time.Duration) error {
	if token == "" {
		return fmt.Errorf("control token must not be empty")
	}
	deadline := time.Now().Add(timeout)
	for {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return fmt.Errorf("no authenticated client connected to control socket within %v", timeout)
		}
		if err := c.AcceptOnce(remaining); err != nil {
			return err
		}
		if err := c.authenticate(token, 2*time.Second); err != nil {
			c.closeConn()
			continue
		}
		return nil
	}
}

func (c *ControlChannel) authenticate(token string, timeout time.Duration) error {
	c.mu.Lock()
	conn := c.conn
	c.mu.Unlock()
	if conn == nil {
		return fmt.Errorf("no client connected")
	}
	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	defer conn.SetReadDeadline(time.Time{})

	reader := bufio.NewReaderSize(conn, 64*1024)
	line, err := readBoundedLine(reader, 4096)
	if err != nil {
		return fmt.Errorf("read auth frame: %w", err)
	}
	var msg map[string]any
	if json.Unmarshal([]byte(strings.TrimSpace(line)), &msg) != nil {
		return fmt.Errorf("auth frame is not json")
	}
	if msg["type"] != "auth" {
		return fmt.Errorf("first frame must be auth, got %v", msg["type"])
	}
	got, _ := msg["token"].(string)
	if !tokensEqual(token, got) {
		return fmt.Errorf("control token mismatch")
	}
	return nil
}

func (c *ControlChannel) closeConn() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn != nil {
		c.conn.Close()
		c.conn = nil
	}
}

func tokensEqual(expected, got string) bool {
	if len(expected) != len(got) {
		return false
	}
	var acc byte
	for i := 0; i < len(expected); i++ {
		acc |= expected[i] ^ got[i]
	}
	return acc == 0
}

// Send marshals and writes msg as one NDJSON line. The mutex is held across
// the entire write, not just the conn field read: the main goroutine
// (runner_started/harness_exited/termination_complete) and the ReadLoop
// goroutine (pong) can both call Send concurrently, and releasing the lock
// before the write would let their writes interleave mid-syscall and
// corrupt NDJSON framing on the wire.
func (c *ControlChannel) Send(msg map[string]any) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("marshal control message: %w", err)
	}
	data = append(data, '\n')

	c.mu.Lock()
	defer c.mu.Unlock()

	if c.conn == nil {
		return fmt.Errorf("no client connected")
	}

	_, err = c.conn.Write(data)
	return err
}

// ReadLoop reads NDJSON lines from the connected client until EOF or an
// error, invoking onMessage per line and onEOF exactly once when the
// connection ends. This is the mechanism that detects "the daemon is gone":
// a kill -9 of the daemon process closes every file descriptor it held,
// including its end of this socket connection, which surfaces here as an
// ordinary read EOF -- no daemon-side cooperation is required.
func (c *ControlChannel) ReadLoop(onMessage func(map[string]any), onEOF func()) {
	c.mu.Lock()
	conn := c.conn
	c.mu.Unlock()

	if conn == nil {
		onEOF()
		return
	}

	// readBoundedLine bounds memory per line (unlike an unbounded
	// bufio.Reader.ReadString) without ever making the read loop itself
	// unusable the way bufio.Scanner does: once Scan() returns false due to
	// an error (e.g. a too-long line), that Scanner can never be resumed, so
	// treating a too-long line as anything other than "stop reading forever"
	// would be a lie. A too-long line here is instead skipped (resynced to
	// the next '\n') and reading continues -- the control channel must stay
	// alive through one malformed frame, since giving up on it is exactly as
	// bad as the daemon actually dying: onEOF only fires for a genuine read
	// error (real disconnect), never for errLineTooLong.
	reader := bufio.NewReaderSize(conn, 64*1024)
	for {
		line, err := readBoundedLine(reader, maxControlLineBytes)
		if errors.Is(err, errLineTooLong) {
			continue
		}
		if trimmed := strings.TrimSpace(line); trimmed != "" {
			var msg map[string]any
			if jsonErr := json.Unmarshal([]byte(trimmed), &msg); jsonErr == nil {
				onMessage(msg)
			}
		}
		if err != nil {
			break
		}
	}

	onEOF()
}

var errLineTooLong = errors.New("control channel line exceeds the maximum size")

// readBoundedLine reads one '\n'-terminated line, bounded to max bytes. A
// line exceeding max is fully drained up to and including its terminating
// '\n' (so the stream stays correctly framed for the next line) and
// reported as errLineTooLong instead of being returned -- the caller
// decides to skip it and keep reading, never to stop reading altogether.
func readBoundedLine(r *bufio.Reader, max int) (string, error) {
	var buf []byte
	tooLong := false

	for {
		chunk, err := r.ReadSlice('\n')
		if len(chunk) > 0 && !tooLong {
			if len(buf)+len(chunk) > max {
				tooLong = true
				buf = nil
			} else {
				buf = append(buf, chunk...)
			}
		}

		if err == nil {
			if tooLong {
				return "", errLineTooLong
			}
			return string(buf), nil
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		return "", err
	}
}

func (c *ControlChannel) Close() error {
	c.mu.Lock()
	conn := c.conn
	c.mu.Unlock()

	if conn != nil {
		conn.Close()
	}
	return c.listener.Close()
}
