# Made managed-mode protocol

This document specifies the contract between consigliere-next's daemon (added in Phase 1, in-place in this repository, on the rewrite branch) and Made, used as an external validation tool starting in Phase 5.
Made remains a separate repository and binary; this document specifies a new command surface Made must add, not a modification request against its existing interactive daemon.

## Grounding: what Made does today, and why it cannot be reused as-is

Direct evidence from Made's current source (`internal/orchestrator/workfunc.go`, `internal/daemon/reviewdecisions.go`, `internal/daemon/runmanager.go`, `cmd/made/*.go`):

- `chain.parkForApproval` (`workfunc.go`, called from both the review stage and the document stage whenever a stage reports pending findings) calls `c.reviewDecisions.Wait(c.ctx, c.runID, stage)`, which is a real blocking Go `select` over a channel in `internal/daemon/reviewdecisions.go`. This goroutine sits parked, holding an open worktree and daemon connection, until a human answers via the interactive `made review` command (which itself reads from stdin) or the context is canceled. This is the exact "blocked goroutine waiting on human input" anti-pattern master-prompt section 4.6 requires to be structurally impossible.
- `RunManager` (`internal/daemon/runmanager.go`) is entirely in-memory: a `map[string]*run` behind a mutex, no SQLite, no bbolt, no file-backed spool anywhere in the repository. A daemon restart loses every run, every pending finding, and every parked decision, unconditionally.
- There is no `input_sha`, `InputSHA`, or `inputSha` field anywhere in the codebase. Made does not tie a validation result to an exact commit SHA today beyond ad hoc `git rev-parse` calls inside individual stages.
- The current CLI surface is `made daemon start|stop|status`, `made status [--json]`, `made review [--run]` (interactive), `made pr`, `made doctor`, `made gate init|admit-push|notify-push`. No `made validate --managed` or equivalent single-shot command exists.
- One thing to explicitly preserve: the PR stage's method set is test-enforced to exclude any merge-capable GitHub call (per Made's own `plans/made-rewrite.md`), and Made's `RunCompleted` state is deliberately never reached on CI-passed-but-unmerged runs, because "merging is a human decision made cannot observe." This existing discipline, that Made structurally cannot merge, is exactly the shape master-prompt section 12 and section 21 want preserved and should not be weakened by managed mode.

Conclusion: managed mode is new surface area in Made, built alongside the existing interactive daemon path, not a flag on top of `parkForApproval`. The existing daemon/orchestrator/`ReviewDecisions` machinery continues to serve standalone (no-Consigliere) users exactly as it does today; consigliere-next never talks to that path.

## Command contract

```text
made validate --managed \
  --run-id <run-id> \
  --workspace <path> \
  --input-sha <sha> \
  --policy-hash <hash> \
  --decisions <file> \
  --json-events
```

Flags:

