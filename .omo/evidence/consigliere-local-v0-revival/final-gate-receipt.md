# Final exact-head gate receipt

The final runtime evidence is bound to source commit `42933d103da9171c76b1564888e0d6557291fb5d` on `revival/v0-local-codex`.

The packaged runtime input parent is `42933d103da9171c76b1564888e0d6557291fb5d`.

`git diff --exit-code 42933d103da9171c76b1564888e0d6557291fb5d HEAD -- daemon cli runner scripts .github` exited `0` with no runtime, package, workflow, CLI, or runner input changes.

The bounded redacted output records for these claims are `daemon-linux-gate-final.log`, `cli-go-gate-final.log`, `runner-go-gate-final.log`, `package-artifact-final.log`, `installed-lifecycle-final.log`, and `macos-native-gate-final.log` in this evidence directory.

The older `daemon-compile-gate-rerun.log` and `daemon-compile-gate.log` are failed macOS environment probes with exit code `127` because the local Erlang executable was not on `PATH`; they are not authoritative Linux gate runs and are excluded from the final success claims.

The authoritative Linux command was `docker run --rm -v "$PWD":/workspace -w /workspace/runner/cs-runner elixir:1.20-otp-29 sh -lc 'set -e; apt-get update -qq && apt-get install -y -qq golang-go >/dev/null && go version && go build -o /workspace/daemon/priv/cs-runner . && cd /workspace/daemon && mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test --no-color --seed 0'`.

The Linux container built actual Go `1.26.6`, format passed, warnings-as-errors compilation passed, and three sequential seed-0 runs each returned `482 passed (1 doctest, 481 tests)` with exit code `0`.

The CLI command `cd cli && test -z "$(gofmt -l .)" && go vet ./... && go test ./... && go test -race -shuffle=on -count=1 ./... && go build ./cmd/cs ./cmd/csd` exited `0`.

The runner command `cd runner/cs-runner && test -z "$(gofmt -l .)" && go vet ./... && go test ./... && go test -race -shuffle=on -count=1 ./... && go build ./...` exited `0`.

The package command `PATH=/opt/homebrew/opt/erlang/bin:$PATH scripts/package.sh /Users/douglasjarquin/.herdr/worktrees/consigliere/cs-consigliere-local-v0-revival/.tmp/package-42933d1.mZakYT` exited `0`.

The package prefix was `.tmp/package-42933d1.mZakYT`.

The package `cs`, `csd`, `cs-runner`, and `cs-attempt` files were all native `Mach-O 64-bit executable arm64` binaries.

The package hashes were `cs` `4b3891c4a27c3c21b10c8324627f2701288cdf83842f8a02619da61df2dd4a2c`, `csd` `400d29f584f7ceacf225608cb28c25ddaf3c9846b19e8e8aa890496afa020b48`, `cs-runner` `fa583582034b6c3aa1c1831f387fe578519172990876c6cf4774c28b7b12a382`, and `cs-attempt` `9393d8fecbadaf680caec85f260443fed17c9a5bdaa76a3ad408d683d95b2acb`.

The installed package returned `{"cs":"0.1.0","protocol":1}` from `cs version --json`; `cs-runner --help` exited `0`, and `cs-attempt --help` exited `2` with its usage text, as expected because the helper parser treats `--help` as invalid without an operation.

The installed lifecycle ran from `/tmp` with `env -i`, package-only `PATH`, fresh `CS_HOME=/tmp/cs-final-42933d1-home.e7matc`, `CS_RELEASE` set to the package release root, and `CS_CSD_FORCE_BACKGROUND=1`.

The lifecycle sequence was `cs version --json`, `csd migrate`, `csd start`, `cs ping`, `cs health`, `cs doctor`, `csd status`, `cs projects`, repeated `csd stop`, `csd restart`, `cs ping`, `cs health`, `cs doctor`, `csd status`, and final repeated `csd stop`.

Every lifecycle command exited `0`, the restart owner PID and start timestamp changed, and `csd status` reported `owner=verified` after each start.

The final cleanup assertion reported `F3_INSTALLED_LIFECYCLE stop=verified sockets=0 pid_files=0 owner_files=0 notifications=0` and a separate package-process scan reported `package_processes=0`.

The cleanup receipt was `CLEANUP=trashed:/tmp/cs-final-42933d1-home.e7matc`, and the isolated environment home `/tmp/cs-final-42933d1-env.C2tGuR` was also moved to Trash.

The native macOS daemon command passed formatting and compilation and reported `473/482` tests with nine host-specific socket, path, and reconciler-fixture observations.

The selected canary was not rerun against this final package because the operator-controlled canary forbids duplicate implementation work.

The selected canary remains one completed Consigliere Mission with one operator-authorized continuation, zero FirstMate Missions, and insufficient evidence for Promote.
