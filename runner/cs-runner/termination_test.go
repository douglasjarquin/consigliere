package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
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
	// Start tracking immediately after spawn, exactly as main.go's real
	// production code does: a single snapshot taken only at termination
	// time cannot see a descendant whose parent-child link to the harness
	// has already been severed by then.
	tracker := startDescendantTracker(handle.PID, 20*time.Millisecond)
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

	// Give the tracker a real chance to observe the grandchild before
	// terminating anything: the tracker's guarantee is "caught within one
	// poll interval," not "caught instantly," so a test that terminates
	// within microseconds of the grandchild existing is testing a race the
	// design explicitly does not claim to close (see descendant_tracker.go).
	time.Sleep(5 * 20 * time.Millisecond)

	verified, err := TerminateGroupAndDescendants(handle.PGID, tracker, 2*time.Second, 2*time.Second)
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

// TestTerminateGroupAndDescendants_GroupStillTerminatesButOverallVerificationFailsWhenDescendantTrackingCanNeverSeeAnything
// proves a failed descendant snapshot never skips the group-scoped kill:
// with `ps` entirely unreachable (a broken PATH) for the tracker's whole
// life, the group must still be signaled and verified dead --
// TerminateGroupAndDescendants must not silently give up on the one part
// of termination it can always do regardless of process-tree visibility.
// But the overall verified result must be false: a post-closure
// verification-gate round found the original version of this test
// asserting verified=true here, which enshrined a real bug -- ps being
// entirely unreachable means a real escaped descendant could have existed
// and gone completely unseen, which is exactly as unverifiable as an
// EPERM liveness check, and must never be reported as confirmed dead.
func TestTerminateGroupAndDescendants_GroupStillTerminatesButOverallVerificationFailsWhenDescendantTrackingCanNeverSeeAnything(t *testing.T) {
	pgid, cmd := startGroupedProcess(t, "sleep 30")
	go cmd.Wait()

	originalPath := os.Getenv("PATH")
	t.Cleanup(func() { os.Setenv("PATH", originalPath) })
	os.Setenv("PATH", t.TempDir())

	tracker := startDescendantTracker(pgid, 20*time.Millisecond)
	time.Sleep(60 * time.Millisecond)

	verified, _ := TerminateGroupAndDescendants(pgid, tracker, 300*time.Millisecond, 300*time.Millisecond)
	if verified {
		t.Fatalf("expected verified=false: descendant tracking could never run at all (broken PATH), so the descendant side is unverifiable even though the group itself terminated cleanly")
	}
	if groupHasSurvivors(pgid) {
		t.Fatalf("process group %d still has a member after termination", pgid)
	}
}

// TestTerminateGroupAndDescendants_DescendantPhaseStillRunsWhenGroupPhaseErrors
// proves a group-scoped signal failure (e.g. EPERM on the negative-pgid
// broadcast, per docs/protocols/runner.md's explicit "process the runner
// cannot signal" case) never skips the descendant phase: a trackable,
// individually-signalable escaped descendant must still be terminated even
// though the unrelated group-scoped signal failed -- the mirror image of
// round-1 finding B1 (a failed descendant snapshot must not skip the group
// kill), in the other direction, found by a later verification-gate round.
func TestTerminateGroupAndDescendants_DescendantPhaseStillRunsWhenGroupPhaseErrors(t *testing.T) {
	origSignal := sendSignal
	origCurrentStartedAtFn := currentStartedAtFn
	t.Cleanup(func() {
		sendSignal = origSignal
		currentStartedAtFn = origCurrentStartedAtFn
	})

	var mu sync.Mutex
	descendantSignaled := false

	sendSignal = func(pid int, sig syscall.Signal) error {
		if pid < 0 {
			return syscall.EPERM
		}
		mu.Lock()
		defer mu.Unlock()
		if sig == 0 {
			if descendantSignaled {
				return syscall.ESRCH
			}
			return nil
		}
		if sig == syscall.SIGTERM {
			descendantSignaled = true
		}
		return nil
	}
	currentStartedAtFn = func() (map[int]string, error) {
		return map[int]string{555: "same"}, nil
	}

	tracker := startDescendantTracker(0, time.Hour)
	tracker.seen[555] = "same"

	verified, err := TerminateGroupAndDescendants(4242, tracker, 200*time.Millisecond, 200*time.Millisecond)
	if err == nil {
		t.Fatalf("expected the group phase's EPERM to surface as an error")
	}
	if verified {
		t.Fatalf("expected verified=false: the group phase failed")
	}
	mu.Lock()
	signaled := descendantSignaled
	mu.Unlock()
	if !signaled {
		t.Fatalf("expected the descendant phase to still signal pid 555 even though the group phase errored")
	}
}

// seededTracker returns a tracker whose accumulated set is pre-populated
// directly rather than through real polling: root 0 is degenerate, so the
// tracker's own background goroutine never touches t.seen, letting a test
// control exactly what terminateTrackedDescendants sees via Peek()/Stop().
func seededTracker(seen map[int]string) *descendantTracker {
	tracker := startDescendantTracker(0, time.Hour)
	tracker.mu.Lock()
	for pid, startedAt := range seen {
		tracker.seen[pid] = startedAt
	}
	tracker.mu.Unlock()
	return tracker
}

