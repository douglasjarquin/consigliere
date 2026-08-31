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

## Final implementation-head addendum

The final runtime implementation head is `a45cb4b4e5ead190ce05f1b3672bfbdeb4214f52`.

The daemon suite returned `502 passed (1 doctest, 501 tests)` after the deterministic reader-query fix.

The rebuilt native arm64 package and fresh package-only reader/lifecycle proof are recorded in `final-head-attestation-a45cb4b.md`.

The selected canary was not rerun, no duplicate Mission was created, and no Promote claim was made.

## Current exact runtime source gate

The current runtime source head is `7c54c782552f3ee5a09ddee35735e90cba1b9339` on `revival/v0-local-codex`.

The Linux daemon command passed formatting, warnings-as-errors compilation, and `496 passed (1 doctest, 495 tests)` in each of three consecutive seed-0 runs.

The native macOS daemon command passed formatting, warnings-as-errors compilation, and the complete `496`-test suite.

The CLI and runner Go commands exited `0` after format, vet, ordinary tests, race and shuffle tests, and builds.

The package command exited `0` and produced native arm64 `cs`, `csd`, `cs-runner`, `cs-attempt`, and `erlexec` identities recorded in `package-artifact-7c54c78.md`.

The installed package lifecycle exited `0` for every product command, changed the verified owner PID across restart, converged repeated stop, and ended with zero sockets, PID files, owner files, and package processes.

The package-only lifecycle cleanup receipt was `CLEANUP=trashed:/tmp/cs-final-7c54c78-env.lWqmiv,/tmp/cs-final-7c54c78-home.1fzjUd`.

The final runtime audit follow-up and fresh review reports are bound to this exact source head.

The selected real canary was not rerun because the operator-controlled no-duplicate rule forbids duplicate implementation work.

## Closing delivery-head gate

The runtime source gates are bound to `7c54c782552f3ee5a09ddee35735e90cba1b9339`.

The pushed evidence delivery head is `85f02c5b739116d7de0d3f04a372f463bbb913e6`.

The delivery-head runtime diff check against `daemon`, `cli`, `runner`, `scripts`, and `.github` exited `0`, proving that the evidence commit added no product-input changes.

Remote CI run `33322422318` completed successfully with all five checks passing at the exact pushed PR head.

PR #141 is open and draft against `rewrite-in-elixer`, and PR #101 remains unchanged and unmerged.

The final gate verdict is PASS for plan compliance, source quality, package/manual QA, remote CI, and scope fidelity, with the canary correctly recorded as insufficient for Promote.

The supporting final gate review is `gate-review-final-85f02c5.md`.

## Final pushed-head attestation

The final pushed head is `c060b88035128bbdbf361f1bcab9a100521965e9`.

Its runtime source ancestor is `7c54c782552f3ee5a09ddee35735e90cba1b9339`, and the final delivery delta is documentation/evidence-only.

Remote CI run `33322804969` completed successfully with all five jobs passing at the exact PR head.

PR #141 is open and draft, PR #101 is unchanged and unmerged, and no canary rerun occurred.

The complete final delivery attestation is `final-delivery-attestation-c060b88.md`.

## Current exact-head closure

The current runtime source head is `71593738cf6aae723c9208743405fa12a9dc7a03` on `revival/v0-local-codex`.

The exact-head bounded receipts are `daemon-linux-gate-7159373.md`, `go-gates-7159373.md`, `package-artifact-7159373.md`, `installed-lifecycle-7159373.md`, and `macos-native-gate-7159373.md`.

The Linux daemon gate passed `491 passed (1 doctest, 490 tests)` in three consecutive seed-0 runs.

The package-only lifecycle and Go gates exited `0`, and the selected canary was not rerun because doing so would create duplicate implementation work.

The selected canary remains one completed Consigliere Mission with one operator-authorized continuation, zero FirstMate Missions, and insufficient evidence for Promote.

## Historical exact-head gate receipt for bf22b5d

The final runtime and package evidence is bound to source commit `bf22b5d4cae239a222a3065ca4b34b574dd676ad` on `revival/v0-local-codex`.

The authoritative Linux command passed format, warnings-as-errors compilation, and `486 passed (1 doctest, 485 tests)` in each of three consecutive seed-0 runs.

The CLI and runner commands passed formatting, vet, ordinary tests, race and shuffle tests, and builds.

The package command exited `0`, and the package artifact receipt records native arm64 `cs`, `csd`, `cs-runner`, and `cs-attempt` hashes plus the version response.

The installed lifecycle ran from `/tmp` with `env -i`, fresh temporary homes, and package-only execution.

Every lifecycle command exited `0`, restart changed the verified owner identity, repeated stop was idempotent, and final cleanup reported zero sockets, PID files, owner files, notification files, and package processes.

The exact package and lifecycle outputs are `package-artifact-bf22b5d.log` and `installed-lifecycle-bf22b5d.log`, with `macos-native-gate-bf22b5d.log` retaining the named host-only characterization.

The selected canary was not rerun against this final package because the operator-controlled canary forbids duplicate implementation work.

## Authoritative final implementation-head receipt

The authoritative final runtime implementation head is `df939ab3e06c1c5bad15ae4156b27bfeae805b16`.

The exact-head daemon suite returned `502 passed (1 doctest, 501 tests)` after the bounded reader-query hardening.

The fresh native arm64 package and package-only lifecycle proof are recorded in `final-head-attestation-df939ab.md`.

The selected canary was not rerun, no duplicate Mission was created, and no Promote claim was made.
