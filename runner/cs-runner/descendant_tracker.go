package main

import (
	"sync"
	"time"
)

// descendantTracker continuously polls the OS process tree rooted at a
// harness pid throughout its entire life, accumulating every descendant
// pid still confirmed alive -- including one that later calls setsid() and
// escapes the harness's own process group, or one whose parent-child link
// to the harness is later severed by the harness itself exiting and being
// reaped. A single point-in-time snapshot taken only at termination time
// cannot see either case: by the time termination begins, the harness may
// already be dead and its escaped descendants already reparented to init,
// with no trace connecting them back to the harness in a fresh snapshot.
// Continuous polling closes that window for a descendant reached, at some
// poll, by an unbroken chain of parent-child links that are ALL present
// together in that one poll's own snapshot and that connect back to a pid
// already a valid root going into that poll -- the harness pid, or any
// pid a strictly earlier poll already added. A single poll's own BFS
// walks that snapshot to any depth, so it can catch several brand-new
// generations at once with no earlier poll ever having seen the
// intermediate links individually (this is why even the tracker's first,
// synchronous poll can catch a multi-generation escape in one pass, not
// just a direct child). And because every pid ever added remains a valid
// root for every later poll for as long as it is still that same live
// process, a subtree already reached through some
// ancestor keeps being explored on future polls even after that ancestor
// has since died and been pruned -- a long chain is routinely completed
// incrementally this way, across many different polls, long after an
// upstream link has broken. The one thing that permanently breaks
// discovery is a descendant for which no poll, at any point in the
// harness's life, ever catches an intact chain back to whatever was a
// valid root at that moment: in practice, one specific link on the path
// back to the harness was already severed (its parent had already
// exited) before any poll's snapshot could ever catch both ends of it
// together, and the child beyond that missed link can therefore never
// itself become a root -- so everything beneath it is invisible no
// matter how long it subsequently lives or how many further descendants
// it goes on to have (see docs/spikes/spike-c-results.md's double-fork
// Known Limitations bullet, which is exactly this case).
// A pid is pruned from the accumulated set once its identity no longer
// validates (it exited on its own, or the pid number has been recycled by
// the OS to an unrelated process), so the accumulated set at any moment is
// "every descendant seen and not yet ruled out", not a permanent record
// of everything ever observed.
type descendantTracker struct {
	mu         sync.Mutex
	seen       map[int]string
	pollFailed bool
	stop       chan struct{}
	done       chan struct{}
	stopOnce   sync.Once
}

func startDescendantTracker(rootPID int, interval time.Duration) *descendantTracker {
	t := &descendantTracker{
		seen: make(map[int]string),
		stop: make(chan struct{}),
		done: make(chan struct{}),
	}

	// The very first poll runs synchronously, before this function returns
	// to its caller: a goroutine's first scheduling is not guaranteed to
	// happen promptly, and this tracker exists specifically to survive a
	// caller that proceeds to kill the root again quickly (a harness that
	// spawns an escaping grandchild and exits almost immediately) --
	// without this synchronous poll, Stop() could be called before the
	// background goroutine ever ran at all, returning an empty result.
	t.poll(rootPID)

	go func() {
		defer close(t.done)

		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-t.stop:
				t.poll(rootPID)
				return
			case <-ticker.C:
				t.poll(rootPID)
			}
		}
	}()

	return t
}

func (t *descendantTracker) poll(rootPID int) {
	if rootPID <= 1 {
		return
	}

	t.mu.Lock()
	roots := make([]trackedPID, 0, len(t.seen)+1)
	roots = append(roots, trackedPID{PID: rootPID})
	for pid, startedAt := range t.seen {
		roots = append(roots, trackedPID{PID: pid, StartedAt: startedAt})
	}
	t.mu.Unlock()

	pids, validRoots, err := descendantsOfAny(roots)

	t.mu.Lock()
	defer t.mu.Unlock()
	if err != nil {
		// A failed enumeration means this poll could not see who was alive
		// at this instant: a descendant that appeared and disappeared
		// entirely within this one failed window is permanently invisible,
		// so the tracker's accumulated result can no longer be trusted as
		// complete. Recorded here so the caller can report the descendant
		// side as unverifiable, rather than silently treating whatever
		// happened to be seen as everything there was.
		t.pollFailed = true
		return
	}

	// A previously-seen pid that no longer validates against this poll
	// (exited on its own, or recycled by the OS to an unrelated process)
	// is dropped: it must stop acting as a polling root before its
	// unrelated replacement's real children could ever be mistaken for
	// descendants of the harness.
	stillValid := make(map[int]bool, len(validRoots))
	for _, r := range validRoots {
		stillValid[r.PID] = true
	}
	for pid := range t.seen {
		if !stillValid[pid] {
			delete(t.seen, pid)
		}
	}

	for _, p := range pids {
		if _, ok := t.seen[p.PID]; !ok {
			t.seen[p.PID] = p.StartedAt
		}
	}
}

// Peek returns every pid currently tracked as a descendant of the root --
// one seen and not since pruned for failing revalidation -- plus whether
// that result can be trusted as complete. Same result shape as Stop(), but
// without halting polling: a caller can inspect the tracker's live,
// still-changing accumulated set while it keeps running in the background.
func (t *descendantTracker) Peek() (pids []trackedPID, reliable bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.snapshotLocked()
}

// Stop halts polling (after one final poll) and returns every pid still
// tracked as a descendant of the root at that point, plus whether that
// result can be trusted as complete. reliable is false if even one poll
// over the tracker's life failed to enumerate the process tree (e.g. `ps`
// timed out or was unreachable): a gap during which a real descendant
// could have come and gone unseen, so the caller must treat the
// descendant side as unverifiable rather than assuming the pids it did
// see are the only ones that ever existed. Idempotent: calling Stop() more
// than once returns the same result rather than panicking on a
// doubly-closed channel.
func (t *descendantTracker) Stop() (pids []trackedPID, reliable bool) {
	t.stopOnce.Do(func() { close(t.stop) })
	<-t.done

	t.mu.Lock()
	defer t.mu.Unlock()
	return t.snapshotLocked()
}

func (t *descendantTracker) snapshotLocked() (pids []trackedPID, reliable bool) {
	pids = make([]trackedPID, 0, len(t.seen))
	for pid, startedAt := range t.seen {
		pids = append(pids, trackedPID{PID: pid, StartedAt: startedAt})
	}
	return pids, !t.pollFailed
}
