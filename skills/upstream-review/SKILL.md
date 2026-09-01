---
name: upstream-review
description: Review new Firstmate commits since the last-reviewed SHA and propose editorial ports into Consigliere. Use when the boss invokes /upstream-review or asks to check what Firstmate changed, sync with upstream, or port Firstmate improvements. Never merges or cherry-picks; ports are fresh implementations against consigliere's structure.
---

# Upstream review

Consigliere is a personal rewrite of Firstmate.
Upstream improvements arrive by editorial review, never by git merge or cherry-pick, because the codebases share concepts and on-disk formats but not code shape.

## Procedure

0. Before anything else, check for an open PR touching `docs/upstream-review.md`.
   If one exists, the previous batch is not yet on the books: surface that PR to the boss and stop.
   One review batch is in flight at a time, because `last-reviewed:` on the default branch is the only value `bin/cs-upstream-log.sh` reads, and starting a second batch against it would re-triage the previous batch's range.
1. Run `bin/cs-upstream-log.sh` (add `--oneline` first when the backlog of commits is long, then `--stat` for the shortlist).
   If it warns that no `last-reviewed:` SHA exists, seed the tracked ledger `docs/upstream-review.md` with a first line `last-reviewed: <sha>` through the same PR path as step 5; never guess the seed - ask the boss which firstmate commit the port baseline was.
2. Triage every commit against the relevance table below.
   Triage by the PROBLEM the commit fixed, not by whether its diff applies; the diff never applies directly.
3. For each relevant commit, summarize the problem it fixed in one or two sentences and propose exactly one disposition:
   - **port now** - dispatch a soldier on the consigliere repo with a brief that describes the problem and consigliere's own structure; never hand the soldier the firstmate diff as a patch to apply.
   - **backlog** - file a backlog item linking the firstmate commit SHA.
   - **skip** - with the reason (out of scope, already handled differently, dropped subsystem).
4. Present the triage to the boss as one batch (use `lavish-axi` when the batch is large), and act on their dispositions.
5. After the batch is dispositioned, ship the ledger update through the ordinary consigliere-repo delivery path: on a branch, advance the `last-reviewed:` first line of `docs/upstream-review.md` to the newest reviewed SHA, append a dated entry recording the range and each disposition, open a PR, and give the boss the full PR URL.
   The ledger is shared tracked material under `AGENTS.md` section 1: never edit it directly on the default branch, and never treat the review as closed until the boss merges the ledger PR.

## Relevance table

Ignore by path (subsystems consigliere deliberately dropped):
- `bin/backends/tmux.sh`, `zellij.sh`, `orca.sh`, `cmux.sh` and their docs/tests
- `bin/fm-x-*`, `fmx-respond`, X-mode config and docs
- `bin/fm-harness.sh`, `bin/fm-dispatch-select.sh`, `harness-adapters` skill, dispatch-profile config
- `bin/fm-pr-check-migrate.sh` and migration tests
- herdr presentation-spaces / projection code paths
- claude/grok/pi/opencode hook dirs and guard variants (`fm-turnend-guard-grok`, `fm-arm-pretool-*`, `fm-cd-pretool-*`, `fm-continuity-*`, `fm-subagent-*`, `.pi/`, `.grok/`, `.opencode/`)
- `fm-watch-arm.sh` and the arm/continuity layer (consigliere's only wait shape is the foreground checkpoint)

Always relevant, regardless of which harness or backend triggered the fix:
- `bin/fm-teardown.sh` - landed-work proofs (sacred; consigliere ported them near-verbatim)
- `bin/fm-watch.sh`, `bin/fm-classify-lib.sh`, `bin/fm-crew-state.sh` - absorb/surface semantics, verb vocabulary, run attribution
- `bin/backends/herdr.sh`, `docs/herdr-backend.md` - herdr incidents and verified facts (check against consigliere's docs/herdr.md)
- codex facts anywhere (harness-adapters codex section, codex hooks, supervision-protocols/codex.md)
- `bin/fm-pending-reply-lib.sh`, `bin/fm-marker-lib.sh`, `bin/fm-send.sh` - correlation and marker contracts
- `bin/fm-pr-lib.sh`, `fm-pr-check/poll/merge`, `fm-check-*` - poll authentication and merge safety
- `bin/fm-supervise-daemon.sh`, afk skill, `fm-composer-lib.sh` - away-mode and composer-emptiness incidents
- `bin/fm-home-seed.sh`, `fm-config-inherit-lib.sh`, secondmate-provisioning skill - capo-equivalent safety
- `AGENTS.md` contract-language changes and new prime-directive nuances
- `bin/fm-fleet-sync.sh`, `fm-update.sh`, `fm-ff-lib.sh` - sync/update safety
- new tests that encode incident regressions in any always-relevant area

Everything else: judge by the problem statement; when unsure, present it rather than silently skipping.

## docs/upstream-review.md format

```
last-reviewed: <firstmate-sha>

## 2026-07-22 - reviewed <old>..<new> (<n> commits)
- <sha> port-now: <problem summary> -> <task id>
- <sha> backlog: <problem summary> -> <backlog id>
- <sha> skip: <reason>
```
