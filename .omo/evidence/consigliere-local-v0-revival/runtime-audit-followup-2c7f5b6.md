# Runtime audit: security-aligned watcher follow-up

Reviewed source head: `2c7f5b67c8d37737d8f2dd3e0f7110687a800748`.

## Boundary audit

The command verifier checks the accumulated and received command-output byte sizes before the normal concatenation path and slices only the bounded prefix on overflow.

The ContextPack completion contract requires a terminal result without a preceding checkpoint and its regression asserts the machine-consumed metadata only.

The default advisory operation list includes the documented read-only `attempt.logs` operation.

The advisory log projection discards captured free-form lines, omits the private path, limits output to the collection bound, and emits only event summaries whose sequence and type match the fixed durable event allowlist.

Authority-bearing advisory mutations remain denied before mutation.

## Independent checks

`git rev-parse --verify HEAD` returned `2c7f5b67c8d37737d8f2dd3e0f7110687a800748`.

`git branch --show-current` returned `revival/v0-local-codex`.

`git diff --check` passed with exit `0`.

The focused watcher suite passed `31 tests`.

The serial full daemon gate passed `499 tests`, and the current runner and CLI race gates passed.

The rebuilt package and real Codex lifecycle passed the terminal projection, structured default log read, repeated restart, repeated stop, and final residue checks.

The final process scan found no product daemon, runner, Attempt, or Codex process.

## Adversarial review

The advisory regression supplied prompt-injection text and a bearer-shaped secret in the captured log and observed neither in the response.

The audit also covered malformed input, output overflow, stale runner state, dirty workspaces, hung commands, cancellation and interruption, duplicate terminal reports, exact-SHA mismatch, private-path leakage, and repeated lifecycle interruption through the focused and inherited suites.

No raw log, transcript, Boss credential, capability, mirror path, retry, resume, automatic delivery, or canary duplication was introduced.

## Verdict

PASS for runtime source head `2c7f5b67c8d37737d8f2dd3e0f7110687a800748`.
