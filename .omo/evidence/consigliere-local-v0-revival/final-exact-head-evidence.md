# Final exact-head verification record

Target branch: `revival/v0-local-codex`.

Target runtime commit: `98fc4d3ebbe78e0b73e7bba9c19d3861ff966565`.

Base commit: `24ffea8fa1f5bc983fb5965efab0a89b6116f05b` from `origin/rewrite-in-elixer`.

The runtime source commits included at this exact head are `e0e3fb3b7f8f8ff5b180f404ff11a5a8efdfe8f6` for provider-key redaction, `a2636f70b104988f5c676c2012543a0299064be3` for authenticated stderr retention, `f1d1dfa02f39bf88b682855a440d8dc6d5214ebf` for fragmented runner stdout buffering, and `98fc4d3ebbe78e0b73e7bba9c19d3861ff966565` for terminal-sequence-safe result replay.

The documentation-only delta from runtime commit `98fc4d3ebbe78e0b73e7bba9c19d3861ff966565` to the final evidence head contains only task evidence records and `docs/v0-canary.md`.

Command:

    git diff --exit-code 98fc4d3ebbe78e0b73e7bba9c19d3861ff966565 HEAD -- daemon cli runner scripts .github

Result: exit 0 with no runtime, package, workflow, CLI, or runner input changes in that documentation-only delta.

## Authoritative Linux daemon gate

Command:

    docker run --rm -v "$PWD":/workspace -w /workspace/runner/cs-runner elixir:1.20-otp-29 sh -lc 'set -o pipefail; apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && go build -o /workspace/daemon/priv/cs-runner . && cd /workspace/daemon && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test --no-color'

Result: format passed, compile with warnings as errors passed, and `468 passed (1 doctest, 467 tests)`.

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

    set -e; package_prefix=$(mktemp -d "$PWD/.tmp/package-final-98fc4d3.XXXXXX"); scripts/package.sh "$package_prefix"

Package prefix: `.tmp/package-final-98fc4d3.AuR9NG`.

Package hashes: `cs` `d49af9343e7df1012d934460200a07dee8db663b11398cd287781e4078dc9b4f`, `csd` `299ab54b56a4c7d212b0226f9c0ef62eaa26dd8b285fe89f29a59a476bcbd0dc`, `cs-runner` `c2a25413583308309e85395c8fef5c0be88bed38cbeff8f4c26de9cfa2777155`, and `cs-attempt` `b9dccb7c04fbff4406d8cae209d51e97730a52f653726f5d2257a61b431794a7`.

`file` reported native arm64 Mach-O for all four inspected executables.

The package tree contained zero `.go`, `.ex`, `mix.exs`, `mix.lock`, or `go.mod` source-like files.

`cs version --json` returned `{"cs":"0.1.0","protocol":1}`.

The installed lifecycle used fresh `/tmp/cs-final-98fc4d3.5MFJpk`, `env -i`, the exact package prefix, and a working directory of `/tmp`.

The commands were `csd migrate`, `csd start`, `cs ping`, `cs health`, `cs doctor`, `csd status`, `cs projects`, absence of `notifications.log`, `csd stop`, repeated `csd stop`, `csd restart`, `cs ping`, `cs doctor`, `csd status`, absence of `notifications.log`, final `csd stop`, PID absence, and Unix-socket absence.

Result: `F3_INSTALLED_LIFECYCLE stop=verified sockets=absent pid=absent notifications=absent package=/Users/douglasjarquin/.herdr/worktrees/consigliere/cs-consigliere-local-v0-revival/.tmp/package-final-98fc4d3.AuR9NG runner=c2a25413583308309e85395c8fef5c0be88bed38cbeff8f4c26de9cfa2777155 attempt=b9dccb7c04fbff4406d8cae209d51e97730a52f653726f5d2257a61b431794a7`.

The fresh migration emitted one transient SQLite `database is locked` connection log while the schema lock initialized, then completed successfully and all lifecycle commands returned success.

Cleanup receipt: `CLEANUP=trashed:/tmp/cs-final-98fc4d3.5MFJpk`.

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
