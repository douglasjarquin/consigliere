# Code review - latest_review

## Scope

Reviewed `27743a6cd2a7a7fed7c66b134f42b9314225a18f` against `c8d15ef023ee527549e1bde4dd69e2837000489e`.

Changed paths inspected: `AGENTS.md`, `bin/cs-board.sh`, `docs/configuration.md`, `skills/casino/SKILL.md`, and `tests/cs-board.test.sh`.

No tests were run, per the assigned read-only review scope.

## Findings

### CRITICAL

None.

### HIGH

1. `bin/cs-board.sh:160-165` permits dispatching a non-Ready role when the configurable `ready-label` aliases `Inbox`, `Backlog`, or `Done`.
   `cmd_start` verifies only that the destination option is distinct from every protected role, then authorizes the move when the card status equals `READY_LABEL`.
   It never verifies that `READY_OPT` is distinct from `INBOX_OPT`, `BACKLOG_OPT`, `DONE_OPT`, or `INPROGRESS_OPT`.
   For example, `project o 7 Backlog In_Progress Status Inbox Backlog` makes an open Backlog card satisfy `current == READY_LABEL` and allows `start` to move it to In Progress, bypassing the documented boss-only Backlog-to-Ready authorization gate.
   The equivalent `Inbox` and `Done` aliases also wrongly permit dispatch from those protected states.
   The existing test at `tests/cs-board.test.sh:159-164` only checks `in-progress-label=Ready`, so it does not cover the source-role aliases.

### MEDIUM

None.

### LOW

None.

## Skill-perspective check

Ran the required `programming` and `remove-ai-slops` review perspectives.

The diff does not introduce unnecessary production parsing, normalization, abstraction, untyped escape hatches, brittle prose assertions, tautological tests, deletion-only tests, or implementation-mirroring tests.
The state-transition test suite uses a fake `gh` boundary and asserts its observable edit arguments, which is appropriate.
The added production script remains below the 250 pure-LOC threshold.
The missing source-role-alias coverage is a correctness gap, not a slop-only concern.

## Verdict

`codeQualityStatus`: BLOCK

`recommendation`: REQUEST_CHANGES

`blockers`:

- Reject `ready-label` aliases to Inbox, Backlog, Done, and In Progress in `cmd_start`, before any item edit.
- Add focused tests for each protected source-role alias, especially `ready-label=Backlog`, proving no edit occurs.
