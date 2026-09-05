# Delivery modes

## Sub-features

- `made` runs the gated validation path through a PR and leaves merge authority with the boss.
- `direct-PR` pushes and opens a PR without the Made pipeline.
- `local-only` uses guarded local landing and cannot close a board issue through a merged PR.
- Yolo posture changes routine decision handling but never transfers merge authority.

## How to get to it (user POV)

Give Consigliere the requested work and its project context, then the task intake records the explicit mode and posture before dispatch.

For a board issue, the PR path carries the issue-closing keyword so the board's built-in workflow can move the closed issue to Done.

## Driving it

- `bin/cs-project-mode.sh` reads the registered project posture and closed mode set.
- `bin/cs-brief.sh`, `bin/cs-spawn.sh`, and `bin/cs-promote.sh` carry and cross-check per-task delivery fields.
- `skills/task-lifecycle/SKILL.md` owns intake, validation, handoff, and landing custody.
- `.made.yaml` owns this repository's Made review, CI, lint, and evidence policy.

## Gotchas

- A mode is not silently re-derived from the project registry after the task contract is written.
- Made review agents must not load Consigliere's fleet-supervisor identity from project settings.
- No delivery mode permits an autonomous merge, and a red PR remains unmergeable.
