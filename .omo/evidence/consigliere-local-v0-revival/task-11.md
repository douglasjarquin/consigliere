# Task 11 evidence

## Scope

Task #11 is the plan's issue #126, runner identity, liveness, termination, and outcome reconciliation.

The implementation commit is 8e122e1e9fd32ae078b13a6cf089a32771fbe615.

The implementation adds the canonical runtime inventory liveness verifier, platform process identity checks, runner executable identity in the manifest, immediate identity revalidation before termination, descendant-aware process termination coverage, safe handling for missing manifests, and first-terminal-event preservation.

## Tests-first record

The liveness-category, terminal-preservation, and no-manifest signaling cases were written before the corresponding implementation edits.

The initial GREEN attempt exposed that the new identity requirement needed to be present in real-process fixtures and that revalidation had to retain the complete manifest rather than only its process-group ID.

Those gaps were corrected and the exact task suite below passed.

## Automated verification

Command:

    docker run --rm -v "$PWD:/repo" -v "$PWD/.tmp/go-wrapper:/usr/local/bin/go:ro" -w /repo/daemon elixir:1.20-otp-29 sh -lc 'mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test test/consigliere/reconciler_test.exs test/consigliere/reconciler_persist_test.exs test/consigliere/runtime/inventory_test.exs test/consigliere/process_group_test.exs test/consigliere/kill_everything_test.exs test/consigliere/runner_process_exit_status_test.exs test/consigliere/runner_process_fencing_test.exs'

Result: 50 passed.

The Elixir compile completed with warnings treated as errors.

The temporary Go wrapper supplied the already-built Linux runner binary to the Elixir container because that image has no Go compiler.

Command:

    cd runner/cs-runner && test -z "$(gofmt -l .)" && go vet ./... && go test ./... && go test -race -shuffle=on -count=1 ./...

Result: go test passed normally and under race detection, with the race run completing in 40.758 seconds.

## Manual process QA

Command:

    cd runner/cs-runner && go test -run 'TestTerminate_(CooperativeProcessExitsOnSIGTERM|StubbornProcessRequiresSIGKILL)|TestTerminateGroupAndDescendants_KillsAHarnessGrandchildThatDaemonizesAway' -count=1 -v

Observed result:

    TestTerminate_CooperativeProcessExitsOnSIGTERM: PASS
    TestTerminate_StubbornProcessRequiresSIGKILL: PASS
    TestTerminateGroupAndDescendants_KillsAHarnessGrandchildThatDaemonizesAway: PASS
    PASS

The Elixir process fixtures also launched a real session-leader group, verified the recorded runner executable, adopted and terminated the exact group, and confirmed the group was gone before reconciliation completed.

The final CLI characterization also added the documented read-only `cs status MISSION` alias to the same bounded `mission.why` projection, so the packaged status surface and the state explanation surface cannot diverge.

## Adversarial coverage

- Forged manifests, missing Attempt rows, unsafe PGIDs, stale fences, mismatched workspace paths, lease generations, and fencing generations failed closed without signaling.
- Missing runner PID, absent runner identity, wrong executable, and mismatched executable identity never became verified live runner state.
- A live Attempt without a manifest was quarantined without signaling its unverified process group.
- A stale running manifest with a verified-dead group reconciled as lost, while an ambiguous live identity quarantined the workspace and preserved the durable Attempt.
- ESRCH and EPERM-style distinctions, observation failures, stubborn processes, recycled-PID protection, and repeated descendant polling were covered by the existing Go termination and descendant suites.
- A daemonizing-away grandchild was terminated and verified dead by the real process test.
- Explicit cancel, missing semantic results, exit-status reconciliation, and stale fencing were covered by the exact Elixir runner and reconciliation suites.
- Duplicate terminal events are rejected after the first valid terminal event, while replaying that exact event remains a duplicate and does not advance the durable sequence.
- Late terminal events from a superseded Attempt remain fenced and cannot overwrite the earlier outcome.
- Prompt injection was not applicable at this boundary because inventory and reconciliation consume no model-authored instructions; the bounded Codex context boundary remains covered by task 9.
- Dirty workspaces and untrusted bases are not signalable through this boundary; workspace and Git identity checks remain owned by the task 4 verifier.
- Resume is not a process action in V0, and native Codex resume remains unsupported.
- Low-disk capture faults and bounded output handling remain owned by task 10 and were not duplicated here.

