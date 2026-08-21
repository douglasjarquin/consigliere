package main

import (
	"errors"
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

// sendSignal, checkProcessGroupFn, and currentStartedAtFn are package-level
// seams so tests can simulate signal-delivery, liveness-check, and
// process-identity outcomes (in particular, EPERM/unknown states that
// require privileges this test suite cannot assume) without touching real,
// unrelated processes.
var (
	sendSignal          = syscall.Kill
	checkProcessGroupFn = checkProcessGroup
	currentStartedAtFn  = currentStartedAt
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
// terminates every descendant pid the caller's tracker observes still alive
// (via terminateTrackedDescendants) -- closing the
// daemonize-escape gap: a harness grandchild that calls setsid() itself
// leaves the process group entirely, so Terminate's group-scoped
// kill(-pgid, ...) can never reach it, even though it is very much still
// a descendant of the harness. The descendant pid list must come from a
// tracker that has been polling continuously since the harness was
// spawned (descendantTracker), not a single snapshot taken here: by the
// time termination begins, the harness may already be dead (a natural
// exit reaps it before this function is ever called) and any escaped
// descendant already reparented to init, with no trace connecting it back
// to the harness in a fresh snapshot taken now.
//
// The descendant phase always runs, even if the group phase errored: a
// group-scoped signal can fail for reasons unrelated to a specific escaped
// descendant (e.g. a permissions change affecting the negative-pgid
// broadcast but not an individually-addressed pid), and a trackable,
// killable escapee must not go untouched just because the unrelated group
// phase failed. Likewise, a descendant-tracking failure never skips the
// group phase, which runs and is verified unconditionally first.
//
// verified is true only if the group is confirmed gone, descendant
// tracking ran reliably for the harness's whole life (never failed to
// enumerate the process tree), and every descendant it saw is confirmed
// gone: an enumeration failure means a real escapee could have existed and
// gone unseen, which is exactly as unverifiable as a liveness check that
// returns EPERM, and must never be reported as if it were confirmed dead.
func TerminateGroupAndDescendants(pgid int, tracker *descendantTracker, gracefulTimeout, verifyTimeout time.Duration) (verified bool, err error) {
	groupVerified, groupErr := Terminate(pgid, gracefulTimeout, verifyTimeout)

	descVerified, descErr := terminateTrackedDescendants(tracker, gracefulTimeout, verifyTimeout)

	verified = groupVerified && descVerified
	return verified, errors.Join(groupErr, descErr)
}

// terminateTrackedDescendants runs the same bounded SIGTERM -> wait ->
// SIGKILL -> verify sequence Terminate uses for a process group, but
// against tracker's live, still-growing accumulated set rather than a
// single snapshot taken up front. tracker is left running for this entire
// call and is only stopped just before returning: a verification-gate
// round found that stopping it first (to grab one static pid list) left a
// blind spot for the whole of this function's own multi-second graceful-
// wait and verify windows, during which an already-tracked, SIGTERM-
// resistant escapee could fork a brand-new child that would never be
// discovered or signaled, behind a manifest that still claimed
// dead_verified. Keeping the tracker alive here means its own background
// polling (which already treats every previously-seen pid as an extra
// root) keeps discovering such newcomers throughout, not just before this
// function was ever called.
//
// Every newly-discovered pid is revalidated against a fresh snapshot
// before being signaled: the OS is free to recycle a pid number to a
// completely unrelated process once the original one has exited, and this
// function must never mistake that unrelated process for the one it was
// asked to terminate. A pid whose current start time no longer matches
// what was recorded (or that no longer exists at all) is treated as
// already resolved -- never signaled, never waited on. If revalidation
// itself cannot run at all, nothing is signaled and the whole call reports
// unverified, rather than guessing.
func terminateTrackedDescendants(tracker *descendantTracker, gracefulTimeout, verifyTimeout time.Duration) (verified bool, err error) {
	// Guarantees the tracker's background goroutine is always stopped,
	// even on an early error return -- a verification-gate round found
	// every error path here previously returned without ever calling
	// Stop(), leaking a goroutine that polled `ps` forever. Idempotent
	// (sync.Once-backed), so this is harmless alongside the explicit
	// Stop() call the normal completion path below still makes to get at
	// its actual return values.
	defer func() { tracker.Stop() }()

	known := make(map[int]bool)

	signalFresh := func(sig syscall.Signal, doneThisPhase map[int]bool, candidates []trackedPID) error {
		var fresh []trackedPID
		for _, p := range candidates {
			if !doneThisPhase[p.PID] {
				fresh = append(fresh, p)
			}
		}
		if len(fresh) == 0 {
			return nil
		}
		current, snapErr := currentStartedAtFn()
		if snapErr != nil {
			return snapErr
		}
		for _, p := range fresh {
			doneThisPhase[p.PID] = true
			if current[p.PID] != p.StartedAt {
				continue
			}
			known[p.PID] = true
			if killErr := sendSignal(p.PID, sig); killErr != nil && killErr != syscall.ESRCH {
				return killErr
			}
		}
		return nil
	}

	allKnownGone := func() bool {
		for pid := range known {
			if checkPID(pid) != groupGone {
				return false
			}
		}
		return true
	}

	runPhase := func(sig syscall.Signal, deadline time.Time) error {
		doneThisPhase := make(map[int]bool)
		for {
			pids, _ := tracker.Peek()
			if err := signalFresh(sig, doneThisPhase, pids); err != nil {
				return err
			}
			if allKnownGone() {
				return nil
			}
			if time.Now().After(deadline) {
				return nil
			}
			time.Sleep(20 * time.Millisecond)
		}
	}

	if err := runPhase(syscall.SIGTERM, time.Now().Add(gracefulTimeout)); err != nil {
		return false, err
	}

	if !allKnownGone() {
		if err := runPhase(syscall.SIGKILL, time.Now().Add(verifyTimeout)); err != nil {
			return false, err
		}
	}

	finalPIDs, reliable := tracker.Stop()
	knownBefore := len(known)
	if err := signalFresh(syscall.SIGKILL, make(map[int]bool), finalPIDs); err != nil {
		return false, err
	}
	if len(known) > knownBefore {
		// Stop()'s own final poll found something no earlier phase loop
		// had a chance to see: give it a short grace period rather than
		// judging it immediately after a single SIGKILL.
		pids := make([]int, 0, len(known))
		for pid := range known {
			pids = append(pids, pid)
		}
		waitUntilPIDsGone(pids, 500*time.Millisecond)
	}

	return reliable && allKnownGone(), nil
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
