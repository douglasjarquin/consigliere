# Historical exact-head gate receipt for 42933d1

This section is historical evidence for source commit `42933d103da9171c76b1564888e0d6557291fb5d` and is not an assertion about the current delivery head.

The historical runtime evidence was bound to source commit `42933d103da9171c76b1564888e0d6557291fb5d` on `revival/v0-local-codex`.

The historical packaged runtime input parent was `42933d103da9171c76b1564888e0d6557291fb5d`.

At the time of that historical receipt, `git diff --exit-code 42933d103da9171c76b1564888e0d6557291fb5d HEAD -- daemon cli runner scripts .github` exited `0` with no runtime, package, workflow, CLI, or runner input changes.

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

## Historical implementation-head addendum for a45cb4b

The historical runtime implementation head was `a45cb4b4e5ead190ce05f1b3672bfbdeb4214f52`.

The daemon suite returned `502 passed (1 doctest, 501 tests)` after the deterministic reader-query fix.

The rebuilt native arm64 package and fresh package-only reader/lifecycle proof are recorded in `final-head-attestation-a45cb4b.md`.

The selected canary was not rerun, no duplicate Mission was created, and no Promote claim was made.

## Historical superseded implementation receipt for 4cb71b4

The superseded runtime source head was `4cb71b41075631d8beb30ddaeca5171c9b835234`.

The superseded daemon, package, lifecycle, and Away boundedness receipts were `away-return-4cb71b4.md`, `daemon-gate-eb41191.md`, `package-artifact-4cb71b4.md`, and `installed-lifecycle-4cb71b4.md`.

That superseded runtime head passed the Away RED/GREEN regression, five repeated bounded-reader runs, and the full `503`-test daemon gate.

The superseded package-only lifecycle passed `cs boss away`, `cs boss return`, identity-safe restart, repeated stop, and zero-residue cleanup from a fresh `env -i` home.

That superseded implementation and package pass contained no canary rerun, duplicate Mission, FirstMate implementation, Made operation, push, PR creation, or merge.

## Historical superseded exact implementation and package receipt for 8010d5f

The historical runtime source head is `8010d5fdaa69f9e998b951f8282fddd01e5099ea`.

The historical exact daemon, cursor, package, and lifecycle receipts are `away-return-8010d5f.md`, `daemon-gate-8010d5f.md`, `package-artifact-8010d5f.md`, and `installed-lifecycle-8010d5f.md`.

The historical daemon gate passed `506 tests (1 doctest, 505 tests)` after the bounded Away and monotonic cursor fixes.

The historical package-only lifecycle passed migration, start, ping, Away, restart, repeated stop, and cleanup with `package_processes=0`.

The final evidence child is documentation-only above this runtime source, and its exact-head reviewers must bind their verdicts to that immutable child.

Historical local final-gate verdict: PASS for runtime source `8010d5fdaa69f9e998b951f8282fddd01e5099ea` and its then evidence child.

## Historical superseded exact implementation and package receipt for 0fd7d3b

The historical runtime source head is `0fd7d3b951672df7cb37e6c160401d1593386ba2`.

The historical exact daemon, cursor, package, and lifecycle receipts are `away-return-0fd7d3b.md`, `daemon-gate-0fd7d3b.md`, `package-artifact-0fd7d3b.md`, and `installed-lifecycle-0fd7d3b.md`.

The historical daemon gate passed `505 passed (1 doctest, 504 tests)` after format and warnings-as-errors compilation.

The historical package-only lifecycle passed migration, start, ping, Away, restart, repeated stop, and cleanup with `package_processes=0`.

The current source commit removes the exported cursor acknowledgement helper and uses an atomic SQL `MAX` update for monotonic acknowledgements under concurrent returns.

The final evidence child is documentation-only above this runtime source, and its exact-head reviewers must bind their verdicts to that immutable child.

Historical local final-gate verdict: PASS for runtime source `0fd7d3b951672df7cb37e6c160401d1593386ba2` and its then immutable evidence child.

