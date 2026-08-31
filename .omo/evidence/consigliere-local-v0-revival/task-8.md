# Task 8 evidence: exactly one recoverable Attempt after authorization

Branch: `revival/v0-local-codex`.

Base: `24ffea8fa1f5bc983fb5965efab0a89b6116f05b`.

Implementation commit: `b781849fa99a7579e1bf1a4744c2a7825970f312`.

`mission.grant_work` now commits the Authorization, one workspace generation, one planned Attempt, and one dispatch operation in the same authoritative SQLite transaction.

The dispatch operation records immutable correlation and idempotency identities, authorization, Project and Mission identities, workspace generation, base and checkpoint SHAs, and the Attempt fencing generation.

Workspace materialization and identity verification happen outside the SQLite writer transaction before the operation advances to `workspace_ready`.

The coordinator activates the pre-created Mission and Attempt without inserting a second workspace or Attempt, then launches only the durable Attempt identity.

The bootstrap scan includes active Missions, every nonterminal dispatch operation, and every planned or starting Attempt so a missed event is repaired by durable state.

Unknown process existence is fail-closed: an Attempt in `starting` without a matching Registry runner becomes `unknown` and remains held for identity reconciliation rather than being spawned again.

Terminal Attempts and failed or completed dispatch operations block scheduling and cannot be redispatched.

Project exclusivity is enforced before authorization, and the V0 scheduler retains one worker slot per `CS_HOME` without activating a second Mission when capacity is busy.

`cs why` now exposes bounded durable dispatch identity, Attempt, workspace, runner, generation, SHA, slot, child-state, and error fields, and the human client renders the dispatch boundary.

The initial RED characterization was run before the implementation:

```text
MIX_ENV=test mix test --no-color test/consigliere/dispatch_recovery_test.exs
Result: 0/1 passed
```

The failing assertion proved that authorization committed no workspace, Attempt, or dispatch intent before the fix.

The focused recovery suite passed after the implementation:

```text
docker run --rm -v "$PWD:/repo" -w /repo/daemon elixir:1.20-otp-29 sh -c 'mix local.hex --force >/dev/null; mix deps.get >/dev/null; mix format lib/consigliere/dispatch.ex lib/consigliere/mission_bootstrap.ex lib/consigliere/mission_coordinator.ex lib/consigliere/missions.ex lib/consigliere/missions/transitions.ex lib/consigliere/api/protocol.ex test/consigliere/dispatch_recovery_test.exs && MIX_ENV=test mix compile --warnings-as-errors && export PATH=/repo/.tmp/consigliere-test-bin:$PATH; MIX_ENV=test mix test --no-color test/consigliere/dispatch_recovery_test.exs'
Result: 8 passed
```

The existing dispatch, grant, and coordinator rehydration tests also passed:

```text
docker run --rm -v "$PWD:/repo" -w /repo/daemon elixir:1.20-otp-29 sh -c 'export PATH=/repo/.tmp/consigliere-test-bin:$PATH; mix local.hex --force >/dev/null; mix deps.get >/dev/null; MIX_ENV=test mix test --no-color test/consigliere/mission_grant_dispatch_test.exs test/consigliere/dispatch_test.exs test/consigliere/mission_coordinator_rehydrate_test.exs'
Result: 10 passed
```

The CLI package tests and vet gate passed after the `cs why` rendering change:

```text
cd cli && go test ./... && go vet ./...
Result: cli/client ok, cli/service ok, command packages have no test files, vet passed
```

A temporary process driver was created at `daemon/task8_manual.exs`, run after a fresh test migration, and moved to macOS Trash after the run.

```text
docker run --rm -v "$PWD:/repo" -w /repo/daemon elixir:1.20-otp-29 sh -c 'export PATH=/repo/.tmp/consigliere-test-bin:$PATH; mix local.hex --force >/dev/null; mix deps.get >/dev/null; mix format task8_manual.exs'
docker run --rm -v "$PWD:/repo" -w /repo/daemon elixir:1.20-otp-29 sh -c 'export PATH=/repo/.tmp/consigliere-test-bin:$PATH; mix local.hex --force >/dev/null; mix deps.get >/dev/null; MIX_ENV=test mix ecto.create --quiet; MIX_ENV=test mix ecto.migrate --quiet; MIX_ENV=test mix run task8_manual.exs'
TASK8 ambiguous_unknown=true
TASK8 ambiguous_runner_absent=true
TASK8 ambiguous_attempts=1
TASK8 ambiguous_dispatches=1
TASK8 duplicate_response=true
TASK8 authorizations=1
TASK8 workspaces=1
TASK8 attempts=1
TASK8 dispatches=1
TASK8 live_runner=true
TASK8 why_dispatch=true
TASK8 why_attempt_bound=true
```

The process driver exercised the real daemon application and Go runner path, verified that an ambiguous starting Attempt did not create a runner, then verified duplicate authorization requests and duplicate coordinator wakeups converged to one Authorization, workspace, Attempt, dispatch operation, and live runner.

The test also verified that the `mission.why` response binds the live runner to the durable Attempt identity.

Adversarial coverage included malformed request and identity input through the existing protocol and transition validation tests.

Prompt injection was ruled out for this task because authorization dispatch carries no model prompt or free-form model instruction into an authority handler.

