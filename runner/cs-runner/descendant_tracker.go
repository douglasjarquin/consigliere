package main

import (
	"sync"
	"time"
)

// descendantTracker continuously polls the OS process tree rooted at a
// harness pid throughout its entire life, accumulating every descendant
// pid ever observed -- including one that later calls setsid() and
// escapes the harness's own process group, or one whose parent-child link
// to the harness is later severed by the harness itself exiting and being
// reaped. A single point-in-time snapshot taken only at termination time
// cannot see either case: by the time termination begins, the harness may
// already be dead and its escaped descendants already reparented to init,
// with no trace connecting them back to the harness in a fresh snapshot.
// Continuous polling closes that window down to, at worst, the single
// poll interval immediately before the tracker is stopped -- a residual,
// disclosed limitation of finite-frequency polling, not an unbounded gap.
type descendantTracker struct {
	mu   sync.Mutex
	seen map[int]bool
	stop chan struct{}
	done chan struct{}
}

func startDescendantTracker(rootPID int, interval time.Duration) *descendantTracker {
	t := &descendantTracker{
		seen: make(map[int]bool),
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
	pids, err := descendantsOf(rootPID)
	if err != nil {
		return
	}
	t.mu.Lock()
	for _, pid := range pids {
		t.seen[pid] = true
	}
	t.mu.Unlock()
}

// Stop halts polling (after one final poll) and returns every pid ever
// observed as a descendant of the tracked root. Safe to call exactly once
// per tracker.
func (t *descendantTracker) Stop() []int {
	close(t.stop)
	<-t.done

	t.mu.Lock()
	defer t.mu.Unlock()
	pids := make([]int, 0, len(t.seen))
	for pid := range t.seen {
		pids = append(pids, pid)
	}
	return pids
}
