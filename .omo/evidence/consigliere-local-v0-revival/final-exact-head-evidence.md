# Exact-head verification archive

Superseded sections in this archive are explicitly marked historical; the current delivery claims below are bound to the latest immutable evidence child.

The historical implementation evidence was bound to runtime source `0c2b24c02490c8f6f53b7f6bc1a9fb9add519861` and its immutable evidence child, in `final-gate-receipt.md`, `F1.md`, `F2.md`, `F3.md`, and `F4.md`.

The historical exact implementation included the bounded Away digest, monotonic paged cursor acknowledgement fix, durable cancellation cause, deferred cancellation outcome fix, marker snapshot fence, unverified terminating Attempt reconciliation, and filesystem marker token fence, with focused RED/GREEN, daemon, package, and lifecycle receipts in `away-return-0c2b24c.md`, `termination-0c2b24c.md`, `daemon-gate-0c2b24c.md`, `package-artifact-0c2b24c.md`, and `installed-lifecycle-0c2b24c.md`.

Target branch: `revival/v0-local-codex`.

Historical target runtime commit: `42933d103da9171c76b1564888e0d6557291fb5d`.

Base commit: `24ffea8fa1f5bc983fb5965efab0a89b6116f05b` from `origin/rewrite-in-elixer`.

The runtime source commits included at this exact head are `e0e3fb3b7f8f8ff5b180f404ff11a5a8efdfe8f6` for provider-key redaction, `a2636f70b104988f5c676c2012543a0299064be3` for authenticated stderr retention, `f1d1dfa02f39bf88b682855a440d8dc6d5214ebf` for fragmented runner stdout buffering, `98fc4d3ebbe78e0b73e7bba9c19d3861ff966565` for terminal-sequence-safe result replay, `a3951ec73989f236a075973c373c9c57b2672af9` for camel-case credential redaction, `bf2dce60b52447e9075f05f135c4c36ccb2722ae` for runner failure and stream recovery, `39f342e7f8003ffd1b4c585a05a036ebcdc48fb7` for recovery slot and protocol-stream hardening, `f840893055303ab1802bbec5ee33861ece1b5853` for stale dispatch race reconciliation, `95ea4e5e38c6350f6560339708bbc33b985010b8` for protocol-failure exit classification and shared test-home serialization, `9a7b1626a1a2113f8d7faac1521f4ea4305c0b19` for atomic dispatch-slot persistence, `bc7e980c90aa54e165d5aed3dae060f3a2c9e584` for scheduler rebuild coverage, `49db8624a8140eda0449a03f5f706142eeb99493` for one recoverable Attempt and planned cancellation slot release, and `42933d103da9171c76b1564888e0d6557291fb5d` for SQLite uniqueness characterization.

The historical documentation-only delta from runtime commit `42933d103da9171c76b1564888e0d6557291fb5d` to its then-final evidence head contained only task evidence records, final gate records, `docs/v0-local.md`, and `docs/v0-canary.md`.

Historical command:

    git diff --exit-code 42933d103da9171c76b1564888e0d6557291fb5d HEAD -- daemon cli runner scripts .github

Result: exit 0 with no runtime, package, workflow, CLI, or runner input changes in that documentation-only delta.

## Historical authoritative Linux daemon gate for 42933d1

Command:

    docker run --rm -v "$PWD":/workspace -w /workspace/runner/cs-runner elixir:1.20-otp-29 sh -lc 'set -o pipefail; apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && go build -o /workspace/daemon/priv/cs-runner . && cd /workspace/daemon && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test --no-color'

Result: format passed, compile with warnings as errors passed, and `482 passed (1 doctest, 481 tests)` in three consecutive seed-0 runs with Go 1.26.6 built inside the CI-shaped Elixir container.

The complete daemon suite passed three consecutive seed-0 runs after the final hardening.

The suite includes the persisted-PGID termination, structured event redaction, oversized ContextPack, PATH-independent process observation, and pause identity regressions.

## Historical Go gates for 42933d1

CLI command:

    cd cli && test -z "$(gofmt -l .)" && go vet ./... && go test ./... && go test -race -shuffle=on -count=1 ./... && go build ./cmd/cs ./cmd/csd

CLI result: format, vet, ordinary tests, race and shuffle tests, and build passed.

Runner command:

    cd runner/cs-runner && test -z "$(gofmt -l .)" && go vet ./... && go test ./... && go test -race -shuffle=on -count=1 ./... && go build ./...

Runner result: format, vet, ordinary tests, race and shuffle tests, and build passed.

## Historical exact-head package and installed lifecycle for 42933d1

Package command:

    PATH=/opt/homebrew/opt/erlang/bin:$PATH scripts/package.sh "$PWD/.tmp/package-42933d1.mZakYT"

