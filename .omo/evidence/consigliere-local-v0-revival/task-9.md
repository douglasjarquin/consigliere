# Task 9 evidence: real Codex execution with bounded context and no native resume

Branch: revival/v0-local-codex.
Base: 24ffea8fa1f5bc983fb5965efab0a89b6116f05b.
Implementation commit: ebcc885bb987acefe82e4bf12b4a672fdf9e9587.

The daemon now builds a canonical Soldier context pack from the Mission and dispatch-bound Attempt identity, including the exact trusted base, workspace ID and generation, fencing generation, fresh invocation ID, allowed operations, checkpoint summary, and explicit current instructions.

The context pack records measured bytes and a conservative input-token estimate, and rejects either a 65,536-byte or 8,192-token overage before dispatch.

The pack filters unknown extras and credential-shaped Mission content, and never carries a capability secret, Boss credential, GitHub credential, daemon secret, transcript, or unbounded tool output.

The Codex adapter runs codex exec --json with explicit model, reasoning effort, sandbox, approval, workspace, pinned executable path, and fresh invocation identity, with native resume unsupported.

The configured CLI version is collected through a bounded direct process invocation and persisted with the Attempt execution policy.

The external runner drains short-lived harness output through a bounded completion barrier before reporting harness exit, while cancellation remains independently bounded.

The daemon loads the configured adapter before testing its decoder, so production Codex JSONL is not silently ignored when the module has not yet been loaded.

JSONL normalization distinguishes semantic, authentication, budget, infrastructure, malformed, truncated, and missing-terminal outcomes, and thread.completed cannot create a second semantic terminal event.

Successful semantic terminal output still requires the existing exact-SHA protocol and verified runner death before the Attempt can become successful.

The private per-Attempt usage ledger stores only system, Project, Mission, Attempt, session, model, effort, CLI version, context hash, timestamp, and bounded input, output, cached-input, and total-token counters.

The runner environment remains scrubbed of CS_HOME, Boss state, SQLite files, GitHub credentials, and unrelated adapter credentials, while CODEX_HOME is owner-only and receives only configured Codex authentication files.

The initial RED characterization was run before the implementation.

    MIX_ENV=test mix test test/consigliere/harness/context_pack_test.exs test/consigliere/harness/codex_test.exs --seed 0
    Result: 11/16 passed; Failed: 5 tests

The RED failures covered missing measured pack fields and token-bound rejection, missing bounded CLI-version discovery, duplicate thread-terminal normalization, and distinct semantic failure classification.

The added credential-redaction and real-process assertions were also run RED before their implementation.

    MIX_ENV=test mix test test/consigliere/harness/context_pack_test.exs test/consigliere/runner_process_codex_test.exs --seed 0
    Result: 3/5 passed; Failed: 2 tests

One failure was the configured Codex decoder path being skipped before adapter loading, and the other was credential-shaped process output remaining in the Attempt log.

The focused daemon validation passed after the implementation.

    docker run --rm -v "$PWD:/repo" -w /repo/daemon elixir:1.20-otp-29 sh -lc 'mix local.hex --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted lib/consigliere/attempts/attempt.ex lib/consigliere/attempts/transitions.ex lib/consigliere/dispatch.ex lib/consigliere/harness/codex.ex lib/consigliere/harness/context_pack.ex lib/consigliere/harness/redaction.ex lib/consigliere/harness/usage_ledger.ex lib/consigliere/runner_process.ex test/consigliere/harness/codex_test.exs test/consigliere/harness/context_pack_test.exs test/consigliere/harness/usage_ledger_test.exs test/consigliere/mission_grant_dispatch_test.exs test/consigliere/runner_process_codex_test.exs support/fixtures.ex priv/repo/migrations/20260829171000_codex_execution_identity.exs && mix compile --force >/dev/null && mix test test/consigliere/harness/codex_test.exs test/consigliere/harness/context_pack_test.exs test/consigliere/harness/usage_ledger_test.exs test/consigliere/harness/events_test.exs test/consigliere/runner_process_codex_test.exs test/consigliere/runner_process_test.exs test/consigliere/runner_process_env_test.exs test/consigliere/mission_grant_dispatch_test.exs --seed 0'
    Result: 34 passed

The process-level manual QA used the normal daemon-side RunnerProcess and the external Go runner with a temporary Codex-compatible JSONL executable.

    docker run --rm -v "$PWD:/repo" -w /repo/daemon elixir:1.20-otp-29 sh -lc 'mix local.hex --force >/dev/null && mix deps.get >/dev/null && mix compile --force >/dev/null && mix test test/consigliere/runner_process_codex_test.exs --seed 0'
    Result: 1 passed

The observed process result was one fresh session with native session ID persisted, one semantic terminal event, a protocol failure because the fixture deliberately omitted an exact checkpoint SHA, a verified terminal Attempt, one bounded usage row with nonzero token counters, and a log free of the credential-shaped fixture.

The dispatch integration test also verified that a normal authorization path persists the context hash, measured pack fields, execution policy, fresh invocation ID, owner-only context file, and byte-for-byte hash match before the runner is live.

The Go runner lifecycle tests passed after the authenticated control-frame correction and bounded stream-drain fix.

    go test ./...
    Result: ok consigliere/cs-runner 39.248s

Adversarial coverage included malformed JSONL, truncated JSONL, missing terminal output, exit-zero without terminal output, nonzero and fatal output, semantic failure, authentication failure, budget failure, duplicate thread completion, oversized byte and token context, credential-shaped Mission content, credential-shaped process output, stale plain control frames, native resume calls, and adapter module load races.

Malformed and truncated JSONL are ruled out from success because normalization emits no terminal event and exit reconciliation produces a distinct lost outcome.

Nonzero and fatal harness exits are ruled out from success because the runner reports the exit status and the Attempt reconciliation requires both a semantic terminal result and the expected exit status.

Prompt injection is ruled out at this boundary because model text is confined to the bounded Mission fields, authority is fixed false, allowed operations are fixed by the daemon, and the adapter does not expose native transcript resume.

Cancel and resume are ruled out as Codex execution inputs because the production adapter rejects native resume and the external runner owns cancellation through its authenticated control channel.

Dirty workspaces and untrusted bases are ruled out here because dispatch reuses the earlier trusted Project and workspace identity verifier before composing or launching the pack.

Hung CLI-version discovery and short-lived output loss are bounded by the version deadline and runner stream-drain deadline, while a process-group termination path remains independently bounded.

Misleading model output cannot mark an Attempt successful because semantic output alone is insufficient without verified death and exact-SHA reconciliation.

Repeated interruption is ruled out from duplicate execution because the existing durable dispatch operation and Attempt identity are reused, and the runner invocation ID is persisted before launch.

No second harness, native Codex transcript resume, legacy Bash supervisor, Made action, GitHub action, push, pull request, merge, telemetry service, full transcript, raw secret, or fixed canary allocation was added.

Temporary Go runner binaries, the Linux test wrapper, and temporary process fixtures were moved to Trash after QA, and no debug instrumentation remains in the source or evidence.

git diff --check passed before commit.
