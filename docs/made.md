# made verified facts

Verified against source (`~/github/douglasjarquin/made`, HEAD `ebc2fa0df816a14bdf2d17847d04a16fbca43576`, working tree clean) and live against a real running daemon on the same machine, on 2026-09-05.
The binary at `~/.local/bin/made` was confirmed built from that exact commit (`go version -m`: `vcs.revision=ebc2fa0df816a14bdf2d17847d04a16fbca43576`, `vcs.modified=false`).
Re-verify this table after any made upgrade, the same discipline `docs/herdr.md` applies to herdr.
`bin/cs-made-lib.sh` and `bin/cs-made-run-lib.sh` cite this file for made's verified command surface, replacing an earlier forward-reference framing that pointed at a numbered task list living only in made's OWN repository (already fully checked off there), never in this one.

## Command surface (verified against source, made `ebc2fa0`)

The full CLI dispatch switch, `cmd/made/main.go:21-59`: `validate, capabilities, run, status, daemon, review, doctor, plan, gate, receipts, config, verify, cursor`.
There is no `axi` case anywhere in made's `.go` files (repo-wide grep, zero hits).
`axi` (`run`/`status`/`abort`/`respond`/`sync`/`logs`) is a predecessor-tool (`no-mistakes`) name, explicitly called out in made's own planning docs as a deferred, never-built forward reference: `plans/made-orchestrator.md:75`, "No `made runs`/`made axi abort` CLI additions (explicitly deferred)".

Live-verified `made capabilities --json`:
```json
{"schema_version":1,"protocol_version":1,"commands":["run.submit","run.status","run.list","run.cancel","review.decide","doctor","validate.managed.v1","verify","cursor"],"agents":["codex","claude","cursor","grok"],"managed_validation":{"review_sources":["internal","external"],"optional_stages":["review","test","document","lint"]}}
```

## `run list` / `run status` / `run cancel` / `review decide` / `doctor` (verified against source, made `ebc2fa0`)

- `made run list --json [--active]` (`cmd/made/runcommands.go:186-214`) -> `{"schema_version":1,"protocol_version":1,"runs":[StatusReport, ...]}`.
  `--active` filters via `activeRunStatus()` (`cmd/made/runhandlers.go:174-181`) to exactly `queued, running, awaiting_review, awaiting_merge` - excludes `succeeded, failed, canceled, superseded`.
