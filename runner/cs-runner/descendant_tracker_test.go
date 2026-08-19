package main

import (
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

	pids := tracker.Stop()
	found := false
	for _, pid := range pids {
		if pid == childPID {
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
		pids := tracker.Stop()
		if len(pids) != 0 {
			t.Fatalf("startDescendantTracker(%d, ...) tracked %d pids, expected the degenerate root to be ignored entirely", root, len(pids))
		}
	}
}
