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
	for _, p := range descendants {
		got[p.PID] = true
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

// TestPSSnapshot_TimesOutRatherThanHangingForever proves a hung `ps` bounds
// psSnapshot's return within psSnapshotTimeout instead of blocking forever
// -- a `ps` that never returns previously hung every caller indefinitely:
// startDescendantTracker's synchronous first poll (blocking the manifest
// write and reaper that must start immediately after spawning a harness)
// and descendantTracker.Stop() (blocking the entire termination path).
func TestPSSnapshot_TimesOutRatherThanHangingForever(t *testing.T) {
	dir := t.TempDir()
	fakePS := filepath.Join(dir, "ps")
	if err := os.WriteFile(fakePS, []byte("#!/bin/sh\nexec /bin/sleep 30\n"), 0o755); err != nil {
		t.Fatalf("write fake ps: %v", err)
	}

	originalPath := os.Getenv("PATH")
	t.Cleanup(func() { os.Setenv("PATH", originalPath) })
	os.Setenv("PATH", dir)

	start := time.Now()
	_, err := psSnapshot()
	elapsed := time.Since(start)

	if err == nil {
		t.Fatalf("expected an error from a ps that never returns")
	}
	if elapsed < psSnapshotTimeout {
		t.Fatalf("psSnapshot returned in %v, before its own %v timeout even elapsed", elapsed, psSnapshotTimeout)
	}
	if elapsed >= 30*time.Second {
		t.Fatalf("psSnapshot took %v, did not respect its bound against a hung ps", elapsed)
	}
}

// TestPSSnapshot_BoundedEvenWhenPSForksAChildThatOutlivesItAndHoldsStdoutOpen
// proves psSnapshotTimeout's bound holds even when `ps` itself exits (or is
// killed) but leaves an orphaned child holding the stdout pipe's write end
// open: a verification-gate round found exec.CommandContext's kill only
// reaches the direct child, so Output() kept blocking on a read that would
// never see EOF until the orphan exited on its own (reproduced as a 61s
// hang in the real runner) -- a bare context, with no WaitDelay, does not
// actually bound this call the way it appears to.
func TestPSSnapshot_BoundedEvenWhenPSForksAChildThatOutlivesItAndHoldsStdoutOpen(t *testing.T) {
	dir := t.TempDir()
	fakePS := filepath.Join(dir, "ps")
	script := "#!/bin/sh\n/bin/sleep 30 &\nexec /bin/sleep 30\n"
	if err := os.WriteFile(fakePS, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake ps: %v", err)
	}

	originalPath := os.Getenv("PATH")
	t.Cleanup(func() { os.Setenv("PATH", originalPath) })
	os.Setenv("PATH", dir)

	start := time.Now()
	_, err := psSnapshot()
	elapsed := time.Since(start)

	if err == nil {
		t.Fatalf("expected an error from a ps whose child never returns")
	}
	bound := psSnapshotTimeout + psWaitDelay + 2*time.Second
	if elapsed >= bound {
		t.Fatalf("psSnapshot took %v, exceeding its bound of %v -- an orphaned child holding stdout open must not be able to extend this indefinitely", elapsed, bound)
	}
}
