package main

import (
	"syscall"
	"time"
)

// Terminate implements docs/protocols/runner.md's termination sequence:
// SIGTERM the full process group, wait up to gracefulTimeout, SIGKILL the
// full group if anything remains, wait up to verifyTimeout, then verify via
// a real process-group existence check (kill(-pgid, 0)) rather than trusting
// that the wait alone means the group is gone. Returns verified=false only
// if the group still has a live member after both signals and the full
// verify window have elapsed -- the caller is responsible for writing
// dead_unverified and quarantining in that case, never for retrying the kill
// itself (this function already tried everything it is allowed to try).
func Terminate(pgid int, gracefulTimeout, verifyTimeout time.Duration) (verified bool, err error) {
	if killErr := syscall.Kill(-pgid, syscall.SIGTERM); killErr != nil && killErr != syscall.ESRCH {
		return false, killErr
	}

	if waitUntilGone(pgid, gracefulTimeout) {
		return true, nil
	}

	if killErr := syscall.Kill(-pgid, syscall.SIGKILL); killErr != nil && killErr != syscall.ESRCH {
		return false, killErr
	}

	if waitUntilGone(pgid, verifyTimeout) {
		return true, nil
	}

	return false, nil
}

func pgidHasMember(pgid int) bool {
	err := syscall.Kill(-pgid, 0)
	return err == nil
}

func waitUntilGone(pgid int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	pollInterval := 20 * time.Millisecond

	for time.Now().Before(deadline) {
		if !pgidHasMember(pgid) {
			return true
		}
		time.Sleep(pollInterval)
	}

	return !pgidHasMember(pgid)
}
