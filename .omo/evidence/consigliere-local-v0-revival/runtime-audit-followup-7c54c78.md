# Runtime audit follow-up at exact source head

Date: 2026-08-30.

Target source head: `7c54c782552f3ee5a09ddee35735e90cba1b9339` on `revival/v0-local-codex`.

The preceding runtime audit at source head `71593738cf6aae723c9208743405fa12a9dc7a03` was BLOCKED by five concrete findings.

The findings and their RED-to-GREEN closure are:

| finding | RED proof | GREEN boundary |
| --- | --- | --- |
| An incompatible ignored packaged runner was selected on macOS. | `runner_launcher_test.exs` replaced the packaged runner with an invalid ELF file and observed the old selection path reach the control-socket timeout. | `RunnerLauncher` validates native Mach-O or ELF magic and the current CPU architecture before accepting a packaged runner, then uses the source build path when the package is stale or incompatible. |
| Missing workspace and fencing generations were accepted by inventory verification. | `runtime/inventory_test.exs` supplied an incomplete manifest and observed the old verifier accept it. | Inventory now requires nonempty workspace generation, fencing generation, runner start fingerprint, and harness start fingerprint, with a focused rejection test. |
| A terminal Attempt could leave a live RunnerProcess registered and suppress reconciliation. | `reconciler_persist_test.exs` created a terminal Attempt with a live RunnerProcess and observed the old liveness shortcut skip cleanup. | Reconciliation reads durable Attempt status, terminates a live terminal RunnerProcess, and does not treat terminal Attempts as live work. |
| Darwin process observers used unbounded `System.cmd` calls. | `runtime/command_test.exs` supplied a hung native observer and observed the old observer lack a bounded return. | `Runtime.Command` uses bounded native ports with output limits and timeout handling, and process-group and process-identity observers use it. |
| Daemon and harness identity lacked a start fingerprint. | `runtime/process_identity_test.exs` supplied a live PID with a mismatched start fingerprint and observed the old identity path accept it. | Process identity verifies a platform start fingerprint from Linux `/proc` or absolute Darwin `ps`, and the runner records both runner and harness fingerprints in its manifest. |

The focused RED commands returned the expected old behavior or undefined helper failures before implementation.

The focused GREEN boundary slice passed `35` daemon tests, including incompatible-runner, generation, bounded-command, process-start, inventory, and reconciliation cleanup coverage.

The full authoritative Linux gate passed format, warnings-as-errors compilation, and `496 passed (1 doctest, 495 tests)` in three consecutive seed-0 runs.

The native macOS daemon gate passed the complete `496`-test suite.

The CLI and runner Go gates passed formatting, vet, ordinary tests, race and shuffle tests, and builds.

The exact-head package built native arm64 product executables and the installed lifecycle passed in `package-artifact-7c54c78.md` and `installed-lifecycle-7c54c78.md`.

The runtime audit did not create a Mission, Attempt, Codex process, FirstMate duplicate, PR, merge, or Made-daemon action.

The selected real canary remains the single operator-controlled naturally occurring Mission recorded in `task-15.md` and `docs/v0-canary.md`.

Verdict: the five preceding runtime blockers are closed by tests and full-process evidence; a fresh final review still binds the final delivery verdict.
