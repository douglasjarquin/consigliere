# Supervision

How consigliere waits for workers, handles notifications, and stays reachable to the boss.

## Sub-features

- one bounded wait per turn: the checkpoint is the only in-turn wait, and a second one is refused.
- drain first: every notification-handling turn empties the durable queue before peeking, steering, or other work.
- persistent watcher: a monitor outlives the turn and queues notifications; the home activates itself when the queue sits unattended.
- wake types: worker signals, stopped-responding workers, named polls, and heartbeat fleet review.
- away mode: batch routine updates and surface only decisions, failures, credentials, and review-ready work.

## How to get to it (user POV)

After dispatching work, consigliere waits rather than polling the boss.
The boss hears when a PR is ready, a decision is needed, something failed, or a credential is missing.
Routine progress stays off the desk.
If the boss goes away, the same watcher keeps running; merge authority does not expand.

## Driving it

- `docs/supervision.md` owns the cycle, drain durability, and per-type handling.
- `bin/cs-wake-drain.sh` drains; `bin/cs-watch-checkpoint.sh` is the one per-turn wait; `bin/cs-monitor.sh` and `bin/cs-activate.sh` keep the home watched across turns.
- Load `stuck-soldier-recovery` for a stopped, looping, or unresponsive worker.
- Load `/afk` when the boss is away or `state/.afk` exists.

## Gotchas

- Ending the turn is what lets a boss message arrive; stacking waits in one turn made the session unreachable.
- A capo's quiet idle pane is healthy, not a stale worker.
- Away mode never authorizes a merge.
- `escalation-style` owns which outcomes reach the boss and the exact `Boss, taken care of.` routine reply.
