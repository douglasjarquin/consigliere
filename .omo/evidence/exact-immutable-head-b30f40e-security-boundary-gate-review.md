# Exact immutable HEAD security boundary gate review

recommendation: APPROVE

blockers: none

## Original intent

Perform a read-only final pre-push security-boundary review of immutable delivery HEAD `b30f40e10dee9513403aeff14b03fba79f27ee9a`, whose runtime parent is `d63f2390944a534f4746c64ef60e43332fd546c3`, without changing shared runtime, Git, PR, or canary state.

Verify cross-home lock isolation, token fencing, stale and malformed state behavior, bounded inputs and outputs, authority boundaries, secret and path exposure, forbidden scope, and the correction of stale current claims that pointed at `0c2b24c`.

## Desired outcome

The Away correction serializes each home's marker write and cursor update under the canonical expanded-home lock, builds return digests outside that lock, and locks only cursor acknowledgement plus token-checked marker removal.

No stale return may remove a newer marker or move the durable cursor backwards.

No security or data-loss blocker, temporary production hook, `DatabaseWriter.serialize` detour, secret exposure, cross-home cleanup, or forbidden external mutation may remain.

## User outcome review

PASS.

The checked-out branch and immutable HEAD match the request.
The product-input diff from runtime parent `d63f239` to delivery HEAD `b30f40e` is empty.

`Away.mark/1` holds `:global.trans({{Consigliere.Away, Path.expand(home)}, self()}, fun)` around both the marker write and cursor upsert at `daemon/lib/consigliere/away.ex:27-34,76-78`.
Because the canonical expanded home is part of the lock resource, distinct homes do not share this serialization resource, while equivalent relative and absolute paths for one home converge on one resource.

`Away.return/1` builds and size-checks its digest before locking, then locks only acknowledgement and token-checked marker removal at `daemon/lib/consigliere/away.ex:41-68`.
The acknowledgement update is monotonic through SQL `MAX`, checks the expected `away_since`, and reports stale snapshots instead of acknowledging a newer marker at `daemon/lib/consigliere/away.ex:185-229`.
Marker deletion reads the file and removes it only when its exact ISO-8601 token equals the acknowledged snapshot at `daemon/lib/consigliere/away.ex:232-243`.
Malformed, missing, or newer marker contents therefore remain untouched.

Digest queries cap questions, events, and missions at 32 rows, project only bounded event metadata, redact prompt and objective text, truncate those fields to 4,096 characters, and reject an encoded response larger than the protocol frame at `daemon/lib/consigliere/away.ex:21-23,46-68,98-154`.
The reviewed path does not emit credentials, raw event payloads, transcripts, database paths, or arbitrary filesystem contents.
The home setup makes the home and runtime directories mode `0700` and credentials mode `0600` in `daemon/lib/consigliere/home.ex:8-69`.

Public callers invoke `Away.mark/0` and `Away.return/0` through the existing Boss CLI/API surfaces; the correction introduces no new operation, credential, advisory authority, shell execution, push, PR, merge, Made action, canary run, or shared-daemon lifecycle action.

The new regression exercises real public `Away.mark/0` calls against the exact lock resource and verifies marker/cursor agreement at `daemon/test/consigliere/away_cursor_test.exs:160-208`.
Existing behavior-facing tests cover stale marker preservation, bounded payload projection, page-bounded acknowledgement, and monotonic overlapping returns at `daemon/test/consigliere/away_cursor_test.exs:38-157`.

The direct `omo:remove-ai-slops` pass found no deletion-only test, requested-removal-only test, tautological assertion, prompt-prose assertion, implementation-constant parser test, needless production extraction, parsing, normalization, abstraction, or temporary hook in the correction.
The direct `omo:programming` pass found no new untyped escape hatch or boundary validation duplication.
`away.ex` is 211 pure LOC and the changed test is 167 pure LOC, both below the applied 250 pure-LOC ceiling.

The code review report at `.omo/evidence/consigliere-local-v0-revival-code-review.md:35-41` explicitly records both required skill perspectives and covers deletion-only, tautological, prompt-text, constant-mirroring, parsing, normalization, abstraction, untyped escape hatch, and temporary-hook criteria.
Its noted 100 ms scheduling assertion weakness is a non-blocking test-quality note because the production lock boundary is directly visible and the exact-runtime receipt records ten passing seeds.

Every occurrence of `0c2b24c` in the current verdict records is now explicitly historical or superseded.
Current receipt claims bind to `d63f239`, including `.omo/evidence/consigliere-local-v0-revival/final-gate-receipt.md:183-191`.

## Checked artifacts

- `/Users/douglasjarquin/github/douglasjarquin/consigliere/.omo/plans/consigliere-local-v0-revival.md`
- `daemon/lib/consigliere/away.ex` at `b30f40e`
- `daemon/lib/consigliere/home.ex` at `b30f40e`
- `daemon/lib/consigliere/txn.ex` at `b30f40e`
- `daemon/test/consigliere/away_test.exs` at `b30f40e`
- `daemon/test/consigliere/away_cursor_test.exs` at `b30f40e`
- `.omo/evidence/consigliere-local-v0-revival/F1.md`
- `.omo/evidence/consigliere-local-v0-revival/F2.md`
- `.omo/evidence/consigliere-local-v0-revival/F3.md`
- `.omo/evidence/consigliere-local-v0-revival/F4.md`
- `.omo/evidence/consigliere-local-v0-revival/final-exact-head-evidence.md`
- `.omo/evidence/consigliere-local-v0-revival/final-gate-receipt.md`
- `.omo/evidence/consigliere-local-v0-revival/away-return-d63f239.md`
- `.omo/evidence/consigliere-local-v0-revival/daemon-gate-d63f239.md`
- `.omo/evidence/consigliere-local-v0-revival/go-gates-d63f239.md`
- `.omo/evidence/consigliere-local-v0-revival/package-artifact-d63f239.md`
- `.omo/evidence/consigliere-local-v0-revival/installed-lifecycle-d63f239.md`
- `.omo/evidence/consigliere-local-v0-revival-code-review.md`
- `.omo/ulw-notepad-20260830.md`

## Exact evidence gaps and notes

- Independent focused Mix rerun did not execute because `/tmp/consigliere-daemon-test-home` was already held by another test application; startup failed at `Consigliere.Home.Lock` with `:already_running`.
  The holder was not stopped or altered.
  This does not contradict the committed exact-runtime receipt in `away-return-d63f239.md:13-23`, which records ten focused seeds and the adversarial classes, and it is not tied to a failed security or data-loss criterion.
- The concurrent mark regression uses a 100 ms negative-receive window at `daemon/test/consigliere/away_cursor_test.exs:195-197`.
  This can weaken the test oracle under pathological scheduler delay, but it is not evidence of a runtime boundary failure and therefore is a NOTE, not a blocker.
- `build_digest/1` uses the process-default home for the informational `"away"` field.
  All production callers use the default home and each daemon is bound to one explicit `CS_HOME`; explicit alternate-home calls are not an exposed authority path.
  No stated success criterion is violated, so this is a NOTE only.

## Security and data-loss verdict

No security or data-loss blocker was found.
The immutable candidate satisfies the requested Away lock, fencing, stale-state, bounds, authority, exposure, and forbidden-scope checks.
