# Watcher follow-up evidence

Date: 2026-08-30.

Exact implementation source head for this record: `c727e94ae2bac1be0d3d33fc0005258e5fd850cd` on `revival/v0-local-codex`.

The full source SHA was captured with `git rev-parse HEAD` immediately before this record was written.

## P0 packaged completion regression

The baseline package was assembled with `scripts/package.sh "$PWD/.tmp/watcher-followup/package-prefix"` from source head `b3ba05b3ff1c7fb5ecca69dc75d7dc405029a2e4`.

The first baseline run used a task-worktree-relative `CS_HOME` and stopped before dispatch with macOS `{:bind_failed, {:error, :einval}}` because the Unix-domain socket path was too long.

The faithful retry used a fresh short `/tmp` home and the real installed `codex-cli 0.151.0` through `.tmp/watcher-followup/p0-real-baseline.sh`.

The baseline command was `./.tmp/watcher-followup/p0-real-baseline.sh > .tmp/watcher-followup/p0-real-baseline.log 2>&1`.

The real Codex session committed exact SHA `151179a247353e32827e846a452c1b0504331d7` and its final shell action ran `$CS_ATTEMPT_BIN checkpoint --sha ...` followed by `$CS_ATTEMPT_BIN complete --sha ...`.

The durable baseline result was Attempt `a83bac49-3ec9-450e-af3e-940daf7177fb` with result kind `checkpoint` and status `checkpointed`.

The baseline Mission `786f700b-3dc4-4e7f-b882-5a160023b7b8` remained `active` with the status next action `validate`.

This proves the first-terminal result rule was correctly preserving the checkpoint, while the ContextPack's `completion.require_checkpoint: true` caused a real final completion to be sent after the checkpoint and rejected as a result conflict.

The RED ContextPack test was `PATH="/opt/homebrew/opt/erlang/bin:$PATH" MIX_ENV=test mix test test/consigliere/harness/context_pack_test.exs:128 --seed 0 --no-color`.

Its result was `result.pack["completion"]["require_checkpoint"]` left `true` instead of `false`, with `Result: 0/1 passed` and exit `2`.

The GREEN fix is in `daemon/lib/consigliere/harness/context_pack.ex` and tells the model to report exactly one terminal result, makes final completion independent of a prior checkpoint, and explicitly forbids checkpoint before completion.

The focused GREEN command was `PATH="/opt/homebrew/opt/erlang/bin:$PATH" mix format lib/consigliere/harness/context_pack.ex test/consigliere/harness/context_pack_test.exs && PATH="/opt/homebrew/opt/erlang/bin:$PATH" MIX_ENV=test mix test test/consigliere/harness/context_pack_test.exs test/consigliere/runner_process_attempt_report_test.exs test/consigliere/exact_sha_progression_test.exs --seed 0 --no-color`.

The corrected result was `Result: 11 passed` and exit `0`.

The exact-head package was rebuilt with `scripts/package.sh "$PWD/.tmp/watcher-followup/package-prefix" > .tmp/watcher-followup/package-exact-c727e94.log 2>&1`.

The exact-head packaged run was `./.tmp/watcher-followup/p0-real-baseline.sh > .tmp/watcher-followup/p0-exact-c727e94.log 2>&1`.

It used real `codex-cli 0.151.0`, produced one completed report for Attempt `86e93c30-fc58-4aa0-9282-6079aeaa34b6`, and reached Mission `bea55ffd-ff2a-446f-b05f-66bd37d75786` phase `ready_for_review`.

The observed progression was `running -> completed/reported -> completed/imported`, followed by exact-SHA verification and `ready_for_review`.

The exact imported result SHA was `86eb7772474e05cc40e19f8e6510867696f91806`, with the daemon-owned result ref and a passed review verification row.

The default `cs attempt logs` command in that run returned exit `0`, bounded redacted lines, and no private path.

The full package lifecycle refresh then executed repeated `csd stop`, `csd restart`, `cs status`, `cs why`, `cs review`, `cs doctor`, `csd status`, and final repeated stop without creating a second canary record.

