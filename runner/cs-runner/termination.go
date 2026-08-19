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

func pgidHasMember(pgid int) bool {
	return checkProcessGroupFn(pgid) == groupAlive
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
