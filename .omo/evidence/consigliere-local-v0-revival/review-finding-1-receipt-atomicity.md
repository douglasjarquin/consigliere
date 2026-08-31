# Review finding 1: database-only receipt atomicity

Database-only commands now claim, invoke through a nested transaction boundary, and finalize their bounded receipt envelope within one serialized writer transaction.
The callback uses existing transaction-aware domain operations, while rollback-shaped domain errors are preserved as committed error envelopes.

## RED

The crash-boundary regression used a SQLite trigger that aborts receipt finalization.
Before the fix, the receipt claim and Mission mutation had already committed, leaving one Mission after finalization failed.

```text
Assertion with == failed
code: assert Repo.aggregate(Consigliere.Missions.Mission, :count) == 0
left: 1
right: 0
```

## GREEN

```text
$ PATH="/opt/homebrew/opt/erlang/bin:$PATH" mix test test/consigliere/command_receipts_test.exs:137 --trace
Result: 1 passed, 13 excluded

$ PATH="/opt/homebrew/opt/erlang/bin:$PATH" mix test test/consigliere/command_receipts_test.exs --seed 0
Result: 14 passed
```

The regression verified that a finalization abort leaves neither the Mission nor its receipt.
Existing tests also cover replay, stable error envelopes, invalid payload persistence, same-key conflicts, pending recovery, and slow external work remaining outside the writer transaction.

Pending receipt recovery is now an application child immediately after `DatabaseWriter` and before the EventBus, Reconciler, runner bootstrap, and API supervisor.
External finalized envelopes include the durable receipt operation ID, and the external reference regression passed in the same focused run.
