# Task 1 evidence: V0 baseline, scope, branch, and green CI

Date: 2026-08-29.

Commit scope: `chore(v0-00): establish local V0 baseline and scope`.

## Identity and custody

`pwd -P` returned `/Users/douglasjarquin/.herdr/worktrees/consigliere/cs-consigliere-local-v0-revival`.

`git rev-parse --show-toplevel` returned the same disposable worktree.

`git branch --show-current` returned `revival/v0-local-codex` after the required pre-commit rename.

`git rev-parse origin/rewrite-in-elixer` returned `24ffea8fa1f5bc983fb5965efab0a89b6116f05b`.

`git rev-parse HEAD` returned `24ffea8fa1f5bc983fb5965efab0a89b6116f05b` before the task-1 implementation commit.

`/opt/homebrew/bin/gh-axi pr view 101` confirmed PR #101 is open, draft, unmerged, and historical.

## Tests-first proof

The host probe `MIX_ENV=test mix test test/consigliere/runner_process_env_test.exs` could not start because this host has no `erl` executable.

A clean Linux-equivalent `elixir:1.20-otp-29` probe with a prebuilt Linux `cs-runner` passed `runner_process_env_test.exs` with `2/2` tests.

The same clean image without Go exposed the actual CI defect before the fix.

The full daemon probe passed format and compile but reported `354/379` tests and `25` failures.

The failures were setup failures at `System.cmd(go, [build, -o, cs-runner, .])` in runner-backed daemon tests because the daemon CI job did not install Go.

The targeted `runner_process_test.exs` and `reconciler_test.exs` probe reproduced the same `:enoent` failure before any production change.

The new machine-consumed CI contract test was then run against the unchanged workflow and failed `10/11` with the expected assertion that the daemon job lacked `actions/setup-go@v5`.

## Implementation and GREEN proof

`.github/workflows/ci.yml` now installs Go in the daemon job using `actions/setup-go@v5` and `go-version-file: runner/cs-runner/go.mod`.

`daemon/test/ci_contract_test.exs` pins that daemon-job dependency and passed `11/11` in the Linux-equivalent container.

The full daemon command `mix deps.get && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test` passed with `380` tests.

The full gate used Elixir `1.20` with OTP `29` and installed Go only inside the disposable container.

The exact runner environment test passed after the fix path with `2/2` tests and no leaked environment values.

## Packaged manual QA

The exact package command was `/workspace/scripts/package.sh /workspace/prefix` in a disposable `elixir:1.20-otp-29` container with the repository archived into a temporary directory.

The package result was exit `0` and installed `cs`, `csd`, the OTP release, `cs-runner`, and the cutover runbook.

The installed-only shell used `env -i`, `PATH=/tmp/installed/bin:/usr/local/bin:/usr/bin:/bin`, `CS_RELEASE=/tmp/installed/libexec/consigliere_daemon`, and a fresh temporary `CS_HOME`.

The installed-only sequence was `csd migrate`, `csd start`, `cs ping`, `cs doctor`, `csd stop`, `csd restart`, and a final cleanup `csd stop`.

The observed output included `migrated`, `started`, `pong`, live boss and API sockets, `stopped`, `restarted`, and `stopped`, with `package_result=0`.

The smoke ran from `/tmp` without Mix, a checkout path, or a legacy Bash supervisor on `PATH`.

The container was removed by Docker and the temporary source and package directory were moved to the host trash by the shell trap.

## Adversarial coverage

Malformed workflow structure was covered by the CI contract parser and a missing daemon Go setup failed closed before the fix.

Missing runtime dependencies were probed through the host `erl` failure and the container `go` failure, and the valid Linux-equivalent path was then used for GREEN.

Misleading output was not trusted because the contract test asserted parsed workflow content, the language gate asserted exit status, and the package smoke asserted live socket state through `cs doctor`.

Fresh-home and stale-state behavior were covered only at the package baseline level by starting from a new temporary home and observing the lock and socket state.

Cancel, resume, authorization, runner identity, prompt injection, and canary allocation are not task-1 surfaces and remain ruled out by the task-1 scope contract for later queue items.

Dirty worktree handling was covered by running the package from a clean `git archive` copy and overlaying only the task-1 files.

Repeated interruption, response loss, hung external work, and exact-SHA recovery require later queue items and were not claimed by this baseline evidence.

## Cleanup receipt

The temporary archive, package prefix, installed home, container, and restarted daemon were all cleaned within the QA command, and the final `csd stop` returned success.

## Final head closure

The final runtime head is `95ea4e5e38c6350f6560339708bbc33b985010b8`.

The CI-shaped Linux daemon command used Elixir `1.20`, OTP `29`, Go `1.26.6`, `mix format --check-formatted`, `MIX_ENV=test mix compile --warnings-as-errors`, and three seed-0 full-suite runs.

Each run passed `476 tests` including one doctest.

The final native package and installed lifecycle are recorded in `F3.md` with exact artifact hashes and stop cleanup receipts.

The final source, Go, package, and lifecycle gates were run after the runtime audit commits and before the replacement PR is updated.

The final native package was `.tmp/package-95ea4e5-Gfnr21` with `cs` hash `4b977c4361239244630749d331837c58d5aad99e1d197103d4847c628a433815`, `csd` hash `49074f20047840f485d110190da0fd20fbd52646969dc5f1d920f778cb584bed`, `cs-runner` hash `a188c50b3c0fa578dc7606a38bec41eeafa1889cd2ca41b553f9ec016481c5a8`, and `cs-attempt` hash `c6c0a480facfafdb45c7b37e36d41fd6fc17605da576c6b0e7633cb5776702a9`.

The package and installed lifecycle details are recorded in the final F1 through F3 evidence records.
