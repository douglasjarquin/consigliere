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