## Historical superseded exact implementation and package receipt for cf56963

The historical runtime source head is `cf56963a7206e5c5a260442c08eaa7bdcd65ec7a`.

The historical exact daemon, cursor, termination, package, and lifecycle receipts are `away-return-cf56963.md`, `termination-cf56963.md`, `daemon-gate-cf56963.md`, `package-artifact-cf56963.md`, and `installed-lifecycle-cf56963.md`.

The historical daemon gate passed `506 passed (1 doctest, 505 tests)` after format and warnings-as-errors compilation.

The historical package-only lifecycle passed migration, start, ping, Away, restart, repeated stop, and cleanup with `package_processes=0`.

The historical cancellation path requested runner termination and deferred terminal outcome and workspace disposition until the reconciler or RunnerProcess exit path verified death.

The final evidence child is documentation-only above this runtime source, and its exact-head reviewers must bind their verdicts to that immutable child.

Historical local final-gate verdict: PASS for runtime source `cf56963a7206e5c5a260442c08eaa7bdcd65ec7a` and its then immutable evidence child.

## Historical superseded exact implementation and package receipt for ec47784

The historical superseded runtime source head is `ec47784a801ee8168fae7b249bf3b8342951ae17`.

The historical exact daemon, cursor, termination, package, and lifecycle receipts are `away-return-ec47784.md`, `termination-ec47784.md`, `daemon-gate-ec47784.md`, `package-artifact-ec47784.md`, and `installed-lifecycle-ec47784.md`.

The historical daemon gate passed `507 passed (1 doctest, 506 tests)` after format and warnings-as-errors compilation.

The historical package-only lifecycle passed migration, start, ping, Away, restart, repeated stop, and cleanup with `package_processes=0`.

The historical cancellation path persisted its cause while deferring terminal outcome and workspace disposition until verified runner death, and Away acknowledgement was fenced by the exact marker snapshot.

The final evidence child is the immutable documentation commit containing this receipt, with its full SHA established by the final `git rev-parse HEAD` custody command.

Historical local final-gate verdict: PASS for runtime source `ec47784a801ee8168fae7b249bf3b8342951ae17` and its immutable evidence child.

## Historical superseded exact implementation and package receipt for 0c2b24c

The superseded runtime source head was `0c2b24c02490c8f6f53b7f6bc1a9fb9add519861`.

The historical exact daemon, cursor, termination, package, and lifecycle receipts are `away-return-0c2b24c.md`, `termination-0c2b24c.md`, `daemon-gate-0c2b24c.md`, `package-artifact-0c2b24c.md`, and `installed-lifecycle-0c2b24c.md`.

The historical daemon gate passed `510 passed (1 doctest, 509 tests)` after format and warnings-as-errors compilation.

The historical package-only lifecycle passed migration, start, ping, Away, restart, repeated stop, and cleanup with `package_processes=0`.

The superseded cancellation path persisted its cause while deferring terminal outcome and workspace disposition until verified runner death, routed unverified terminating exits through lost and quarantine reconciliation, and fenced Away acknowledgement and marker removal by the exact marker snapshot token.

The final evidence child is the immutable documentation commit containing this receipt, with its full SHA established by the final `git rev-parse HEAD` custody command.

Historical local final-gate verdict: PASS for runtime source `0c2b24c02490c8f6f53b7f6bc1a9fb9add519861` and its immutable evidence child.

## Historical exact runtime source gate for 7c54c78

The historical runtime source head was `7c54c782552f3ee5a09ddee35735e90cba1b9339` on `revival/v0-local-codex`.

The Linux daemon command passed formatting, warnings-as-errors compilation, and `496 passed (1 doctest, 495 tests)` in each of three consecutive seed-0 runs.

The native macOS daemon command passed formatting, warnings-as-errors compilation, and the complete `496`-test suite.

The CLI and runner Go commands exited `0` after format, vet, ordinary tests, race and shuffle tests, and builds.

