# Exact-head Away cursor concurrency receipt

Source head: `0fd7d3b951672df7cb37e6c160401d1593386ba2`.

The reviewed source removes the exported `acknowledge_cursor/1` helper and keeps cursor acknowledgement private to the Away return path.

The owning fix uses one SQL update with `MAX(last_event_id, returned_event_id)` so acknowledgement is monotonic when returns overlap.

The focused cursor suite passed `5 tests` in five consecutive seed-0 runs with exit status `0`.

The overlapping-return regression releases twenty workers from an explicit readiness barrier in two bounded-page waves over sixty-four events, then verifies the cursor advances from the first page to the final event without moving backwards.

The full daemon gate passed `505 passed (1 doctest, 504 tests)` after format and warnings-as-errors compilation.

Applicable adversarial classes were overlapping returns, stale state, bounded pages, cursor loss, repeated interruption timing, and idempotent acknowledgement.

Malformed schemas, prompt injection, cancellation or resume, dirty worktrees, hung external commands, and process identity are outside this cursor persistence path and remain covered by the owning task evidence.
