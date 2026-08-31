# Historical exact-head Away cursor race receipt for f064f4f

Source head: `f064f4f79d9865c27c083e2dbf47e039cbe09c3f`.

The Away return path fences cursor acknowledgement and marker removal on the exact `away_since` snapshot used to build the bounded digest.

The focused Away cursor and termination slice passed `8 tests` in five consecutive seed-0 runs with exit status `0`.

The overlapping-return regression uses an explicit worker readiness barrier, two bounded-page waves over sixty-four events, and rejects stale marker snapshots while the cursor reaches the final event.

The complete daemon suite passed `508 passed (1 doctest, 507 tests)` after format and warnings-as-errors compilation.
