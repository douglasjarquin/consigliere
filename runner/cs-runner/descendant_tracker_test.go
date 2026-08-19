package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// TestDescendantTracker_AccumulatesAcrossPollsEvenAfterRootExits proves the
// tracker retains a descendant it observed while the root was alive, even
// after the root has since exited and been reaped and the descendant has
// been reparented to init -- a fresh one-shot snapshot taken at that later
// point would find nothing, since the parent-child link is gone by then.
func TestDescendantTracker_AccumulatesAcrossPollsEvenAfterRootExits(t *testing.T) {
	dir := t.TempDir()
	childPidFile := filepath.Join(dir, "child.pid")

	cmd := exec.Command("sh", "-c", `sleep 30 & echo $! > "$0"; sleep 0.1; exit 0`, childPidFile)
	if err := cmd.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}
	rootPID := cmd.Process.Pid
	go cmd.Wait()

	tracker := startDescendantTracker(rootPID, 20*time.Millisecond)

	childPID := waitForPIDFile(t, childPidFile, 2*time.Second)
	t.Cleanup(func() { syscall.Kill(childPID, syscall.SIGKILL) })

	// Give the tracker time to observe the child while root is still (or
	// was very recently) alive, then let root fully exit and get reaped
	// before we stop tracking.
	time.Sleep(200 * time.Millisecond)

	pids, reliable := tracker.Stop()
	if !reliable {
		t.Fatalf("expected reliable=true: ps was available throughout")
	}
	found := false
	for _, p := range pids {
		if p.PID == childPID {
			found = true
		}
	}
	if !found {
		t.Fatalf("tracker.Stop() = %v, missing child %d observed while root was alive, even though root has since exited and the child was reparented", pids, childPID)
	}
}

func TestDescendantTracker_IgnoresADegenerateRoot(t *testing.T) {
	for _, root := range []int{0, 1, -5} {
		tracker := startDescendantTracker(root, 10*time.Millisecond)
		time.Sleep(50 * time.Millisecond)
		pids, reliable := tracker.Stop()
		if !reliable {
			t.Fatalf("startDescendantTracker(%d, ...): expected reliable=true, a degenerate root never even attempts ps", root)
		}
		if len(pids) != 0 {
			t.Fatalf("startDescendantTracker(%d, ...) tracked %d pids, expected the degenerate root to be ignored entirely", root, len(pids))
		}
	}
}

// TestDescendantTracker_ReportsUnreliableAfterAFailedPoll proves a tracker
// that could never enumerate the process tree (ps unreachable, via a
// broken PATH) reports reliable=false rather than silently claiming
// whatever it happened to see (nothing) is everything there was -- a real
// escapee could have come and gone entirely within a failed poll window.
func TestDescendantTracker_ReportsUnreliableAfterAFailedPoll(t *testing.T) {
	originalPath := os.Getenv("PATH")
	t.Cleanup(func() { os.Setenv("PATH", originalPath) })
	os.Setenv("PATH", t.TempDir())

	tracker := startDescendantTracker(os.Getpid(), 10*time.Millisecond)
	time.Sleep(30 * time.Millisecond)

	_, reliable := tracker.Stop()
	if reliable {
		t.Fatalf("expected reliable=false: every poll failed with ps unreachable (broken PATH)")
	}
}

// TestDescendantTracker_StopIsSafeToCallTwice proves Stop() is idempotent
// rather than panicking on a doubly-closed channel: nothing in this
// codebase currently calls it twice, but that invariant should not depend
// solely on call-site discipline.
func TestDescendantTracker_StopIsSafeToCallTwice(t *testing.T) {
	tracker := startDescendantTracker(0, time.Hour)
	firstPIDs, firstReliable := tracker.Stop()
	secondPIDs, secondReliable := tracker.Stop()
	if len(firstPIDs) != len(secondPIDs) || firstReliable != secondReliable {
		t.Fatalf("second Stop() call returned a different result than the first: (%v,%v) vs (%v,%v)", firstPIDs, firstReliable, secondPIDs, secondReliable)
	}
}
