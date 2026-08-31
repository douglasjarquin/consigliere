# manualQa: Consigliere local V0 final pre-push review

Review target: immutable HEAD `b30f40e10dee9513403aeff14b03fba79f27ee9a`.

Runtime parent: `d63f2390944a534f4746c64ef60e43332fd546c3`.

Branch: `revival/v0-local-codex`.

Review mode: read-only.

No product files, commits, pushes, PRs, merges, Made operations, or shared daemon processes were altered.

## surfaceEvidence

| scenario id | criterion reference | surface | exact invocation | verdict | artifactRefs |
| --- | --- | --- | --- | --- | --- |
| S1 | Away cursor and marker concurrency | Archived Elixir daemon test surface | `MIX_ENV=test mix test --no-color --seed <1..10> test/consigliere/away_cursor_test.exs test/consigliere/away_test.exs` in tmux | PASS: ten seeds, nine tests passed per seed | `AWAY` |
| S2 | Full daemon gate | Archived Elixir daemon source | `mix format --check-formatted; MIX_ENV=test mix compile --warnings-as-errors; MIX_ENV=test mix test --no-color --seed 0` with archive-only `GOFLAGS=-buildvcs=false` | PASS: `511 passed (1 doctest, 510 tests)` | `DAEMON` |
| S3 | Go/package companion gates | Archived CLI and runner modules | `gofmt`, `go vet ./...`, ordinary tests, race/shuffle tests, and builds in `cli` and `runner/cs-runner` | PASS: both sessions returned `0` | `GO` |
| S4 | Package artifact identity | Fresh package prefix | `scripts/package.sh /tmp/cs-qa-b30f40e.OmD2Fc/package; env -i ... cs version --json; file; shasum` | PASS: package built, version `0.1.0`, four native arm64 artifacts | `PKG` |
| S5 | Installed restart/stop and cleanup | Package-only `csd`/`cs` from `/tmp` | `csd migrate; csd start; cs ping; cs health; cs doctor; csd status; csd restart; ...; csd stop; csd stop; find ...` | PASS: owner changed `25922` to `26211`; repeated stop and residue scans passed | `PKG` |
| S6 | Installed Away behavior | Package-only boss CLI | `cs boss away; test -f <CS_HOME>/away; cs boss return; test ! -e <CS_HOME>/away` | PASS: mark and return succeeded, marker was created then removed | `PKG` |
| S7 | Exact source and stale receipt claims | Local Git and committed evidence | `git rev-parse HEAD; git diff --quiet HEAD --; git grep ...; git grep ... 0c2b24c` | PASS: exact HEAD, tracked diff `0`, forbidden detour scan empty, 0c2b24c references historical-only | `CUSTODY` |

## adversarialCases

| scenario id | criterion reference | adversarial class | expected behavior | verdict | artifactRefs |
| --- | --- | --- | --- | --- | --- |
| AC1 | Away mark lock contract | Concurrent mark | Both mark calls remain blocked behind the exact home lock, then complete with marker/cursor agreement | PASS: focused test passed in all ten seeds | `AWAY` |
| AC2 | Away cursor monotonicity | Overlapping returns | A stale overlapping return is rejected as `stale_away_return`; cursor never moves backward and later page advances | PASS: focused test passed in all ten seeds | `AWAY` |
| AC3 | Away marker snapshot fencing | Stale/newer marker | Return acknowledges only its snapshot and does not remove a newer marker | PASS: focused test passed in all ten seeds | `AWAY` |
| AC4 | Away boundedness | Oversized payload and bounded page | Return omits raw payload and acknowledges only the bounded page | PASS: focused test passed in all ten seeds | `AWAY` |
| AC5 | Daemon lifecycle identity | Restart and repeated stop | Restart obtains a new verified owner; repeated stop is idempotent and removes runtime handles | PASS: owner changed, both stops returned `0`, scans were empty | `PKG` |
| AC6 | Package isolation | Source/Mix/shared-daemon leakage | Installed commands use only package artifacts and fresh home state | PASS: source-like package scan and package-process scan were empty | `PKG` |
| AC7 | Detour exclusion | `DatabaseWriter.serialize` or temporary hook reappears | Exact HEAD must contain neither forbidden serialization API nor temporary test hook | PASS: exact Git scan returned no matches | `CUSTODY` |
| AC8 | Stale receipt correction | Current claim still points at 0c2b24c | Superseded references must be explicitly historical, with current runtime claims bound to the newer runtime line | PASS: all 0c2b24c references are explicitly historical/superseded; no current claim points there | `CUSTODY` |
| AC9 | Candidate remote custody | Remote CI or PR mutation during pre-push review | Local QA must not push or mutate PR; old remote head must not be treated as candidate proof | PASS: PR remains open/draft/unmerged at prior head; no mutation performed | `CUSTODY` |

## artifactRefs

| id | kind | description | path |
| --- | --- | --- | --- |
| `AWAY` | tmux-transcript-receipt | Ten-seed focused Away suite covering concurrent mark, overlapping returns, stale marker, and bounded data | `.omo/evidence/consigliere-local-v0-revival/manual-qa-b30f40e-focused-away.md` |
| `DAEMON` | tmux-transcript-receipt | Full daemon format, warnings-as-errors compile, and 511-test final run | `.omo/evidence/consigliere-local-v0-revival/manual-qa-b30f40e-daemon.md` |
| `GO` | tmux-transcript-receipt | CLI and runner format, vet, unit, race/shuffle, and build gates | `.omo/evidence/consigliere-local-v0-revival/manual-qa-b30f40e-go.md` |
| `PKG` | tmux-transcript-receipt | Fresh package identity, installed lifecycle, Away mark/return, restart, stop, and cleanup | `.omo/evidence/consigliere-local-v0-revival/manual-qa-b30f40e-package-lifecycle.md` |
| `CUSTODY` | git-read-receipt | Exact HEAD, remote custody, forbidden detour scan, and historical-only 0c2b24c classification | `.omo/evidence/consigliere-local-v0-revival/manual-qa-b30f40e-custody.md` |

## final verdict

PASS for the requested local pre-push runtime and installed-package QA.

Remote CI for b30f40e is intentionally not claimed because PR #141 still points at its prior remote head.
