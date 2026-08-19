package main

import (
	"fmt"
	"syscall"
	"time"
)

type processGroupState int

const (
	groupGone processGroupState = iota
	groupAlive
	groupUnknown
)

// sendSignal and checkProcessGroupFn are package-level seams so tests can
// simulate signal-delivery and liveness-check outcomes (in particular,
// EPERM/unknown states that require privileges this test suite cannot
// assume) without touching real, unrelated processes.
var (
	sendSignal          = syscall.Kill
	checkProcessGroupFn = checkProcessGroup
)

// Terminate implements docs/protocols/runner.md's termination sequence:
// SIGTERM the full process group, wait up to gracefulTimeout, SIGKILL the
// full group if anything remains, wait up to verifyTimeout, then verify via
// a real process-group existence check rather than trusting that the wait
// alone means the group is gone. Returns verified=false whenever the group's
// liveness cannot be conclusively determined to be gone -- either because a
// member survived both signals, or because the check itself could not tell
// (e.g. EPERM after a permissions change, per docs/protocols/runner.md's
// explicit "process the runner cannot signal" case) -- never because the
// check merely stopped returning "alive". The caller is responsible for
// writing dead_unverified and quarantining in that case, never for retrying
// the kill itself (this function already tried everything it is allowed to
// try).
func Terminate(pgid int, gracefulTimeout, verifyTimeout time.Duration) (verified bool, err error) {
	if pgid <= 1 {
		return false, fmt.Errorf("refusing to signal process group %d: not a valid, non-degenerate pgid", pgid)
	}

	if killErr := sendSignal(-pgid, syscall.SIGTERM); killErr != nil && killErr != syscall.ESRCH {
		return false, killErr
	}

	if waitUntilGone(pgid, gracefulTimeout) {
		return true, nil
	}

	if killErr := sendSignal(-pgid, syscall.SIGKILL); killErr != nil && killErr != syscall.ESRCH {
		return false, killErr
	}

	return waitUntilGone(pgid, verifyTimeout), nil
}

// TerminateGroupAndDescendants runs Terminate against pgid and then
// terminates every descendant pid the caller's tracker observed over the
// harness's life still alive (via terminatePIDList) -- closing the
// daemonize-escape gap: a harness grandchild that calls setsid() itself
// leaves the process group entirely, so Terminate's group-scoped
// kill(-pgid, ...) can never reach it, even though it is very much still
// a descendant of the harness. The descendant pid list must come from a
// tracker that has been polling continuously since the harness was
// spawned (descendantTracker), not a single snapshot taken here: by the
// time termination begins, the harness may already be dead (a natural
// exit reaps it before this function is ever called) and any escaped
// descendant already reparented to init, with no trace connecting it back
// to the harness in a fresh snapshot taken now. The two phases run
// sequentially, not concurrently: descendant termination only starts once
// the group phase (which can itself produce new descendants right up
// until the group is confirmed gone) has finished, so a descendant that
// appears mid-graceful-window is still caught by the caller's tracker
// (which keeps polling until stopped, after this function's group phase
// completes) rather than being missed by a snapshot taken too early.
// verified is true only if both phases verify their targets are gone.
func TerminateGroupAndDescendants(pgid int, tracker *descendantTracker, gracefulTimeout, verifyTimeout time.Duration) (verified bool, err error) {
	groupVerified, groupErr := Terminate(pgid, gracefulTimeout, verifyTimeout)

	// The tracker keeps polling in its own goroutine for the entire
	// duration of the group phase above, so a descendant that appears
	// mid-graceful-window (after termination was triggered but before the
	// group is confirmed gone) is still observed before Stop() takes its
	// final poll and returns everything ever seen.
	descendantPIDs := tracker.Stop()

	if groupErr != nil {
		return false, groupErr
	}

	descVerified, descErr := terminatePIDList(descendantPIDs, gracefulTimeout, verifyTimeout)
	if descErr != nil {
		return false, descErr
	}

	return groupVerified && descVerified, nil
}

// terminatePIDList runs the same bounded SIGTERM -> wait -> SIGKILL ->
// verify sequence Terminate uses for a process group, but against each
// pid in a pre-determined list individually rather than a group
// broadcast, since an escaped descendant's own group cannot be assumed
// safe to broadcast-signal (it may not be a group of one). Every pid is
// signaled unconditionally (no upfront "is it alive" filter): an ESRCH on
// signal delivery is harmless and expected for a pid that has already
// exited on its own, mirroring Terminate's own group-signal handling.
func terminatePIDList(pids []int, gracefulTimeout, verifyTimeout time.Duration) (verified bool, err error) {
	if len(pids) == 0 {
		return true, nil
	}

	for _, pid := range pids {
		if killErr := sendSignal(pid, syscall.SIGTERM); killErr != nil && killErr != syscall.ESRCH {
			return false, killErr
		}
	}
	if waitUntilPIDsGone(pids, gracefulTimeout) {
		return true, nil
	}

	for _, pid := range pids {
		if killErr := sendSignal(pid, syscall.SIGKILL); killErr != nil && killErr != syscall.ESRCH {
			return false, killErr
		}
	}
	return waitUntilPIDsGone(pids, verifyTimeout), nil
}

// checkPID mirrors checkProcessGroup for a specific pid rather than a
// negative-pgid broadcast target: only ESRCH is conclusive evidence of
// death, so an EPERM (or any other error) can never be misread as "gone"
// (round 1 finding B2's fix, applied identically here).
func checkPID(pid int) processGroupState {
	switch err := sendSignal(pid, 0); err {
	case nil:
		return groupAlive
	case syscall.ESRCH:
		return groupGone
	default:
		return groupUnknown
	}
}

// waitUntilPIDsGone mirrors waitUntilGone for a list of specific pids:
// resolves true only once every pid conclusively checks as gone (ESRCH),
// treating an unverifiable check (EPERM) the same as "still alive" rather
// than "gone", exactly like the group-scoped check.
func waitUntilPIDsGone(pids []int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)

	for {
		allGone := true
		for _, pid := range pids {
			if checkPID(pid) != groupGone {
				allGone = false
				break
			}
		}
		if allGone {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func checkProcessGroup(pgid int) processGroupState {
	switch err := syscall.Kill(-pgid, 0); err {
	case nil:
		return groupAlive
	case syscall.ESRCH:
		return groupGone
	default:
		return groupUnknown
	}
}

// waitUntilGone returns true only once checkProcessGroupFn conclusively
// reports groupGone. groupUnknown (liveness cannot be determined) is treated
// the same as groupAlive here -- both keep the loop waiting rather than
// resolving to "gone" -- so a permissions error can never be mistaken for a
// confirmed kill.
func waitUntilGone(pgid int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)

	for {
		if checkProcessGroupFn(pgid) == groupGone {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(20 * time.Millisecond)
	}
}