Cancel and resume were ruled out as dispatch creation inputs because cancel is a separate terminal transition and V0 continuation is a later ordered task; the dispatch state remains durable across those boundaries.

Stale state was exercised by starting an already-`starting` Attempt with no Registry runner and requiring `unknown` instead of a retry.

Dirty worktrees were ruled out at this boundary because workspace preparation delegates to the trusted identity verifier and never accepts an unverified workspace for a trusted Project.

Hung external work is bounded by the existing workspace and runner launch deadlines, while no SQLite transaction encloses that work.

Flaky timing was ruled out by polling bounded durable state and Registry identity instead of fixed sleeps in the new tests and manual driver.

Misleading output cannot advance dispatch because only durable operation status, Attempt status, workspace identity, exact generation, and Registry runner identity are used for scheduling.

Repeated interruption was exercised through duplicate command requests, duplicate coordinator starts, and the ambiguous spawn window; each case retained one logical Attempt.

No second dispatcher, hidden spawn retry, worker before authorization, native transcript resume, legacy supervisor dependency, Made action, GitHub action, PR action, merge action, credential, secret, or unbounded output was added.

`git diff --check` was clean, and the temporary driver, Go wrapper, and generated runner binaries were moved to Trash rather than permanently deleted.

## Exact-head boundary closure

At exact head `8d839378a55e36222e13c19e84e1f91543fc92c4`, the RED boundary slice returned `8/10` before the scheduler, advisory, and runner-persistence fixes, with the expected immediate-capacity and handshaken-runner failures.

The GREEN command was `docker run --rm -v "$PWD":/workspace -w /workspace/runner/cs-runner elixir:1.20-otp-29 ... mix format --check-formatted ... MIX_ENV=test mix test test/consigliere/global_scheduler_test.exs test/consigliere/advisory_test.exs test/consigliere/runner_process_recovery_test.exs --no-color --seed 0`.

It returned `10 passed`.

The scheduler regression now proves a planned cancellation releases both the durable dispatch slot and the live scheduler cache without releasing a slot while another Attempt or unreleased dispatch remains.

The advisory regression now rejects `attempt.logs` before log loading for the model-advisory principal.

The runner regression now proves a fenced `starting` to `running` persistence failure cancels the authenticated external runner, records a bounded spawn failure, leaves no Registry runner, and reaches a terminal manifest.

The full Linux daemon gate then returned `483 passed (1 doctest, 482 tests)` in three consecutive seed-0 runs.

The exact-head receipt is `.omo/evidence/consigliere-local-v0-revival/daemon-linux-gate-8d83937.log`.

## Post-audit invariant closure

The final audit reproduced a recovery leak where canceling a planned Attempt left its durable dispatch slot pending and a scheduler rebuild remained busy.

The RED regression was `MIX_ENV=test mix test test/consigliere/global_scheduler_test.exs --no-color --seed 0`, which returned `3/4 passed` because the canceled operation remained `pending`.

The fix is committed in `49db8624a8140eda0449a03f5f706142eeb99493` and releases the planned operation inside the same transaction that marks the Attempt canceled.

The final invariant audit also added the SQLite partial unique index `attempts_one_recoverable_per_mission` for `planned` and `starting` rows, preflight checks in every Attempt-creation path, and a planned supersession regression.

The GREEN command `MIX_ENV=test mix test test/consigliere/attempts/attempt_test.exs test/consigliere/exact_sha_progression_test.exs test/consigliere/global_scheduler_test.exs test/consigliere/attempts/transitions_test.exs --no-color --seed 0` returned `22 passed` with formatting and warnings-as-errors compilation clean.

The authoritative Linux daemon gate on the committed follow-up returned `482 passed (1 doctest, 481 tests)` in each of three consecutive seed-0 runs.

The failure classes covered here were stale planned slots, duplicate recoverable continuation, direct SQLite uniqueness violation, planned replacement, restart rebuild, and repeated cancellation.

## Final exact-head boundary receipt

The final source head is `bf22b5d4cae239a222a3065ca4b34b574dd676ad`.

The runner startup boundary RED proof against the pre-fix runtime failed with `a runner started without a durable Attempt`.

The GREEN recovery suite passed six tests after startup now fails closed for missing, invalid, non-starting, and failed-persistence Attempt identities, tears down the authenticated runner, records a bounded spawn failure, and leaves no Registry runner.

The complete Linux daemon gate then passed `486 passed (1 doctest, 485 tests)` in three consecutive seed-0 runs.

The bounded receipt is `.omo/evidence/consigliere-local-v0-revival/runner-startup-boundary-bf22b5d.log`.

## Historical superseded exact-head closure for 7159373

The historical final runtime source head is `71593738cf6aae723c9208743405fa12a9dc7a03`.

The historical Linux daemon gate passed `491 passed (1 doctest, 490 tests)` in three consecutive seed-0 runs, and the packaged lifecycle proved one verified owner, identity-safe restart, repeated-stop idempotence, and zero residual processes.

The historical Go, package, and native macOS receipts are `go-gates-7159373.md`, `package-artifact-7159373.md`, `installed-lifecycle-7159373.md`, and `macos-native-gate-7159373.md`.

The selected real canary was not rerun after this runtime closure because duplicate implementation work is forbidden.
