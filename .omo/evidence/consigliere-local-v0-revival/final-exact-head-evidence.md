# Final exact-head verification record

Target branch: `revival/v0-local-codex`.

Target commit: `e40189a2fd10d286380f78d3997646b15f7ccb5b`.

Base commit: `24ffea8fa1f5bc983fb5965efab0a89b6116f05b` from `origin/rewrite-in-elixer`.

The runtime source commits included at this exact head are `4a22c19313a53faa3fe019f396f58d3cfdbf9a5d` for event map redaction and `94079e332f6b95cfe32678e65b93bc6a66fb8614` for identity-safe pause termination.

The documentation-only delta from runtime commit `94079e332f6b95cfe32678e65b93bc6a66fb8614` to the target head contains only task evidence records.

Command:

    git diff --exit-code 94079e332f6b95cfe32678e65b93bc6a66fb8614 e40189a2fd10d286380f78d3997646b15f7ccb5b -- daemon cli runner scripts .github

Result: exit 0 with no runtime, package, workflow, CLI, or runner input changes in that documentation-only delta.

## Authoritative Linux daemon gate

Command:

    docker run --rm -v "$PWD":/workspace -w /workspace/runner/cs-runner elixir:1.20-otp-29 sh -lc 'set -o pipefail; apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && go build -o /workspace/daemon/priv/cs-runner . && cd /workspace/daemon && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test --no-color'

Result: format passed, compile with warnings as errors passed, and `458 passed (1 doctest, 457 tests)`.

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

    set -e; package_prefix=$(mktemp -d "$PWD/.tmp/package-final-e40189a.XXXXXX"); scripts/package.sh "$package_prefix"

Package prefix: `.tmp/package-final-e40189a.1xpSxh`.

Package hashes: `cs` `99e5284f05e0cf0d729d330210f4c9f6688e66d00901198360f034ec18357e5e`, `csd` `9a8620699aa6b40ab3a465f483523ac88b33c9cbbfe9010eb966fd735f96404e`, `cs-runner` `34b3445a67731717c43c4925e0bc2b869633d43c4fb93183ab1255fc2cb1f13d`, and `cs-attempt` `94d08ec7f8c5b3ff03d686e28faeb9e7db8b800c051b18e053d7aedd056b4a53`.

`file` reported native arm64 Mach-O for all four inspected executables.

`cs version --json` returned `{"cs":"0.1.0","protocol":1}`.

The installed lifecycle used fresh `/tmp/cs-f5-final-B5tMD0`, `env -i`, the exact package prefix, and a working directory of `/tmp`.

The commands were `csd migrate`, `csd start`, `cs ping`, `cs health`, `cs doctor`, `csd status`, `cs projects`, absence of `notifications.log`, `csd stop`, repeated `csd stop`, `csd restart`, `cs ping`, `cs doctor`, `csd status`, absence of `notifications.log`, final `csd stop`, PID absence, and Unix-socket absence.

Result: `F3_INSTALLED_LIFECYCLE stop=verified sockets=absent pid=absent notifications=absent package=<exact-prefix> runner=34b3445a67731717c43c4925e0bc2b869633d43c4fb93183ab1255fc2cb1f13d attempt=94d08ec7f8c5b3ff03d686e28faeb9e7db8b800c051b18e053d7aedd056b4a53`.

The fresh migration printed one transient SQLite `database is locked` connection log while the schema lock initialized, then completed successfully with all lifecycle commands returning success.

Cleanup receipt: `.tmp/installed-lifecycle-e40189a.cleanup` records `CLEANUP=trashed:/tmp/cs-f5-final-B5tMD0`.

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
