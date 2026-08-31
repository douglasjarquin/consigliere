# Historical exact-head Away cursor concurrency receipt

Source head: `cf56963a7206e5c5a260442c08eaa7bdcd65ec7a`.

The private Away cursor acknowledgement and bounded return implementation is unchanged from runtime `0fd7d3b` and is included in this exact runtime source.

The focused cursor suite passed `5 tests` in five consecutive seed-0 runs at this runtime source with exit status `0`.

The explicit readiness-barrier regression releases twenty concurrent returns in two bounded-page waves over sixty-four events and verifies that the cursor advances from the first page to the final event without moving backwards.

The full daemon gate passed `506 passed (1 doctest, 505 tests)` after format and warnings-as-errors compilation.

Applicable adversarial classes were overlapping returns, stale state, bounded pages, cursor loss, repeated interruption timing, and idempotent acknowledgement.
