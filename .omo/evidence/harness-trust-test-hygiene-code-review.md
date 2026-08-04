# Code review - harness trust test hygiene

## Review scope

Base: `1269f280a1a8ea479c908e6d889a320459988c0b`.
Target: `a748555c0e66a92226cb0f2edb5425832585a7d1`.
Special post-fix delta reviewed: `ff597daf1239021f7139885b793bf6c8d66f294f..a748555c0e66a92226cb0f2edb5425832585a7d1`.

This was a fresh, read-only source review.
No tests, shellcheck runs, builds, live lanes, or pipelines were run.

`omo ulw-loop status --json` reported `ULW_LOOP_PLAN_MISSING`, so this report uses the required fallback evidence path.

## Evidence inspected

- The complete base-to-target diff and the post-fix delta.
- Current source with line numbers for all changed docs and test files.
- The four commits in the range and the target commit's file list.
- All `cs_test_tmproot`, `cs_test_cleanup`, and EXIT-trap callers in the test suite.
- The two tracked `.omo/evidence` artifacts.

The tracked evidence files were added by target commit `a748555` with subject `no-mistakes(review): Hardened cleanup, added regressions, corrected Codex docs`.
They are pipeline-owned review artifacts, not product or bin changes, and do not contradict the expressly allowed docs/tests-only source scope.
Their older target references and rejected findings are historical evidence, not claims about the present target.

## Skill-perspective check

Ran: yes.
The available `omo:remove-ai-slops` and `omo:programming` skills were loaded and applied before judging test relevance and maintainability.

The diff violates neither perspective.
The child-shell cases test observable EXIT and command-substitution behavior, not prose or implementation constants.
They are not deletion-only, requested-removal-only, tautological, prompt, or implementation-mirroring tests.
The canonicalization and candidate parsing are necessary at the destructive-cleanup boundary and introduce no needless abstraction, untyped escape hatch, or unrelated production complexity.

## Reconstructed behavior

`CS_TEST_TMPBASE` resolves `TMPDIR` physically and falls back to `/tmp` if it cannot resolve or resolves to `/`.
The caller installs the EXIT trap before command substitutions run.
Each command-substitution child appends its `mktemp` result to the shared PID registry.
At cleanup, a candidate must resolve physically to exactly one real leaf beneath the resolved non-root base; the base itself, trailing-slash and dot spellings, traversal spellings, outside paths, and symlink escapes are rejected.
The registry is then removed, making a second cleanup call a no-op.

The new child-shell regressions directly cover the previously missing base canonicalization, root-TMPDIR, base, trailing-slash, and dot cases.

## Findings

### CRITICAL

None.

### HIGH

None.

### MEDIUM

None.

### LOW

None.

## Verdict and risk

`codeQualityStatus`: CLEAR.
`recommendation`: APPROVE.

Risk: low for the reviewed scope.
The deliberate Codex trust-dialog gap and the labelled KNOWN-HOLLOW idle wait were respected as explicit non-findings.

## Blockers

None.