Its final receipt was `LIFECYCLE=stopped sockets=0 pid_files=0`.

## P1 default attempt-log read

The P1 packaged RED was the baseline `cs attempt logs a83bac49-3ec9-450e-af3e-940daf7177fb --json` call, which returned `{"ok":false,"error":{"code":"unauthorized","reason":"advisory_operation_forbidden"}}` and exit `5`.

The RED test was `daemon/test/consigliere/advisory_test.exs:advisory can read bounded redacted Attempt logs without private paths`.

The RED result was `response["ok"] == false`, with `Result: 0/1 passed` and exit `2`.

The GREEN implementation restores `attempt.logs` as a read-only advisory operation and uses a dedicated bounded log sanitizer that returns redacted lines while omitting the private path.

The focused GREEN command was `PATH="/opt/homebrew/opt/erlang/bin:$PATH" mix format lib/consigliere/api/protocol.ex lib/consigliere/advisory.ex test/consigliere/advisory_test.exs && PATH="/opt/homebrew/opt/erlang/bin:$PATH" MIX_ENV=test mix test test/consigliere/advisory_test.exs test/consigliere/api_cli_ops_test.exs test/consigliere/api_protocol_test.exs --seed 0 --no-color`.

The result was `Result: 21 passed` and exit `0`.

The exact-head packaged run returned `ATTEMPT_LOGS_EXIT=0` and exposed bounded redacted lines without the path key.

The existing advisory mutation matrix remained green, including refusal of authorization, pause, cancel, continuation, delivery, question answer, reconciliation, and daemon shutdown.

## Command-output bound

The RED test was `daemon/test/consigliere/project_verifications_command_test.exs:bounds one oversized command output before accumulating it`.

The controlled pre-fix RED used one `head -c 200000 /dev/zero` command output stream in a monitored process with a bounded heap and observed the old process killed before a bounded result, with `Result: 4/5 passed` and exit `2`.

The GREEN implementation checks `byte_size(output) + byte_size(data)` before appending, then retains only the remaining prefix up to 65,536 bytes.

The GREEN command was `PATH="/opt/homebrew/opt/erlang/bin:$PATH" mix format lib/consigliere/project_verifications/command.ex test/consigliere/project_verifications_command_test.exs && PATH="/opt/homebrew/opt/erlang/bin:$PATH" MIX_ENV=test mix test test/consigliere/project_verifications_command_test.exs --seed 0 --no-color`.

The result was `Result: 5 passed` and exit `0`.

The existing literal argv, timeout, and scrubbed environment tests remained green.

## Full relevant gates

The prescribed daemon command was `mix deps.get && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test --seed 0 --no-color` from `daemon`.

The daemon result was `Result: 499 passed (1 doctest, 498 tests)` and exit `0`.

The first runner log redirection used one incorrect relative path and failed before the gate started.

The corrected runner command was `test -z "$(gofmt -l .)" && go vet ./... && go test -race -shuffle=on -count=1 ./...` from `runner/cs-runner`.

The runner result was `ok consigliere/cs-runner 44.384s` and exit `0`.

The corresponding CLI command was `test -z "$(gofmt -l .)" && go vet ./... && go test -race -shuffle=on -count=1 ./...` from `cli`.

The CLI result passed `github.com/douglasjarquin/consigliere/cli/client` and `cli/service`, with command and package exits `0`.

The current package artifacts are native arm64 Mach-O files with SHA-256 values `cs=eb6f04d737ab175a2b167c9d4af85cdf1498143837fe2ed76682aa3bf62699c2`, `csd=6f0d2a9aec3b1e3b443e4cbbd05face85ab0db4acb479f4c6992c5fce1644738`, `cs-runner=37a8416a9820d5990942f6e6767f9816725056456065dca9b145432fcb7dcb56`, and `cs-attempt=b98cbf9768eeb2a89e0a54bdc5b3506cf56da4a74058e286621481a7a8969d7f`.

The installed release contains the 15 required migration `.exs` files and no checkout `go.mod`, `mix.exs`, or application source tree.

## Adversarial and custody coverage

