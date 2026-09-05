# Consigliere feature map

This index is a trusted Review guide (`review.guides`).
It names the major capabilities and the scripts, skills, or docs that own them.
Follow only the entries relevant to the base-to-input change unless the change is a full sweep.
Do not paste `AGENTS.md` into a review note or a second copy of a contract.

Documentation placement for this repo lives in [knowledge-placement.md](knowledge-placement.md).
That file points at `skills/consigliere-coding-guidelines/SKILL.md`, which owns the decision tree.

## Session, fleet, and workers

- [session-start-and-lock.md](session-start-and-lock.md): one session-start digest, the per-home lock, and the read-only path when the lock is refused.
- [spawn-steer-teardown.md](spawn-steer-teardown.md): dispatch a worker, steer it, and clean up only after the work has landed.
- [supervision.md](supervision.md): one bounded wait per turn, durable notifications, and the persistent watcher.

## Persistent helpers and delivery

- [capos.md](capos.md): persistent isolated helpers with a charter, idle by default.
- [delivery-modes.md](delivery-modes.md): `made`, `direct-PR`, and `local-only`, plus who may land the work.

## Boards and self-update

- [boards-and-casino.md](boards-and-casino.md): Ready-column ships and the Inbox-to-Backlog factory in front of them.
- [self-update.md](self-update.md): fast-forward this repo and registered capo homes from origin.

## Knowledge

- [knowledge-placement.md](knowledge-placement.md): where a new fact belongs, and the review checks for tracked Markdown.

## Entry contract

Every feature file uses the same four H2s:

- `Sub-features`
- `How to get to it (user POV)`
- `Driving it`
- `Gotchas`

Keep new entries behavior-level and short.
Name the owning script, skill, or doc rather than restating it.
