package main

import (
	"fmt"
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

	cmd := exec.Command("sh", "-c", `sleep 30 & echo $! > "$0"; read _`, childPidFile)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}
	rootPID := cmd.Process.Pid
	waitDone := make(chan error, 1)
	go func() { waitDone <- cmd.Wait() }()

	tracker := startDescendantTracker(rootPID, 20*time.Millisecond)

	childPID := waitForPIDFile(t, childPidFile, 2*time.Second)
	t.Cleanup(func() { syscall.Kill(childPID, syscall.SIGKILL) })

	deadline := time.Now().Add(2 * time.Second)
	for {
		pids, _ := tracker.Peek()
		found := false
		for _, p := range pids {
			if p.PID == childPID {
				found = true
				break
			}
		}
		if found {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("tracker never observed child %d while root %d was alive", childPID, rootPID)
		}
		time.Sleep(20 * time.Millisecond)
	}

	if _, err := stdin.Write([]byte("\n")); err != nil {
		t.Fatalf("release root: %v", err)
	}
	if err := stdin.Close(); err != nil {
		t.Fatalf("close root stdin: %v", err)
	}
	select {
	case err := <-waitDone:
		if err != nil {
			t.Fatalf("wait root: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("root %d did not exit after release", rootPID)
	}

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

// TestDescendantTracker_TracksAChildForkedByAnAlreadyTrackedDescendantAfterRootExits
// proves a pid the tracker has already seen keeps acting as its own polling
// root: a verification-gate round found that once the harness (root) dies
// and is reaped, a BFS rooted only at the harness's own pid can no longer
// reach anything, so a still-alive tracked descendant that later forks its
// own child would never be discovered at all -- even though every process
// involved lives for many poll intervals, and even though the manifest
// would still report the harness's death as fully verified.
func TestDescendantTracker_TracksAChildForkedByAnAlreadyTrackedDescendantAfterRootExits(t *testing.T) {
	dir := t.TempDir()
	childPidFile := filepath.Join(dir, "child.pid")
	grandchildPidFile := filepath.Join(dir, "grandchild.pid")

	rootScript := `sh -c 'sleep 0.3; sleep 30 & echo $! > "$0"; sleep 30' "$1" &
child=$!
echo $child > "$0"
sleep 0.1
exit 0
`
	cmd := exec.Command("sh", "-c", rootScript, childPidFile, grandchildPidFile)
	if err := cmd.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}
	rootPID := cmd.Process.Pid
	go cmd.Wait()

	tracker := startDescendantTracker(rootPID, 20*time.Millisecond)

	childPID := waitForPIDFile(t, childPidFile, 2*time.Second)
	t.Cleanup(func() { syscall.Kill(childPID, syscall.SIGKILL) })

	grandchildPID := waitForPIDFile(t, grandchildPidFile, 2*time.Second)
	t.Cleanup(func() { syscall.Kill(grandchildPID, syscall.SIGKILL) })

	// Give the tracker a real chance to observe the grandchild via its own
	// poll interval before stopping.
	time.Sleep(100 * time.Millisecond)

	pids, reliable := tracker.Stop()
	if !reliable {
		t.Fatalf("expected reliable=true: ps was available throughout")
	}
	found := false
	for _, p := range pids {
		if p.PID == grandchildPID {
			found = true
		}
	}
	if !found {
		t.Fatalf("tracker.Stop() = %v, missing grandchild %d forked by already-tracked descendant %d after root %d had already exited", pids, grandchildPID, childPID, rootPID)
	}
}

// TestDescendantTracker_PrunesAStalePollingRootAndNeverAdoptsItsUnrelatedChildren
// proves a previously-seen pid whose recorded start time no longer matches
// the live process at that pid number is pruned from the tracker rather
// than kept as a permanent polling root -- a verification-gate round found
// that without this, a recycled pid would sweep an unrelated process's
// real children into the tracked set, and terminateTrackedDescendants'
// own identity revalidation (a later, separate check) cannot catch this,
// since those children are recorded with their own correct, matching
// start times.
func TestDescendantTracker_PrunesAStalePollingRootAndNeverAdoptsItsUnrelatedChildren(t *testing.T) {
	dir := t.TempDir()
	impostorChildPidFile := filepath.Join(dir, "impostor-child.pid")

	impostorCmd := exec.Command("sh", "-c", `sleep 30 & echo $! > "$0"; wait`, impostorChildPidFile)
	if err := impostorCmd.Start(); err != nil {
		t.Fatalf("start impostor: %v", err)
	}
	impostorPID := impostorCmd.Process.Pid
	go impostorCmd.Wait()
	t.Cleanup(func() { syscall.Kill(impostorPID, syscall.SIGKILL) })

	impostorChildPID := waitForPIDFile(t, impostorChildPidFile, 2*time.Second)
	t.Cleanup(func() { syscall.Kill(impostorChildPID, syscall.SIGKILL) })

	// A separate, real root the tracker actually tracks -- unrelated to the
	// impostor, needed only so the tracker's background poll runs its full
	// body (a degenerate root skips it entirely).
	rootCmd := exec.Command("sleep", "30")
	if err := rootCmd.Start(); err != nil {
		t.Fatalf("start root: %v", err)
	}
	rootPID := rootCmd.Process.Pid
	go rootCmd.Wait()
	t.Cleanup(func() { syscall.Kill(rootPID, syscall.SIGKILL) })

	tracker := startDescendantTracker(rootPID, 20*time.Millisecond)
	// Seed a stale entry: the impostor's pid, but with a start time that
	// does not match its real one -- simulating "this pid number was
	// previously a different, now-exited process the tracker legitimately
	// saw".
	tracker.mu.Lock()
	tracker.seen[impostorPID] = "Mon Jan  1 00:00:00 2001"
	tracker.mu.Unlock()

	time.Sleep(150 * time.Millisecond)

	pids, reliable := tracker.Stop()
	if !reliable {
		t.Fatalf("expected reliable=true: ps was available throughout")
	}
	for _, p := range pids {
		if p.PID == impostorPID {
			t.Fatalf("stale entry for recycled pid %d was not pruned: %v", impostorPID, pids)
		}
		if p.PID == impostorChildPID {
			t.Fatalf("impostor's real, unrelated child %d was adopted into the tracked set: %v", impostorChildPID, pids)
		}
	}
}

// writeFakePS writes an executable at path that, when run in place of a
// real `ps`, prints exactly the given pid/ppid/lstart rows -- used to give
// a test full control over what a poll sees, independent of the real
// process table and its timing.
func writeFakePS(t *testing.T, path string, rows [][2]int) {
	t.Helper()
	// echo is a shell builtin, not an external command: the script must
	// never depend on anything resolved via PATH, since the whole point
	// of this stub is to run with PATH overridden to nothing but itself.
	script := "#!/bin/sh\n"
	for _, row := range rows {
		script += fmt.Sprintf("echo '%d %d Mon Jan  1 00:00:00 2001'\n", row[0], row[1])
	}
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake ps: %v", err)
	}
}