Malformed input, prompt injection, stale identity, dirty or unsafe workspaces, hung commands, misleading model output, cancel and checkpoint continuation, repeated interruption, duplicate terminal reports, exact-SHA conflicts, unauthorized advisory mutations, log redaction, and output overflow remain covered by the existing task evidence and the full daemon suite.

The new P0 proof specifically rules out a parser or Git verification failure because the baseline and fixed packages used the same real Codex version, exact workspace commit path, runner death verification, import, and review gate.

The new P1 proof specifically rules out a privilege widening because only the bounded read operation was added to the advisory allowlist and private paths remain omitted.

No selected canary Mission was rerun, no FirstMate duplicate was created, no fixed comparison allocation or Promote claim was added, and no shared Made daemon was started, stopped, or changed.

The temporary package prefix, temporary Codex homes, temporary source repositories, test process crash dump, and QA driver artifacts require the cleanup receipts appended below before delivery.

## Cleanup receipt

The task-owned `/tmp/cs-p0-real.*` homes were absent after each driver's identity-safe cleanup trap, and a final process scan found no Consigliere daemon, runner, Attempt process, or Codex process.

The exact worktree cleanup command was `trash "$PWD/.tmp/watcher-followup"; trash "$PWD/erl_crash.dump"`.

The command returned `watcher_trash_rc=0 crash_trash_rc=0` and verified `watcher-followup absent` and `erl_crash.dump absent`.

The unrelated `.tmp/attempt-report-*`, `cli/.tmp`, `_build`, and runner scratch artifacts were preserved.

## Current-head security-aligned addendum

The source head advanced to `2c7f5b67c8d37737d8f2dd3e0f7110687a800748` for the security-aligned advisory projection and the ContextPack test-quality cleanup.

Tests-first RED changed the advisory regression to include prompt-injection text and a bearer-shaped secret while requiring only structured event summaries in the response.

The GREEN focused command was `PATH="/opt/homebrew/opt/erlang/bin:$PATH" mix format --check-formatted && PATH="/opt/homebrew/opt/erlang/bin:$PATH" MIX_ENV=test mix test test/consigliere/advisory_test.exs test/consigliere/api_cli_ops_test.exs test/consigliere/api_protocol_test.exs test/consigliere/harness/context_pack_test.exs test/consigliere/project_verifications_command_test.exs --seed 0 --no-color`.

The result was `31 passed` with exit `0`.

The prescribed daemon gate was rerun serially after the earlier concurrent review clone released the shared test fixture home.

The daemon result was `499 passed (1 doctest, 498 tests)` with exit `0`.

The runner race gate returned `ok consigliere/cs-runner 45.162s` with exit `0`.

The CLI race gate passed `cli/client` and `cli/service` with exit `0`.

The package was rebuilt from this head and produced native arm64 Mach-O artifacts with SHA-256 values `cs=80ea4c4b0f4f34ea3a1f43d2c79eb84f38ad71c0a1d6c603bb1d1be4555ef712`, `csd=fe5974be3d56860d56de0ea633bc2b5f030877aaaec32e5aeaba618a2a25b692`, `cs-runner=36db0deb9d9d71585296f1dd8bfe3eeb4288386991f81c232141b869cde62345`, and `cs-attempt=51050042a4c3d8402c02dc85fad7cf2fb069cdfbf20f5213f4599ec14ef4eb0b`.

The package contains 15 required release migration `.exs` files and no checkout `go.mod` or `mix.exs`.

The packaged real Codex run used `codex-cli 0.151.0`, reached `ready_for_review` at poll 44, and ended with Attempt `ae033bd4-58cb-43ff-ad57-c424d53e2ccd`, Mission `3f7e0877-2b87-4bf9-b146-d08f330a97d0`, and imported result SHA `de807e26860bcd67eb81f0f2e82570015ffd3563`.

Its default `cs attempt logs` call returned `ATTEMPT_LOGS_EXIT=0` and exposed only structured event summaries.

The same package passed repeated stop, restart, status, why, review, doctor, and final stop checks with `LIFECYCLE=stopped sockets=0 pid_files=0`.

