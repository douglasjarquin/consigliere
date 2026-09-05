# Supervision

## Sub-features

- The persistent monitor watches each home between turns and feeds a durable wake queue.
- A bounded foreground checkpoint gives the active session a chance to handle work without owning the watcher.
- Wake draining folds open decisions and reconciles task status before ordinary handling.
- Away mode and stuck-soldier recovery preserve evidence while escalating only actionable failures.

## How to get to it (user POV)

After dispatch, Consigliere keeps supervising while the boss is away or the active turn ends.

On a wake, it drains the queue first, reads the current task state, and then chooses whether to steer, recover, report, or remain quiet.

## Driving it

- `bin/cs-monitor.sh` owns persistent watcher liveness and wake production.
- `bin/cs-watch-checkpoint.sh` owns the one bounded foreground checkpoint per turn.
- `bin/cs-wake-drain.sh` owns durable queue rotation, open-decision folding, and liveness assertions.
- `bin/cs-crew-state.sh` owns current-state reconciliation across Made status, native agent state, and status-log fallback.
- `docs/supervision.md`, `skills/afk/SKILL.md`, and `skills/stuck-soldier-recovery/SKILL.md` own the protocol and recovery procedures.

## Gotchas

- Drain wakes before peeking or steering because a status line is not current-state truth until reconciliation.
- Only one foreground checkpoint is allowed per turn, and a quiet checkpoint is not evidence that a soldier finished.
- Unreadable process or service state fails closed rather than being interpreted as idle, gone, or safe to remove.
