package main

import (
	"bufio"
	"encoding/json"
	"fmt"
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

func waitForManifestState(t *testing.T, manifestPath string, state ManifestState, timeout time.Duration) Manifest {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		m, err := ReadManifest(manifestPath)
		if err == nil && m.State == state {
			return m
		}
		if time.Now().After(deadline) {
			t.Fatalf("manifest %s never reached state %s: last=%+v err=%v", manifestPath, state, m, err)
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

// TestRun_RunningManifestWriteFailureTerminatesAlreadySpawnedHarness proves
// a third post-spawn abandonment path: if writing the "running" manifest
// itself fails (a transient disk/permissions issue), the already-spawned
// harness is still terminated rather than leaked as an unfindable orphan
// (its pgid is known in memory even though the write that would have
// persisted it failed). Simulated via the writeManifestFn seam, since
// reliably forcing a real disk failure on exactly the second write is not
// portable.
func TestRun_RunningManifestWriteFailureTerminatesAlreadySpawnedHarness(t *testing.T) {
	orig := writeManifestFn
	t.Cleanup(func() { writeManifestFn = orig })

	callCount := 0
	writeManifestFn = func(path string, m Manifest) error {
		callCount++
		if callCount == 2 {
			return fmt.Errorf("simulated running-manifest write failure")
		}
		return orig(path, m)
	}

	dir := shortSocketDir(t)
	manifestPath := filepath.Join(dir, "manifest.json")
	controlSocketPath := filepath.Join(dir, "control.sock")

	err := run("attempt-5", "mission-5", "fence-5", manifestPath, controlSocketPath, []string{"sleep", "30"})
	if err == nil {
		t.Fatalf("expected run() to return an error when the running manifest write fails")
	}

	m, readErr := ReadManifest(manifestPath)
	if readErr != nil {
		t.Fatalf("ReadManifest: %v", readErr)
	}
	if m.State != StateDeadVerified && m.State != StateDeadUnverified {
		t.Fatalf("expected a terminal manifest state after a running-manifest write failure, got %s", m.State)
	}
	if m.PGID == 0 {
		t.Fatalf("final manifest has no pgid recorded, cannot verify the harness was cleaned up")
	}
	if err := syscall.Kill(-m.PGID, 0); err != syscall.ESRCH {
		t.Fatalf("harness process group %d was left running after a running-manifest write failure (kill err=%v)", m.PGID, err)
	}
}

// TestRun_ManifestWriteFailureOnTheCancelPathStillTerminatesTheHarness is a
// table-driven proof, across the two writeManifestFn calls in the cancel-
// triggered termination path that occur once a harness is already running
// (3=terminating, 4=final-inside-terminateAndFinalize; calls 1=starting and
// 2=running are covered by their own dedicated tests above, since a failure
// there happens before or without ever reaching this path), that a write
// failure at that call still terminates the already-spawned harness --
// closing the specific gap at the "terminating" write (a fourth abandonment
// path distinct from the three already covered) and guarding against a
// fifth one hiding later in this same sequence.
func TestRun_ManifestWriteFailureOnTheCancelPathStillTerminatesTheHarness(t *testing.T) {
	for _, failAt := range []int{3, 4} {
		t.Run(fmt.Sprintf("failAt=%d", failAt), func(t *testing.T) {
			orig := writeManifestFn
			t.Cleanup(func() { writeManifestFn = orig })

			callCount := 0
			writeManifestFn = func(path string, m Manifest) error {
				callCount++
				if callCount == failAt {
					return fmt.Errorf("simulated write failure at call %d", failAt)
				}
				return orig(path, m)
			}

			dir := shortSocketDir(t)
			manifestPath := filepath.Join(dir, "manifest.json")
			controlSocketPath := filepath.Join(dir, "control.sock")

			runErrCh := make(chan error, 1)
			go func() {
				runErrCh <- run(fmt.Sprintf("attempt-tbl-%d", failAt), "mission-tbl", "fence-tbl",
					manifestPath, controlSocketPath, []string{"sleep", "30"})
			}()

			conn := dialControlSocketWithRetry(t, controlSocketPath, 3*time.Second)
			defer conn.Close()
			go io.Copy(io.Discard, conn)

			waitForManifestState(t, manifestPath, StateRunning, 3*time.Second)
			if _, err := conn.Write([]byte(`{"type":"cancel"}` + "\n")); err != nil {
				t.Fatalf("send cancel: %v", err)
			}

			select {
			case err := <-runErrCh:
				if err == nil {
					t.Fatalf("failAt=%d: expected run() to return an error", failAt)
				}
			case <-time.After(10 * time.Second):
				t.Fatalf("failAt=%d: run() never returned", failAt)
			}

			m, readErr := ReadManifest(manifestPath)
			if readErr != nil {
				t.Fatalf("failAt=%d: ReadManifest: %v", failAt, readErr)
			}
			if m.PGID == 0 {
				t.Fatalf("failAt=%d: final manifest has no pgid recorded, cannot verify cleanup", failAt)
			}
			if err := syscall.Kill(-m.PGID, 0); err != syscall.ESRCH {
				t.Fatalf("failAt=%d: harness process group %d was left running (kill err=%v)", failAt, m.PGID, err)
			}
		})
	}
}

// TestRun_SignaledHarnessExitReportsSignaledTrue proves that a harness
// killed by a signal (as opposed to exiting with its own status code) is
// reported as such -- both in the harness_exited control message and the
// final manifest -- rather than the signaled field being hardcoded false
// and the exit code being an uninformative -1 with no way to tell the two
// cases apart.
func TestRun_SignaledHarnessExitReportsSignaledTrue(t *testing.T) {
	dir := shortSocketDir(t)
	manifestPath := filepath.Join(dir, "manifest.json")
	controlSocketPath := filepath.Join(dir, "control.sock")

	runErrCh := make(chan error, 1)
	go func() {
		runErrCh <- run("attempt-6", "mission-6", "fence-6", manifestPath, controlSocketPath,
			[]string{"sleep", "30"})
	}()

	conn := dialControlSocketWithRetry(t, controlSocketPath, 3*time.Second)
	defer conn.Close()

	reader := bufio.NewReader(conn)
	skipLine(t, reader) // runner_started

	m := waitForManifestState(t, manifestPath, StateRunning, 3*time.Second)
	if err := syscall.Kill(m.HarnessPID, syscall.SIGKILL); err != nil {
		t.Fatalf("kill harness pid %d: %v", m.HarnessPID, err)
	}

	line := readLine(t, reader) // harness_exited
	var msg map[string]any
	if err := json.Unmarshal([]byte(line), &msg); err != nil {
		t.Fatalf("unmarshal %q: %v", line, err)
	}
	if msg["type"] != "harness_exited" {
		t.Fatalf("expected harness_exited, got: %+v", msg)
	}
	if msg["signaled"] != true {
		t.Fatalf("expected signaled=true for a SIGKILL'd harness, got: %+v", msg)
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
	if final.ExitCode == nil {
		t.Fatalf("expected a non-nil exit code recording the signal-terminated exit")
	}
}

func skipLine(t *testing.T, r *bufio.Reader) {
	t.Helper()
	readLine(t, r)
}

func readLine(t *testing.T, r *bufio.Reader) string {
	t.Helper()
	line, err := r.ReadString('\n')
	if err != nil {
		t.Fatalf("read control channel line: %v", err)
	}
	return line
}
