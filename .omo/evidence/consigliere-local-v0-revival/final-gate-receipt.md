# Final exact-head gate receipt

The final runtime evidence is bound to source commit `95ea4e5e38c6350f6560339708bbc33b985010b8` on `revival/v0-local-codex`.

The packaged runtime input parent is `95ea4e5e38c6350f6560339708bbc33b985010b8`.

`git diff --exit-code 95ea4e5e38c6350f6560339708bbc33b985010b8 HEAD -- daemon cli runner scripts .github` exited `0` with no runtime, package, workflow, CLI, or runner input changes.

The bounded redacted output records for these claims are `daemon-linux-gate-final.log`, `cli-go-gate-final.log`, `runner-go-gate-final.log`, `package-artifact-final.log`, `installed-lifecycle-final.log`, and `macos-native-gate-final.log` in this evidence directory.

The older `daemon-compile-gate-rerun.log` and `daemon-compile-gate.log` are failed macOS environment probes with exit code `127` because the local Erlang executable was not on `PATH`; they are not authoritative Linux gate runs and are excluded from the final success claims.

The authoritative Linux command was `docker run --rm -v "$PWD":/workspace -w /workspace/runner/cs-runner elixir:1.20-otp-29 sh -lc 'apt-get update -qq; apt-get install -y -qq golang-go; go version; go build -o /workspace/daemon/priv/cs-runner .; cd /workspace/daemon; mix local.hex --force; mix local.rebar --force; mix deps.get; mix format --check-formatted; MIX_ENV=test mix compile --warnings-as-errors; MIX_ENV=test mix test --no-color --seed 0'`.

The Linux container built actual Go `1.26.6`, format passed, warnings-as-errors compilation passed, and three sequential seed-0 runs each returned `476 passed (1 doctest, 475 tests)` with exit code `0`.

The CLI command `cd cli && test -z "$(gofmt -l .)" && go vet ./... && go test ./... && go test -race -shuffle=on -count=1 ./... && go build ./cmd/cs ./cmd/csd` exited `0`.

The runner command `cd runner/cs-runner && test -z "$(gofmt -l .)" && go vet ./... && go test ./... && go test -race -shuffle=on -count=1 ./... && go build ./...` exited `0`.

The package command `PATH=/opt/homebrew/opt/erlang/bin:$PATH scripts/package.sh /Users/douglasjarquin/.herdr/worktrees/consigliere/cs-consigliere-local-v0-revival/.tmp/package-95ea4e5-Gfnr21` exited `0`.

The package prefix was `.tmp/package-95ea4e5-Gfnr21`.

The package `cs`, `csd`, `cs-runner`, and `cs-attempt` files were all native `Mach-O 64-bit executable arm64` binaries.

The package hashes were `cs` `4b977c4361239244630749d331837c58d5aad99e1d197103d4847c628a433815`, `csd` `49074f20047840f485d110190da0fd20fbd52646969dc5f1d920f778cb584bed`, `cs-runner` `a188c50b3c0fa578dc7606a38bec41eeafa1889cd2ca41b553f9ec016481c5a8`, and `cs-attempt` `c6c0a480facfafdb45c7b37e36d41fd6fc17605da576c6b0e7633cb5776702a9`.

The installed package returned `{"cs":"0.1.0","protocol":1}` from `cs version --json` and exit `0` from `cs-runner --help` and `cs-attempt --help`.

The installed lifecycle ran from `/tmp` with `env -i`, package-only `PATH`, fresh `CS_HOME=/tmp/cs-final-95ea4e5-home.crzsf5`, `CS_RELEASE` set to the package release, and `CS_CSD_FORCE_BACKGROUND=1`.

The lifecycle sequence was `cs version --json`, `csd migrate`, `csd start`, `cs ping`, `cs health`, `cs doctor`, `csd status`, `cs projects`, repeated `csd stop`, `csd restart`, `cs ping`, `cs health`, `cs doctor`, `csd status`, and final repeated `csd stop`.

Every lifecycle command exited `0`, the restart owner PID and start timestamp changed, and `csd status` reported `owner=verified` after each start.

The final cleanup assertion reported `F3_INSTALLED_LIFECYCLE stop=verified sockets=0 pid_files=0 owner_files=0 notifications=0` and a separate package-process scan reported `package_processes=0`.

The cleanup receipt was `CLEANUP=trashed:/tmp/cs-final-95ea4e5-home.crzsf5`, and the isolated environment home `/tmp/cs-final-95ea4e5-env.CAN45Z` was also moved to Trash.

The native macOS daemon command passed formatting and compilation and reported `467/476` tests with nine host-specific socket, path, and reconciler-fixture observations.

The selected canary was not rerun against this final package because the operator-controlled canary forbids duplicate implementation work.

The selected canary remains one completed Consigliere Mission with one operator-authorized continuation, zero FirstMate Missions, and insufficient evidence for Promote.
