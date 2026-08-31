package client

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestGeneratedMutatingRequestSurvivesProcessRestart(t *testing.T) {
	home, err := os.MkdirTemp("/tmp", "cs-retry-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(home) })
	socket := filepath.Join(home, "api.sock")
	firstRequests, firstDone := startRetryServer(t, socket, 1, false)
	first := runRetryHelper(t, home, socket, "failure")
	if first.exitCode != 0 {
		t.Fatalf("first helper failed: %s", first.String())
	}
	<-firstDone
	firstRequest := <-firstRequests

	secondRequests, secondDone := startRetryServer(t, socket, 1, true)
	second := runRetryHelper(t, home, socket, "success")
	if second.exitCode != 0 {
		t.Fatalf("restart helper failed: %s", second.String())
	}
	<-secondDone
	replayed := <-secondRequests

	if firstRequest["idempotency_key"] != replayed["idempotency_key"] {
		t.Fatalf("idempotency key changed across process restart: first=%v replay=%v", firstRequest["idempotency_key"], replayed["idempotency_key"])
	}
	if firstRequest["canonical_hash"] != replayed["canonical_hash"] {
		t.Fatalf("canonical hash changed across process restart: first=%v replay=%v", firstRequest["canonical_hash"], replayed["canonical_hash"])
	}
	entries, err := os.ReadDir(filepath.Join(home, "requests"))
	if err != nil || len(entries) != 0 {
		t.Fatalf("successful replay left retry state: err=%v entries=%d", err, len(entries))
	}
}

func TestRetryPersistenceHelper(t *testing.T) {
	mode := os.Getenv("CS_RETRY_HELPER")
	if mode == "" {
		return
	}

	dialer := NewDialer(Home{Dir: os.Getenv("CS_HOME")})
	dialer.Socket = os.Getenv("CS_SOCKET")
	dialer.Principal = "boss"
	dialer.Secret = "test-secret"
	dialer.ConnectTimeout = time.Second
	dialer.ReadTimeout = 100 * time.Millisecond
	_, err := dialer.Call("mission.submit", map[string]any{"mission_id": "mission-1"}, "correlation", "")
	if mode == "failure" {
		if err == nil {
			t.Fatal("response-loss helper unexpectedly succeeded")
		}
		return
	}
	if err != nil {
		t.Fatalf("successful retry returned error: %v", err)
	}
}

func runRetryHelper(t *testing.T, home, socket, mode string) retryHelperResult {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=TestRetryPersistenceHelper", "--")
	cmd.Env = append(os.Environ(), "CS_RETRY_HELPER="+mode, "CS_HOME="+home, "CS_SOCKET="+socket)
	output, err := cmd.CombinedOutput()
	if err != nil && mode == "success" {
		t.Fatalf("retry helper execution failed: %v: %s", err, output)
	}
	return retryHelperResult{output: output, exitCode: cmd.ProcessState.ExitCode()}
}

type retryHelperResult struct {
	output   []byte
	exitCode int
}

func (r retryHelperResult) String() string { return string(r.output) }

func startRetryServer(t *testing.T, socket string, requestCount int, respond bool) (<-chan map[string]any, <-chan struct{}) {
	t.Helper()
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	requests := make(chan map[string]any, requestCount)
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer listener.Close()
		defer os.Remove(socket)
		seen := 0
		for seen < requestCount {
			conn, acceptErr := listener.Accept()
			if acceptErr != nil {
				return
			}
			request, readErr := bufio.NewReader(conn).ReadBytes('\n')
			if readErr != nil || len(request) == 0 {
				conn.Close()
				continue
			}
			var decoded map[string]any
			if json.Unmarshal(request, &decoded) != nil {
				conn.Close()
				continue
			}
			requests <- decoded
			seen++
			if respond {
				_, _ = conn.Write([]byte(`{"v":1,"id":"correlation","ok":true,"payload":{}}` + "\n"))
			}
			conn.Close()
		}
	}()
	return requests, done
}