// TestTerminateTrackedDescendants_UnverifiableDescendantReportsUnverifiedRatherThanAssumingGone
// proves the descendant path never confuses an unverifiable liveness check
// (EPERM) with confirmed death, exactly like the group-scoped path (round
// 1 finding B2) -- a real escaped descendant behind a permissions change
// must quarantine, not silently be assumed gone.
func TestTerminateTrackedDescendants_UnverifiableDescendantReportsUnverifiedRatherThanAssumingGone(t *testing.T) {
	origSignal := sendSignal
	origCurrentStartedAtFn := currentStartedAtFn
	t.Cleanup(func() {
		sendSignal = origSignal
		currentStartedAtFn = origCurrentStartedAtFn
	})

	currentStartedAtFn = func() (map[int]string, error) {
		return map[int]string{424242: "same"}, nil
	}
	sendSignal = func(pid int, sig syscall.Signal) error {
		if sig == 0 {
			return syscall.EPERM
		}
		return nil
	}

	tracker := seededTracker(map[int]string{424242: "same"})

	start := time.Now()
	verified, err := terminateTrackedDescendants(tracker, 50*time.Millisecond, 50*time.Millisecond)
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("terminateTrackedDescendants: %v", err)
	}
	if verified {
		t.Fatalf("expected verified=false when a descendant's liveness cannot be determined (e.g. EPERM), not assumed gone")
	}
	if elapsed < 100*time.Millisecond {
		t.Fatalf("returned in %v, faster than both bounded wait windows it should have exhausted before giving up", elapsed)
	}
}

// TestTerminateTrackedDescendants_NeverSignalsAPidTheOSHasRecycledToAnUnrelatedProcess
// proves a tracked pid whose current start time no longer matches what was
// recorded is treated as already resolved -- not signaled, not waited on
// -- closing a bug a verification-gate round found: a long-lived tracker's
// pid list can go stale, since the OS is free to reuse a pid number for a
// completely unrelated process once the original one has exited, and this
// function must never mistake that unrelated process for the one it was
// asked to terminate.
func TestTerminateTrackedDescendants_NeverSignalsAPidTheOSHasRecycledToAnUnrelatedProcess(t *testing.T) {
	origSignal := sendSignal
	origCurrentStartedAtFn := currentStartedAtFn
	t.Cleanup(func() {
		sendSignal = origSignal
		currentStartedAtFn = origCurrentStartedAtFn
	})

	signaled := false
	sendSignal = func(pid int, sig syscall.Signal) error {
		signaled = true
		return nil
	}
	currentStartedAtFn = func() (map[int]string, error) {
		return map[int]string{555: "a-different-process-now"}, nil
	}

	tracker := seededTracker(map[int]string{555: "original-process"})

	verified, err := terminateTrackedDescendants(tracker, 50*time.Millisecond, 50*time.Millisecond)
	if err != nil {
		t.Fatalf("terminateTrackedDescendants: %v", err)
	}
	if !verified {
		t.Fatalf("expected verified=true: the originally-tracked process is gone (its pid now belongs to something else), which is exactly the desired outcome")
	}
	if signaled {
		t.Fatalf("terminateTrackedDescendants signaled pid 555, but it is no longer the process that was tracked -- it must never be touched")
	}
}

// TestTerminateTrackedDescendants_UnableToRevalidateReportsUnverifiedWithoutSignalingAnything
// proves that when identity revalidation itself cannot run (e.g. ps
// unreachable), terminateTrackedDescendants signals nothing and reports
// unverified, rather than guessing at identity and signaling blind.
func TestTerminateTrackedDescendants_UnableToRevalidateReportsUnverifiedWithoutSignalingAnything(t *testing.T) {
	origSignal := sendSignal
	origCurrentStartedAtFn := currentStartedAtFn
	t.Cleanup(func() {
		sendSignal = origSignal
		currentStartedAtFn = origCurrentStartedAtFn
	})

	signaled := false
	sendSignal = func(pid int, sig syscall.Signal) error {
		signaled = true
		return nil
	}
	currentStartedAtFn = func() (map[int]string, error) {
		return nil, fmt.Errorf("ps unavailable")
	}

	tracker := seededTracker(map[int]string{555: "original-process"})

	verified, err := terminateTrackedDescendants(tracker, 50*time.Millisecond, 50*time.Millisecond)
	if err == nil {
		t.Fatalf("expected the revalidation failure to surface as an error")
	}
	if verified {
		t.Fatalf("expected verified=false when identity cannot be revalidated at all")
	}
	if signaled {
		t.Fatalf("terminateTrackedDescendants signaled a pid it could not revalidate -- must never guess")
	}
}

// TestTerminateTrackedDescendants_StopsTheTrackerEvenOnAnErrorReturn proves
// every error return path still stops the tracker's background goroutine --
// a verification-gate round found the early error returns introduced when
// this function was rewritten to keep the tracker alive throughout (see the
// comment above it) all skipped calling Stop() entirely, leaking a
// goroutine that would poll `ps` forever.
func TestTerminateTrackedDescendants_StopsTheTrackerEvenOnAnErrorReturn(t *testing.T) {
	origCurrentStartedAtFn := currentStartedAtFn
	t.Cleanup(func() { currentStartedAtFn = origCurrentStartedAtFn })

	currentStartedAtFn = func() (map[int]string, error) {
		return nil, fmt.Errorf("ps unavailable")
	}

	tracker := seededTracker(map[int]string{555: "original-process"})

	if _, err := terminateTrackedDescendants(tracker, 50*time.Millisecond, 50*time.Millisecond); err == nil {
		t.Fatalf("expected an error")
	}

	select {
	case <-tracker.done:
	default:
		t.Fatalf("tracker's background goroutine was not stopped after an error return -- it leaks forever")
	}
}
