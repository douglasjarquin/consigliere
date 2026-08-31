# Mission coordinator scheduler reset synchronization

The full daemon gate exposed a race in `mission_coordinator_rehydrate_test.exs`: the test reset SQLite and the in-memory scheduler while a prior test coordinator could still have pending mailbox work.
That allowed the first Mission's coordinator to observe transient cross-test state and miss the active transition before the five-second assertion deadline.

The test now terminates all MissionDynamicSupervisor children and waits for the supervisor to report no children before resetting tables and rebuilding scheduler occupancy.
It asserts the rebuilt scheduler is empty before creating the next Mission.
Production scheduling behavior is unchanged.

```text
$ PATH="/opt/homebrew/opt/erlang/bin:$PATH" mix test test/consigliere/mission_coordinator_rehydrate_test.exs --seed 0
Result: 5 passed
```

The complete coordinator regression file passed in five consecutive runs.
