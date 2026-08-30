# Final exact-head verification record

Target branch: `revival/v0-local-codex`.

Target runtime commit: `95ea4e5e38c6350f6560339708bbc33b985010b8`.

Base commit: `24ffea8fa1f5bc983fb5965efab0a89b6116f05b` from `origin/rewrite-in-elixer`.

The runtime source commits included at this exact head are `e0e3fb3b7f8f8ff5b180f404ff11a5a8efdfe8f6` for provider-key redaction, `a2636f70b104988f5c676c2012543a0299064be3` for authenticated stderr retention, `f1d1dfa02f39bf88b682855a440d8dc6d5214ebf` for fragmented runner stdout buffering, `98fc4d3ebbe78e0b73e7bba9c19d3861ff966565` for terminal-sequence-safe result replay, `a3951ec73989f236a075973c373c9c57b2672af9` for camel-case credential redaction, `bf2dce60b52447e9075f05f135c4c36ccb2722ae` for runner failure and stream recovery, `39f342e7f8003ffd1b4c585a05a036ebcdc48fb7` for recovery slot and protocol-stream hardening, `f840893055303ab1802bbec5ee33861ece1b5853` for stale dispatch race reconciliation, and `95ea4e5e38c6350f6560339708bbc33b985010b8` for protocol-failure exit classification and shared test-home serialization.

The documentation-only delta from runtime commit `95ea4e5e38c6350f6560339708bbc33b985010b8` to the final evidence head contains only task evidence records, `docs/v0-local.md`, and `docs/v0-canary.md`.

Command:

    git diff --exit-code 95ea4e5e38c6350f6560339708bbc33b985010b8 HEAD -- daemon cli runner scripts .github

Result: exit 0 with no runtime, package, workflow, CLI, or runner input changes in that documentation-only delta.

## Authoritative Linux daemon gate

Command:

    docker run --rm -v "$PWD":/workspace -w /workspace/runner/cs-runner elixir:1.20-otp-29 sh -lc 'set -o pipefail; apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && go build -o /workspace/daemon/priv/cs-runner . && cd /workspace/daemon && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test --no-color'

Result: format passed, compile with warnings as errors passed, and `476 passed (1 doctest, 475 tests)` in three consecutive seed-0 runs with Go 1.26.6 built inside the CI-shaped Elixir container.

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

    set -e; package_root=$(mktemp -d "$PWD/.tmp/package-95ea4e5.XXXXXX"); scripts/package.sh "$package_root"

Package prefix: `.tmp/package-95ea4e5-Gfnr21`.

Package hashes: `cs` `4b977c4361239244630749d331837c58d5aad99e1d197103d4847c628a433815`, `csd` `49074f20047840f485d110190da0fd20fbd52646969dc5f1d920f778cb584bed`, `cs-runner` `a188c50b3c0fa578dc7606a38bec41eeafa1889cd2ca41b553f9ec016481c5a8`, and `cs-attempt` `c6c0a480facfafdb45c7b37e36d41fd6fc17605da576c6b0e7633cb5776702a9`.

`file` reported native arm64 Mach-O for all four inspected executables.

The package tree contained zero `.go`, `.ex`, `mix.exs`, `mix.lock`, or `go.mod` source-like files outside the shipped Ecto migration scripts.

`cs version --json` returned `{"cs":"0.1.0","protocol":1}`.

The installed lifecycle used fresh `/tmp/cs-final-95ea4e5-home.crzsf5`, `env -i`, the exact package prefix, and a working directory of `/tmp`.

The commands were `csd migrate`, `csd start`, `cs ping`, `cs health`, `cs doctor`, `csd status`, `cs projects`, absence of `notifications.log`, `csd stop`, repeated `csd stop`, `csd restart`, `cs ping`, `cs doctor`, `csd status`, absence of `notifications.log`, final `csd stop`, PID absence, and Unix-socket absence.

Result: `F3_INSTALLED_LIFECYCLE stop=verified sockets=0 pid_files=0 owner_files=0 notifications=0 package=/Users/douglasjarquin/.herdr/worktrees/consigliere/cs-consigliere-local-v0-revival/.tmp/package-95ea4e5-Gfnr21 runner=a188c50b3c0fa578dc7606a38bec41eeafa1889cd2ca41b553f9ec016481c5a8 attempt=c6c0a480facfafdb45c7b37e36d41fd6fc17605da576c6b0e7633cb5776702a9`.

The fresh migration emitted one transient SQLite `database is locked` connection log while the schema lock initialized, then completed successfully and all lifecycle commands returned success.

Cleanup receipt: `CLEANUP=trashed:/tmp/cs-final-95ea4e5-home.crzsf5`; the isolated environment home `/tmp/cs-final-95ea4e5-env.CAN45Z` was also moved to Trash.

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
