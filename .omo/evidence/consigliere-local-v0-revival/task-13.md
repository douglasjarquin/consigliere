# Task 13 evidence

## Scope

Task #13 is the plan's issue #123, exact-SHA import and review-ready progression.

The implementation commit is 20c5f59d3db1f46cd8251f222f5f507d0b07edee.

The implementation records one strict Attempt result with Project, Mission, Attempt, Workspace, lease, base or parent, fence, exact SHA, result kind, and accepted terminal sequence identity.

It verifies runner death before external Git work, validates the exact commit and ancestry in the bound Workspace, hardens Workspace permissions, imports the exact object once to the daemon-owned result ref, and persists the durable progression phases.

It runs only bounded literal local Project commands with scrubbed environment, per-command and total time limits, bounded output, typed outcomes, and durable verification rows.

Successful completion stops at `ready_for_review` and exposes the Project, base, checkpoint, result ref, Workspace, and verification identity through `cs mission`, `cs review`, and `cs why`.

Checkpoint continuation requires the exact current SHA and creates a fresh Attempt, Workspace generation, fence, and capability without native Codex resume.

## Tests-first record

The initial exact-SHA RED characterization ran before the progression implementation.

It failed all three new scenarios because result refs and continuation were absent and the real Git fixture did not yet have a local commit identity.

The implementation then made those cases green and added regression coverage for conflicting SHA reports, missing death proof, identity mismatch, foreign ancestry, dirty or unsafe Workspace configuration, idempotent import, checkpoint continuation, and review-surface evidence.

## Automated verification

Command:

    docker run --rm -v "$PWD:/workspace" -v "$PWD/.tmp/task13-package/go-wrapper:/usr/local/bin/go:ro" -v "$PWD/.tmp/task13-package/cs-runner-linux:/tmp/cs-runner-linux:ro" -w /workspace/daemon elixir:1.20-otp-29 sh -c 'mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test'

Result: 439 passed, including one doctest and 438 tests.

The daemon compiled with warnings treated as errors.

Command:

    MIX_ENV=test mix test test/consigliere/progression_test.exs test/consigliere/git_test.exs test/consigliere/checkpoints_test.exs test/consigliere/gates/gate_test.exs test/consigliere/gates/transitions_test.exs test/consigliere/reconciler_persist_test.exs

Result: 55 passed.

Command:

    MIX_ENV=test mix test test/consigliere/project_verifications_command_test.exs test/consigliere/exact_sha_progression_test.exs

Result: 6 passed.

The direct command tests proved shell interpolation is not executed, timeout results are typed and bounded, and output is capped at 65,536 bytes.

The final security regression added to this command boundary proved that a synthetic parent environment value is absent from the verification child while the sanitized PATH and Git configuration variables remain available.

The verification child now starts through `env -i` with only the bounded allowlisted environment, so unlisted daemon or operator variables cannot cross into Project-configured commands.

Command:

    test -z "$(gofmt -l cli)" && (cd cli && go vet ./... && go test -race -shuffle=on -count=1 ./...)

Result: Go formatting, vet, and race suites passed for `cli/client` and `cli/service` on the macOS host.

A root Linux container attempt was not counted as a pass because its test process was PID 1 with process group 1, which correctly exercised the lifecycle identity guard and caused the process-group test to reject the synthetic owner.

The same Go gate passed on the host with `cli/client` in 1.471 seconds and `cli/service` in 1.757 seconds.

## Packaged terminal QA

Command:

    docker run --rm -v "$PWD:/workspace" -v "$PWD/.tmp/task13-package/go-wrapper:/usr/local/bin/go:ro" -v "$PWD/.tmp/task13-package/cs-runner-linux:/tmp/cs-runner-linux:ro" -v "$PWD/.tmp/task13-package/cs-linux:/tmp/cs-linux:ro" -v "$PWD/.tmp/task13-package/csd-linux:/tmp/csd-linux:ro" -w /workspace elixir:1.20-otp-29 sh -c './scripts/package.sh /workspace/.tmp/task13-package/prefix3'

