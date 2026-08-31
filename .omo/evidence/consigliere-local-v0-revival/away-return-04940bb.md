# Exact-head Away cursor and bounded-return receipt

Source head: `04940bb620efa47c6d399c056a52a6dff837daf7`.

The focused RED command was `mix test test/consigliere/away_cursor_test.exs:68 --no-color --seed 0`.

Before the fix it failed `0/1 passed` because the cursor acknowledged the latest event in the database instead of the last event returned in the bounded page.

The GREEN command was `mix test test/consigliere/away_cursor_test.exs test/consigliere/away_test.exs test/consigliere/api_protocol_test.exs --no-color --seed 0`.

The GREEN result was `15 passed` with exit status `0`.

The regression inserted 33 events after marking Away, observed a first page of 32 events, verified the cursor matched the last returned event, and verified the next page returned the remaining event.

Five repeated reader and Away runs each returned `16 passed, 8 excluded` with exit status `0`.

The full daemon gate ran `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `MIX_ENV=test mix test --no-color --seed 0`.

The full daemon result was `504 passed (1 doctest, 503 tests)` with exit status `0`.

The bounded return path keeps 32 rows per collection, deterministic ordering, bounded redacted text, allowlisted event summaries, and validates the encoded response before advancing the cursor.

The relevant adversarial classes were oversized durable payloads, response-size enforcement, cursor loss from concurrent insertion, deterministic ordering, malformed authorization, advisory authorization, and repeated timing.

Malformed schemas, prompt injection, cancellation or resume, dirty worktrees, hung external commands, and process interruption do not enter this read-and-ack path and remain covered by the owning task evidence.
