# Exact-head Away cursor race receipt

Source head: `ec47784a801ee8168fae7b249bf3b8342951ae17`.

The Away return path fences cursor acknowledgement and marker removal on the exact `away_since` snapshot read with the bounded digest.

The focused Away cursor and termination slice passed `8 tests` in five consecutive seed-0 runs with exit status `0`.

The overlapping-return regression uses an explicit worker readiness barrier, two bounded-page waves over sixty-four events, and asserts stale marker snapshots are rejected while the cursor reaches the final event.

The complete daemon suite passed `507 passed (1 doctest, 506 tests)` after format and warnings-as-errors compilation.
