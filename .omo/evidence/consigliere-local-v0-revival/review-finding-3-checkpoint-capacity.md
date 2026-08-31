# Review finding 3 - checkpoint capacity release

Head before this correction: 85cc4060f87d245b8e209377d4603d87da856043.

RED: `PATH="/opt/homebrew/Cellar/erlang/29.0.5/bin:$PATH" MIX_ENV=test mix test test/consigliere/attempts/transitions_test.exs:98 --no-color` failed because the checkpointed Attempt left its durable dispatch slot `granted`.

GREEN: the same focused test passed after `record_checkpointed_txn/3` released the durable slot in the database transaction and `record_checkpointed/3` released the in-memory scheduler slot after commit.

The regression proves a second mission can acquire capacity after checkpoint reset without releasing memory before durable commit.
