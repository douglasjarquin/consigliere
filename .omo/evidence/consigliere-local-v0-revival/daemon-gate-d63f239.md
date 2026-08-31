# Exact-head daemon gate receipt

Runtime source head: `d63f2390944a534f4746c64ef60e43332fd546c3`.

Commands: `PATH="/opt/homebrew/Cellar/erlang/29.0.5/bin:$PATH" MIX_ENV=test mix format --check-formatted lib/consigliere/away.ex lib/consigliere/database_writer.ex test/consigliere/away_cursor_test.exs` and `PATH="/opt/homebrew/Cellar/erlang/29.0.5/bin:$PATH" MIX_ENV=test mix test --no-color --seed 0`.

The focused Away regression passed at seeds `0` through `9`, with `7` tests per seed.

The complete daemon suite passed `511 passed (1 doctest, 510 tests)`.

The prior zsh wrapper reported a read-only-variable error after the suite completed, so the captured log was independently checked for the exact `Result: 511 passed` line.

No Consigliere product process remained after the gate.
