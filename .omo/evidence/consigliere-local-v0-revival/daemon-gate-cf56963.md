# Historical exact-head daemon gate receipt

Source head: `cf56963a7206e5c5a260442c08eaa7bdcd65ec7a`.

Commands:

```text
cd daemon
PATH=/opt/homebrew/opt/erlang/bin:$PATH MIX_ENV=test mix format --check-formatted
PATH=/opt/homebrew/opt/erlang/bin:$PATH MIX_ENV=test mix compile --warnings-as-errors
PATH=/opt/homebrew/opt/erlang/bin:$PATH MIX_ENV=test mix test --no-color --seed 0
```

All commands exited `0`.

The complete daemon result was `506 passed (1 doctest, 505 tests)`.

The cancellation ordering regression and Away cursor concurrency proof are recorded in `termination-cf56963.md` and `away-return-0fd7d3b.md`.
