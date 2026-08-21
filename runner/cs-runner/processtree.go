package main

import (
	"bufio"
	"context"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// psSnapshotTimeout bounds every `ps` invocation this package makes.
// Without a bound, a hung or unreachable `ps` would block descendant
// tracking indefinitely -- which a post-closure verification-gate round
// found could either abandon an already-spawned harness mid-startup (its
// synchronous first poll blocking the manifest write and reaper that
// depend on running first) or hang the termination path forever (Stop()
// waiting on a poll that never returns).
const psSnapshotTimeout = 2 * time.Second

// psWaitDelay bounds the extra time psSnapshot waits, after psSnapshotTimeout
// has already killed `ps` itself, for its stdout pipe to actually close. A
// context alone is not enough: exec.CommandContext only kills the direct
// child, but a `ps` that forks a background child before dying (or is a
// wrapper script that does) leaves that child holding the pipe's write end
// open, so Output() keeps blocking on a read that will never see EOF until
// the orphan exits on its own -- a later verification-gate round reproduced
// this as a genuine 61-second hang despite the context timeout already
// having fired. WaitDelay forces the pipe closed once it elapses, regardless
// of what still holds it open.
const psWaitDelay = 1 * time.Second

// processInfo is one row of a `ps` snapshot: a pid, its parent, and its
// start time. startedAt is an opaque fingerprint (ps's own `lstart`
// rendering, never parsed as a real time.Time) used only to tell whether a
// pid observed earlier is still the same OS process or has since exited
// and been recycled by something else entirely.
type processInfo struct {
	pid       int
	ppid      int
	startedAt string
}

// psSnapshot takes one bounded `ps` invocation and returns every process's
// pid, parent pid, and start time.
func psSnapshot() ([]processInfo, error) {
	ctx, cancel := context.WithTimeout(context.Background(), psSnapshotTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "ps", "-axo", "pid=,ppid=,lstart=")
	cmd.WaitDelay = psWaitDelay
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	var rows []processInfo
	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 2 {
			continue
		}
		pid, err1 := strconv.Atoi(fields[0])
		ppid, err2 := strconv.Atoi(fields[1])
		if err1 != nil || err2 != nil {
			continue
		}
		rows = append(rows, processInfo{pid: pid, ppid: ppid, startedAt: strings.Join(fields[2:], " ")})
	}
	return rows, scanner.Err()
}

// trackedPID identifies a specific process instance, not just a pid
// number: startedAt lets a later revalidation tell "still the same
// process" apart from "this pid number has since been recycled by the OS
// to something else entirely", closing the window where blindly signaling
// every pid ever observed could hit an unrelated process.
type trackedPID struct {
	PID       int
	StartedAt string
}

// descendantsOf returns every transitive descendant of root from a single
// process-table snapshot -- including a descendant that has escaped root's
// own process group (e.g. by calling setsid()), which a pgid-scoped signal
// can never reach. A single snapshot only reflects one instant, which is
// why descendantTracker calls this repeatedly throughout a harness's whole
// life rather than taking one snapshot at termination time: root itself
// may already be dead and reaped by then, having already reparented any
// escaped descendant to init and severed the very link this function
// needs to find it.
func descendantsOf(root int) ([]trackedPID, error) {
	descendants, _, err := descendantsOfAny([]trackedPID{{PID: root}})
	return descendants, err
}

// descendantsOfAny returns every transitive descendant of any of the given
// roots, from a single process-table snapshot, excluding the roots
// themselves, along with which of those roots are still valid. A root with
// a non-empty StartedAt is revalidated against this same snapshot before
// being traversed: if the pid's current start time no longer matches (the
// process exited, or the pid number has since been recycled by the OS to
// something else entirely), it is dropped rather than traversed -- an
// unrelated process's real children must never be adopted just because
// its pid happens to match a number this runner once cared about. A root
// with an empty StartedAt (the harness's own pid, whose identity this
// package does not track) is always trusted and traversed unconditionally.
//
// descendantTracker polls with every pid it has already tracked as an
// extra root, not just the harness: once the harness itself has died and
// been reaped, a BFS rooted only at the harness pid can
// no longer reach anything, so a still-alive tracked descendant that later
// forks its own child would otherwise never be discovered at all. Letting
// every previously-seen pid keep acting as its own root closes that gap.
func descendantsOfAny(roots []trackedPID) (descendants []trackedPID, validRoots []trackedPID, err error) {
	rows, err := psSnapshot()
	if err != nil {
		return nil, nil, err
	}

	children := make(map[int][]int)
	startedAt := make(map[int]string, len(rows))
	for _, row := range rows {
		children[row.ppid] = append(children[row.ppid], row.pid)
		startedAt[row.pid] = row.startedAt
	}

	seen := make(map[int]bool, len(roots))
	queue := make([]int, 0, len(roots))
	for _, root := range roots {
		if root.StartedAt != "" && startedAt[root.PID] != root.StartedAt {
			continue
		}
		if seen[root.PID] {
			continue
		}
		seen[root.PID] = true
		queue = append(queue, root.PID)
		validRoots = append(validRoots, root)
	}
	for len(queue) > 0 {
		pid := queue[0]
		queue = queue[1:]
		for _, child := range children[pid] {
			if seen[child] {
				continue
			}
			seen[child] = true
			descendants = append(descendants, trackedPID{PID: child, StartedAt: startedAt[child]})
			queue = append(queue, child)
		}
	}
	return descendants, validRoots, nil
}

// currentStartedAt takes a fresh snapshot and returns every currently-live
// pid's start time, used to revalidate that a previously-tracked pid is
// still the same process before signaling it.
func currentStartedAt() (map[int]string, error) {
	rows, err := psSnapshot()
	if err != nil {
		return nil, err
	}
	byPID := make(map[int]string, len(rows))
	for _, row := range rows {
		byPID[row.pid] = row.startedAt
	}
	return byPID, nil
}
