# Review finding 4: boot ordering and seeded reconciliation

The application child specification starts `Consigliere.Registry` and `Consigliere.RunnerDynamicSupervisor` before `Consigliere.Reconciler`.
This makes runner identity lookup available during the first reconciliation pass.

The application child-order regression was RED before the reorder because the registry index followed the reconciler index.
The focused order suite is now GREEN.

The production callback path is also exercised with a seeded running Attempt and a `dead_verified` manifest.
`Reconciler.init(run_on_boot: true, poll_interval_ms: :infinity)` returns its production continuation, and `Reconciler.handle_continue(:run, state)` reconciles the seeded Attempt to `lost`.

```text
$ PATH="/opt/homebrew/opt/erlang/bin:$PATH" mix test test/consigliere/reconciler_persist_test.exs:267 --trace
Result: 1 passed, 16 excluded
```

The test uses a unique `CS_HOME`, a real SQLite-seeded Attempt, and the real manifest reconciliation path.
No test-only production hook is used.
