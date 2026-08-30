# Runtime audit: final watcher follow-up

Reviewed runtime source head: `4e99cf4219998c15b01d23b23349730f27546c61`.

## Boundary audit

The project verifier and native runtime command both check accumulated bytes plus the received chunk size before the normal concatenation path.

Both overflow paths close the port and materialize only a bounded prefix for the returned error.

The ContextPack requires one terminal completion without a preceding checkpoint, and the regression asserts the machine-consumed completion metadata.

The default advisory `attempt.logs` path is authorized but returns only bounded summaries from the fixed durable harness-event allowlist.

Captured free-form log text, private paths, and authority-bearing operations remain unavailable to advisory callers.

## Independent checks

`git rev-parse --verify HEAD` for the runtime source returned `4e99cf4219998c15b01d23b23349730f27546c61` before the evidence-only attestations.

`git branch --show-current` returned `revival/v0-local-codex`.

`git diff --check` passed with exit `0`.

The focused runtime and project verifier command tests passed `7 tests`.

The serial full daemon gate passed `500 tests`, and the current runner and CLI race gates passed.

The rebuilt package passed the real Codex `ready_for_review` transition, authorized event-only Attempt log read, repeated restart and stop, and final residue checks.

The final product-process scan found no daemon, runner, Attempt, or Codex process after the identity-safe stop.

The runner gate returned `ok consigliere/cs-runner 44.122s` with exit `0`, and the CLI gate passed `cli/client` and `cli/service` with exit `0`.

The final temporary package home and package QA directory were moved to macOS Trash with zero return codes and verified absent.

## Adversarial review

The one-chunk overflow regression rules out unbounded iodata retention and flattening in both reviewed command boundaries.

The advisory regression supplies prompt-injection and bearer-shaped log content and verifies that captured text and private paths do not cross the advisory boundary.

Existing tests cover malformed input, stale identity, dirty workspaces, hung commands, cancellation and interruption, duplicate terminal reports, exact-SHA mismatch, and repeated lifecycle interruption.

No retry, native resume, raw transcript, raw log, Boss credential, capability, mirror path, automatic delivery, canary duplicate, or Made mutation was introduced.

## Verdict

PASS for runtime source head `4e99cf4219998c15b01d23b23349730f27546c61`.
