# Spawn, steer, and teardown

## Sub-features

- Ship and scout tasks receive isolated herdr worktrees and task-scoped durable records.
- Steering sends a bounded instruction to the existing task owner without creating a duplicate soldier.
- Teardown removes a worktree only after landed-work and ownership checks pass.
- Recovery handles dead, stale, or workspace-less soldiers without discarding unlanded work.

## How to get to it (user POV)

Describe the project work in plain language and Consigliere creates the brief, spawns the soldier, supervises the result, and reports the review-ready commit.

When a soldier needs input, use the task's existing steer path and wait for its semantic status instead of launching another worker.

## Driving it

- `bin/cs-brief.sh` writes the task contract and delivery mode before a ship spawn.
- `bin/cs-spawn.sh` creates the task worktree, metadata, and inherited harness launch.
- `bin/cs-send.sh` is the guarded steer and decision-answer entry point.
- `bin/cs-teardown.sh` owns landed-work verification and cleanup of the task worktree.
- `skills/task-lifecycle/SKILL.md` and `skills/stuck-soldier-recovery/SKILL.md` own lifecycle and recovery decisions.

## Gotchas

- A terminal pane is not semantic completion until the task has a report, commit, PR, or explicit failure evidence.
- Never tear down unlanded work or bypass a refusal with a force option without the boss's concrete authority.
- A task's delivery mode and yolo posture are per-task contract fields and must agree across brief, spawn, and promotion.