Result: package assembly completed successfully.

The corrected artifact probe confirmed Linux ELF binaries at `prefix3/bin/cs`, `prefix3/bin/csd`, and `prefix3/libexec/consigliere_daemon/lib/consigliere_daemon-0.1.0/priv/cs-runner`.

The installed-only driver mounted only the package prefix and a fresh temporary `CS_HOME`, ran as UID 1000, used `/opt/consigliere/bin` plus system tools on `PATH`, set `CS_RELEASE` to the installed OTP release, set a fixture `CS_CODEX_BIN`, and ran from `/tmp` without a source checkout.

The driver invoked installed `csd migrate`, `csd start`, `cs project add`, `cs mission create`, `cs mission submit`, and `cs mission authorize`.

The real fixture Codex session wrote a bounded result, emitted JSONL lifecycle and usage events, committed the Workspace, and reported the exact result SHA through the authenticated Attempt channel.

The driver observed `phase=ready_for_review`, a 40-character lowercase result SHA, `status=imported`, `kind=completed`, the daemon-owned result ref, a nonempty Workspace identity, and a passed review verification row.

Bounded observed output included:

    mission 766d53da-b590-4525-ad8d-ae57019c13cf phase=ready_for_review project=ec849423-eec3-4c20-9469-2b3299c63921 base_sha=1ba883488a24b477d1180163041870c6e408eed5 checkpoint_sha=20ca83de704a5cdee2fdf16fb5322c58e1eeccb2
    result: sha=20ca83de704a5cdee2fdf16fb5322c58e1eeccb2 status=imported kind=completed ref=refs/consigliere/projects/ec849423-eec3-4c20-9469-2b3299c63921/attempts/f92af2ea-c4f6-408f-9c2d-fb3413a55858/result
    workspace: id=85325308-e619-4df5-bf2d-c0784c651d29 attempt=f92af2ea-c4f6-408f-9c2d-fb3413a55858 generation=876c3eee2cce1c833d5dcdedce1bd31f status=daemon_exclusive
    verification: gate=review ordinal=1 outcome=passed input_sha=20ca83de704a5cdee2fdf16fb5322c58e1eeccb2 output_digest=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    TASK13_PACKAGE stop=verified result=exact_sha_ready review_surface=verified

The installed human `cs mission`, `cs review`, and `cs why` surfaces all retained the full result SHA, daemon-owned ref, Workspace ID, and verification identity without `truncated` fields.

The installed `csd stop` completed and the driver asserted that `priv.sock`, `api.sock`, and `boss.sock` were absent afterward.

No push, pull request, merge, Made operation, legacy supervisor, native resume, or automatic delivery occurred.

## Adversarial coverage

- Short, non-hex, foreign, non-commit, non-ancestor, and conflicting result SHAs fail closed.
- Missing or unverified runner death prevents import and leaves the daemon-owned result ref absent.
- Wrong Project, Mission, Attempt, Workspace, lease, base, parent, fence, or terminal sequence identity is rejected before progression.
- Dirty or unsafe Workspace configuration, symlinked Git metadata, remotes, alternates, credential helpers, inherited hooks, and unsafe permissions are rejected or normalized before exact verification.
- A second import of the same exact result is idempotent, while a different object at the same daemon-owned ref is rejected.
- Exit zero without the strict result report cannot complete an Attempt.
- Duplicate terminal or result reports replay only the original bounded envelope and cannot replace the stored identity.
- Checkpoint continuation accepts only the exact current checkpoint SHA and produces fresh bound state rather than native transcript resume.
- Literal argv containing shell metacharacters remains data and cannot create a filesystem marker.
- Malformed policies, empty commands, non-literal argv, more than eight commands, missing executables, hung commands, canceled commands, and output above 65,536 bytes produce typed bounded failures.
- Project policy and mission policy are overlaid deterministically, so a mission gate selection cannot discard Project-configured verification commands.
- Prompt injection and misleading Codex prose cannot authorize progression because only the authenticated strict result payload, accepted terminal event, exact Git object, and typed verification outcome are authoritative.
- Repeated interruption and stale state are handled by durable result and verification rows and idempotent progression reconciliation.
- No full prompt, transcript, credential, raw command output, GitHub mutation, automatic PR, merge, telemetry platform, or fixed canary allocation was added.

