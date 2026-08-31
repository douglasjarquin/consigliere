# Task 3 evidence: logically idempotent commands and transaction-free external work

Plan item: #125, `Make V0 commands logically idempotent and external operations transaction-free`.

Branch: `revival/v0-local-codex`.

Base: `24ffea8fa1f5bc983fb5965efab0a89b6116f05b`.

Implementation commits: `c0194a4` for Go retry persistence, `fc14c20` and `4366f30` for receipt atomicity, and `48c7323` for external operation recovery.
The current runtime source head is `9260a9f22af55c6c073de3afae3602f58e4e8061`.

The initial RED proof used a clean Linux Elixir container and the Go client test suite.

Before implementation, the Elixir receipt tests failed because `canonical_request/4` was undefined and the receipt response had no protocol version field.

Before implementation, the Go forced-response-drop test failed because the client did not retry a mutating request with the same logical key.

The implementation adds one versioned V0 operation registry in Elixir and one matching operation-version table in the Go client.

Canonical requests use UTF-8 JSON with sorted object keys, compact encoding, explicit operation versions, authenticated authority scope, logical idempotency key, and validated payload.

Unsupported floating values, unsupported Go values, invalid UTF-8, excessive nesting, excessive fields, excessive list length, excessive strings, and oversized receipt detail are rejected or bounded at the protocol boundary.

Attempt receipt scope includes the exact Attempt identity and fencing token.

Request correlation IDs remain separate from logical idempotency keys.

The Go client generates a cryptographically random key when a mutating call has no key and reuses that key and request body across a forced response-loss retry.

Elixir receipts persist bounded versioned success and error envelopes with stable error codes, IDs, operation identifiers, and redacted details.

Invalid first requests are recorded and replay the same bounded validation failure.

Changed operation or payload under an existing key returns a stable idempotency conflict.

Protocol-supplied canonical hashes are checked before the command is accepted.

Database-only finalization rollback leaves no pending receipt for boot reconciliation.
External commands claim a separate durable `command_operations` row before work, link it to the receipt, and reconcile only linked pending operations.
The `project.add` recovery path resolves a killed external worker from the persisted Project domain record and stores the durable operation and Project IDs in bounded evidence.
Insufficient external domain evidence remains explicitly `recovery_required`, while unrelated pending receipts are not blanket-converted.

The receipt callback runs after the claim transaction releases the SQLite writer, and slow external work does not run inside the writer callback.

Existing database transitions retain their established transition APIs, while external work is kept outside SQLite transactions and represented by durable receipt state and reconciliation.

RED-to-GREEN targeted proof:

```text
cd daemon && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix test test/consigliere/command_receipts_test.exs test/consigliere/database_writer_test.exs test/consigliere/database_writer_atomicity_test.exs
Historical result before the external-operation correction: 18 passed.

Current receipt regression after the correction:

```text
PATH="/opt/homebrew/opt/erlang/bin:$PATH" mix test test/consigliere/command_receipts_test.exs
Result: 17 passed
```

The rollback test asserts `reconcile_pending/0` returns zero after the transaction abort.
The external recovery test starts real receipt work, kills it after the durable claim, persists domain evidence, and verifies one linked operation and one linked receipt are committed without callback replay.
```

Clean Linux daemon proof:

```text
cd daemon && mix deps.get && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test
Result: 387 passed (1 doctest, 386 tests)
```

Go proof:

```text
cd cli && test -z "$(gofmt -l .)" && go vet ./... && go test ./... && go test -race -shuffle=on -count=1 ./... && go build ./cmd/cs ./cmd/csd
Result: normal tests, race tests, vet, and builds passed; command packages reported no test files.

Exact current Go gates at runtime source `9260a9f22af55c6c073de3afae3602f58e4e8061` also passed for CLI and runner.
The CLI race suite passed in 3.442s and the runner race suite passed in 45.487s.
```

Packaged manual QA used `scripts/package.sh` in a disposable Linux container with only the installed prefix, `/usr/bin`, and `/bin` on `PATH`.

The fake Unix-socket API server dropped the first mutating response and returned the second response.

The installed `cs mission create` call produced one mission and the fake server observed the same logical key on both requests.

The fake server observed a canonical request hash and operation version `1`.

```text
go: downloading go1.26.6 (linux/arm64)
mission-1 draft
fake_server_keys_same=yes
canonical_hash_present=yes
operation_version=1
task3_manual_qa=pass
```

The package proof also asserted that a package-only `PATH` could not resolve Mix or the source checkout.

The exact current package was rebuilt from runtime source `9260a9f22af55c6c073de3afae3602f58e4e8061`.
Its bounded artifact hashes were `cs=40dfe538c79e6e498b469c24b281f7d13e534ff56f2c2364ce9c25ea71076e36`, `csd=fcbbc344bee19e0106ab9d23f8b2c9b39ba3329afaeecbd72b88be8209b9de2e`, `cs-attempt=c43fe457f610bb21f33c9e8b1a975ac8ce92ac6a692ede090029b4c16e292eab`, and `cs-runner=5f12f764b60b34ceea42e28b46411c94f077c9b99a0abba1188470c6803b70c3`.
The installed-only lifecycle migrated schema `20260831160000`, started, pinged, ran doctor, stopped, restarted, pinged again, stopped, and accepted a repeated stop.
The final scan reported zero sockets, PID files, owner files, and package processes.
The private QA home and package prefix were moved to macOS Trash after the proof.

The temporary package driver, inner fake-server driver, archive, and container were removed automatically after the successful run.

Adversarial coverage included malformed payloads, floats and bounds, changed operation or payload, invalid-request replay, Attempt scope isolation, forced response loss, slow external callbacks, pending boot reconciliation, canonical-hash mismatch, dirty source archive input, source/Mix path absence, and repeated callback suppression.

Prompt injection, cancel or resume semantics, dirty Git worktrees, hung Git commands, and repeated process interruption belong to the later runner, workspace, and lifecycle tasks and were not claimed by this task.

No native Codex resume, offline queue, distributed transaction, second command queue, telemetry platform, unbounded transcript, automatic GitHub delivery, or PR creation was added.