The generated runner binary, temporary Go wrapper, and temporary debug journal were moved to the macOS Trash after validation.

No credentials, raw logs, transcripts, or secrets were written to this evidence record.

`git diff --check` passed before the implementation commit.

## Exact-head startup persistence closure

Commit `8d839378a55e36222e13c19e84e1f91543fc92c4` closes the handshaken-runner leak found by the exact-head code review.

`RunnerProcess` now accepts a runner only after the durable `starting` to `running` transition succeeds.

If that transition fails, the authenticated control channel receives cancellation, the bounded termination completion is consumed, the socket and port are closed, the private channel secret is released, and the Attempt is marked `spawn_failed` when still recoverable.

The RED/GREEN process proof and the three-run full Linux result are recorded in `task-8.md` and `.omo/evidence/consigliere-local-v0-revival/daemon-linux-gate-8d83937.log`.

The current native macOS characterization is `474/483` with the same nine host-only fixture categories named in `.omo/evidence/consigliere-local-v0-revival/macos-native-gate-8d83937.log`.

## Exact-head hardening follow-up

The exact-head review found that the prior verifier accepted a same-basename executable and hashed the configured path rather than the executable belonging to the observed PID.

Commit `71265e859e0eaf819872985d0f2f32f28994244f` closes that gap.

Linux now reads `/proc/<pid>/exe`, macOS now obtains the executable from `lsof`, and the fallback observer no longer treats a basename as an exact identity.

The verifier canonicalizes both observed and expected paths when `realpath` is available and hashes the observed executable path.

Tests-first RED proof:

    export PATH="/opt/homebrew/opt/erlang/bin:/opt/homebrew/bin:/Users/douglasjarquin/.local/bin:$PATH"
    MIX_ENV=test mix test test/consigliere/runtime/process_identity_test.exs --seed 0

The new same-basename fixture returned `:verified` under the old implementation, while the test required `:identity_mismatch`.

Tests-first GREEN proof:

    MIX_ENV=test mix test test/consigliere/runtime/process_identity_test.exs --seed 0

Result: 2 passed.

The two tests observed a real live `sleep` process, rejected a different executable with the same basename, and verified the exact executable path and SHA-256 hash.

The later affected reconciliation suite retained its known macOS-only process-fixture observations and is covered by the authoritative Linux container gate recorded in the final verification lanes.

## PATH-independent termination follow-up

The full Linux gate then reproduced a flaky `RunnerProcessCodexTest` failure where the Attempt became `lost` instead of `failed` while another test temporarily removed `kill` from `PATH`.

Commit `3039294c305d419dc29b6ae5a2f1d2cb9978114b` makes the daemon's `kill` and macOS `ps` observers resolve from fixed system paths, and adds a regression that terminates a real process group with `PATH=/nonexistent`.

RED proof was the authoritative container run at the preceding source, which returned `453 passed` and one `RunnerProcessCodexTest` failure with `lost` versus `failed`.

GREEN proof:

    docker run --rm -v "$PWD:/workspace" -w /workspace/runner/cs-runner elixir:1.20-otp-29 sh -lc 'apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && go build -o /workspace/daemon/priv/cs-runner . && cd /workspace/daemon && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test'

Result: 454 passed.

The focused process-group suite also passed with 6 tests, including the PATH-independent real termination case.

## Exact-head termination identity follow-up

The exact-head security review found that termination trusted a persisted Attempt PGID before verifying that a live inventory manifest bound that PGID to the Attempt, fence, workspace, and runner identity.

Commit `ef5872f87900fd387fc1f7f709939fbf7af5f0e7` makes termination consult the canonical inventory first, require a matching persisted PGID, reject a registered runner for direct signaling, and require verified live runner liveness before signaling.

Tests-first RED proof:

    docker run --rm -v "$PWD":/workspace -w /workspace/daemon elixir:1.20-otp-29 sh -lc 'apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && MIX_ENV=test mix test test/consigliere/termination_test.exs test/consigliere/harness/redaction_test.exs --no-color'