The temporary package prefix, Linux build fixtures, wrapper, fake Codex executable, generated runner, and manual QA script remain disposable validation artifacts and are scheduled for macOS Trash cleanup before the next delivery phase.

No credentials, raw logs, or transcripts were written to this evidence record.

`git diff --check` passed before the implementation commit.

## Exact-head result replay identity follow-up

The exact-head review found that the idempotency comparator mapped `terminal_sequence` to a nonexistent struct field, allowing a same-SHA report with a different accepted terminal sequence to replay as a duplicate.

Tests-first RED proof added a later accepted terminal event and the prior implementation returned `{:ok, :duplicate}` instead of a result conflict.

Commit `98fc4d3ebbe78e0b73e7bba9c19d3861ff966565` maps `terminal_sequence` to the persisted `accepted_terminal_sequence` field.

Tests-first GREEN proof passed the exact-SHA, fragmented runner output, and fencing regressions with 6 tests.

The result row now treats a changed terminal event identity as a conflict while preserving idempotent replay for the complete original report.

## Durable progression checkpoint regression

The RED test installed a SQLite trigger that rejects the durable `AttemptResult` status update during progression.

Against the prior implementation, `Progression.run/2` still created the daemon-owned result ref even though the checkpoint write failed, proving that ignored persistence errors could publish external state without a durable checkpoint.

The GREEN fix propagates terminal-sequence, death-verification, commit-verification, and imported-status persistence failures and stops before result-ref import when a required checkpoint cannot be recorded.

Command:

    MIX_ENV=test mix test test/consigliere/progression_test.exs --seed 0

Result: 7 passed.

No credentials, raw logs, or transcripts were written to this regression record.

## Exact-head checkpoint workspace hygiene follow-up

The exact-head security review found that checkpoint import called `Git.import_sha/4` without first applying the full trusted-workspace verifier used by final result progression.

Commit `cbdf6f7f2cbc2b1718ac73e2aa47c0ad2519dfad` verifies the exact workspace HEAD, alternates, remotes, credential helpers, hooks path, Git permissions, and shared-object identity before any checkpoint import work.

Tests-first RED proof:

    docker run --rm -v "$PWD":/workspace -w /workspace/daemon elixir:1.20-otp-29 sh -lc 'set -o pipefail; apt-get update -qq >/dev/null && apt-get install -y -qq golang-go >/dev/null && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && MIX_ENV=test mix test test/consigliere/checkpoints_test.exs --no-color 2>&1 | tail -n 120'

The new test created a real checkpoint workspace with `.git/objects/info/alternates`; the prior implementation imported the checkpoint instead of returning `{:error, :alternates_present}`.

Tests-first GREEN proof:

    docker run --rm -v "$PWD":/workspace -w /workspace/daemon elixir:1.20-otp-29 sh -lc 'set -o pipefail; apt-get update -qq >/dev/null && apt-get install -y -qq golang-go >/dev/null && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix test test/consigliere/process_group_test.exs test/consigliere/runtime/inventory_test.exs test/consigliere/checkpoints_test.exs test/consigliere/reconciler_persist_test.exs --no-color 2>&1 | tail -n 140'

Result: 30 tests passed.

The rejected checkpoint left the Mission checkpoint SHA unset and the Attempt in `checkpoint_requested`, proving that no external import or durable progression occurred after the hygiene failure.

