package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestStartDetachedRunnerSurvivesBrokerExit(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "child.identity")
	broker := exec.Command(os.Args[0], marker)
	broker.Env = append(os.Environ(), "CS_RUNNER_TEST_HELPER=detached-bootstrap-broker")
	if err := broker.Start(); err != nil {
		t.Fatalf("start broker: %v", err)
	}
	brokerPID := broker.Process.Pid
	if err := broker.Wait(); err != nil {
		t.Fatalf("broker: %v", err)
	}

	waitForFile(t, marker, 3*time.Second)
	fields := strings.Fields(mustReadFile(t, marker))
	if len(fields) != 2 {
		t.Fatalf("child identity = %q", fields)
	}
	childPID, err := strconv.Atoi(fields[0])
	if err != nil {
		t.Fatalf("child pid = %q: %v", fields[0], err)
	}
	if childPID <= 1 || childPID == brokerPID {
		t.Fatalf("child pid = %d, broker pid = %d", childPID, brokerPID)
	}
	if err := syscall.Kill(childPID, 0); err != nil {
		t.Fatalf("detached child is not live after broker exit: %v", err)
	}

	if err := syscall.Kill(childPID, syscall.SIGTERM); err != nil {
		t.Fatalf("stop detached child: %v", err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(childPID, 0); err == syscall.ESRCH {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("detached child %d did not exit after cleanup", childPID)
}

func mustReadFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}
