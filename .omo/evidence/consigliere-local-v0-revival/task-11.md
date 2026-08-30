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
