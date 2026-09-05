# Delivery modes

How a ship task lands: the closed mode set, the orthogonal yolo posture, and the rule that the boss always lands the work.

## Sub-features

- `made`: the Made pipeline owns review through a green PR, then waits for the boss's merge decision.
- `direct-PR`: the worker pushes and opens a PR without the pipeline, then waits for the same merge decision.
- `local-only`: the worker stops on a clean ready branch; consigliere fast-forwards only after the boss approves.
- yolo: who answers a routine in-task decision, never who merges.
- ask-user: consigliere decides only within accepted intent; load `ask-user-authority` before any such decision.

## How to get to it (user POV)

The boss asks for a project change.
Consigliere picks a delivery path at intake and says so in the worker's instructions.
The boss still says the word before any PR merges or any local branch lands on main, including when yolo is on and including when the boss is away.

## Driving it

- `bin/cs-delivery-lib.sh` owns the closed set `made|direct-PR|local-only` and the brief's `Delivery contract:` line.
- `bin/cs-dod-lib.sh` renders the mode-specific definition of done for briefs and promotions.
- `skills/task-lifecycle/SKILL.md` owns when to pick which path; `skills/ask-user-authority/SKILL.md` owns routine vs expanding decisions.
- `bin/cs-pr-merge.sh` and `bin/cs-merge-local.sh` are the only landing helpers.

## Gotchas

- A missing or mismatched `--mode` / `--yolo` between brief and spawn is a refusal, not a default.
- Never merge a red PR; no instruction waives that.
- Complexity alone is not contract expansion; a hard fix required by accepted intent stays in the current task.
- Do not invent a manual review gate on a faster path; escalate whether to use `made` instead.
