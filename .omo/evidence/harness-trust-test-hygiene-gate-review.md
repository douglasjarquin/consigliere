# Final gate security review

recommendation: REJECT

## Original intent

Deliver exactly the three named docs-and-tests fixes without bin changes or redesign.
For the cleanup fix, replace the subshell-lost array with a caller-visible file registry, install cleanup in the caller, remove only minted paths under `TMPDIR`, reject corrupted registry paths with an empty leaf or traversal, and remain idempotent.

## Desired outcome

The live suites truthfully reflect Claude and Codex post-turn behavior while preserving the expressly accepted Codex trust-dialog gap.
Test temp roots are reliably removed without allowing registry corruption, hostile path input, collisions, or symlinks to cause destructive cleanup or writes outside the test temp boundary.

## User outcome review

The Claude/Codex status changes and documentation remain within the stated docs/tests scope, and the intentional Codex KNOWN-HOLLOW behavior is not treated as a defect.
The temp registry now survives command substitution, but the shipped cleanup boundary is unsafe for two reachable path classes.
The branch therefore does not satisfy the explicit safe-cleanup criterion.

## Blockers

### SEC-1 - HIGH - auto-fix

- violatedCriterion: Cleanup removes only minted paths under `TMPDIR`, with nonempty leaf and no traversal, even when registry input is corrupted or untrusted.
- observation: `TMPDIR=/` becomes an empty `CS_TEST_TMPBASE` after trailing-slash removal, so the allowlist pattern becomes `/?*` and accepts every non-root absolute path.
- reachability: A corrupted registry line `/etc` passes both cases and reaches `rm -rf "/etc"` because `/etc` contains no `..`.
- evidencePointer: `tests/lib.sh:64-66`, `tests/lib.sh:83-90` at target `ff597daf1239021f7139885b793bf6c8d66f294f`.
- testGap: `tests/cs-test-lib.test.sh:89-109` checks hostile lines only under the process's ordinary non-root temp base, so it does not exercise the root-normalization collapse.

### SEC-2 - HIGH - auto-fix

- violatedCriterion: Corrupted/untrusted registry input and collisions must not create a reachable security or destructive-cleanup risk.
- observation: The registry is a predictable pathname in a shared temp directory and is opened for append without exclusive creation or symlink rejection.
- reachability: Another local process can pre-create `cs-test-reg.<victim-pid>` as a symlink to any victim-writable file; `printf >> "$CS_TEST_REGISTRY"` then appends the minted temp path to that file.
- secondaryRisk: Cleanup also follows that symlink for `[ -f ]` and input redirection, allowing attacker-selected contents under the accepted temp prefix to drive `rm -rf`; final `rm -f` removes only the symlink.
- evidencePointer: `tests/lib.sh:66`, `tests/lib.sh:78-92`, `tests/lib.sh:97-98` at target `ff597daf1239021f7139885b793bf6c8d66f294f`.
- testGap: `tests/cs-test-lib.test.sh:51-59` checks ordinary registry consumption but has no collision, pre-existing-file, or symlink case.

## Risk assessment

Overall risk: HIGH.
The affected code is test infrastructure, but it executes `rm -rf` automatically from a file explicitly treated as untrusted.
SEC-1 enables broad deletion under an allowed environment value.
SEC-2 enables writes outside the temp boundary and can steer cleanup through a predictable shared-temp registry.

## Direct slop and programming pass

The production/test diff was inspected directly for excessive or useless tests, deletion-only tests, requested-removal-only tests, tautologies, implementation mirroring, and unnecessary extraction/parsing/normalization.
The six child-shell tests are behavior-oriented and materially cover command-substitution registration, EXIT behavior, idempotence, and ordinary corrupted input.
They are not deletion-only or requested-removal-only tests.
However, the corrupted-registry test overstates safety because it omits the two boundary classes above, creating false confidence against the stated security criterion.
The new registry parsing is necessary, but its string-prefix validation is incomplete because the base is not canonical/nonempty and the registry file is not securely minted.
No unrelated production extraction or scope drift was found.

## Checked artifacts

- Worktree: `/Users/douglasjarquin/.no-mistakes/worktrees/cb19a45d4913/01KZ6KCQ2NV913H3NYGAZ85E5T`
- Base: `1269f280a1a8ea479c908e6d889a320459988c0b`
- Target: `ff597daf1239021f7139885b793bf6c8d66f294f`
- Changed files: `docs/claude.md`, `docs/codex.md`, `docs/herdr.md`, `tests/cs-lifecycle-claude-live.test.sh`, `tests/cs-lifecycle-live.test.sh`, `tests/cs-test-lib.test.sh`, `tests/lib.sh`
- Commit history: `385f740`, `d7a01fe`, `ff597da`
- Parent implementation: `tests/lib.sh` at base revision
- Direct diff and current target source for all seven changed files
- `omo ulw-loop status --json`: no plan exists, so the required fallback evidence path was used
- `git diff --check`: inspected and produced no output
- `omo:programming` and `omo:remove-ai-slops` skill criteria

## Exact evidence gaps

- No executor evidence artifact path was supplied or found.
- No code review report artifact path was supplied or found, so there is no report-level confirmation of the required skill-perspective and overfit/slop coverage.
- No manual QA matrix artifact path was supplied or found.
- No notepad path was supplied or found.
- Tests, shellcheck, live lanes, builds, and pipeline controls were not run, exactly as the assignment prohibited.
- The missing reports are not independent blockers because the direct source review proves the two criterion failures above.

## Notes

- The deliberate Codex folder-trust gap, KNOWN-HOLLOW idle wait, and per-run trust entry were accepted constraints and were not reported as findings.
- No finding was raised for architecture taste, hypothetical hardening, pipeline delivery, or pre-existing behavior.
