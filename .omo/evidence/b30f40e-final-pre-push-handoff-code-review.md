# Code review - b30f40e final pre-push handoff

## Decision

Code quality status: WATCH.
Recommendation: APPROVE.

There are no CRITICAL or HIGH findings and no blocker to pushing the reviewed candidate.

## Reviewed target and scope

- Immutable HEAD: `b30f40e10dee9513403aeff14b03fba79f27ee9a`.
- Runtime parent: `d63f2390944a534f4746c64ef60e43332fd546c3`.
- Branch: `revival/v0-local-codex`.
- `b30f40e` is an evidence-only child: its parent diff changes 16 documentation and evidence files and no `daemon`, `cli`, `runner`, `scripts`, or workflow path.
- The runtime correction is `0c2b24c..d63f239`: `Away.mark/1`, `Away.return/1`, the focused Away test, and removal of the temporary `DatabaseWriter.serialize/2` escape hatch.
- `git diff --check` passed for both reviewed ranges, the runtime parent is an ancestor of HEAD, and HEAD's tree matches the requested commit tree.

## Verified behavior

- `Away.mark/1` locks the marker write and cursor upsert under `:global.trans({{Consigliere.Away, Path.expand(home)}, self()}, fun)` at `daemon/lib/consigliere/away.ex:27-34,76-78`.
- `Away.return/1` builds and bounds the digest before taking that lock, then locks only acknowledgement plus token-checked marker removal at `daemon/lib/consigliere/away.ex:41-68`.
- The return path keeps the existing monotonic cursor update and stale-marker result handling at `daemon/lib/consigliere/away.ex:185-229`.
- `DatabaseWriter.serialize/2` is absent from the reviewed tree. The normal `DatabaseWriter.transaction/2` is retained at `daemon/lib/consigliere/database_writer.ex:31-37`.
- No temporary hook or test-only production control was found in the reviewed Away and writer paths.
- All references to `0c2b24c` in the changed F1-F4, final evidence, final receipt, and canary document are explicitly historical or superseded. Current claims name `d63f239`.

## Test and evidence review

- The new test at `daemon/test/consigliere/away_cursor_test.exs:160-208` uses a real global-lock holder and two real `Away.mark/0` tasks, then checks cursor/marker agreement after release. It is relevant and not deletion-only, tautological, implementation-constant mirroring, or a prompt test.
- Independent execution: `MIX_ENV=test mix test test/consigliere/away_cursor_test.exs --seed 0..9` passed all ten seeds, with 7 tests per seed and no failures.
- The five committed d63 receipts were inspected directly: focused Away, daemon gate, Go gates, package artifact, and installed lifecycle. Because the runtime/package surface is unchanged from `d63f239` to HEAD, those receipts remain applicable to this evidence-only child.
- The package and installed lifecycle were not rerun because that would write build/package output or start lifecycle processes, outside this read-only handoff review.

## Skill-perspective check

The required `omo:remove-ai-slops` and `omo:programming` skills were loaded and applied before judging test relevance and maintainability.

The production diff violates neither perspective: it adds no parsing or normalization beyond the required home expansion for lock identity, no needless abstraction, no untyped escape hatch, and no temporary API or hook.

The test violates neither perspective at HIGH severity, but has the MEDIUM determinism concerns below.

## Findings

### CRITICAL

None.

### HIGH

None.

### MEDIUM

1. `daemon/test/consigliere/away_cursor_test.exs:195-197` uses `refute_receive :away_mark_finished, 100` as the proof that both callers are blocked.
   A task delayed before attempting the lock can make this timed negative assertion pass even if the lock were ineffective.
   The real lock-holder setup and post-release durable-state assertions make the test relevant, but this is not fully deterministic synchronization and can provide false confidence.

2. `daemon/config/test.exs:3` uses a shared fixed test home, `/tmp/consigliere-daemon-test-home`.
   The inspected prior focused-run record documents `Home.Lock :already_running` when another QA process used that path.
   This is an existing suite-isolation defect, not a runtime regression introduced by d63, but it weakens repeatability of the new concurrency regression across concurrent worktrees.

### LOW

None.

## Blockers

None.

## Verdict

PASS with WATCH-level test-harness follow-up.
