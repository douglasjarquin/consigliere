# Task 6 evidence: minimal per-Attempt capability scopes

Plan item: #132, `Enforce minimal per-Attempt capability scopes`.

Branch: `revival/v0-local-codex`.

Base: `24ffea8fa1f5bc983fb5965efab0a89b6116f05b`.

The RED characterization first extended the capability test with the closed operation set, durable generation fields, workspace binding, mint validation, and malformed-scope rejection.

Before implementation the focused run reported `Result: 3/7 passed` with four expected failures.

The Attempt capability schema now stores a durable generation, Workspace ID, Workspace lease generation, issuance time, expiry, revocation state, exact Attempt and Mission IDs, the fencing token, and a hash of the secret.

Capability minting validates the closed V0 worker operation set, rejects unknown or privileged operations, revokes an older generation, and records only bounded identity metadata in the event log.

The exact worker operation set is:

```text
ping
mission.get_own
attempt.progress
question.open
attempt.checkpoint
attempt.complete
attempt.fail
```

Authentication preserves capability ID, generation, Attempt, Mission, Workspace, lease, fence, allowlist, and expiry metadata in the request actor.

Authorization intersects the server maximum, durable allowlist, current Attempt and Mission state, current Workspace lease, current fence, and request scope before the operation writer runs.

Declared capability, generation, Attempt, Mission, Workspace, Workspace generation, and fencing generation fields are rejected when missing where required, conflicting, altered, stale, or supplied only by a mismatched caller declaration.

Attempt mutations revalidate the durable capability inside the serialized writer boundary, so an already-authenticated actor cannot mutate after explicit revocation, generation replacement, fence replacement, or terminal state.

Progress, Question, checkpoint, completion, and failure reports are bound to the authenticated Attempt and remain reports until the later verified-death reconciliation makes a terminal decision.

Cancellation, supersession, checkpoint finalization, fencing replacement, spawn failure, loss, completion, and failure revoke the capability before changing the corresponding durable Attempt state.

The context pack and runner protocol document the exact worker operations and reporting rules without adding Boss, GitHub, source-repository, or daemon-owner authority.

Required capability suite:

```text
docker run --rm -v "$PWD:/workspace" -w /workspace/daemon elixir:1.20-otp-29 sh -lc 'mix local.hex --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix test --no-color test/consigliere/capabilities_test.exs test/consigliere/capabilities_chaos_test.exs test/consigliere/capabilities_security_test.exs'
Result: 15 passed
```

The context-pack protection characterization was included in the post-change run:

```text
Result: 17 passed
```

The full daemon gate ran in a Linux container with Go installed because the existing daemon runner tests build the external runner during test setup.

```text
docker run --rm -v "$PWD:/workspace" -w /workspace/daemon elixir:1.20-otp-29 sh -lc 'apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && mix local.hex --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test --no-color'
Result: 405 passed (1 doctest, 404 tests)
```

The CLI and runner Go gates passed with formatting, vet, normal tests, race tests, and builds.

```text
cli: go test ./... and go test -race -shuffle=on -count=1 ./... passed; go vet ./... and go build ./cmd/cs ./cmd/csd passed
runner/cs-runner: go test ./... and go test -race -shuffle=on -count=1 ./... passed; go vet ./... and go build ./... passed
```

The real manual QA started the Elixir application, migrated a fresh SQLite home, and connected to the live Unix API socket as an authenticated capability client.

It exercised every operation in the seven-operation set, then replayed progress with a tampered Workspace generation and after revocation.

The context pack was checked for the exact operation set and the capability secret was absent from its encoded bytes.

```text
ping=pass
mission.get_own=pass
attempt.progress=pass
question.open=pass
attempt.checkpoint=pass
attempt.complete=pass
attempt.fail=pass
tampered_scope=unauthorized
revoked_scope=unauthorized
context_pack_secret_scan=clean
task6_manual_qa=pass
```

The first manual process attempt stopped before product behavior because the fresh test database had not been migrated and the EventBus could not start.

The corrected process run used `MIX_ENV=test mix ecto.create` and `MIX_ENV=test mix ecto.migrate` before starting the application and passed.

The capability migration was also exercised through an up, rollback, and up cycle in a disposable SQLite database.

Adversarial coverage included unknown and privileged mint operations, malformed stored allowlists, one-operation allowlists, cross-Attempt and cross-Mission requests, altered capability IDs, capability generations, Attempt IDs, Mission IDs, Workspace IDs, Workspace generations, fencing generations, explicit revocation, terminal failure, new-generation revocation, prompt-injection regression coverage, and concurrent revoke/report scheduling.

Database and event assertions found no raw capability secret, and the bounded context-pack scan found no reusable secret.

Dirty Git workspaces, hung commands, runner process-group termination, daemon restart, native resume, and repeated OS interruption are ordered into later tasks and were not claimed by this task.

No Boss, GitHub, source-repository, daemon-owner, Made, remote-worker, transcript, telemetry, PR, push, merge, or automatic delivery authority was added.

## Cleanup receipt

The manual process used the canonical test home `/tmp/consigliere-daemon-test-home` rather than a task-owned disposable home.

The application and API socket were not left running after the proof, and a current process scan finds no Consigliere daemon, runner, Attempt, or Codex process.

The canonical test home is shared test infrastructure and was preserved rather than moved to Trash by this task.

## Exact-head harness transport hardening

The exact-head security review found that the Codex harness did not need the daemon API socket or reusable Attempt capability to emit its private report marker, but the old environment forwarded both values.

Tests-first RED proof changed the CLI bridge test to omit both transport values, and the bridge then failed with `required bound identity CS_API_SOCKET is missing`; the runner environment test also observed the old socket and capability values.

Commit `771e72a32145dca791ae30286cdddf8b774a7285` makes bridge-mode `cs-attempt` validate only its bound identity fields, removes the transport values from `RunnerProcess`, and keeps the Go runner scrubber from forwarding them.

Tests-first GREEN proof passed the CLI bridge test, the runner spawn suite, and the Elixir runner environment regression; the combined Elixir hardening slice passed 11 tests.

The trusted runner retains the short-lived report capability and forwards only the bounded bridge report, while the harness receives no direct daemon transport secret.
