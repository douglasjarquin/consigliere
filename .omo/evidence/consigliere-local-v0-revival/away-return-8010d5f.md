# Exact-head Away cursor concurrency receipt

Source head: `8010d5fdaa69f9e998b951f8282fddd01e5099ea`.

The RED regression used 20 overlapping `Away.return` calls over 64 events and failed because stale acknowledgements could overwrite a newer cursor.

The owning fix uses one SQL update with `MAX(last_event_id, returned_event_id)` so acknowledgement is monotonic even when returns overlap.

The focused cursor suite passed `6 tests` in five consecutive seed-0 runs with exit status `0`.

The direct stale-acknowledgement regression advances the cursor to a later event and then submits an older event ID, proving the durable cursor remains at the later event.

The full daemon gate passed `506 passed (1 doctest, 505 tests)` after format and warnings-as-errors compilation.

The package-only lifecycle was rerun from this source head and is recorded in `package-artifact-8010d5f.md` and `installed-lifecycle-8010d5f.md`.

Applicable adversarial classes were overlapping returns, stale state, bounded pages, cursor loss, repeated interruption timing, and idempotent acknowledgement.

Malformed schemas, prompt injection, cancellation or resume, dirty worktrees, hung external commands, and process identity are outside this cursor persistence path and remain covered by the owning task evidence.
