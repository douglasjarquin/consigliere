package main

import (
	"bufio"
	"encoding/hex"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func secureTestIdentity() InvocationIdentity {
	return InvocationIdentity{
		ProtocolVersion:     controlProtocolVersion,
		InvocationID:        "invocation-1",
		AttemptID:           "attempt-1",
		MissionID:           "mission-1",
		WorkspacePath:       "/tmp/workspace-1",
		WorkspaceGeneration: "workspace-generation-1",
		FencingGeneration:   "fence-1",
	}
}

func secureTestRunner(identity InvocationIdentity) RunnerIdentity {
	return RunnerIdentity{
		InvocationIdentity:      identity,
		RunnerPID:               101,
		PGID:                    101,
		ManifestDigest:          strings.Repeat("a", 64),
		RunnerExecutableSHA256:  strings.Repeat("b", 64),
		HarnessExecutableSHA256: strings.Repeat("c", 64),
	}
}

func secureTestBootstrap(identity InvocationIdentity) Bootstrap {
	return Bootstrap{
		SecretHex:                      hex.EncodeToString([]byte("01234567890123456789012345678901")),
		Identity:                       identity,
		ExpectedRunnerExecutableSHA256: strings.Repeat("b", 64),
	}
}

func performSecureTestClient(t *testing.T, conn net.Conn, bootstrap Bootstrap, runner RunnerIdentity) {
	t.Helper()
	secret, err := hex.DecodeString(bootstrap.SecretHex)
	if err != nil {
		t.Fatalf("decode test secret: %v", err)
	}

	daemonNonce := strings.Repeat("d", 64)
	challenge := handshakeMessage("daemon_challenge", bootstrap.Identity, RunnerIdentity{
		InvocationIdentity:     bootstrap.Identity,
		RunnerExecutableSHA256: bootstrap.ExpectedRunnerExecutableSHA256,
	}, daemonNonce, "", secret)
	writeSecureTestMessage(t, conn, challenge)

	reader := bufio.NewReader(conn)
	hello := readSecureTestMessage(t, reader)
	if hello["type"] != "runner_hello" {
		t.Fatalf("expected runner_hello, got %+v", hello)
	}

	ack := handshakeMessage("daemon_ack", runner.InvocationIdentity, runner, daemonNonce, hello["runner_nonce"].(string), secret)
	writeSecureTestMessage(t, conn, ack)
}

func writeSecureTestMessage(t *testing.T, conn net.Conn, message map[string]any) {
	t.Helper()
	data, err := json.Marshal(message)
	if err != nil {
		t.Fatalf("marshal secure test message: %v", err)
	}
	if _, err := conn.Write(append(data, '\n')); err != nil {
		t.Fatalf("write secure test message: %v", err)
	}
}

func readSecureTestMessage(t *testing.T, reader *bufio.Reader) map[string]any {
	t.Helper()
	line, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("read secure test message: %v", err)
	}
	var message map[string]any
	if err := json.Unmarshal([]byte(line), &message); err != nil {
		t.Fatalf("decode secure test message: %v", err)
	}
	return message
}

func TestNewControlChannelRefusesSymlinkSubstitution(t *testing.T) {
	dir := shortSocketDir(t)
	target := filepath.Join(dir, "target")
	socketPath := filepath.Join(dir, "control.sock")
	if err := os.WriteFile(target, []byte("must survive"), 0o600); err != nil {
		t.Fatalf("write target: %v", err)
	}
	if err := os.Symlink(target, socketPath); err != nil {
		t.Fatalf("create socket symlink: %v", err)
	}

	if _, err := NewControlChannel(socketPath); err == nil {
		t.Fatal("expected a symlink socket path to be rejected")
	}
	if _, err := os.Lstat(socketPath); err != nil {
		t.Fatalf("socket symlink was removed: %v", err)
	}
	if data, err := os.ReadFile(target); err != nil || string(data) != "must survive" {
		t.Fatalf("symlink target changed: data=%q err=%v", data, err)
	}
}

func TestSecureControlChannelRejectsAttackerThenAuthenticates(t *testing.T) {
	dir := shortSocketDir(t)
	socketPath := filepath.Join(dir, "control.sock")
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

	attacker, err := net.DialTimeout("unix", socketPath, time.Second)
	if err != nil {
		t.Fatalf("attacker dial: %v", err)
	}
	if _, err := attacker.Write([]byte(`{"type":"daemon_challenge","invocation_id":"wrong"}` + "\n")); err != nil {
		t.Fatalf("attacker write: %v", err)
	}
	attacker.Close()

	daemon, err := net.DialTimeout("unix", socketPath, time.Second)
	if err != nil {
		t.Fatalf("daemon dial: %v", err)
	}
	defer daemon.Close()
	performSecureTestClient(t, daemon, bootstrap, runner)

	if err := <-acceptErrCh; err != nil {
		t.Fatalf("AcceptHandshake: %v", err)
	}
	if err := cc.SendFrame(map[string]any{"type": "runner_started"}); err != nil {
		t.Fatalf("SendFrame: %v", err)
	}
	started := readSecureTestMessage(t, bufio.NewReader(daemon))
	if started["type"] != "runner_started" || started["seq"] != float64(1) {
		t.Fatalf("unexpected authenticated frame: %+v", started)
	}
}

func TestSecureFrameRejectsReplayAndIdentityMismatch(t *testing.T) {
	identity := secureTestIdentity()
	secret, err := hex.DecodeString(secureTestBootstrap(identity).SecretHex)
	if err != nil {
		t.Fatalf("decode test secret: %v", err)
	}
	cc := &ControlChannel{
		secret:        secret,
		identity:      identity,
		authenticated: true,
		recvSeq:       1,
	}

	replayed := frameMessage(identity, 1, map[string]any{"type": "ping"}, secret)
	if err := cc.verifyFrame(replayed); err == nil {
		t.Fatal("expected replayed sequence to be rejected")
	}

	forgedIdentity := identity
	forgedIdentity.AttemptID = "other-attempt"
	forged := frameMessage(forgedIdentity, 2, map[string]any{"type": "ping"}, secret)
	if err := cc.verifyFrame(forged); err == nil {
		t.Fatal("expected mismatched Attempt identity to be rejected")
	}
	if cc.recvSeq != 1 {
		t.Fatalf("invalid frames advanced receive sequence to %d", cc.recvSeq)
	}
}

func TestSecureControlChannelRejectsOversizedHandshakeBeforeAuthentication(t *testing.T) {
	dir := shortSocketDir(t)
	socketPath := filepath.Join(dir, "control.sock")
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

	attacker, err := net.DialTimeout("unix", socketPath, time.Second)
	if err != nil {
		t.Fatalf("attacker dial: %v", err)
	}
	if _, err := attacker.Write([]byte(strings.Repeat("x", maxHandshakeFrameBytes+1) + "\n")); err != nil {
		t.Fatalf("write oversized handshake: %v", err)
	}
	attacker.Close()

	daemon, err := net.DialTimeout("unix", socketPath, time.Second)
	if err != nil {
		t.Fatalf("daemon dial: %v", err)
	}
	defer daemon.Close()
	performSecureTestClient(t, daemon, bootstrap, runner)

	if err := <-acceptErrCh; err != nil {
		t.Fatalf("AcceptHandshake after oversized frame: %v", err)
	}
}
