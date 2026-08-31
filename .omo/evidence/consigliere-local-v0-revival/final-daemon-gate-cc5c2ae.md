# Final daemon gate

The exact source head was `cc5c2ae368007ec30fba81d74d5a30808176a9d8`.

The command was `export PATH="/opt/homebrew/opt/erlang/bin:/opt/homebrew/bin:/usr/bin:/bin"; cd daemon; mix format --check-formatted; MIX_ENV=test mix compile --warnings-as-errors; MIX_ENV=test mix test --seed 0 --no-color`.

The format check, warnings-as-errors compilation, and serial ExUnit suite passed with exit `0`.

The suite result was `500 passed (1 doctest, 499 tests)`.