The package command exited `0` and produced native arm64 `cs`, `csd`, `cs-runner`, `cs-attempt`, and `erlexec` identities recorded in `package-artifact-7c54c78.md`.

The installed package lifecycle exited `0` for every product command, changed the verified owner PID across restart, converged repeated stop, and ended with zero sockets, PID files, owner files, and package processes.

The package-only lifecycle cleanup receipt was `CLEANUP=trashed:/tmp/cs-final-7c54c78-env.lWqmiv,/tmp/cs-final-7c54c78-home.1fzjUd`.

The final runtime audit follow-up and fresh review reports are bound to this exact source head.

The selected real canary was not rerun because the operator-controlled no-duplicate rule forbids duplicate implementation work.

## Historical closing delivery-head gate for 85f02c5

The runtime source gates are bound to `7c54c782552f3ee5a09ddee35735e90cba1b9339`.

The pushed evidence delivery head is `85f02c5b739116d7de0d3f04a372f463bbb913e6`.

The delivery-head runtime diff check against `daemon`, `cli`, `runner`, `scripts`, and `.github` exited `0`, proving that the evidence commit added no product-input changes.

Remote CI run `33322422318` completed successfully with all five checks passing at the exact pushed PR head.

PR #141 is open and draft against `rewrite-in-elixer`, and PR #101 remains unchanged and unmerged.

The final gate verdict is PASS for plan compliance, source quality, package/manual QA, remote CI, and scope fidelity, with the canary correctly recorded as insufficient for Promote.

The supporting final gate review is `gate-review-final-85f02c5.md`.

## Current exact-head correction for d63f239

The current immutable runtime source head is `d63f2390944a534f4746c64ef60e43332fd546c3`.

The exact current receipts are `away-return-d63f239.md`, `daemon-gate-d63f239.md`, `go-gates-d63f239.md`, `package-artifact-d63f239.md`, and `installed-lifecycle-d63f239.md`.

The focused Away regression passed at ten seeds, the complete daemon gate passed `511 passed (1 doctest, 510 tests)`, both Go module gates exited `0`, and the fresh installed lifecycle passed with zero package processes after cleanup.

The five final pre-push review lanes passed at candidate `b30f40e10dee9513403aeff14b03fba79f27ee9a`; the lane reports are recorded in `final-review-b30f40e.md`.

Remote CI and PR custody remain pending until the final evidence child is pushed.

## Historical pushed-head attestation for c060b88

The final pushed head is `c060b88035128bbdbf361f1bcab9a100521965e9`.

Its runtime source ancestor is `7c54c782552f3ee5a09ddee35735e90cba1b9339`, and the final delivery delta is documentation/evidence-only.

Remote CI run `33322804969` completed successfully with all five jobs passing at the exact PR head.

PR #141 is open and draft, PR #101 is unchanged and unmerged, and no canary rerun occurred.

The complete final delivery attestation is `final-delivery-attestation-c060b88.md`.

## Historical exact-head closure for 7159373

The historical runtime source head was `71593738cf6aae723c9208743405fa12a9dc7a03` on `revival/v0-local-codex`.

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

## Historical implementation-head receipt for bf7a73d

The historical runtime implementation head was `bf7a73dd005fe6c1746a1c73f1929411cd7392c1`.

The exact-head daemon suite returned `502 passed (1 doctest, 501 tests)` after the bounded reader-query hardening.

The historical native arm64 package and package-only lifecycle proof are recorded in `final-head-attestation-bf7a73d.md`.

The selected canary was not rerun, no duplicate Mission was created, and no Promote claim was made.

## Historical superseded implementation-head receipt for eb41191

The superseded runtime implementation head was `eb41191b73a04b93d613d8d0cf8b2183a55272ef`.

The exact-head daemon suite returned `502 passed (1 doctest, 501 tests)`.

The native arm64 package and package-only lifecycle proof are recorded in `package-artifact-eb41191.md` and `installed-lifecycle-eb41191.md`.

The selected canary was not rerun, no duplicate Mission was created, and no Promote claim was made.
