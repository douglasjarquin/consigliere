# Review finding 1: receipt atomicity and external operation recovery

This receipt is bound to implementation commit `48c73236172763bb4b5b3cad26aa2c0b9e0e6a42`.

Database-only operations claim, invoke, and finalize their bounded receipt envelope in one serialized writer transaction.
They do not create an external operation row.
The existing transaction-aware domain functions remain usable without nested writer calls, and rollback-shaped domain errors remain committed error envelopes.

External operations now claim a receipt and a separate durable `command_operations` row atomically before invoking external work.
The operation stores the operation name, authority scope, bounded request payload, and intent evidence.
The receipt stores the operation ID as a durable indexed reference, while the operation owns the foreign-key association back to the receipt.
Finalization updates both rows atomically after external work.

Boot reconciliation selects only pending operations that are linked to pending receipts.
It resolves a pending external operation from durable domain evidence, such as the persisted Project for `project.add`, and records the operation ID and domain ID in both bounded responses and evidence.
An operation without sufficient domain evidence is explicitly marked `recovery_required`; an unrelated or legacy pending receipt is not blanket-converted by this path.

## RED

The first focused run after adding the operation model exposed a schema cleanup defect.
The initial draft used foreign keys in both directions, so the existing fixture reset attempted to delete child operations before receipts and failed with `FOREIGN KEY constraint failed` for all 15 tests.
The new crash test also initially used the unsupported `Task.shutdown(task, :kill)` option and failed with `FunctionClauseError`.
These failures were fixed in the migration and test harness before the green run.

```text
$ PATH="/opt/homebrew/opt/erlang/bin:$PATH" mix test test/consigliere/command_receipts_test.exs
Result: 0/15 passed
Failure: DELETE FROM "command_operations" failed with FOREIGN KEY constraint failed

Failure: Task.shutdown/2 received :kill, but the supported hard-stop option is :brutal_kill.
```

## GREEN

```text
$ PATH="/opt/homebrew/opt/erlang/bin:$PATH" mix test test/consigliere/command_receipts_test.exs
Result: 15 passed

$ PATH="/opt/homebrew/opt/erlang/bin:$PATH" mix compile --warnings-as-errors
Result: exit 0
```

The rollback regression now proves that a database-only finalization abort leaves neither the Mission nor its receipt, and that reconciliation finds zero pending records afterward.
The external recovery regression starts a real external receipt operation, kills the worker after the durable claim, persists a Project domain record, and verifies that reconciliation commits the linked operation and receipt from that domain evidence without invoking external work again.
The external reference regression verifies that the response operation ID is the durable `command_operations.id`, not the receipt ID echoed as a surrogate.

Applicable adversarial classes exercised here are transaction crash/finalization failure, killed external worker, stale pending state, duplicate reconciliation, repeated replay, changed payload conflict, malformed invalid input, and bounded response persistence.
Prompt injection, credential disclosure, dirty worktrees, hung external commands beyond the killed-worker boundary, and process-group containment are not exercised by this receipt-specific change and remain covered by their owning task gates.
