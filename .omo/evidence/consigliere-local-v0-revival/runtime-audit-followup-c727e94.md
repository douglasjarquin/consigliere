# Runtime audit: watcher follow-up

Reviewed source head: `c727e94ae2bac1be0d3d33fc0005258e5fd850cd`.

## Boundary audit

The command verifier's receive branch checks `byte_size(output) + byte_size(data)` before the normal `output <> data` path.

The overflow branch closes the port and slices only the remaining bounded prefix before building the error result.

The ContextPack completion metadata and instruction agree that a terminal completion is required and a checkpoint must not precede it for the same Attempt.

The default advisory operation list includes only the read-only `attempt.logs` operation, and that result takes a dedicated sanitizer which removes the private path while preserving bounded redacted lines.

Existing advisory mutation and authority-bearing operation denials remain unchanged and green.

## Independent checks

`git diff --check` passed with exit `0`.

`git rev-parse --verify HEAD` returned `c727e94ae2bac1be0d3d33fc0005258e5fd850cd`.

`git branch --show-current` returned `revival/v0-local-codex`.

The changed runtime source files were clean after their implementation commits.

The exact-head daemon, runner, CLI, package, and real Codex lifecycle receipts are in `watcher-followup-c727e94.md`.

The final process scan found no Consigliere daemon, runner, Attempt process, or Codex process after cleanup.

## Adversarial review

The audit covered malformed command output, oversized one-chunk output, prompt-instructed checkpoint-before-completion behavior, unauthorized advisory mutations, private-path leakage, stale runner state, dirty workspaces, hung commands, repeated stop, restart, and exact-SHA mismatch paths through the focused regressions and existing full suite.

No new retry, resume, external mutation, transcript retention, or authority bypass was introduced.

## Verdict

PASS for runtime source head `c727e94ae2bac1be0d3d33fc0005258e5fd850cd`.
