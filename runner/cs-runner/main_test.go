package main

import (
	"io"
	"net"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func dialControlSocketWithRetry(t *testing.T, path string, timeout time.Duration) net.Conn {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		conn, err := net.DialTimeout("unix", path, 200*time.Millisecond)
		if err == nil {
			return conn
		}
		if time.Now().After(deadline) {
			t.Fatalf("never connected to control socket %s: %v", path, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// TestRun_NaturalHarnessExitReapsSurvivingGroupMembers proves that when the
// harness's own process exits on its own (not via the termination sequence),
// run() still verifies the full process group is empty -- reaping any
// grandchildren the harness backgrounded and left behind -- before writing
// dead_verified, rather than trusting Cmd.Wait() returning as proof the
// group is clear.
func TestRun_NaturalHarnessExitReapsSurvivingGroupMembers(t *testing.T) {
	dir := shortSocketDir(t)
	manifestPath := filepath.Join(dir, "manifest.json")
	controlSocketPath := filepath.Join(dir, "control.sock")

	runErrCh := make(chan error, 1)
	go func() {
		runErrCh <- run("attempt-1", "mission-1", "fence-1", manifestPath, controlSocketPath,
			[]string{"sh", "-c", "(sleep 30 &); exit 0"})
	}()

	conn := dialControlSocketWithRetry(t, controlSocketPath, 3*time.Second)
	defer conn.Close()
	go io.Copy(io.Discard, conn)

	select {
	case err := <-runErrCh:
		if err != nil {
			t.Fatalf("run: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatalf("run() never returned")
	}

	m, err := ReadManifest(manifestPath)
	if err != nil {
		t.Fatalf("ReadManifest: %v", err)
	}
	if m.State != StateDeadVerified {
		t.Fatalf("expected dead_verified after reaping surviving group members, got %s (pgid %d)", m.State, m.PGID)
	}
	if err := syscall.Kill(-m.PGID, 0); err != syscall.ESRCH {
		t.Fatalf("process group %d still has a surviving member after run() reported %s (kill err=%v)", m.PGID, m.State, err)
	}
}

// TestRun_UnverifiableTerminationWritesDeadUnverified proves the
// dead_unverified path is real and reachable through the full run()
// lifecycle, not just theoretical: when the process group's post-signal
// liveness cannot be determined (simulated via the checkProcessGroupFn/
// sendSignal seams, since a real EPERM/unkillable-process case needs
// privileges or timing this test cannot assume), run() must write
// dead_unverified rather than assume success.
func TestRun_UnverifiableTerminationWritesDeadUnverified(t *testing.T) {
	origCheck := checkProcessGroupFn
	origSignal := sendSignal
	t.Cleanup(func() {
		checkProcessGroupFn = origCheck
		sendSignal = origSignal
	})

	dir := shortSocketDir(t)
	manifestPath := filepath.Join(dir, "manifest.json")
	controlSocketPath := filepath.Join(dir, "control.sock")

	runErrCh := make(chan error, 1)
	go func() {
		runErrCh <- run("attempt-2", "mission-2", "fence-2", manifestPath, controlSocketPath,
			[]string{"sleep", "30"})
	}()

	conn := dialControlSocketWithRetry(t, controlSocketPath, 3*time.Second)
	defer conn.Close()
	go io.Copy(io.Discard, conn)

	// Only start faking liveness once the harness is genuinely running and
	// its real pgid is known, so the SIGKILL cleanup below targets the real
	// process rather than a stale/guessed pgid.
	m, err := ReadManifest(manifestPath)
	deadline := time.Now().Add(3 * time.Second)
	for err == nil && m.State != StateRunning && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
		m, err = ReadManifest(manifestPath)
	}
	if err != nil || m.State != StateRunning {
		t.Fatalf("harness never reached running state: manifest=%+v err=%v", m, err)
	}
	realPGID := m.PGID

	sendSignal = func(pid int, sig syscall.Signal) error { return nil }
	checkProcessGroupFn = func(pgid int) processGroupState { return groupUnknown }

	if _, err := conn.Write([]byte(`{"type":"cancel"}` + "\n")); err != nil {
		t.Fatalf("send cancel: %v", err)
	}

	select {
	case err := <-runErrCh:
		if err != nil {
			t.Fatalf("run: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatalf("run() never returned")
	}

	final, err := ReadManifest(manifestPath)
	if err != nil {
		t.Fatalf("ReadManifest: %v", err)
	}
	if final.State != StateDeadUnverified {
		t.Fatalf("expected dead_unverified when the process group's liveness cannot be verified, got %s", final.State)
	}

	checkProcessGroupFn = origCheck
	sendSignal = origSignal
	syscall.Kill(-realPGID, syscall.SIGKILL)
}

// TestRun_ControlSocketBindFailureTerminatesAlreadySpawnedHarness proves that
// when NewControlChannel fails after the harness has already been spawned
// (here, a control-socket path long enough to exceed sockaddr_un.sun_path),
// run() still terminates the already-running harness and writes a terminal
// manifest state, rather than abandoning a live process group with the
// manifest stuck at "running".
func TestRun_ControlSocketBindFailureTerminatesAlreadySpawnedHarness(t *testing.T) {
	shortDir := shortSocketDir(t)
	manifestPath := filepath.Join(shortDir, "manifest.json")
	longControlSocketPath := filepath.Join(t.TempDir(), "control.sock")

	err := run("attempt-3", "mission-3", "fence-3", manifestPath, longControlSocketPath, []string{"sleep", "30"})
	if err == nil {
		t.Fatalf("expected run() to return an error for an unbindable control socket path")
	}

	m, readErr := ReadManifest(manifestPath)
	if readErr != nil {
		t.Fatalf("ReadManifest: %v", readErr)
	}
	if m.State != StateDeadVerified && m.State != StateDeadUnverified {
		t.Fatalf("expected a terminal manifest state after control-channel setup failure, got %s", m.State)
	}
	if err := syscall.Kill(-m.PGID, 0); err != syscall.ESRCH {
		t.Fatalf("harness process group %d was left running after control-channel setup failure (kill err=%v)", m.PGID, err)
	}
}

// TestRun_AcceptTimeoutTerminatesAlreadySpawnedHarness proves the same
// invariant as above for the other post-spawn failure path: no daemon ever
// connects to accept the control channel within its bound. Uses
// runWithAcceptTimeout to keep the test fast rather than waiting out the
// real 30s production timeout.
func TestRun_AcceptTimeoutTerminatesAlreadySpawnedHarness(t *testing.T) {
	dir := shortSocketDir(t)
	manifestPath := filepath.Join(dir, "manifest.json")
	controlSocketPath := filepath.Join(dir, "control.sock")

	err := runWithAcceptTimeout("attempt-4", "mission-4", "fence-4", manifestPath, controlSocketPath,
		[]string{"sleep", "30"}, 200*time.Millisecond)
	if err == nil {
		t.Fatalf("expected run() to return an error when no daemon ever connects")
	}

	m, readErr := ReadManifest(manifestPath)
	if readErr != nil {
		t.Fatalf("ReadManifest: %v", readErr)
	}
	if m.State != StateDeadVerified && m.State != StateDeadUnverified {
		t.Fatalf("expected a terminal manifest state after an accept timeout, got %s", m.State)
	}
	if err := syscall.Kill(-m.PGID, 0); err != syscall.ESRCH {
		t.Fatalf("harness process group %d was left running after an accept timeout (kill err=%v)", m.PGID, err)
	}
}
