# Task 11 rehydration regression follow-up

This follow-up is bound to source head `30ba157976b34219be2336e230644a2de6688f93`.

## Diagnosis

Remote run `33388262833` failed one daemon test at `daemon/test/consigliere/mission_coordinator_rehydrate_test.exs:150`.

The bounded CI log showed `mission.phase` becoming `active` while the Attempt was still `starting`, followed by `attempt.spawn_requested` and a later `attempt` transition to `running`.

The replacement coordinator was therefore allowed to run dispatch recovery before the RunnerProcess had registered, and its fail-closed inventory check correctly recorded `unknown` for the still-in-flight spawn.

This is a test synchronization race, not evidence that the existing `starting`-without-runner safety contract should be weakened.

## RED evidence

The authoritative remote RED was run `33388262833` at the pushed parent head `1301933d65e48bf65baffdf5536c5c21d49b1513`.

The failure was `assert snap.reason in [:occupying, :recover]`, with `left: :unknown`.

The log timestamp was `2026-08-31T11:44:00.2781932Z`.

## GREEN change

Commit `30ba157976b34219be2336e230644a2de6688f93` makes the rehydration test wait for both `mission.phase == "active"` and the durable Attempt status `"running"` before killing the coordinator.

That is the first durable boundary after RunnerProcess identity persistence, and it removes the phase-only scheduling window without changing production dispatch, inventory, or unknown-state behavior.

The existing ambiguous-start test remains the characterization proof that a `starting` Attempt without a registered runner becomes `unknown` and is not redispatched.

## Automated proof

`cd daemon && PATH="/opt/homebrew/Cellar/erlang/29.0.5/bin:$PATH" MIX_ENV=test mix test test/consigliere/mission_coordinator_rehydrate_test.exs --no-color --seed 0 --repeat-until-failure 100` passed all 100 same-VM repetitions, each with 5 tests.

`cd daemon && PATH="/opt/homebrew/Cellar/erlang/29.0.5/bin:$PATH" mix format --check-formatted` passed.

`cd daemon && PATH="/opt/homebrew/Cellar/erlang/29.0.5/bin:$PATH" MIX_ENV=test mix compile --warnings-as-errors` passed.

`cd daemon && PATH="/opt/homebrew/Cellar/erlang/29.0.5/bin:$PATH" MIX_ENV=test mix test --no-color` passed `511 tests` and `1 doctest` with `0 failures`.

## Packaged manual proof

`scripts/package.sh "$(mktemp -d)"` completed successfully and built the installed `cs`, `csd`, daemon release, and `cs-runner` artifacts without requiring the source checkout at runtime.

Against the fresh isolated home `/tmp/consigliere-manual-qa-fix.qNIu6W`, the packaged sequence `csd migrate`, `csd start`, `cs ping`, `cs doctor`, `csd status`, `csd stop`, `csd restart`, `cs ping`, `csd stop`, and repeated `csd stop` all returned exit code 0.

The bounded output included `pong`, `lock: ... held pid=27281`, `probe socket: live`, `priv socket: live`, `api socket: live`, `codex auth: absent`, `restarted`, and final `stopped`.

The temporary package prefix and manual-QA home were moved to macOS Trash after verification as own QA residue.

## Applicable adversarial coverage

Flaky timing was applicable and was observed in the remote run; the corrected same-VM repetition passed 100 repetitions.

Stale dispatch state was applicable and remains covered by the existing ambiguous-start `unknown` test.

Repeated interruption was applicable through the coordinator kill and replacement path; the focused repetition and full daemon suite passed.

Malformed input, prompt injection, cancel or resume, dirty worktree, hung external commands, and misleading output are outside this coordinator test's input surface and remain covered by their owning task suites; no new behavior here consumes those inputs.

The worktree remained on `revival/v0-local-codex`, and no shared daemon, unrelated lock, PR #101, or merge state was touched.
