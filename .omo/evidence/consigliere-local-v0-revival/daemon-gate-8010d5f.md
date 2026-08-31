# Historical exact-head daemon gate receipt

Source head: `8010d5fdaa69f9e998b951f8282fddd01e5099ea`.

Commands:

```text
cd daemon
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=test mix test --no-color --seed 0
```

All commands exited `0`.

The complete daemon result was `506 passed (1 doctest, 505 tests)`.

The focused concurrency regression and five repeated runs are recorded in `away-return-8010d5f.md`.
