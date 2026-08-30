# Final exact-head verification record

Target branch: `revival/v0-local-codex`.

Target runtime commit: `42933d103da9171c76b1564888e0d6557291fb5d`.

Base commit: `24ffea8fa1f5bc983fb5965efab0a89b6116f05b` from `origin/rewrite-in-elixer`.

The runtime source commits included at this exact head are `e0e3fb3b7f8f8ff5b180f404ff11a5a8efdfe8f6` for provider-key redaction, `a2636f70b104988f5c676c2012543a0299064be3` for authenticated stderr retention, `f1d1dfa02f39bf88b682855a440d8dc6d5214ebf` for fragmented runner stdout buffering, `98fc4d3ebbe78e0b73e7bba9c19d3861ff966565` for terminal-sequence-safe result replay, `a3951ec73989f236a075973c373c9c57b2672af9` for camel-case credential redaction, `bf2dce60b52447e9075f05f135c4c36ccb2722ae` for runner failure and stream recovery, `39f342e7f8003ffd1b4c585a05a036ebcdc48fb7` for recovery slot and protocol-stream hardening, `f840893055303ab1802bbec5ee33861ece1b5853` for stale dispatch race reconciliation, `95ea4e5e38c6350f6560339708bbc33b985010b8` for protocol-failure exit classification and shared test-home serialization, `9a7b1626a1a2113f8d7faac1521f4ea4305c0b19` for atomic dispatch-slot persistence, `bc7e980c90aa54e165d5aed3dae060f3a2c9e584` for scheduler rebuild coverage, `49db8626a1a2113f8d7faac1521f4ea4305c0b19` for one recoverable Attempt and planned cancellation slot release, and `42933d103da9171c76b1564888e0d6557291fb5d` for SQLite uniqueness characterization.

The documentation-only delta from runtime commit `42933d103da9171c76b1564888e0d6557291fb5d` to the final evidence head contains only task evidence records, final gate records, `docs/v0-local.md`, and `docs/v0-canary.md`.

Command:

    git diff --exit-code 42933d103da9171c76b1564888e0d6557291fb5d HEAD -- daemon cli runner scripts .github

Result: exit 0 with no runtime, package, workflow, CLI, or runner input changes in that documentation-only delta.

## Authoritative Linux daemon gate

Command:

    docker run --rm -v "$PWD":/workspace -w /workspace/runner/cs-runner elixir:1.20-otp-29 sh -lc 'set -o pipefail; apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && go build -o /workspace/daemon/priv/cs-runner . && cd /workspace/daemon && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test --no-color'

Result: format passed, compile with warnings as errors passed, and `482 passed (1 doctest, 481 tests)` in three consecutive seed-0 runs with Go 1.26.6 built inside the CI-shaped Elixir container.

The complete daemon suite passed three consecutive seed-0 runs after the final hardening.

The suite includes the persisted-PGID termination, structured event redaction, oversized ContextPack, PATH-independent process observation, and pause identity regressions.

## Go gates

CLI command:

    cd cli && test -z "$(gofmt -l .)" && go vet ./... && go test ./... && go test -race -shuffle=on -count=1 ./... && go build ./cmd/cs ./cmd/csd

CLI result: format, vet, ordinary tests, race and shuffle tests, and build passed.

Runner command:

    cd runner/cs-runner && test -z "$(gofmt -l .)" && go vet ./... && go test ./... && go test -race -shuffle=on -count=1 ./... && go build ./...

Runner result: format, vet, ordinary tests, race and shuffle tests, and build passed.

## Exact-head package and installed lifecycle

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

## Canary custody

The real operator-controlled canary remains the single naturally occurring dotfiles Mission recorded in `task-15.md` and `docs/v0-canary.md`.

It used the committed package from `e2b7fe445e96c356354f31f849e9756b265ecec8`, created exactly one checkpoint Attempt and one explicit operator-authorized continuation, and reached exact-SHA review-ready.

The final exact-head package was exercised through the installed lifecycle only because rerunning the same implementation would violate the no-duplicate canary rule.

There are zero FirstMate duplicate Missions and fewer than 20 naturally occurring comparable Missions, so the evidence remains insufficient for Promote and the operator retains Continue or Stop.

Raw canary database, manifests, usage rows, and logs remain outside this repository.

## Custody and scope

`git diff --check` passed at the target head.

`git status --short --untracked-files=no` was empty at the target head.

Only intended tracked implementation, test, documentation, and evidence files are staged for delivery; local untracked build logs and scratch artifacts are excluded from the PR.

PR #101 remains historical input and PR #141 is the separate draft replacement; neither is merged.
