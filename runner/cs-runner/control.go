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

func (c *ControlChannel) Send(msg map[string]any) error {
	c.mu.Lock()
	conn := c.conn
	c.mu.Unlock()

	if conn == nil {
		return fmt.Errorf("no client connected")
	}

	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("marshal control message: %w", err)
	}

	_, err = conn.Write(append(data, '\n'))
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