- `--run-id`: caller-supplied identifier (consigliere-next's Gate id), used only for correlating output and logs; Made does not need to persist it beyond the process lifetime, since Made itself owns no durable Gate concept in managed mode.
- `--workspace`: absolute path to the Mission workspace clone to validate. Made operates read-mostly here except for stages that must produce a repair commit (lint auto-fix, etc.); it never pushes, never touches remotes, and never has credentials for anything beyond local git.
- `--input-sha`: the exact commit SHA being validated. Every stage's result and every finding this invocation reports must be understood by the caller as scoped to this SHA and no other; if the workspace HEAD does not match `--input-sha` when the process starts, it is an immediate `infrastructure_error` exit, not a best-effort validation of whatever HEAD happens to be.
- `--policy-hash`: a hash of the validation policy configuration in effect (which stages run, what thresholds apply). Consigliere-next uses this together with `--input-sha` to know whether a cached/prior Gate result is still valid; Made itself does not need to interpret the hash, only echo it back on every emitted event so the caller can verify it never silently ran under a different policy than requested.
- `--decisions <file>`: a JSON file of previously granted Decisions (waivers, approvals) scoped to specific finding fingerprints, described below. Made consults this file to avoid re-raising a `needs_decision` for a finding the caller has already resolved; it does not consult any other decision source (no interactive stdin prompt exists in this mode at all).
- `--json-events`: every event Made emits during this run is one JSON object per line on stdout (NDJSON, matching the runner protocol's framing choice for the same operability reasons). No other output format is supported in managed mode; there is no human-readable interactive fallback.

## Event stream

Made emits one line per meaningful state transition. Proposed event shapes:

```json
{"event": "stage.started", "run_id": "...", "stage": "review", "input_sha": "9f2b1a...", "policy_hash": "..."}
{"event": "stage.finding", "run_id": "...", "stage": "review", "finding": {"finding_code": "REVIEW-CORRECTNESS", "finding_class": "correctness", "path": "internal/foo/bar.go", "symbol": "DoThing", "description": "...", "severity": "blocking"}}
{"event": "stage.completed", "run_id": "...", "stage": "review", "outcome": "passed"}
{"event": "run.needs_decision", "run_id": "...", "stage": "review", "findings": [ { "...": "as above" } ], "decision_request": {"question": "...", "options": ["waive", "block"]}}
{"event": "run.terminal", "run_id": "...", "outcome": "passed", "input_sha": "9f2b1a...", "policy_hash": "..."}
```

Every finding carries a `finding_code`/`rule_id`, a `finding_class`, a repository-relative `path`, and an `symbol` where derivable, per master-prompt section 11's fingerprint requirement; `description` and any line number are evidence only, never identity. This is new surface area for Made's `internal/agent`/`internal/pipeline/review` packages, since findings today are freeform `Description` strings with no such structured identity.

## Terminal outcomes and exit codes

The process always exits, never blocks past the point of needing a decision. Exit code maps 1:1 to the final `run.terminal` event's `outcome`:

```text
0   passed
2   needs_decision
3   failed_retryable
4   failed_terminal
5   infrastructure_error
6   canceled
```

`needs_decision` is not a failure in the shell-exit-code sense that should trigger retry logic in a calling script; it is a distinct, expected outcome that hands control back to consigliere-next.

## Protocol walkthrough: a finding requiring a human decision

1. Consigliere-next starts `made validate --managed` with a fresh `--run-id`, the Mission's current checkpoint SHA, the Project's policy hash, and an empty (or previously accumulated) `--decisions` file.
2. Made runs its stage chain against the workspace at that SHA. The review stage reports a blocking finding with no matching entry in `--decisions`.
3. Made emits `stage.finding`, then `run.needs_decision` (with the finding list and a decision request), then exits with code 2. No goroutine is left parked; the process has fully terminated.
4. Consigliere-next persists a Gate row (`status: needs_decision`, `input_sha`, `policy_hash`, `finding_digest`) and a Question row referencing that Gate, and creates a Mission blocker, all inside the same short transaction (`docs/architecture/database.md`).
5. The Mission is now blocked on that Question. No process, goroutine, or model session is waiting; the runner slot Made used is fully released.
6. At some later point (seconds or days later), the boss (or, for a delegated non-boss-authority finding class, an authorized advisory principal) answers the Question through the appropriate channel (`docs/architecture/authority-model.md`).
7. Consigliere-next persists a Decision row scoped to that finding's fingerprint (and, if the boss chooses, scoped to the SHA only, or to the Mission as a standing waiver for that fingerprint per master-prompt section 11).
8. Consigliere-next starts a **new** `made validate --managed` invocation, with a **new** `--run-id`, the **same** `--input-sha` (the workspace has not changed; nothing was repaired), the **same** `--policy-hash`, and a `--decisions` file that now includes the new Decision.
9. Made re-runs the required stages (at minimum, the stage that produced the finding; full re-run of the chain is the simpler and initially preferred default, since Made has no stage memoization contract in V1 per master-prompt section 12). This time the finding's fingerprint matches an entry in `--decisions`, so no `run.needs_decision` is raised for it, and the run proceeds to `passed` (or to the next unresolved finding, if any).
10. Consigliere-next observes `run.terminal` with `outcome: passed`, transitions the Gate to `passed`, and the Mission's validation ledger is updated: `total_runs` increments, but the fingerprint-suppressed-by-waiver case is recorded distinctly from an "identical finding recurred and was not waived" case, since only the latter counts against the repair-round budget.

## Protocol walkthrough: an auto-fixable finding

1. Made's lint stage reports a `failed_retryable` outcome for an auto-fixable class of finding (not `needs_decision`, since no human judgment is required).
2. Consigliere-next increments the Mission's validation ledger repair-round counter for this Gate type, and dispatches a repair Attempt against the same workspace.
3. The repair Attempt makes a new commit. Consigliere-next imports that commit as a new checkpoint SHA.
4. Consigliere-next starts a fresh `made validate --managed` invocation against the **new** `--input-sha`. A new Gate row is created for the new SHA, but the Mission validation ledger (which is keyed by Mission and gate type, not by Gate row) carries the repair-round count forward unchanged; a new SHA never resets it, per invariant #12/#17.
5. If the same fingerprint recurs after the configured maximum identical-finding-occurrence count (default 2, per master-prompt section 11), Made still reports the finding normally; it is consigliere-next's ledger logic, not Made, that recognizes the threshold has been crossed, stops dispatching further automatic repairs, and raises a Question and an incident instead.

## What Made must not do in managed mode

Per master-prompt section 12 and section 21, in managed mode Made must never:

- Push to any remote, or hold any push credential. (Consistent with the existing plan's `--session made`/no-ambient-`HERDR_SESSION` discipline and the test-enforced merge-incapable PR stage; extend that same discipline to forbid push entirely in this mode, since push and PR creation belong to consigliere-next's delivery lane, not Made's validation lane.)
- Create or modify a pull request.
- Observe, poll, or gate on CI status.
- Decide Soldier lifecycle (start, retry, or terminate an Attempt); Made only validates a workspace state consigliere-next hands it.
- Decide Mission-level retries or repair-round budgets; Made reports outcomes and findings, consigliere-next's ledger decides whether to try again.
- Send a boss notification of any kind; Made's only output is the JSON event stream on stdout to its caller.

Made's standalone interactive daemon (`made daemon`, `made review`) is unaffected by any of the above and may continue to serve users who run Made without consigliere-next.

## Open questions for Phase 0 / Phase 5

- Stage memoization (skipping a stage whose inputs have not changed) is explicitly out of scope for the first managed-mode contract, per master-prompt section 12; every managed invocation re-runs the full requested stage set. This is a known cost accepted for correctness simplicity, not an oversight.
- The exact fingerprint algorithm (what counts as "the same finding" across a repair commit that moves line numbers) needs a joint design pass with Made's `internal/agent`/`internal/pipeline/review` maintainers once this contract is accepted, since today's findings carry no structured identity at all.
- Whether `--decisions` should be a single cumulative file consigliere-next maintains and grows, or a fresh file computed per invocation from the current Decision rows, is left to Phase 5 implementation; this document assumes the latter (computed fresh each time) since it avoids Made needing to reconcile a file it did not fully control against consigliere-next's authoritative Decision rows.