- `made run status --json <exact-run-id>` (`cmd/made/runcommands.go:157-184`) -> one `StatusReport`. Exact id only, no prefix match (`statusHandler`, `cmd/made/status.go:74-92`, errors `"run.status: exact run_id %q was not found"`).
- `made run cancel --json <run-id>` (`cmd/made/runcommands.go:216-243`) -> RPC `run.cancel` -> `daemon.RunManager.Cancel` (`internal/daemon/runmanager.go:426-441`).
- `made review decide --json --stage <stage> --decision approved|rejected <run-id>` (`cmd/made/review.go:58-88`) - flags before the positional run-id (Go stdlib `flag.Parse` stops at the first non-flag argument). `--decision` is exactly `"approved"` or `"rejected"` (`internal/daemon/reviewdecisions.go:11-12`), validated client-side (`review.go:73`) and daemon-side (`review.go:42-44`).
- `made doctor --json` (`cmd/made/doctor.go:80-102`) -> `{"schema_version":1,"protocol_version":1,"healthy":bool,"checks":{"daemon":"reachable"|"unreachable","github":"authenticated"|"unavailable","herdr":"...","gate":"initialized"|"not_initialized"}}`. `checks.daemon` has exactly those two values, nothing else.
- Bare `made status` is obsolete (`cmd/made/main.go:28-30`): exits 2, prints exactly `made: status is obsolete; use made run status --json <exact-run-id>`.
- `made daemon start` blocks in the foreground until asked to stop (`cmd/made/daemon.go:56-86`, `<-done`); no fork/exec/setsid anywhere in `cmd/made`/`internal/daemon` (grepped, zero hits) - a caller must detach it itself (`bin/cs-made-lib.sh`'s `cs_made_daemon_start` does this via `bin/cs-detach.py`, the same double-fork mechanism `bin/cs-monitor-lib.sh` already uses for its monitor).

`StatusReport` (`cmd/made/status.go:34-64`, aliasing `internal/daemon` types), the fields consigliere reads:
```
run_id, repo, branch, ref, old_sha, state, input_sha, output_sha,
execution_finished (bool), current_stage, pr_url, error (string, singular),
errors (string[]), message, stages: [{name, result, message?, error?, evidence_refs?}],
pending_findings: [{stage, message}], queued_at, started_at, ended_at
```
`StageResult` (`internal/daemon/runstate.go:8-14`) fields: `name, result` (`"pass"|"fail"|"skipped"`), optional `message`, `error`, `evidence_refs`. A stage not yet run is simply absent from the array - made only appends a stage once it runs (`internal/orchestrator/workfunc.go:211`).

Live-verified today, no active runs on this daemon:
```
$ made doctor --json
{"schema_version":1,"protocol_version":1,"healthy":true,"checks":{"daemon":"reachable","gate":"not_initialized","github":"authenticated","herdr":"unavailable"}}

$ made run list --json
{"schema_version": 1, "protocol_version": 1, "runs": []}

$ made run list --json --active
{"schema_version": 1, "protocol_version": 1, "runs": []}

$ made status
made: status is obsolete; use made run status --json <exact-run-id>
(exit 2)

$ made version
made: unknown command "version"
(exit 2)
```
No `made version`/`made --version` command exists (both hit the unknown-command default case, exit 2) - version evidence comes from `git rev-parse HEAD` / `go version -m <binary>` instead.

## State enum and `execution_finished` (verified against source, made `ebc2fa0`)

Full state enum, 8 distinct JSON strings (`internal/daemon/runmanager.go:16-28`): `queued, running, awaiting_review, awaiting_merge, succeeded, failed, canceled, superseded`.
`RunCompleted` is a same-value Go alias for `succeeded` in made's own code, never a distinct 9th string on the wire.

`execution_finished` is true for `awaiting_merge` plus the 4 terminal states (`succeeded, failed, canceled, superseded`), false for `queued, running, awaiting_review` - set via the orchestrator's `Finish()` call (`internal/orchestrator/workfunc.go:161-162`, `internal/daemon/runmanager.go:448-464`).
`bin/cs-watch.sh`'s `made_run_state` maps this boolean directly to busy/idle rather than re-deriving a state-string allowlist, so it can't drift from made's own semantics.

## Stage pipeline (verified against source, made `ebc2fa0`)

Stage order, 9 stages (`internal/orchestrator/workfunc.go:26-34`): `intent, rebase, review, test, document, lint, push, pr, ci`.
Only `review` and `document` ever call `parkForApproval` (`workfunc.go:309,359` - the only two call sites in the repo), which is what produces `awaiting_review` and populates `pending_findings[]`.
A `rejected` decision fails the run via the same `stageFailure` path every other stage failure uses (`workfunc.go:492-511`) - there is no auto-fix branch.
The per-stage timeout, including the blocking `review`/`document` park, is the ordinary `defaultStageTimeout = 30 * time.Minute` (`internal/config/config.go:15`), not a distinct "review timeout" constant; overridable per-stage via `.made.yaml`'s `stages.<name>.timeout_seconds`.

`Intent: <goal>` is read via `git interpret-trailers --parse` (`internal/pipeline/intent/intent.go:58-76`), the `intent` stage; a missing/empty trailer fails that stage.

## The drive loop (verified against source, made `ebc2fa0`)

`git push` alone creates a run - the post-receive hook (`internal/gitgate/hook.go:36-44`) calls `gate notify-push` -> RPC `gate.notifyPush` -> `rm.SubmitSubmission(...)` directly (`cmd/made/daemon.go:494-497`), never the `run.submit` RPC handler.
`made run submit`, `made verify`, `made validate --managed`, and `made plan` are all real CLI surface but confirmed NOT on this drive path:
- `internal/verify` and `internal/managed` are never imported by `internal/orchestrator` or `internal/daemon` (import-grepped, zero cross-references).
- `internal/planner` is imported by the orchestrator only as a library, to compute which test lanes the `test` stage needs (`internal/orchestrator/lanecommands.go:11,33-40`) - never as CLI participation.

**No wrapper functions exist in consigliere for any of these four** (`run submit`, `verify run`, `validate`, `plan`) - they are not on the push -> poll -> decide -> terminal loop consigliere drives.

## Known gaps / not live-verified

- **`made run cancel` against an `awaiting_merge` run is source-derived, NOT live-observed.** No active run existed on the dev daemon at verification time to drive to `awaiting_merge` (doing so would require opening a real GitHub PR through all 9 pipeline stages, judged out of scope for a shell-layer verification pass). By the time a run reaches `awaiting_merge`, its work-goroutine has already returned and been `Finish()`-finalized (`internal/orchestrator/workfunc.go:161-162`, `internal/daemon/runmanager.go:311-391,444-464`), so `Cancel()`'s context-cancel does nothing observable, and the CLI's own 5-second poll-for-`RunCanceled` loop (`cmd/made/runhandlers.go:130-143`) times out: the call is expected to hang ~5s then error (`made run cancel: run.cancel: cancellation of <id> did not finish: context deadline exceeded`, exit 1). `bin/cs-teardown.sh`'s `conclude_nm_run` is written to never call cancel against `awaiting_merge` (or any terminal state) specifically because of this. **Re-verify live the next time a real run reaches `awaiting_merge`.**
- `StatusReport`'s exact field set (above) was read from source (`cmd/made/status.go`, `internal/daemon/runstate.go`), not round-tripped through a real completed run with every field populated - no live run existed to inspect one. The two live-verified transcripts above only ever showed an empty `runs: []`.
- `made run list --json`'s unfiltered (non-`--active`) call has no documented pagination or limit and could grow large over a long-lived daemon. `bin/cs-made-run-lib.sh`'s `cs_made_resolve_run` calls it only as a fallback when the `--active` listing misses (the common case), never as the primary path.
