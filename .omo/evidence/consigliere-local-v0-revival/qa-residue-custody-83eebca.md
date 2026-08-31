# QA residue custody receipt

The final implementation QA created one package prefix at `.tmp/package-final-83eebca` and fresh `/tmp` homes for package-only lifecycle checks.

The package prefix and fresh homes were removed through `/usr/bin/trash` after the lifecycle assertions passed.

The current worktree still contains pre-existing untracked task evidence, scratch databases, build output, credentials in prior temporary homes, and a detached runner artifact.

Those pre-existing artifacts were not created or modified by this final QA pass and were preserved to avoid deleting another worker's state.

No Consigliere daemon, runner, Attempt process, or Codex process remains running from the final QA pass.

This receipt classifies the retained residue and records that only the final pass's own package and homes were removed through the supported safe path.

The subsequent deterministic-order QA pass created `.tmp/package-final-a45cb4b`, which was also removed through `/usr/bin/trash` after its package-only lifecycle assertions passed.

The final reader-bound QA pass created `.tmp/package-final-df939ab`, which was also removed through `/usr/bin/trash` after its package-only lifecycle assertions passed.

The final reader-order QA pass created `.tmp/package-final-bf7a73d`, which was also removed through `/usr/bin/trash` after its package-only lifecycle assertions passed.

The final cap-alignment QA pass created `.tmp/package-final-73d501e`, which was also removed through `/usr/bin/trash` after its package-only lifecycle assertions passed.

The final flake-remediation QA pass created `.tmp/package-final-eb41191`, which was also removed through `/usr/bin/trash` after its package-only lifecycle assertions passed.

The retained pre-existing raw transcript paths are `.omo/evidence/consigliere-local-v0-revival/manual-qa-1a76188e/real-codex-tmux-transcript-*.raw`.

The retained pre-existing canary state paths are `.tmp/task15-canary/mission.json`, `.tmp/task15-canary/authorize.json`, and `.tmp/task15-canary/home-fixed/credentials/{advisory,boss}`.

The retained pre-existing detached runner path is `runner/cs-runner/detached-bootstrap-child`.

These paths were not created by the final QA passes and were preserved under the task's concurrent-worktree custody rule.

## Exact retained-residue inventory at delivery head 4547d4d

The untracked inventory was captured with `git ls-files --others --exclude-standard` from delivery head `4547d4d2718d3e5070b70757a04c3315bebf8157`.

The manifest contained `24954` paths and had SHA-256 `249dc4186707c5322a90d53ac26fce1b786a3aa8c5cfbd663347f47aeaf8b084`.

The retained categories were `.tmp/package-*` with `23983` paths, `.tmp/attempt-report-*` with `653` paths, `.tmp/task15-canary/*` with `18` paths, other `.tmp/*` with `138` paths, `.omo/evidence/*` with `147` paths, `.omo/ulw-notepad*` with `1` path, `cli/.tmp/*` with `2` paths, `runner/cs-runner/detached-bootstrap-child` with `1` path, `_build/*` with `8` paths, `.debug-journal.md` with `1` path, `AGENTS.md` with `1` path, and `CLAUDE.md` with `1` path.

The retained residue occupied `1.9G` in `.tmp`, `13M` in `.omo/evidence`, `9.8M` in `cli/.tmp`, `4.0K` in the detached runner artifact, and `48K` in `.debug-journal.md`.

The exact final QA prefix `.tmp/package-final-eb41191` was absent and had zero remaining untracked paths.

The retained categories predated the final flake-remediation QA pass and were not modified by it.

The two additional untracked evidence paths since the prior inventory were `.omo/evidence/consigliere-local-v0-plan-compliance-gate-review.md` and `.omo/evidence/consigliere-local-v0-revival/final-read-only-manual-qa.md`.

Those two paths are handoff-review artifacts, are not product inputs, and remain untracked pending the final custody decision.

The retained zero-byte runtime lock paths `.tmp/attempt-report-home-fixed/lock`, `.tmp/attempt-report-home/lock`, and `.tmp/task15-canary/home-fixed/lock` were checked with `lsof` and had no owning process.

They predated the final flake-remediation QA pass and were not created or modified by it, so they remain classified residue rather than being deleted by this worker.

Only the final pass's `.tmp/package-final-eb41191` prefix and its fresh temporary lifecycle homes were owned by that pass, and those were moved through `/usr/bin/trash` after cleanup assertions passed.

The inventory and cleanup checks produced no Consigliere daemon, `cs-runner`, or `cs-attempt` process from the final QA pass.
