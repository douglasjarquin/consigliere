# Spawn, steer, and teardown

How consigliere dispatches a worker into an isolated copy, talks to it, and cleans up only after the work has landed.

## Sub-features

- brief then spawn: write the task-specific brief before launch; spawn creates an isolated herdr worktree distinct from the project's local copy.
- ship vs scout: a ship changes a project; a scout writes `data/<id>/report.md` and never opens a PR.
- steer: one-line messages through fail-closed send; long instructions go in a file.
- lifecycle control: interrupt, exit, and relaunch only through the verified control helper, never by typing those as chat.
- teardown: remove the isolated copy and pane only after landed-work proof, or after a scout report exists and the unresolved-decision gate passes.

## How to get to it (user POV)

The boss asks for work on a named project.
Consigliere classifies it, writes instructions, and a worker appears in an isolated copy of that project.
The boss hears outcomes, not the worker's chat.
Cleanup happens after the PR is merged or the local branch is landed, never while unlanded work still sits in that copy.

## Driving it

- `skills/task-lifecycle/SKILL.md` owns intake, dispatch, validation, and landing.
- `bin/cs-brief.sh` scaffolds the brief; `bin/cs-spawn.sh` launches; `bin/cs-send.sh` steers; `bin/cs-control.sh` owns interrupt/exit/relaunch; `bin/cs-teardown.sh` owns cleanup.
- `bin/cs-promote.sh` turns a finished scout into a ship on the same id rather than duplicating the task.

## Gotchas

- A ship that launched in the project's primary local copy must stop; isolation is a hard assertion, not a preference.
- Spawn, brief, and promotion must state the same delivery mode and yolo posture; a mismatch is refused rather than launched.
- Never `--force` teardown or bypass a landed-work refusal without explicit discard authority.
- Workers never address the boss; a boss message that lands in a worker pane is still authoritative and is reconciled at the next check-in.
