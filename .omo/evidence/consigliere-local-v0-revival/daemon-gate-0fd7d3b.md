# Exact-head daemon gate receipt

Source head: `0fd7d3b951672df7cb37e6c160401d1593386ba2`.

Commands:

```text
cd daemon
PATH=/opt/homebrew/opt/erlang/bin:$PATH MIX_ENV=test mix format --check-formatted
PATH=/opt/homebrew/opt/erlang/bin:$PATH MIX_ENV=test mix compile --warnings-as-errors
PATH=/opt/homebrew/opt/erlang/bin:$PATH MIX_ENV=test mix test --no-color --seed 0
```

All commands exited `0`.

The complete daemon result was `505 passed (1 doctest, 504 tests)`.

The focused concurrency regression passed in five consecutive seed-0 runs, with bounded output recorded in `away-return-0fd7d3b.md`.
