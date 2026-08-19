package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"sync"
	"time"
)

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

	scanner := bufio.NewScanner(conn)
	for scanner.Scan() {
		var msg map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
			continue
		}
		onMessage(msg)
	}

	onEOF()
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
