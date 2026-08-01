---
name: contracts
description: Work a project's GitHub board - pull issues in the Ready column, dispatch soldiers to implement them, and land PRs that close each issue so the board's own workflow moves the card to Done. Use when the boss invokes /contracts, or asks to knock out / clear / work the ready issues on a project, take the open contracts, work the board, or fill lanes from a project board. The boss names a project; consigliere fills up to 3 lanes with independent Ready issues and keeps pulling as lanes free.
---

# Contracts

Board-driven ship work: turn a project's Ready column into landed PRs, hands-off.
Each issue becomes one ship task whose PR carries `Closes #<n>`, so merging closes the issue and the board's built-in "issue closed -> Done" workflow moves the card. Consigliere moves a card only Ready -> In Progress, at dispatch; it never sets Done itself.

This is ordinary section-7 ship lifecycle with a board front door - the safety contract, delivery modes, supervision, and teardown are unchanged. Nothing here overrides a prime directive.

## Preconditions (check once, fast)

1. The project is registered in `data/projects.md` (delivery mode + yolo) and its board is mapped in `data/boards.md`, beside the registry and keyed by the same project name; `docs/configuration.md` owns the mapping line format. If the board mapping is missing, tell the boss the one line they need to add and stop.
2. Run `bin/cs-board.sh check <project>`. It confirms the Ready / In Progress / Done options exist and reminds you the closed->Done workflow must be enabled on the board. If it warns that a `Done` option or the workflow is missing, surface that to the boss before sweeping - with built-in-only Done moves, a missing workflow silently strands cards.
3. Board work needs a PR to close the issue. A `local-only` project cannot close an issue by merge; if the project is `local-only`, tell the boss and confirm they want consigliere to close each issue after the local merge instead, or switch the project to `no-mistakes`/`direct-PR`.

## Sweep

1. Arm the sweep before listing anything: `bin/cs-board-watch.sh arm <project> [--lanes <n>]`.
   This records the boss's standing intent to work that board and arms a poll that reports column depth on the ordinary watcher cadence.
   Without it the sweep exists only in this conversation, and a column that refills after step 2's one listing - a boss promotion into Ready, a lane that frees after this session ends - sits untouched until the boss asks again.
   Pass the boss's explicit lane number when they gave one, so the durable record carries the same cap this sweep runs at.
2. List the ready work: `bin/cs-board.sh ready <project>` -> `<item-id>\t<number>\t<url>\t<title>` per open Ready issue. If empty, tell the boss the column is clear and stop.
3. Read each issue (`gh-axi issue view <n>`) enough to write a real brief: scope, acceptance criteria, and whether it overlaps another issue's subsystem or depends on unlanded work.
4. Order and gate:
   - **Concurrency cap: 3 lanes per project** by default. The boss can override per sweep ("knock out 5 at once"); honor an explicit number.
   - **Serialize only true dependencies.** Same-file or same-subsystem overlap alone does not block concurrent work; queue an issue only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or another concrete condition that makes independent progress or reconciliation unsafe. Independent issues fill the remaining lanes freely.
5. For each issue you dispatch (up to the cap):
   a. Move the card at dispatch: `bin/cs-board.sh start <project> <item-id>` (Ready -> In Progress). Do this only once you are actually spawning the soldier, so the board reflects real work.
   b. Scaffold the brief WITH the issue link: `bin/cs-brief.sh <task-id> <project> --issue <n>`, then replace `{TASK}` with the issue's scope, acceptance criteria, and context. The `--issue` flag bakes in the hard `Closes #<n>` PR requirement; do not remove it.
   c. Spawn: `bin/cs-spawn.sh <task-id> <project-dir> --issue <n> [--model .. --effort ..]` (section 4 chooses model/effort). Use a stable task id derived from the issue, e.g. `<project>-<n>`.
   d. Record the work item in the backlog with the issue link; note any dependents gated by a concrete condition as queued/blocked.
6. Supervise every lane under section 8 (the foreground checkpoint). As a lane finishes and tears down, pull the next Ready/queued issue into it and repeat from step 5 until the column is empty or the boss says stop.
7. When the sweep genuinely ends - the column is clear, or the boss stops it - run `bin/cs-board-watch.sh disarm <project>`. An armed sweep for work nobody intends to do keeps reporting depth that consigliere will not act on. Under `casino` this step does not apply: that skill's factory is standing, and it owns when its sweep ends.

## Board wake

A `check:` wake naming a board sweep carries the project's current Ready and Inbox depth.
The poll reports depth only; it never dispatches, never moves a card, and never judges lane capacity.
Reconcile live lanes with `bin/cs-crew-state.sh`, then resume from step 5 for each free lane, honoring the same cap and true-dependency rules.
Lanes already full is a silent no-op: the sweep is working as intended, and an unchanged fleet is not boss-facing progress.
The poll goes quiet on its own once both columns are clear, and stays quiet while consigliere's own dispatch is what shrank the column, so a wake means work arrived or work has been sitting.

## Landing

- A soldier reports done per its delivery mode (`no-mistakes`: `done: PR <url> checks green`; `direct-PR`: `done: PR <url>`). Arm the merge poll with `bin/cs-pr-check.sh <task-id> <PR url>` and relay the full https URL to the boss.
- On the boss's merge - the only merge authority, `yolo` or not - the PR's `Closes #<n>` closes the issue and the board workflow moves the card to Done. Consigliere does not touch the card.
- After teardown, read-only verify the card is no longer stuck: `bin/cs-board.sh status <project> <item-id>`. If it still reads `In Progress` after the issue is closed, the board's closed->Done workflow is off - warn the boss (with the card and issue) and let them enable it; do not move the card yourself (Done is built-in-only by the boss's choice).
- For a `local-only` project, after the approved local merge, close the issue yourself (`gh-axi issue close <n>`) so the board workflow can still move its card.

## Boundaries

- One card move only, and only to In Progress, and only at real dispatch. Never Ready<-back, never Done, never bulk board edits.
- The issue is closed by the merge, never by hand (except the documented local-only fallback).
- Everything else - isolation, delivery-path rigor, merge authority, teardown landed-work proofs - is the ordinary section-7 contract.
