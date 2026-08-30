# Task 14 evidence

## Scope

Task #14 is the plan's issue #136, the thin non-authoritative model-advisory interface.

The implementation commit is 14118e0abbf8c9fd4c7369285a9b61575e9e5c5e.

The implementation adds the authenticated advisory.orient read operation, Project and Mission filters, one bounded orientation snapshot, safe next actions, Boss-attention requests, and a private advisory measurement ledger.

The advisory projection includes bounded Project, Mission, Attempt, Question, Incident, blocker, base, checkpoint, imported result, verification, review-ready, and safe-action state.

The projection and all advisory responses omit SQLite paths, trusted mirror paths, repository URLs, Workspace filesystem paths, process controls, credentials, capability secrets, command argv, raw logs, and transcript fields.

Only a Mission draft remains available through the advisory principal.

All Boss and delivery operations are rejected before command-receipt mutation, including replayed requests whose body claims the Boss principal.

## Tests-first record

The initial advisory RED characterization ran before implementation.

It failed all three protocol scenarios because the advisory ledger path and orientation operation were absent, and because forbidden advisory operations were still claiming command receipts before their principal checks.

The initial Go RED characterization failed the new orient mapping and channel test with unknown command: orient.

The implementation then made both RED suites green and added regression coverage for bounded fields, advisory credential selection, filters, path and credential omission, safe Mission drafts, Boss-shaped request replay, and no-receipt authorization refusal.

## Automated verification

Command:

    docker run --rm -v "$PWD:/workspace" -w /workspace/daemon elixir:1.20-otp-29 sh -c 'mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test test/consigliere/advisory_test.exs test/consigliere/api_protocol_test.exs test/consigliere/api_cli_ops_test.exs test/consigliere/chaos_security_test.exs'

Result: 30 passed.

The daemon compile completed with warnings treated as errors.

Command:

    docker run --rm -v "$PWD:/workspace" -v "$PWD/.tmp/task14-package/go-wrapper:/usr/local/bin/go:ro" -v "$PWD/.tmp/task14-package/cs-runner-linux:/tmp/cs-runner-linux:ro" -w /workspace/daemon elixir:1.20-otp-29 sh -c 'mix deps.get >/dev/null && mix format --check-formatted && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test'

Result: 442 passed, including one doctest and 441 tests.

Command:

    cd cli && test -z "$(gofmt -l .)" && go vet ./... && go test -race -shuffle=on -count=1 ./...

Result: Go client formatting, vet, and race tests passed.

Command:

    cd runner/cs-runner && test -z "$(gofmt -l .)" && go vet ./... && go test -race -shuffle=on -count=1 ./...

Result: Go runner formatting, vet, and race tests passed in 40.900 seconds.

## Packaged terminal QA

Command:

    docker run --rm -v "$PWD:/workspace" -v "$PWD/.tmp/task14-package/go-wrapper:/usr/local/bin/go:ro" -v "$PWD/.tmp/task14-package/cs-runner-linux:/tmp/cs-runner-linux:ro" -v "$PWD/.tmp/task14-package/cs-linux:/tmp/cs-linux:ro" -v "$PWD/.tmp/task14-package/csd-linux:/tmp/csd-linux:ro" -w /workspace elixir:1.20-otp-29 sh -c './scripts/package.sh /workspace/.tmp/task14-package/prefix4'

Result: package assembly completed successfully.

The artifact probe confirmed Linux ELF binaries at prefix4/bin/cs, prefix4/bin/csd, and the installed release's private cs-runner path.

The installed-only driver mounted only the package prefix and a fresh temporary CS_HOME, ran as UID 1000, used only the installed bin directory plus system tools on PATH, set CS_RELEASE to the installed OTP release, and ran from /tmp without a source checkout.

The driver invoked installed csd migrate, csd start, cs orient --json, cs project add, cs mission create, cs mission submit, cs mission authorize, cs mission, cs review, cs why, and csd stop.

The first non-debug driver attempt ended without a useful assertion line.

A diagnostic rerun against the same fresh package completed successfully and emitted the bounded result below.

Bounded observed output included:

    {"snapshot_version":1,"ledger_status":"recorded","safe_next_actions":[{"action":"draft","mission_id":"b0d41270-256b-49f8-8294-77821e662549"}]}
    {"error":{"code":"unauthorized","reason":"advisory_operation_forbidden"},"ok":false}
    mission b0d41270-256b-49f8-8294-77821e662549 phase=ready_for_review project=82f1a892-8b77-4490-9c8d-38ac53ac5dc1 base_sha=9bc26baaf5a2c9c2194e2ace0d5e50770d10c5ac checkpoint_sha=df1ecc5397c4f92fd90560f1d772c359ec15ca40
    result: sha=df1ecc5397c4f92fd90560f1d772c359ec15ca40 status=imported kind=completed ref=refs/consigliere/projects/82f1a892-8b77-4490-9c8d-38ac53ac5dc1/attempts/30f843d0-58ec-46bc-93e0-1ea68b525ffa/result
    verification: gate=review ordinal=1 outcome=passed input_sha=df1ecc5397c4f92fd90560f1d772c359ec15ca40
    TASK14_PACKAGE advisory=bounded filters=verified boss_refusal=verified direct_codex=verified stop=verified result=df1ecc5397c4f92fd90560f1d772c359ec15ca40