The current package cleanup command was `trash /tmp/cs-p0-real.DH2BRL; trash "$PWD/.tmp/watcher-followup"`.

It returned `home_present=0 watcher_present=0 home_trash_rc=0 watcher_trash_rc=0` and verified `cs-p0-real.DH2BRL absent` and `watcher-followup absent`.

The unrelated taskwork scratch remains preserved.

## Current-head native command bound addendum

The source head advanced to `4e99cf4219998c15b01d23b23349730f27546c61` for the adjacent native command output bound identified during exact-head code review.

The tests-first RED command was `PATH="/opt/homebrew/opt/erlang/bin:$PATH" MIX_ENV=test mix test test/consigliere/runtime/command_test.exs --seed 0 --no-color` after adding a one-chunk 200,000-byte `/dev/zero` regression.

The RED result was `1/2 passed`, with the old implementation returning a 131,072-byte `output_too_large` result under the bounded heap fixture.

The GREEN implementation checks the accumulated byte count plus the received chunk size before combining iodata, then returns at most 65,536 bytes.

The GREEN command was `PATH="/opt/homebrew/opt/erlang/bin:$PATH" mix format lib/consigliere/runtime/command.ex test/consigliere/runtime/command_test.exs && PATH="/opt/homebrew/opt/erlang/bin:$PATH" MIX_ENV=test mix test test/consigliere/runtime/command_test.exs test/consigliere/project_verifications_command_test.exs --seed 0 --no-color`.

The result was `7 passed` with exit `0`.

The serial full daemon gate was rerun after the runtime fix and returned `500 passed (1 doctest, 499 tests)` with exit `0`.

The final package was rebuilt from this runtime source and returned package exit `0`.

It contained native arm64 Mach-O `cs`, `csd`, `cs-runner`, and `cs-attempt` artifacts with SHA-256 values `cs=e291faa43bdd39c19a0313278854aa14362c670476e35c98ae4807e6ecd2339c`, `csd=0b129ccebc0f60dee66257a97ef3e29463975599e5c8f57615946009ebf62b79`, `cs-runner=3fb8fee892f594409508d5417075139daf442f4b2069032b2aec42a4b6af8d95`, and `cs-attempt=a908c6a03230a5c700878985ee336d2d9c41e888fc8c6864c4b9452b097987a6`.

The package contained 15 required release migration `.exs` files and no checkout `go.mod` or `mix.exs`.

The final packaged real Codex run used `codex-cli 0.151.0`, reached `ready_for_review` at poll 32, and ended with Mission `04877deb-2e4b-4eac-be4b-8c6bc85fdee8`, Attempt `2815c4c0-5e0c-4dcc-8754-9e9f27afc255`, and imported result SHA `319cff82093f53ade791d2175646d6d42dba2e2a`.

Its default `cs attempt logs` call returned `ATTEMPT_LOGS_EXIT=0` and only fixed durable event summaries.

The lifecycle proof passed repeated stop, restart, status, why, review, doctor, and final stop with `LIFECYCLE=stopped sockets=0 pid_files=0`.

The final cleanup command was `trash /tmp/cs-p0-real.IeqOkM; trash "$PWD/.tmp/watcher-final"`.

It returned `home_present=0 watcher_present=0 home_trash_rc=0 watcher_trash_rc=0` and verified both task-owned paths absent.

The exact-head runner gate was `test -z "$(gofmt -l .)" && go vet ./... && go test -race -shuffle=on -count=1 ./...` from `runner/cs-runner` and returned `ok consigliere/cs-runner 44.122s` with exit `0`.

The exact-head CLI gate used the same format, vet, race, and shuffle command from `cli` and passed `cli/client` and `cli/service` with exit `0`.

The final 4e99 package cleanup used `/usr/bin/trash` on `/private/tmp/cs-p0-real.IeqOkM` and the task-owned `.tmp/watcher-final` directory.

It returned `home_present=0 watcher_present=0 home_trash_rc=0 watcher_trash_rc=0` and verified `cs-p0-real.IeqOkM absent` and `watcher-final absent`.
