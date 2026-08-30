# Final exact-head verification record

Target branch: `revival/v0-local-codex`.

Target commit: `dd48a6ff54fc48d557b127503c95098f6dcca6a0`.

Base commit: `24ffea8fa1f5bc983fb5965efab0a89b6116f05b` from `origin/rewrite-in-elixer`.

The runtime source commits included at this exact head are `c71bee7a6706b7279beafba0a951795124ad7ed4` for bounded secret redaction and `dd48a6ff54fc48d557b127503c95098f6dcca6a0` for durable asynchronous pause settlement.

The documentation-only delta from runtime commit `dd48a6ff54fc48d557b127503c95098f6dcca6a0` to the target head contains only task evidence records.

Command:

    git diff --exit-code dd48a6ff54fc48d557b127503c95098f6dcca6a0 HEAD -- daemon cli runner scripts .github

Result: exit 0 with no runtime, package, workflow, CLI, or runner input changes in that documentation-only delta.

## Authoritative Linux daemon gate

Command:

    docker run --rm -v "$PWD":/workspace -w /workspace/runner/cs-runner elixir:1.20-otp-29 sh -lc 'set -o pipefail; apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && go build -o /workspace/daemon/priv/cs-runner . && cd /workspace/daemon && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test --no-color'

Result: format passed, compile with warnings as errors passed, and `466 passed (1 doctest, 465 tests)`.

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

    set -e; package_prefix=$(mktemp -d "$PWD/.tmp/package-final-dd48a6f.XXXXXX"); scripts/package.sh "$package_prefix"

Package prefix: `.tmp/package-final-dd48a6f.493EIB`.

Package hashes: `cs` `d82be15073424728f8cb4d71015489155355635134e50f038a0b8b6d7db13087`, `csd` `52f1fa06857570d8ed78f6c584392ef5801a42e134e7798f3e9edf5ba2d335cd`, `cs-runner` `a5f1752480005a074dc3f33f8e8c61f0acfd63abfc2b2d7a65e80a143bc17398`, and `cs-attempt` `6f09ed5c7de9f532cf42ace501a664b5d4a350ad54dbb4713202852cac7d4fad`.

`file` reported native arm64 Mach-O for all four inspected executables.

`cs version --json` returned `{"cs":"0.1.0","protocol":1}`.

The installed lifecycle used fresh `/tmp/cs-final-dd48a6f.K7b3jH`, `env -i`, the exact package prefix, and a working directory of `/tmp`.

The commands were `csd migrate`, `csd start`, `cs ping`, `cs health`, `cs doctor`, `csd status`, `cs projects`, absence of `notifications.log`, `csd stop`, repeated `csd stop`, `csd restart`, `cs ping`, `cs doctor`, `csd status`, absence of `notifications.log`, final `csd stop`, PID absence, and Unix-socket absence.

Result: `F3_INSTALLED_LIFECYCLE stop=verified sockets=absent pid=absent notifications=absent package=/Users/douglasjarquin/.herdr/worktrees/consigliere/cs-consigliere-local-v0-revival/.tmp/package-final-dd48a6f.493EIB runner=a5f1752480005a074dc3f33f8e8c61f0acfd63abfc2b2d7a65e80a143bc17398 attempt=6f09ed5c7de9f532cf42ace501a664b5d4a350ad54dbb4713202852cac7d4fad`.

The fresh migration completed without a user-visible SQLite lock failure, and all lifecycle commands returned success.

Cleanup receipt: `CLEANUP=trashed:/tmp/cs-final-dd48a6f.K7b3jH`.

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
