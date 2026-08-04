# Code review - consigliere harness trust test hygiene

## Review scope

Base: `1269f280a1a8ea479c908e6d889a320459988c0b`.
Target: `a748555c0e66a92226cb0f2edb5425832585a7d1`.
I reviewed the full target range and the follow-up delta from `ff597daf1239021f7139885b793bf6c8d66f294f`.
The supplied `omo ulw-loop status --json` lookup reported `ULW_LOOP_PLAN_MISSING`, so this uses the existing goal-slug fallback artifact path.

## Evidence inspected

I inspected the commit history, full diffs, current line-numbered source, every `cs_test_tmproot` and `cs_test_cleanup` caller, and every test EXIT-trap override.
I also inspected the two tracked `.omo/evidence` files and their committing history.
No tests, shellcheck runs, builds, live lanes, or pipelines were run, as required.
`git diff --check` produced no output.

## Criteria audit

- The Codex launch documentation now accurately says that the bypass flag does not suppress folder trust at `docs/codex.md:17`.
- `tests/lib.sh:64-71` canonicalizes the temporary base and falls back to `/tmp` when the supplied base is invalid or resolves to `/`.
- `tests/lib.sh:84-101` canonicalizes each registry candidate and removes only a single real child of the non-root canonical base.
- `tests/cs-test-lib.test.sh:97-123` covers the base, trailing-slash, dot, and root-`TMPDIR` corrupted-registry cases from a child shell.
- The registry survives command substitution, caller-side EXIT cleanup is installed at source time, and repeated cleanup is a silent no-op after consuming the registry.
- Every reviewed test that replaces the library EXIT trap calls `cs_test_cleanup` from its replacement handler.
- The docs and test updates have no `bin/` changes.
- The tracked `.omo/evidence` files are no-mistakes review artifacts, not product source or behavior changes, so they do not contradict the docs/tests-only implementation criterion.

## Skill-perspective check

Ran: yes.
I loaded and applied the available `omo:remove-ai-slops` and `omo:programming` criteria before judging test relevance and maintainability.
The diff violates neither perspective.
The new child-shell cases test observable EXIT and command-substitution behavior rather than prose, implementation constants, or requested removals.
The minimal candidate normalization is necessary at the untrusted registry boundary and does not add needless parsing, extraction, abstraction, or an untyped escape hatch.

## Findings

### CRITICAL

None.

### HIGH

None.

### MEDIUM

None.

### LOW

None.

## Deliberate behavior not reported

The Codex folder-trust gap and the labelled KNOWN-HOLLOW `idle` wait are explicitly deliberate constraints and are not findings.

## Verdict and risk

`codeQualityStatus`: CLEAR.
`recommendation`: APPROVE.
Risk: low for the reviewed docs/tests changes.

## Blockers

None.