// TestDescendantTracker_FirstPollIsSynchronousAndAlreadyContainsAChild
// proves startDescendantTracker's very first poll has already run, and its
// result is already visible, before the function returns -- a real
// implementation bug this exact guarantee once closed (see
// docs/spikes/spike-c-results.md's "Two real races found" section) had no
// regression test of its own: nothing in the suite failed when this
// synchronous poll was removed.
func TestDescendantTracker_FirstPollIsSynchronousAndAlreadyContainsAChild(t *testing.T) {
	rootCmd := exec.Command("sleep", "30")
	if err := rootCmd.Start(); err != nil {
		t.Fatalf("start root: %v", err)
	}
	rootPID := rootCmd.Process.Pid
	go rootCmd.Wait()
	t.Cleanup(func() { syscall.Kill(rootPID, syscall.SIGKILL) })

	childCmd := exec.Command("sleep", "30")
	if err := childCmd.Start(); err != nil {
		t.Fatalf("start child: %v", err)
	}
	childPID := childCmd.Process.Pid
	go childCmd.Wait()
	t.Cleanup(func() { syscall.Kill(childPID, syscall.SIGKILL) })

	dir := t.TempDir()
	writeFakePS(t, filepath.Join(dir, "ps"), [][2]int{{rootPID, 1}, {childPID, rootPID}})
	originalPath := os.Getenv("PATH")
	t.Cleanup(func() { os.Setenv("PATH", originalPath) })
	os.Setenv("PATH", dir)

	// A 30-second interval guarantees the background ticker cannot have
	// fired by the time Peek() is called immediately below -- only the
	// synchronous first poll can have populated the tracked set.
	tracker := startDescendantTracker(rootPID, 30*time.Second)
	pids, reliable := tracker.Peek()
	tracker.Stop()

	if !reliable {
		t.Fatalf("expected reliable=true: the fake ps always succeeds")
	}
	found := false
	for _, p := range pids {
		if p.PID == childPID {
			found = true
		}
	}
	if !found {
		t.Fatalf("startDescendantTracker's first poll did not already contain child %d: %v", childPID, pids)
	}
}

// TestDescendantTracker_StopsFinalPollCanStillDiscoverANewChild proves
// Stop()'s documented "one final poll" is real and load-bearing: a child
// that appears only after the tracker's last background tick, with no
// further tick ever scheduled to fire, is still discovered because Stop()
// itself triggers one more poll before returning -- nothing in the suite
// failed when this final poll was removed.
func TestDescendantTracker_StopsFinalPollCanStillDiscoverANewChild(t *testing.T) {
	rootCmd := exec.Command("sleep", "30")
	if err := rootCmd.Start(); err != nil {
		t.Fatalf("start root: %v", err)
	}
	rootPID := rootCmd.Process.Pid
	go rootCmd.Wait()
	t.Cleanup(func() { syscall.Kill(rootPID, syscall.SIGKILL) })

	childCmd := exec.Command("sleep", "30")
	if err := childCmd.Start(); err != nil {
		t.Fatalf("start child: %v", err)
	}
	childPID := childCmd.Process.Pid
	go childCmd.Wait()
	t.Cleanup(func() { syscall.Kill(childPID, syscall.SIGKILL) })

	dir := t.TempDir()
	fakePS := filepath.Join(dir, "ps")
	writeFakePS(t, fakePS, [][2]int{{rootPID, 1}})
	originalPath := os.Getenv("PATH")
	t.Cleanup(func() { os.Setenv("PATH", originalPath) })
	os.Setenv("PATH", dir)

	// A 30-second interval guarantees the background ticker never fires
	// again for the rest of this test -- the child added to the snapshot
	// below can only ever be seen by Stop()'s own final poll.
	tracker := startDescendantTracker(rootPID, 30*time.Second)

	writeFakePS(t, fakePS, [][2]int{{rootPID, 1}, {childPID, rootPID}})

	pids, reliable := tracker.Stop()
	if !reliable {
		t.Fatalf("expected reliable=true: the fake ps always succeeds")
	}
	found := false
	for _, p := range pids {
		if p.PID == childPID {
			found = true
		}
	}
	if !found {
		t.Fatalf("Stop()'s final poll did not discover child %d, added to the process table only after the last background tick: %v", childPID, pids)
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
