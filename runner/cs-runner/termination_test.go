package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// waitForFile polls for a file's existence, used to synchronize on a shell
// script having actually executed past a certain point (e.g. having
// installed a trap) rather than guessing with an arbitrary sleep.
func waitForFile(t *testing.T, path string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("ready file %s never appeared within %v", path, timeout)
}

// startGroupedProcess spawns a process with Setsid and waits for the child
// to actually finish calling setsid() (its own pgid becomes its own pid)
// before returning, closing the same startup race a real runner's spawn
// sequence must close: cmd.Start() returns to the parent as soon as fork()
// completes, but the child's own setsid() call happens asynchronously
// afterward, so a signal sent to the intended pgid too early can silently
// miss the child entirely.
func startGroupedProcess(t *testing.T, script string) (pgid int, cmd *exec.Cmd) {
	t.Helper()
	cmd = exec.Command("sh", "-c", script)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start grouped process: %v", err)
	}

	pid := cmd.Process.Pid
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if actualPgid, err := syscall.Getpgid(pid); err == nil && actualPgid == pid {
			return pid, cmd
		}
		time.Sleep(time.Millisecond)
	}

	t.Fatalf("process %d never completed its own setsid() within the timeout", pid)
	return 0, nil
}

func groupHasSurvivors(pgid int) bool {
	err := syscall.Kill(-pgid, 0)
	return err == nil
}

func TestTerminate_CooperativeProcessExitsOnSIGTERM(t *testing.T) {
	pgid, cmd := startGroupedProcess(t, "sleep 30")
	go cmd.Wait()

	verified, err := Terminate(pgid, 2*time.Second, 2*time.Second)
	if err != nil {
		t.Fatalf("Terminate: %v", err)
	}
	if !verified {
		t.Fatalf("expected verified=true for a cooperative process")
	}
	if groupHasSurvivors(pgid) {
		t.Fatalf("process group %d still has a live member after Terminate reported verified", pgid)
	}
}

func TestTerminate_StubbornProcessRequiresSIGKILL(t *testing.T) {
	readyFile := filepath.Join(t.TempDir(), "trap-installed")
	script := `trap '' TERM; touch ` + readyFile + `; while true; do sleep 0.1; done`
	pgid, cmd := startGroupedProcess(t, script)
	go cmd.Wait()

	waitForFile(t, readyFile, 2*time.Second)

	start := time.Now()
	verified, err := Terminate(pgid, 500*time.Millisecond, 2*time.Second)
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("Terminate: %v", err)
	}
	if !verified {
		t.Fatalf("expected verified=true once SIGKILL takes effect")
	}
	if groupHasSurvivors(pgid) {
		t.Fatalf("process group %d still has a live member after Terminate reported verified", pgid)
	}
	if elapsed < 500*time.Millisecond {
		t.Fatalf("Terminate returned in %v, faster than the graceful timeout it should have waited out before escalating", elapsed)
	}
}

func TestTerminate_AlreadyDeadGroupReportsVerifiedImmediately(t *testing.T) {
	pgid, cmd := startGroupedProcess(t, "true")
	cmd.Wait()
	time.Sleep(100 * time.Millisecond)

	verified, err := Terminate(pgid, 2*time.Second, 2*time.Second)
	if err != nil {
		t.Fatalf("Terminate: %v", err)
	}
	if !verified {
		t.Fatalf("expected verified=true for an already-exited group")
	}
}

// TestTerminate_UnverifiableGroupReportsUnverifiedRatherThanAssumingGone proves
// that when the runner cannot determine whether the process group is still
// alive (e.g. kill(-pgid, 0) fails with EPERM after a permissions change,
// per docs/protocols/runner.md's explicit "process the runner cannot signal
// due to a permissions change" case), it reports verified=false instead of
// treating "cannot tell" the same as "confirmed gone". Simulated via the
// injectable checkProcessGroupFn/sendSignal seams rather than an actual
// root-owned process group, since the real EPERM case requires privileges
// this test cannot assume.
func TestTerminate_UnverifiableGroupReportsUnverifiedRatherThanAssumingGone(t *testing.T) {
	origCheck := checkProcessGroupFn
	origSignal := sendSignal
	t.Cleanup(func() {
		checkProcessGroupFn = origCheck
		sendSignal = origSignal
	})

	sendSignal = func(pid int, sig syscall.Signal) error { return nil }
	checkProcessGroupFn = func(pgid int) processGroupState { return groupUnknown }

	start := time.Now()
	verified, err := Terminate(999999, 50*time.Millisecond, 50*time.Millisecond)
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("Terminate: %v", err)
	}
	if verified {
		t.Fatalf("expected verified=false when the process group's liveness cannot be determined (e.g. EPERM), not assumed gone")
	}
	if elapsed < 100*time.Millisecond {
		t.Fatalf("returned in %v, faster than both bounded wait windows it should have exhausted before giving up", elapsed)
	}
}

