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

// TerminateGroupAndDescendants runs Terminate against pgid and, in
// parallel, terminates every OS-process-tree descendant of harnessPID
// still alive (via terminatePIDList) -- closing the daemonize-escape gap:
// a harness grandchild that calls setsid() itself leaves the process
// group entirely, so Terminate's group-scoped kill(-pgid, ...) can never
// reach it, even though it is very much still a descendant of the
// harness. The descendant snapshot is taken FIRST, before either kill
// phase starts: if it were taken concurrently with (or after) the
// group-kill, a fast group-kill could reap the harness before the
// snapshot runs, reparenting any escaped descendant to init and severing
// the very parent-child link this function needs to find it. Both kill
// phases then run concurrently against the snapshot so the combined
// wall-clock stays within the same gracefulTimeout+verifyTimeout budget
// rather than doubling it. verified is true only if both phases verify
// their targets are gone.
func TerminateGroupAndDescendants(pgid, harnessPID int, gracefulTimeout, verifyTimeout time.Duration) (verified bool, err error) {
	descendantPIDs, err := descendantsOf(harnessPID)
	if err != nil {
		return false, err
	}

	type result struct {
		verified bool
		err      error
	}
	groupCh := make(chan result, 1)
	descCh := make(chan result, 1)

	go func() {
		v, e := Terminate(pgid, gracefulTimeout, verifyTimeout)
		groupCh <- result{v, e}
	}()
	go func() {
		v, e := terminatePIDList(descendantPIDs, gracefulTimeout, verifyTimeout)
		descCh <- result{v, e}
	}()

	group := <-groupCh
	desc := <-descCh

	if group.err != nil {
		return false, group.err
	}
	if desc.err != nil {
		return false, desc.err
	}
	return group.verified && desc.verified, nil
}

// terminatePIDList runs the same bounded SIGTERM -> wait -> SIGKILL ->
// verify sequence Terminate uses for a process group, but against each
// pid in a pre-determined list individually rather than a group
// broadcast, since an escaped descendant's own group cannot be assumed
// safe to broadcast-signal (it may not be a group of one).
func terminatePIDList(pids []int, gracefulTimeout, verifyTimeout time.Duration) (verified bool, err error) {
	var alive []int
	for _, pid := range pids {
		if sendSignal(pid, 0) == nil {
			alive = append(alive, pid)
		}
	}
	if len(alive) == 0 {
		return true, nil
	}

	for _, pid := range alive {
		if killErr := sendSignal(pid, syscall.SIGTERM); killErr != nil && killErr != syscall.ESRCH {
			return false, killErr
		}
	}
	if waitUntilPidsGone(alive, gracefulTimeout) {
		return true, nil
	}

	for _, pid := range alive {
		if killErr := sendSignal(pid, syscall.SIGKILL); killErr != nil && killErr != syscall.ESRCH {
			return false, killErr
		}
	}
	return waitUntilPidsGone(alive, verifyTimeout), nil
}

func waitUntilPidsGone(pids []int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)

	for {
		allGone := true
		for _, pid := range pids {
			if sendSignal(pid, 0) == nil {
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
