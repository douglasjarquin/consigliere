# Consigliere feature map

This index is the trusted Made Review guide for Consigliere.

It names the major capabilities, their owners, and the entry points a reviewer needs to follow a change.

Reviewers should follow only the entries relevant to the base-to-input change unless the change requires a full sweep.

## Major capabilities

- [Session start and lock](session-start-lock.md): establish the home, trust boundary, harness, and one-session lock through `bin/cs-session-start.sh` and `bin/cs-lock.sh`.
- [Spawn, steer, and teardown](spawn-steer-teardown.md): create isolated worktrees, send bounded instructions, and remove only safe landed work through `bin/cs-spawn.sh`, `bin/cs-send.sh`, and `bin/cs-teardown.sh`.
- [Supervision](supervision.md): reconcile durable wakes, checkpoints, monitor liveness, and recovery through `docs/supervision.md` and the supervision scripts.
- [Capos](capos.md): seed persistent delegated homes and route capo-owned work through `bin/cs-home-seed.sh` and `skills/capo-provisioning/SKILL.md`.
- [Delivery modes](delivery-modes.md): carry explicit `made`, `direct-PR`, or `local-only` custody from brief to spawn and promotion through `bin/cs-brief.sh`, `bin/cs-spawn.sh`, and `skills/task-lifecycle/SKILL.md`.
- [Boards and Casino](boards-and-casino.md): turn board-ready issues into authorized ship work and keep the Inbox-to-Done factory boundaries through `bin/cs-board.sh`, `skills/contracts/SKILL.md`, and `skills/casino/SKILL.md`.
- [Self-update](self-update.md): fast-forward Consigliere and registered capo homes without touching project clones through `bin/cs-update.sh` and `skills/update-consigliere/SKILL.md`.
- [Knowledge placement](knowledge-placement.md): route operating facts, conditional procedures, reference detail, and exact mechanics to their single owners through `skills/consigliere-coding-guidelines/SKILL.md`.

## Review routing

Every area file uses the same four sections: `Sub-features`, `How to get to it (user POV)`, `Driving it`, and `Gotchas`.

The source of truth for operational-home layout is `docs/configuration.md`.
