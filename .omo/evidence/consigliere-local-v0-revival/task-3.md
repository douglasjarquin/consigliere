# Task 3 evidence: logically idempotent commands and transaction-free external work

Plan item: #125, `Make V0 commands logically idempotent and external operations transaction-free`.

Branch: `revival/v0-local-codex`.

Base: `24ffea8fa1f5bc983fb5965efab0a89b6116f05b`.

Commit: `feat(v0-02): make commands idempotent outside transactions`.

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

Pending receipts are reconciled at daemon boot into a bounded recovery-required result without re-running the callback.

The receipt callback runs after the claim transaction releases the SQLite writer, and slow external work does not run inside the writer callback.

Existing database transitions retain their established transition APIs, while external work is kept outside SQLite transactions and represented by durable receipt state and reconciliation.

RED-to-GREEN targeted proof:

```text
cd daemon && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix test test/consigliere/command_receipts_test.exs test/consigliere/database_writer_test.exs test/consigliere/database_writer_atomicity_test.exs
Result: 18 passed
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

The temporary package driver, inner fake-server driver, archive, and container were removed automatically after the successful run.

Adversarial coverage included malformed payloads, floats and bounds, changed operation or payload, invalid-request replay, Attempt scope isolation, forced response loss, slow external callbacks, pending boot reconciliation, canonical-hash mismatch, dirty source archive input, source/Mix path absence, and repeated callback suppression.

Prompt injection, cancel or resume semantics, dirty Git worktrees, hung Git commands, and repeated process interruption belong to the later runner, workspace, and lifecycle tasks and were not claimed by this task.

No native Codex resume, offline queue, distributed transaction, second command queue, telemetry platform, unbounded transcript, automatic GitHub delivery, or PR creation was added.