The new test left a real session-leader process group without an inventory manifest and observed the prior implementation return `:ok` after signaling it instead of returning `{:error, :death_unverified}`.

Tests-first GREEN proof:

    docker run --rm -v "$PWD":/workspace -w /workspace/daemon elixir:1.20-otp-29 sh -lc 'apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix test test/consigliere/termination_test.exs test/consigliere/harness/redaction_test.exs --no-color'

Result: 2 passed.

The process-group assertion confirmed that the unverified persisted PGID remained alive while the Attempt was quarantined as unconfirmed.

## Pause termination identity follow-up

The exact-head review found that Boss pause independently trusted `Attempt.pgid` in both its termination and liveness checks, bypassing the canonical inventory and runner identity boundary.

Commit `94079e332f6b95cfe32678e65b93bc6a66fb8614` routes pause death verification and process-alive checks through `Consigliere.Termination`, so an unverified or recycled PGID leaves the Mission `:pausing` and cannot be signaled.

Tests-first RED proof:

    docker run --rm -v "$PWD":/workspace -w /workspace/daemon elixir:1.20-otp-29 sh -lc 'apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && MIX_ENV=test mix test test/consigliere/pause_test.exs --no-color'

The new real-process regression observed the prior implementation return `:paused` after signaling the persisted live PGID; the same run also lacked the packaged runner binary for an existing live-runner fixture, so its bounded result was 2/4 passed.

Tests-first GREEN proof is the combined event and pause command recorded in task 10 above.

The green result was 16 passed, and the new process assertion confirmed the unrelated session-leader group remained alive while pause stayed pending.

## Exact-head process-group membership follow-up

The exact-head security review found that a stale runner or harness PID could be alive while belonging to a different process group than the PGID recorded in its manifest.

Commit `c1ff0829985626df7a13ff4afa899e9e40667e3a` adds platform-specific process-group membership observation and requires both the recorded runner and harness to be verified members before inventory liveness can be `:verified`.

Tests-first RED proof:

    docker run --rm -v "$PWD":/workspace -w /workspace/daemon elixir:1.20-otp-29 sh -lc 'set -o pipefail; apt-get update -qq >/dev/null && apt-get install -y -qq golang-go >/dev/null && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && MIX_ENV=test mix test test/consigliere/process_group_test.exs test/consigliere/runtime/inventory_test.exs --no-color 2>&1 | tail -n 120'

The new inventory fixture returned `:verified` under the prior implementation for a live runner and harness in a different session group, and the new ProcessGroup test was undefined.

Tests-first GREEN proof:

    docker run --rm -v "$PWD":/workspace -w /workspace/daemon elixir:1.20-otp-29 sh -lc 'set -o pipefail; apt-get update -qq >/dev/null && apt-get install -y -qq golang-go >/dev/null && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix test test/consigliere/process_group_test.exs test/consigliere/runtime/inventory_test.exs test/consigliere/checkpoints_test.exs test/consigliere/reconciler_persist_test.exs --no-color 2>&1 | tail -n 140'

Result: 30 tests passed.

The test launched two real session leaders, confirmed the same-group identity, and rejected the unrelated group without signaling it.

The reconciler fixture now records harness identity fields so its positive live path exercises the same membership requirement.

The classic double-fork daemonization case was probed in the existing real runner suite and remains a documented structural limitation of periodic process-tree polling, rather than an unbounded V0 claim.

## Exact-head final verification

The full Linux daemon gate at the preceding source commit `cbdf6f7f2cbc2b1718ac73eaa47c0ad` passed `461 passed (1 doctest, 460 tests)` with warnings treated as errors.

The CLI and runner format, vet, ordinary, race, shuffle, and build gates also passed at that exact source head.

## Exact-head termination fence follow-up

The exact-head review found that pause revoked live capabilities and then independently minted a new Attempt fence before the runner manifest could be reconciled, leaving the live manifest stale and making verified-death identity fail closed.

Tests-first RED proof launched a real runner, captured its manifest fence, paused the Mission, and observed that the persisted Attempt fence differed from the manifest fence.

Commit `eca84cff15b651b9fc6a97aa56fd67b0fee143f6` keeps pause capability revocation and termination status changes in place without rotating the fence; the existing terminal identity and capability checks still block worker mutation after revocation.