// TestTerminate_RefusesDegeneratePgidWithoutSignalingCallersOwnGroup proves
// Terminate refuses pgid values of 0, 1, or negative -- kill(-0, ...) and
// kill(-1, ...) are POSIX broadcast signals (the caller's own group, or
// every signalable process on the system) rather than a specific process
// group, so a manifest-sourced pgid of this shape must never reach the
// syscall at all.
func TestTerminate_RefusesDegeneratePgidWithoutSignalingCallersOwnGroup(t *testing.T) {
	innocentPgid, innocentCmd := startGroupedProcess(t, "sleep 30")
	t.Cleanup(func() {
		syscall.Kill(-innocentPgid, syscall.SIGKILL)
		innocentCmd.Wait()
	})

	for _, degenerate := range []int{0, 1, -5} {
		verified, err := Terminate(degenerate, 50*time.Millisecond, 50*time.Millisecond)
		if err == nil {
			t.Fatalf("Terminate(%d, ...) should refuse a degenerate pgid, got no error", degenerate)
		}
		if verified {
			t.Fatalf("Terminate(%d, ...) reported verified=true for a refused, degenerate pgid", degenerate)
		}
	}

	if !groupHasSurvivors(innocentPgid) {
		t.Fatalf("innocent bystander process group %d was affected by a degenerate-pgid Terminate call", innocentPgid)
	}
}

// TestTerminateGroupAndDescendants_KillsAHarnessGrandchildThatDaemonizesAway
// proves the daemonize-escape gap is closed: a harness grandchild that
// calls setsid() itself leaves the harness's own process group entirely,
// so a group-scoped kill(-pgid, ...) alone can never reach it -- exactly
// the limitation an independent fable-model audit surfaced after Spike C's
// verification gate had already closed. TerminateGroupAndDescendants must
// kill and verify both the harness's group AND this escaped descendant.
func TestTerminateGroupAndDescendants_KillsAHarnessGrandchildThatDaemonizesAway(t *testing.T) {
	dir := t.TempDir()
	grandchildPidFile := filepath.Join(dir, "grandchild.pid")

	testBinary, err := os.Executable()
	if err != nil {
		t.Fatalf("os.Executable: %v", err)
	}

	script := `CS_RUNNER_TEST_HELPER=daemonize "$0" & echo $! > "$1"; sleep 30`
	handle, err := SpawnHarness([]string{"sh", "-c", script, testBinary, grandchildPidFile}, 2*time.Second)
	if err != nil {
		t.Fatalf("SpawnHarness: %v", err)
	}
	// Reap the harness concurrently, exactly as main.go's real production
	// code does: kill(-pgid, 0)'s verification depends on the harness
	// being promptly reaped by its actual parent (this process), since an
	// unreaped zombie leader makes kill(-pgid, 0) return EPERM rather than
	// ESRCH on this platform until Wait() actually reaps it (the same
	// finding that shaped every other Terminate test in this file).
	go handle.Cmd.Wait()
	t.Cleanup(func() {
		syscall.Kill(-handle.PGID, syscall.SIGKILL)
	})

	grandchildPID := waitForPIDFile(t, grandchildPidFile, 2*time.Second)
	t.Cleanup(func() { syscall.Kill(grandchildPID, syscall.SIGKILL) })

	// Wait for the grandchild to actually complete its own setsid() call
	// before terminating -- otherwise this test might race it, mirroring
	// the same TOCTOU class spawn.go already guards against for the
	// harness itself.
	deadline := time.Now().Add(2 * time.Second)
	for {
		if pgid, gErr := syscall.Getpgid(grandchildPID); gErr == nil && pgid == grandchildPID {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("grandchild pid %d never completed its own setsid()", grandchildPID)
		}
		time.Sleep(10 * time.Millisecond)
	}

	verified, err := TerminateGroupAndDescendants(handle.PGID, handle.PID, 2*time.Second, 2*time.Second)
	if err != nil {
		t.Fatalf("TerminateGroupAndDescendants: %v", err)
	}
	if !verified {
		t.Fatalf("expected verified=true")
	}

	if err := syscall.Kill(-handle.PGID, 0); err != syscall.ESRCH {
		t.Fatalf("harness process group %d still has a member (err=%v)", handle.PGID, err)
	}
	if err := syscall.Kill(grandchildPID, 0); err != syscall.ESRCH {
		t.Fatalf("escaped grandchild pid %d is still alive after termination (err=%v)", grandchildPID, err)
	}
}