Package prefix: `.tmp/package-42933d1.mZakYT`.

Package hashes: `cs` `4b3891c4a27c3c21b10c8324627f2701288cdf83842f8a02619da61df2dd4a2c`, `csd` `400d29f584f7ceacf225608cb28c25ddaf3c9846b19e8e8aa890496afa020b48`, `cs-runner` `fa583582034b6c3aa1c1831f387fe578519172990876c6cf4774c28b7b12a382`, and `cs-attempt` `9393d8fecbadaf680caec85f260443fed17c9a5bdaa76a3ad408d683d95b2acb`.

`file` reported native arm64 Mach-O for all four inspected executables.

The package tree contained zero `.go`, `.ex`, `mix.exs`, `mix.lock`, or `go.mod` source-like files outside the shipped Ecto migration scripts.

`cs version --json` returned `{"cs":"0.1.0","protocol":1}`.

The installed lifecycle used fresh `/tmp/cs-final-42933d1-home.e7matc`, `env -i`, the exact package prefix, and a working directory of `/tmp`.

The commands were `csd migrate`, `csd start`, `cs ping`, `cs health`, `cs doctor`, `csd status`, `cs projects`, absence of `notifications.log`, `csd stop`, repeated `csd stop`, `csd restart`, `cs ping`, `cs doctor`, `csd status`, absence of `notifications.log`, final `csd stop`, PID absence, and Unix-socket absence.

Result: `F3_INSTALLED_LIFECYCLE stop=verified sockets=0 pid_files=0 owner_files=0 notifications=0 package=/Users/douglasjarquin/.herdr/worktrees/consigliere/cs-consigliere-local-v0-revival/.tmp/package-42933d1.mZakYT runner=fa583582034b6c3aa1c1831f387fe578519172990876c6cf4774c28b7b12a382 attempt=9393d8fecbadaf680caec85f260443fed17c9a5bdaa76a3ad408d683d95b2acb`.

The fresh migration emitted one transient SQLite `database is locked` connection log while the schema lock initialized, then completed successfully and all lifecycle commands returned success.

Cleanup receipt: `CLEANUP=trashed:/tmp/cs-final-42933d1-home.e7matc`; the isolated environment home `/tmp/cs-final-42933d1-env.C2tGuR` was also moved to Trash.

## Historical canary custody for 42933d1

The real operator-controlled canary remains the single naturally occurring dotfiles Mission recorded in `task-15.md` and `docs/v0-canary.md`.

It used the committed package from `e2b7fe445e96c356354f31f849e9756b265ecec8`, created exactly one checkpoint Attempt and one explicit operator-authorized continuation, and reached exact-SHA review-ready.

The final exact-head package was exercised through the installed lifecycle only because rerunning the same implementation would violate the no-duplicate canary rule.

There are zero FirstMate duplicate Missions and fewer than 20 naturally occurring comparable Missions, so the evidence remains insufficient for Promote and the operator retains Continue or Stop.

Raw canary database, manifests, usage rows, and logs remain outside this repository.

## Historical custody and scope for 42933d1

`git diff --check` passed at the target head.

`git status --short --untracked-files=no` was empty at the target head.

Only intended tracked implementation, test, documentation, and evidence files are staged for delivery; local untracked build logs and scratch artifacts are excluded from the PR.

PR #101 remains historical input and PR #141 is the separate draft replacement; neither is merged.

## Historical final exact-head evidence for bf22b5d

The prior receipt targets are historical intermediate heads.

The historical implementation head was `bf22b5d4cae239a222a3065ca4b34b574dd676ad` on `revival/v0-local-codex`.

The final Linux daemon receipt reports `486 passed (1 doctest, 485 tests)` in three consecutive seed-0 runs.

The final CLI and runner Go receipts report format, vet, ordinary tests, race and shuffle tests, and builds passing.

The final package and installed lifecycle receipts are `package-artifact-bf22b5d.log` and `installed-lifecycle-bf22b5d.log`.

The selected real canary remains the single naturally occurring Mission with one operator-authorized continuation and zero FirstMate duplicate Missions.

The canary was not rerun against the final package because the operator-controlled no-duplicate rule forbids duplicate implementation work.

The natural comparable sample remains below 20, so the evidence is insufficient for Promote and the operator retains Continue or Stop.

## Historical exact-head closure for 7159373

The historical runtime source head was `71593738cf6aae723c9208743405fa12a9dc7a03` on `revival/v0-local-codex`.

The exact-head package and lifecycle receipts are `package-artifact-7159373.md` and `installed-lifecycle-7159373.md`.

