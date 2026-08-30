package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const maxControlLineBytes = v0FrameBytes

// ControlChannel is the runner's side of the per-Attempt Unix domain socket
// control channel: the runner is the server, the daemon connects as the one
// client. Framing is NDJSON (one JSON object per line), per
// docs/protocols/runner.md.
type ControlChannel struct {
	listener      net.Listener
	mu            sync.Mutex
	conn          net.Conn
	reader        *bufio.Reader
	socketPath    string
	socketInfo    fs.FileInfo
	secret        []byte
	identity      InvocationIdentity
	authenticated bool
	sendSeq       uint64
	recvSeq       uint64
}

func NewControlChannel(socketPath string) (*ControlChannel, error) {
	if err := validateSocketPath(socketPath); err != nil {
		return nil, err
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return nil, fmt.Errorf("listen on control socket %s: %w", socketPath, err)
	}
	if err := os.Chmod(socketPath, 0o600); err != nil {
		_ = listener.Close()
		return nil, fmt.Errorf("secure control socket %s: %w", socketPath, err)
	}
	socketInfo, err := os.Lstat(socketPath)
	if err != nil {
		_ = listener.Close()
		return nil, fmt.Errorf("stat control socket %s: %w", socketPath, err)
	}
	return &ControlChannel{listener: listener, socketPath: socketPath, socketInfo: socketInfo}, nil
}

func (c *ControlChannel) AcceptOnce(timeout time.Duration) error {
	if err := setListenerDeadline(c.listener, time.Now().Add(timeout)); err != nil {
		return fmt.Errorf("set control accept deadline: %w", err)
	}
	conn, err := c.listener.Accept()
	_ = setListenerDeadline(c.listener, time.Time{})
	if err != nil {
		return fmt.Errorf("accept control connection: %w", err)
	}
	c.mu.Lock()
	c.conn = conn
	c.mu.Unlock()
	return nil
}

func (c *ControlChannel) AcceptHandshake(bootstrap Bootstrap, runner RunnerIdentity, timeout time.Duration) error {
	secret, err := bootstrap.secret()
	if err != nil {
		return err
	}
	if err := bootstrap.Identity.validate(); err != nil {
		return err
	}
	if !runner.InvocationIdentity.equal(bootstrap.Identity) {
		return errors.New("runner identity does not match bootstrap identity")
	}
	if runner.RunnerPID <= 1 || runner.PGID <= 1 || runner.ManifestDigest == "" || runner.RunnerExecutableSHA256 == "" {
		return errors.New("runner identity is incomplete")
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
		reader, err := c.authenticateHandshake(bootstrap, runner, secret, 2*time.Second)
		if err != nil {
			c.closeConn()
			continue
		}
		c.mu.Lock()
		c.reader = reader
		c.secret = append([]byte(nil), secret...)
		c.identity = bootstrap.Identity
		c.authenticated = true
		c.sendSeq = 0
		c.recvSeq = 0
		c.mu.Unlock()
		return nil
	}
}

func (c *ControlChannel) authenticateHandshake(bootstrap Bootstrap, runner RunnerIdentity, secret []byte, timeout time.Duration) (*bufio.Reader, error) {
	c.mu.Lock()
	conn := c.conn
	c.mu.Unlock()
	if conn == nil {
		return nil, fmt.Errorf("no client connected")
	}
	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	defer conn.SetReadDeadline(time.Time{})

	reader := bufio.NewReaderSize(conn, 64*1024)
	line, err := readBoundedLine(reader, maxHandshakeFrameBytes)
	if err != nil {
		return nil, fmt.Errorf("read daemon challenge: %w", err)
	}
	msg, err := decodeMessage(line)
	if err != nil {
		return nil, fmt.Errorf("decode daemon challenge: %w", err)
	}
	if msg["type"] != "daemon_challenge" {
		return nil, fmt.Errorf("first frame must be daemon_challenge, got %v", msg["type"])
	}
	identity, err := decodeHandshakeIdentity(msg)
	if err != nil || !identity.equal(bootstrap.Identity) {
		return nil, errors.New("daemon challenge identity mismatch")
	}
	if msg["runner_pid"] != float64(0) || msg["pgid"] != float64(0) || msg["manifest_digest"] != "" {
		return nil, errors.New("daemon challenge contains runner identity")
	}
	if expected := stringField(msg, "runner_executable_sha256"); bootstrap.ExpectedRunnerExecutableSHA256 != "" && expected != bootstrap.ExpectedRunnerExecutableSHA256 {
		return nil, errors.New("daemon challenge executable mismatch")
	}
	daemonNonce := stringField(msg, "daemon_nonce")
	if daemonNonce == "" || stringField(msg, "runner_nonce") != "" || verifyMAC(msg, secret) != nil {
		return nil, errors.New("invalid daemon challenge authentication")
	}
	runnerNonce := randomNonce()
	hello := handshakeMessage("runner_hello", bootstrap.Identity, runner, daemonNonce, runnerNonce, secret)
	if err := writeMessage(conn, hello); err != nil {
		return nil, fmt.Errorf("send runner handshake: %w", err)
	}
	ackLine, err := readBoundedLine(reader, maxHandshakeFrameBytes)
	if err != nil {
		return nil, fmt.Errorf("read daemon handshake acknowledgement: %w", err)
	}
	ack, err := decodeMessage(ackLine)
	if err != nil || ack["type"] != "daemon_ack" || verifyMAC(ack, secret) != nil {
		return nil, errors.New("invalid daemon handshake acknowledgement")
	}
	ackRunner, err := decodeRunnerIdentity(ack)
	if err != nil || !ackRunner.equal(runner) || stringField(ack, "daemon_nonce") != daemonNonce || stringField(ack, "runner_nonce") != runnerNonce {
		return nil, errors.New("daemon handshake acknowledgement identity mismatch")
	}
	return reader, nil
}

