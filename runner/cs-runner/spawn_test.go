package main

import (
	"syscall"
	"testing"
	"time"
)

func TestSpawnHarness_ConfirmsOwnProcessGroupBeforeReturning(t *testing.T) {
	handle, err := SpawnHarness([]string{"sleep", "5"}, 2*time.Second)
	if err != nil {
		t.Fatalf("SpawnHarness: %v", err)
	}
	defer func() {
		syscall.Kill(-handle.PGID, syscall.SIGKILL)
		handle.Cmd.Wait()
	}()

	if handle.PID != handle.Cmd.Process.Pid {
		t.Fatalf("PID mismatch: handle.PID=%d cmd.Process.Pid=%d", handle.PID, handle.Cmd.Process.Pid)
	}

	actualPgid, err := syscall.Getpgid(handle.PID)
	if err != nil {
		t.Fatalf("Getpgid: %v", err)
	}
	if actualPgid != handle.PGID || actualPgid != handle.PID {
		t.Fatalf("SpawnHarness returned before setsid actually took effect: pgid=%d pid=%d actual=%d", handle.PGID, handle.PID, actualPgid)
	}
}

func TestSpawnHarness_ReturnsErrorForNonexistentExecutable(t *testing.T) {
	_, err := SpawnHarness([]string{"/no/such/executable-cs-runner-test"}, 2*time.Second)
	if err == nil {
		t.Fatalf("expected an error for a nonexistent executable")
	}
}

// TestSpawnHarness_TerminatesOrphanedChildWhenConfirmationTimesOut proves
// that if the confirmation window elapses before the child's own setsid()
// is ever observed (a zero-duration window here forces this deterministically
// regardless of real machine speed), the already-started child process is
// still cleaned up rather than left running forever with no handle anyone
// could use to find or kill it.
func TestSpawnHarness_TerminatesOrphanedChildWhenConfirmationTimesOut(t *testing.T) {
	handle, err := SpawnHarness([]string{"sleep", "30"}, 0)
	if err == nil {
		t.Fatalf("expected an error when the confirmation window is zero")
	}
	if handle == nil || handle.PID == 0 {
		t.Fatalf("expected the orphaned child's pid to still be reported for cleanup verification, got handle=%+v", handle)
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if syscall.Kill(handle.PID, 0) == syscall.ESRCH {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("pid %d was left running after SpawnHarness's confirmation timeout", handle.PID)
}
