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

func waitForPIDFile(t *testing.T, path string, timeout time.Duration) int {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		data, err := os.ReadFile(path)
		if err == nil {
			if s := strings.TrimSpace(string(data)); s != "" {
				if pid, convErr := strconv.Atoi(s); convErr == nil {
					return pid
				}
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("pid file %s never appeared with valid content", path)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// TestDescendantsOf_FindsTransitiveDescendants proves descendantsOf walks
// the real OS process tree by parent/child pid, not just a process group --
// the mechanism a group-scoped kill(-pgid, ...) can never reach a
// descendant that has called setsid() and left the group entirely.
func TestDescendantsOf_FindsTransitiveDescendants(t *testing.T) {
	dir := t.TempDir()
	childPidFile := filepath.Join(dir, "child.pid")
	grandchildPidFile := filepath.Join(dir, "grandchild.pid")

	outerScript := `sh -c 'sleep 30 & echo $! > "$0"; wait' "$1" &
child=$!
echo $child > "$0"
wait $child
`
	cmd := exec.Command("sh", "-c", outerScript, childPidFile, grandchildPidFile)
	if err := cmd.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}
	rootPID := cmd.Process.Pid
	t.Cleanup(func() {
		syscall.Kill(rootPID, syscall.SIGKILL)
		cmd.Wait()
	})

	childPID := waitForPIDFile(t, childPidFile, 2*time.Second)
	grandchildPID := waitForPIDFile(t, grandchildPidFile, 2*time.Second)
	t.Cleanup(func() {
		syscall.Kill(childPID, syscall.SIGKILL)
		syscall.Kill(grandchildPID, syscall.SIGKILL)
	})

	descendants, err := descendantsOf(rootPID)
	if err != nil {
		t.Fatalf("descendantsOf: %v", err)
	}

	got := map[int]bool{}
	for _, pid := range descendants {
		got[pid] = true
	}
	if !got[childPID] {
		t.Fatalf("descendantsOf(%d) = %v, missing direct child %d", rootPID, descendants, childPID)
	}
	if !got[grandchildPID] {
		t.Fatalf("descendantsOf(%d) = %v, missing transitive grandchild %d", rootPID, descendants, grandchildPID)
	}
}

func TestDescendantsOf_ReturnsEmptyForAPidWithNoChildren(t *testing.T) {
	cmd := exec.Command("sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}
	pid := cmd.Process.Pid
	t.Cleanup(func() {
		syscall.Kill(pid, syscall.SIGKILL)
		cmd.Wait()
	})

	descendants, err := descendantsOf(pid)
	if err != nil {
		t.Fatalf("descendantsOf: %v", err)
	}
	if len(descendants) != 0 {
		t.Fatalf("expected no descendants for a childless process, got %v", descendants)
	}
}