Tests-first GREEN proof passed the real runner pause regression and the combined identity hardening slice with 5 pause tests and 41 tests overall.

The final Linux daemon gate at source head `c71bee7a6706b7279beafba0a951795124ad7ed4` passed `465 passed (1 doctest, 464 tests)` with warnings treated as errors.

## Exact-head asynchronous pause settlement follow-up

The exact-head review found that a runner could exit after the initial pause response while the durable `pausing` blocker remained open and the Mission stayed active.

Tests-first RED proof launched the real runner, requested pause, waited for the runner registry entry to disappear, and observed the Mission remain active with an open pause blocker.

Commit `2109e957a79e07f7941dcb61b0a911515512561c` adds that regression and settles the blocker after runner `DOWN`; commit `dd48a6ff54fc48d557b127503c95098f6dcca6a0` places the same retry in the coordinator refresh path so durable reconstruction and transient settlement failures converge.

Tests-first GREEN proof passed the real asynchronous pause test and the full Linux daemon suite passed `466 passed (1 doctest, 465 tests)` on the source head.

The guard checks the durable `pausing` blocker, so ordinary runner completion and active Missions are not paused as a side effect.

## Final runtime audit follow-up

The RED pause regression showed that a failed checkpoint import could still settle the Mission as paused after verified runner death.

The GREEN fix in `bf2dce60b52447e9075f05f135c4c36ccb2722ae` records one bounded checkpoint-import Incident and keeps the Mission in `pausing` until import succeeds.

The same runtime follow-up releases the global scheduler slot after every terminal Attempt classification, including protocol failure.

The focused pause and progression tests passed, and the final Linux daemon suite passed `473 tests` in each of three consecutive seed-0 runs.

## Post-audit recovery and dispatch race closure

The next runtime audit reproduced three additional recovery defects before the fixes: unverified death released the scheduler slot, a later harness-exit frame could overwrite a persisted protocol failure, and repeated native stream gaps could append repeated failure events.

Commit `39f342e7f8003ffd1b4c585a05a036ebcdc48fb7` holds unresolved dispatch slots durably as `unknown`, retains the first protocol-failure reason, and suppresses repeated protocol-failure persistence.

The focused local recovery command passed `6` tests, and the Linux focused recovery slice passed `20` tests including classification, reconciliation persistence, and authenticated runner recovery.

The clean full Linux suite then reproduced a stale `planned` Attempt race in `Dispatch.continue/4`, where a concurrent state change caused a MissionCoordinator `MatchError`.

Tests-first GREEN commit `f840893055303ab1802bbec5ee33861ece1b5853` re-reads the Attempt after the illegal transition, attaches an existing runner, holds unknown liveness, or releases a terminal slot without creating a duplicate Attempt.

The focused dispatch recovery suite passed `8` tests after that fix.

Commit `95ea4e5e38c6350f6560339708bbc33b985010b8` classifies a protocol-failure stop reason as a failed Attempt even when the durable failure marker races with runner termination, and serializes the non-sandboxed shared-home test suite at one case at a time.

The process-level report suite passed `2` tests, and the authoritative Linux daemon gate passed `476 passed (1 doctest, 475 tests)` in three consecutive seed-0 runs.

The native macOS full suite passed `467/476` with nine host-specific socket, path, and reconciler-fixture observations; the packaged macOS lifecycle passed independently with exact owner identity change, repeated stop, restart, and zero residual package processes.

Failure classes exercised or ruled out here were stale state, repeated interruption, malformed protocol completion, misleading process exit status, and flaky shared-test timing.

## Final runner identity and release-gate receipt

The final source head is `bf22b5d4cae239a222a3065ca4b34b574dd676ad`.

The fail-closed startup RED/GREEN proof is recorded in `runner-startup-boundary-bf22b5d.log`.

The final Linux daemon suite passed `486 passed (1 doctest, 485 tests)` in three consecutive seed-0 runs, and the CLI and runner Go gates passed formatting, vet, ordinary tests, race and shuffle tests, and builds.

The final package and installed lifecycle receipts are `package-artifact-bf22b5d.log` and `installed-lifecycle-bf22b5d.log`.

The selected real canary was not rerun after this runtime hardening because the operator-controlled rule forbids duplicate implementation work.