The orientation response contained no trusted_mirror_path, repository_path, workspace_path, database_path, credentials, transcript, or argv fields.

The advisory ledger was written under the private temporary home with session, turn, compaction, reset, human-intervention, token-counter, and snapshot-size fields.

The direct Codex Attempt was not polled through advisory.orient after authorization.

The installed cs mission, cs review, and cs why surfaces returned the exact result SHA and daemon-owned result ref while the advisory sanitizer omitted Workspace filesystem paths and raw log lines.

The installed csd stop completed and the driver asserted that priv.sock, api.sock, and boss.sock were absent afterward.

No source checkout, Mix command, legacy supervisor, Herdr pane, Boss credential, pull request, push, merge, or automatic delivery was used by the installed driver.

## Adversarial coverage

- Missing, malformed, oversized, unsafe, and mismatched Project or Mission filters fail closed without widening the snapshot scope.
- Boss-shaped request bytes with an advisory credential remain model_advisory and are refused before a receipt, Mission mutation, authorization, cancel, or daemon shutdown.
- Every unlisted advisory operation is denied before mutation, including authorization, pause, resume, continuation, delivery authorization, question answer or open, project registration, reconciliation, and shutdown.
- Advisory responses recursively omit known credential, capability, database, mirror, repository, Workspace path, process, argv, raw log, transcript, and socket fields.
- Question prompts, recommendations, incidents, blockers, and Mission text are bounded and redacted before entering the advisory response.
- The advisory ledger accepts only bounded identity strings and non-negative counters, caps rows and bytes, serializes appends, and never stores prompts, transcripts, credentials, command output, or repository content.
- A safe Mission draft succeeds through the advisory principal, while its durable phase remains draft and cannot be submitted or authorized by that principal.
- Review-ready, active, blocked, and draft state are represented as typed fields and safe next actions rather than model-authored authority instructions.
- Losing or compacting an advisory session has no durable state effect because the snapshot is read-only and all state remains in SQLite.
- Hung commands, dirty workspaces, exact-SHA verification, runner termination, repeated interruption, and Codex output provenance remain owned by the earlier execution and progression boundaries and are not reimplemented by the advisory layer.
- Prompt injection and misleading advisory text cannot cross into Boss authority because only the privileged Boss channel can answer Boss Questions, authorize work, authorize delivery, or stop the daemon.
- No Capo, Secondmate, persistent repository manager, remote advisory session, model courier, polling loop, second production harness, telemetry platform, full transcript retention, fixed canary allocation, GitHub mutation, PR creation, push, or merge was added.

The temporary package prefix, Linux binaries, wrapper, fake Codex executable, generated runner, and manual QA scripts were moved to the macOS Trash after the successful diagnostic rerun.

No credentials, raw logs, or transcripts were written to this evidence record.

git diff --check passed before the implementation commit.

## Exact-head advisory boundary closure

Commit `8d839378a55e36222e13c19e84e1f91543fc92c4` removes `attempt.logs` from the model-advisory operation allowlist.

The advisory principal now fails closed before reading Attempt log files, while the Boss and daemon read-only log paths remain unchanged.

The RED/GREEN authorization proof is recorded in `task-8.md`, and the exact-head package and lifecycle receipts are `.omo/evidence/consigliere-local-v0-revival/package-artifact-8d83937.log` and `.omo/evidence/consigliere-local-v0-revival/installed-lifecycle-8d83937.log`.

## Final exact-head advisory boundary receipt

The final source head is `bf22b5d4cae239a222a3065ca4b34b574dd676ad`.

The advisory allowlist remains fail-closed for logs and every authority-bearing operation, and the final Linux daemon, Go, package, and installed-lifecycle receipts pass at that exact head.

The current package and lifecycle receipts are `package-artifact-bf22b5d.log` and `installed-lifecycle-bf22b5d.log`.

The advisory surface was not broadened during the runner recovery hardening, and no canary duplicate or product delivery action was introduced.

## Watcher follow-up: default Attempt log read

The packaged regression reproduced the documented default CLI failure: `cs attempt logs <attempt-id>` returned exit 5 with `unauthorized: advisory_operation_forbidden` for an authenticated default socket caller.

The exact-head fix restores only the bounded `attempt.logs` read operation to the model advisory allowlist and routes it through a dedicated sanitizer that preserves the bounded Attempt identifier and redacted lines while omitting the private log path.

The existing advisory mutation and authority-bearing operation restrictions remain fail-closed, with the RED/GREEN authorization regression and exact packaged CLI proof recorded in `watcher-followup-c727e94.md`.

## Watcher follow-up security closure

The first watcher fix authorized bounded redacted Attempt lines but was rejected by the security audit because arbitrary prompt-bearing log text remained model-visible.

The corrected source head `2c7f5b6c9c3f07f85aa4f4a9173e899ed78c0aa4` keeps `attempt.logs` authorized on the default advisory channel while returning only allowlisted durable harness-event summaries.

The advisory regression covers prompt injection, bearer-shaped secrets, private-path omission, bounded output, and preservation of Boss-only mutation denials.

The exact package/manual proof returned exit `0` for the default `cs attempt logs` command and exposed structured event summaries only.