func (c *ControlChannel) closeConn() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn != nil {
		c.conn.Close()
		c.conn = nil
	}
	c.reader = nil
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

func (c *ControlChannel) SendFrame(msg map[string]any) error {
	if err := validateRunnerFrameSchema(msg); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.authenticated || c.conn == nil {
		return errors.New("control channel is not authenticated")
	}
	c.sendSeq++
	frame := frameMessage(c.identity, c.sendSeq, msg, c.secret)
	if err := c.conn.SetWriteDeadline(time.Now().Add(streamWriteTimeout)); err != nil {
		c.sendSeq--
		return fmt.Errorf("set control write deadline: %w", err)
	}
	defer c.conn.SetWriteDeadline(time.Time{})
	if err := writeMessage(c.conn, frame); err != nil {
		c.sendSeq--
		return err
	}
	return nil
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
	reader := c.reader
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
	if reader == nil {
		reader = bufio.NewReaderSize(conn, 64*1024)
	}
	for {
		line, err := readBoundedLine(reader, maxControlLineBytes)
		if errors.Is(err, errLineTooLong) {
			continue
		}
		if trimmed := strings.TrimSpace(line); trimmed != "" {
			msg, jsonErr := decodeMessage(trimmed)
			if jsonErr == nil {
				if c.isAuthenticated() {
					if verifyErr := c.verifyFrame(msg); verifyErr != nil {
						continue
					}
				}
				onMessage(msg)
			}
		}
		if err != nil {
			break
		}
	}

	onEOF()
}

func (c *ControlChannel) isAuthenticated() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.authenticated
}

func (c *ControlChannel) verifyFrame(message map[string]any) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.authenticated {
		return errors.New("control channel is not authenticated")
	}
	identity, err := decodeHandshakeIdentity(message)
	if err != nil || !identity.equal(c.identity) {
		return errors.New("control frame identity mismatch")
	}
	if token := stringField(message, "fencing_token"); token != c.identity.FencingGeneration {
		return errors.New("control frame fencing mismatch")
	}
	if !allowedDaemonFrame(stringField(message, "type")) {
		return errors.New("unsupported daemon control frame")
	}
	if err := validateDaemonFrameSchema(message); err != nil {
		return err
	}
	seq, err := sequenceField(message)
	if err != nil || seq != c.recvSeq+1 {
		return errors.New("control frame sequence mismatch")
	}
	if err := verifyMAC(message, c.secret); err != nil {
		return err
	}
	c.recvSeq = seq
	return nil
}

func allowedDaemonFrame(kind string) bool {
	switch kind {
	case "cancel", "ping", "checkpoint_request":
		return true
	default:
		return false
	}
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
	listener := c.listener
	c.reader = nil
	c.conn = nil
	c.listener = nil
	c.mu.Unlock()

	if conn != nil {
		_ = conn.Close()
	}
	if listener != nil {
		_ = listener.Close()
	}
	if c.socketPath != "" && c.socketInfo != nil {
		if current, err := os.Lstat(c.socketPath); err == nil && os.SameFile(c.socketInfo, current) {
			return os.Remove(c.socketPath)
		}
	}
	return nil
}

func setListenerDeadline(listener net.Listener, deadline time.Time) error {
	withDeadline, ok := listener.(interface{ SetDeadline(time.Time) error })
	if !ok {
		return errors.New("control listener does not support deadlines")
	}
	return withDeadline.SetDeadline(deadline)
}

func validateSocketPath(socketPath string) error {
	if socketPath == "" {
		return errors.New("control socket path must not be empty")
	}
	if len(socketPath) >= 104 {
		return fmt.Errorf("control socket path exceeds macOS limit: %d bytes", len(socketPath))
	}
	dirInfo, err := os.Lstat(filepath.Dir(socketPath))
	if err != nil {
		return fmt.Errorf("stat control socket directory: %w", err)
	}
	if dirInfo.Mode()&os.ModeSymlink != 0 || !dirInfo.IsDir() {
		return errors.New("control socket directory is not a real directory")
	}
	if dirInfo.Mode().Perm()&0o077 != 0 {
		return errors.New("control socket directory is not owner-only")
	}
	if info, err := os.Lstat(socketPath); err == nil {
		if info.Mode()&os.ModeSymlink != 0 {
			return errors.New("control socket path is a symlink")
		}
		return errors.New("control socket path already exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect control socket path: %w", err)
	}
	return nil
}

func decodeMessage(line string) (map[string]any, error) {
	if err := validateV0JSONFrame([]byte(line)); err != nil {
		return nil, err
	}
	var message map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(line)), &message); err != nil {
		return nil, err
	}
	if message == nil {
		return nil, errors.New("message must be an object")
	}
	if err := validateV0MessageValue(message, 0); err != nil {
		return nil, err
	}
	return message, nil
}

func writeMessage(conn net.Conn, message map[string]any) error {
	if err := validateV0MessageValue(message, 0); err != nil {
		return err
	}
	data, err := json.Marshal(message)
	if err != nil {
		return err
	}
	if len(data) > v0FrameBytes {
		return errFrameTooLarge
	}
	data = append(data, '\n')
	_, err = conn.Write(data)
	return err
}