The test helper explicitly hardened Git permissions and configured the empty hooks directory so the positive checkpoint-import cases continue to exercise the complete verifier.

## Final runner protocol follow-up

The RED bridge regression showed that a rejected authenticated completion report could leave the Attempt nonterminal after the runner exited.

The GREEN runner path now decodes the bridge response, records a bounded `protocol_failure`, carries that classification through verified death, and releases the scheduler slot during terminal classification.

The native stream regression also showed that a gapped stdout sequence was accepted and could advance heartbeat state.

The final GREEN suite rejects missing, duplicate, and gapped native stream sequences while retaining exact result replay and exact-SHA progression behavior.

The final Linux daemon gate passed `473 tests` in three consecutive seed-0 runs after these changes.

## Watcher follow-up: packaged completion projection

The packaged real-Codex regression reproduced the prior runtime contract failure at the inherited head: the generated ContextPack required a checkpoint, so the real Codex process reported a checkpoint before completion and the Attempt became `checkpointed` while the Mission remained active with next action `validate`.

The ContextPack completion contract now requires exactly one terminal result and instructs the runner to complete without reporting a checkpoint first.

The exact-head packaged run used real `codex-cli 0.151.0` and reached `ready_for_review` with Attempt `c715dd59-64f4-413d-9697-60e58356ca9d`, Mission `a41140e2-2b15-446d-a881-3dbdfc1f43f6`, and imported result SHA `7669f9dc389db903835ca99aab4fc21187c94a52`.

The exact commands, bounded output, and cleanup receipt are recorded in `watcher-followup-c727e94.md`.

## Watcher follow-up security-aligned log read

The exact corrected package at source head `2c7f5b67c8d37737d8f2dd3e0f7110687a800748` completed a real Codex Attempt through `ready_for_review` and returned `ATTEMPT_LOGS_EXIT=0`.

The default advisory log response contained only allowlisted durable event summaries such as `1 session.started` and no captured log text or private path.

The source-level adversarial regression supplied prompt-injection text and a bearer-shaped secret in the Attempt log, then verified that neither appeared in the advisory response.

The exact package identifiers, result SHA, artifact hashes, gate commands, and cleanup receipt are in `watcher-followup-c727e94.md` with the current-head addendum below.

## Native command bound follow-up

The final packaged run was rebuilt from source head `4e99cf4219998c15b01d23b23349730f27546c61` after the native command output-bound review finding.

The real Codex terminal transition again reached `ready_for_review`, imported one exact result SHA, and returned `ATTEMPT_LOGS_EXIT=0` with structured event summaries.

## Exact-head default Attempt log boundary closure

Commit `cc5c2ae368007ec30fba81d74d5a30808176a9d8` routes every authorized `attempt.logs` response through the existing bounded event-only sanitizer.

The RED characterization at `daemon/test/consigliere/api_cli_ops_test.exs:117` observed raw captured text and a private path from the default authorized response.

The RED regression then added bearer-shaped secret text and prompt-like text and required the response keys to be exactly `attempt_id` and `lines`.

The GREEN focused command passed `Result: 1 passed, 7 excluded` for the targeted test.

The focused API, advisory, and protocol suite passed `Result: 21 passed` with exit `0`.

The exact-head packaged run is recorded in `manual-qa-cc5c2ae-real-final.log`.

It used native arm64 `cs` and `csd` artifacts, the installed real Codex CLI, one completed Attempt, and one `ready_for_review` Mission.

The default `cs attempt logs` response exposed only bounded allowlisted event summaries.

The response omitted the injected secret-shaped text, prompt-like text, and private filesystem path.

The same run verified the bounded command-output error at 65,536 bytes, changed owner identity after restart, accepted repeated stop, and left zero sockets or PID files.

The temporary package home and source repository were moved to macOS Trash and verified absent.
