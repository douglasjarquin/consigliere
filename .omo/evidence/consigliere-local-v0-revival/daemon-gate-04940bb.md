# Exact-head daemon gate receipt

Source head: `04940bb620efa47c6d399c056a52a6dff837daf7`.

Commands:

```text
cd daemon
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=test mix test --no-color --seed 0
```

All commands exited `0`.

The complete daemon result was `504 passed (1 doctest, 503 tests)`.

The focused Away cursor RED/GREEN and five repeated bounded-reader/Away runs are recorded in `away-return-04940bb.md`.