The Linux daemon gate passed `491 passed (1 doctest, 490 tests)` three times, the CLI and runner Go gates exited `0`, and the native macOS daemon gate passed `491 passed (1 doctest, 490 tests)`.

The selected canary was not rerun against this package because the operator-controlled rule forbids duplicate implementation work.

The public canary result remains one completed Consigliere Mission with two Attempts, zero FirstMate Missions, and insufficient evidence for Promote.

## Historical exact runtime source closure for 7c54c78

The historical runtime source head was `7c54c782552f3ee5a09ddee35735e90cba1b9339` on `revival/v0-local-codex`.

The preceding runtime audit blockers are closed by `runtime-audit-followup-7c54c78.md`.

The authoritative Linux daemon gate passed `496 passed (1 doctest, 495 tests)` in three consecutive seed-0 runs.

The native macOS daemon gate passed the complete `496`-test suite.

The CLI and runner Go gates passed formatting, vet, ordinary tests, race and shuffle tests, and builds.

The exact package and installed lifecycle receipts are `package-artifact-7c54c78.md` and `installed-lifecycle-7c54c78.md`.

The package contained no Go, Elixir, Mix, or module source files, all inspected binaries were native arm64 Mach-O, and `cs version --json` returned `{"cs":"0.1.0","protocol":1}`.

The selected real canary was not rerun against the final package because the operator-controlled rule forbids duplicate implementation work.

The public canary remains one completed Consigliere Mission with two Attempts, zero FirstMate Missions, and insufficient evidence for Promote.

## Historical closing delivery-head evidence for 85f02c5

The runtime source head is `7c54c782552f3ee5a09ddee35735e90cba1b9339`.

The pushed evidence delivery head is `85f02c5b739116d7de0d3f04a372f463bbb913e6`.

The tracked diff from the runtime source head to the delivery head changes only documentation and evidence files.

The exact command `git diff --exit-code 7c54c782552f3ee5a09ddee35735e90cba1b9339 HEAD -- daemon cli runner scripts .github` exited `0`.

PR #141 remains open and draft at the delivery head, with base `rewrite-in-elixer`.

Remote CI run `33322422318` for the delivery head completed successfully with `5 passed, 0 failed, 5 total`.

PR #101 remains historical and unchanged, and neither PR is merged.

The final gate review is `gate-review-final-85f02c5.md` and reports PASS with no blockers.

The selected real canary was not rerun after runtime hardening because the no-duplicate rule forbids another implementation record.

## Historical pushed-head attestation for c060b88

The final pushed head is `c060b88035128bbdbf361f1bcab9a100521965e9`.

It is a documentation/evidence-only child of runtime source `7c54c782552f3ee5a09ddee35735e90cba1b9339`.

The final runtime diff check exited `0`, remote CI run `33322804969` passed all five checks, and PR #141 is open and draft at the exact pushed head.

The complete final delivery attestation is `final-delivery-attestation-c060b88.md`.

## Current exact-head correction for d63f239

The current runtime source head is `d63f2390944a534f4746c64ef60e43332fd546c3` on `revival/v0-local-codex`.

The Away correction preserves the bounded overlapping-return contract while serializing mark's marker and cursor update and return's acknowledgement plus token-checked marker removal on the same expanded-home global resource.

Focused proof passed ten seeds with `7` tests each, the complete daemon gate passed `511 passed (1 doctest, 510 tests)`, and both Go module gates exited `0`.

The fresh package was exercised only through installed artifacts in a fresh `env -i` home, and cleanup reported zero package processes with the package and QA home moved to Trash.

The exact current receipts are `away-return-d63f239.md`, `daemon-gate-d63f239.md`, `go-gates-d63f239.md`, `package-artifact-d63f239.md`, and `installed-lifecycle-d63f239.md`.

The selected canary was not rerun, because the operator-controlled no-duplicate rule forbids duplicate implementation work.

The natural comparable sample remains below 20, so no Promote claim is made and Continue or Stop remains operator-owned.

## Five-lane pre-push review closure for b30f40e

All five final read-only review lanes passed candidate `b30f40e10dee9513403aeff14b03fba79f27ee9a`.

The plan, QA, code-quality, security, and context/custody reports are recorded in `final-review-b30f40e.md` and its linked lane artifacts.

The only retained notes are non-blocking timing-based contention and shared-test-home watches.

## Current exact runtime source handoff

Runtime source head: `9260a9f22af55c6c073de3afae3602f58e4e8061`.

The receipt remediation adds a durable `command_operations` association, domain-evidence recovery, rollback absence proof, and durable operation payload minimization.
The focused receipt suite passed 17 tests in five repeated runs, the full daemon suite passed 525 tests including one doctest, CLI and runner Go gates passed, and a fresh native package lifecycle passed with zero residue.
No canary was rerun or promoted.
