# Code review - consigliere harness trust test hygiene

## Review scope

Base: `1269f280a1a8ea479c908e6d889a320459988c0b`.
Target: `ff597daf1239021f7139885b793bf6c8d66f294f`.
Changed files inspected: `docs/claude.md`, `docs/codex.md`, `docs/herdr.md`, `tests/cs-lifecycle-claude-live.test.sh`, `tests/cs-lifecycle-live.test.sh`, `tests/cs-test-lib.test.sh`, and `tests/lib.sh`.
The required `omo ulw-loop status --json` lookup reported `ULW_LOOP_PLAN_MISSING`, so this fallback path uses the target branch goal slug.

## Evidence inspected

I inspected the full range diff, each changed source file with current line numbers, the three commits in the range, the shared test-library call sites, EXIT-trap overrides, the portable test runner, and CI registration.
`git diff --check 1269f280a1a8ea479c908e6d889a320459988c0b ff597daf1239021f7139885b793bf6c8d66f294f` was clean.
`tests/cs-test-lib.test.sh` is selected by default as a portable test through `bin/cs-test-run.sh`.
No tests, shellcheck runs, builds, live lanes, or pipelines were run, as required by the assignment.

## Skill-perspective check

Ran: yes.
I loaded and applied the available `omo:remove-ai-slops` and `omo:programming` skill criteria before judging test relevance and maintainability.
The diff does not add deletion-only tests, tautological tests, brittle prompt tests, untyped escape hatches, unnecessary production parsing, or needless abstraction.
The new child-process tests are appropriate because EXIT-trap and command-substitution behavior is only observable at shell-process exit.
The diff does violate the required safe-boundary perspective: its registry validation claims to accept only minted paths but accepts arbitrary paths under the shared temporary parent.

## Findings

### CRITICAL

None.

### HIGH

- HIGH - auto-fix - `tests/lib.sh:84-90`, with inadequate coverage at `tests/cs-test-lib.test.sh:97-109`: `cs_test_cleanup` accepts any nonempty path below `CS_TEST_TMPBASE` that contains no `..`, then calls `rm -rf` on it.
  For the normal `TMPDIR=/tmp`, a corrupted registry line `/tmp/unrelated-existing-dir` passes both guards even though `cs_test_tmproot` never minted it.
  This contradicts the stated and authoritative contract that cleanup removes only minted paths and lets a corruptible, predictable registry delete another test or process's temporary directory.
  The regression only proves that paths outside `TMPDIR` and the base itself survive, so it gives false confidence while missing the failing in-boundary sibling case.
  Record minted roots in a private, per-process directory or authenticate/validate each exact minted path, create the registry safely, and add a child-shell regression showing that an unrelated preexisting sibling below `TMPDIR` survives.

### MEDIUM

None.

### LOW

- LOW - auto-fix - `docs/claude.md:4-8`, `docs/claude.md:83-109`, and `docs/herdr.md:56-62`: the newly added empirical documentation uses placeholders and ellipses such as `<isolated>` and `...` instead of the required exact dated commands and recorded output.
  This makes the claimed re-verification non-reproducible from the artifact and misses the stated documentary style requirement.

## Deliberate containment respected

I did not report the Codex trust-dialog gap, the labelled KNOWN-HOLLOW idle wait, or per-run Codex trust entry as defects because the authoritative intent explicitly excludes them.
The Claude wait changes consistently use `done` after the turn-ended signal and do not alter production control flow.
The Codex post-steer wait is changed from a masked `idle` timeout to `done`, which is within the stated scope.

## Verdict and risk

`codeQualityStatus`: BLOCK.
`recommendation`: REQUEST_CHANGES.
Risk: high for cleanup safety and cross-test/process interference until the registry can prove a recorded path was minted rather than merely located under `TMPDIR`.

## Blockers

- Make `tests/lib.sh` reject unregistered sibling paths under `TMPDIR` before `rm -rf`, and add a regression that proves this case.
