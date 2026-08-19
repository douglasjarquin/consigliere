# Gate state machine

## Purpose

A Gate represents one validation run of one gate type (for example, review, test, lint, security) against one exact input SHA, one exact base SHA, and one exact policy hash.
`base_sha` is part of Gate identity, not just `input_sha`, because Made's own pipeline includes a rebase stage and diff-scoped review stages: the same `input_sha` diffed against two different bases can produce two different, equally valid validation results, so a Gate must record which base it was actually run against.
A Gate's job is narrow: record whether validation passed, needs a human decision, failed in a retryable way, or failed terminally, and do so without ever holding a live process open while waiting for that human decision.

A Gate is deliberately not the place where cumulative repair accounting lives.
A new commit produces a new Gate; the Mission validation ledger (Section 10.8 of the architecture, one row per Mission and gate type) is the only place that accumulates across Gates, specifically so that "the boss fixed the SHA and a new Gate was created" can never be mistaken for "the repair budget reset."

## States

- `pending` - a Gate has been created for a given input SHA, base SHA, and policy hash, but the managed validation command has not yet been started.
- `running` - the managed validation command (`made validate --managed ...` or an equivalent validator) has been started for this Gate and is actively executing.
- `passed` - the managed validation command exited with a `passed` outcome for this exact input SHA, base SHA, and policy hash.
- `needs_decision` - the managed validation command exited with `needs_decision`; findings and a decision request have been persisted, and the validating process has already exited. Nothing is waiting.
- `failed_retryable` - the managed validation command exited with `failed_retryable`; a semantic finding exists that an automated repair Attempt may be able to fix.
- `failed_terminal` - the managed validation command exited with `failed_terminal`, or the Mission validation ledger's repair/finding limits were exceeded, and no further automatic repair will be attempted for this Gate.
- `canceled` - the Gate was canceled before reaching a terminal outcome (Mission canceled, superseded, or the boss explicitly aborted validation).
- `invalidated` - a Gate that had reached `passed` is no longer valid because the Mission's checkpoint SHA advanced past the input SHA this Gate validated, or because the Mission's base branch advanced past the base SHA this Gate validated against.

## Transition table

| From | To | Trigger | Guard | Side effects |
|---|---|---|---|---|
| (none) | `pending` | MissionCoordinator determines a Gate is required for the current checkpoint SHA per the Mission's validation_policy | no existing non-invalidated Gate already covers this exact (mission_id, gate_type, input_sha, base_sha, policy_hash) tuple | Gate row inserted; `gate.created` event |
| `pending` | `running` | managed validation command is launched with `--run-id`, `--workspace`, `--input-sha`, `--base-sha`, `--policy-hash`, and the current Decision set | runner slot available per GlobalScheduler | `managed_run_id` recorded; `gate.started` event |
| `running` | `passed` | managed command exits `passed` | exit input SHA matches the Gate's `input_sha` exactly, and exit base SHA matches the Gate's `base_sha` exactly | `output_sha` recorded if applicable; `gate.passed` event; Mission phase may advance if this was the last required Gate |
| `running` | `needs_decision` | managed command exits `needs_decision`, having already emitted structured findings and exited | findings persisted before this transition is recorded, matching the command's actual exit (not inferred from silence) | `finding_digest` recorded; a Question opened (subject_type = gate, requested_authority per finding severity/policy); Mission blocker of kind `validation` opened; `gate.needs_decision` event; the runner slot is released in the same operation that records this transition |
| `running` | `failed_retryable` | managed command exits `failed_retryable` | none beyond a successful, well-formed exit | Mission validation ledger incremented (`total_failed_runs`, `total_repair_rounds` if this triggers an automatic repair); `gate.failed_retryable` event |
| `running` | `failed_terminal` | managed command exits `failed_terminal`, or infrastructure retries and repair rounds both hit their configured caps | ledger counters checked against policy before this transition finalizes | Incident opened; Mission blocker of kind `validation` opened requiring explicit decision; `gate.failed_terminal` event |
| `running` | `failed_retryable` | managed command exits `infrastructure_error` | none | infrastructure retry counter incremented (kept separate from semantic repair counters per Invariant 16); `gate.infrastructure_retry` event; does not count against the semantic repair budget |
| `failed_retryable` | `pending` | a repair Attempt commits a new checkpoint SHA and it is imported | repair Attempt's checkpoint import succeeded | a *new* Gate row is created for the new SHA (this row itself does not transition further); ledger's cumulative counters carried forward, not reset |
| `needs_decision` | `pending` | the Question is answered and a Decision is recorded | Decision's `input_sha` and `base_sha` both match this Gate's `input_sha`/`base_sha` (or the Decision is `sha_bound` to exactly this SHA pair); if either has changed, this transition is refused and a fresh Gate is required instead | a new managed validation invocation is started against the same input SHA, base SHA, and policy hash, now supplying the Decision set; `gate.rerun_after_decision` event |
| `pending`/`running` | `canceled` | Mission canceled or superseded, or boss aborts | none beyond authority to cancel the Mission/Attempt | `gate.canceled` event; any in-flight managed validation process is terminated by the runner, not left running |
| `passed` | `invalidated` | Mission's `current_checkpoint_sha` advances past this Gate's `input_sha`, or the Mission's base branch advances past this Gate's `base_sha` | new checkpoint recorded on the Mission, or base-branch movement observed by reconciliation | `gate.invalidated` event; Mission returns to needing a fresh Gate for the new SHA/base before it can reach `ready_for_review` again |

## Required behavior flows (Section 20)

**Passing validation:** `pending -> running -> passed`. Straightforward; no human wait, no repair.

**Human decision:** `pending -> running -> needs_decision`, Made (or the validator) has already exited by the time this state is recorded, a Question and Mission blocker exist, and the flow only continues via `needs_decision -> pending` once a Decision is recorded and a fresh managed invocation is started against the *same* input SHA, base SHA, and policy hash. If either SHA has changed in the meantime, this Gate's `needs_decision` state is left as historical record and a new Gate is created instead; the old Decision, if `sha_bound`, does not apply to the new SHA pair.

**Auto-fixable finding (repair):** `pending -> running -> failed_retryable`, which increments the Mission validation ledger, triggers a repair Attempt, and on that Attempt's successful checkpoint import produces a brand new Gate row (`pending` again) for the new SHA. The old Gate row stays `failed_retryable` as history; it never transitions into the new Gate's lifecycle. This is what makes "new Gate does not reset ledger" concrete: the ledger row is looked up by `(mission_id, gate_type)`, not by `gate_id`, so it survives across this whole chain of Gate rows.

**Repeated finding escalation:** each `failed_retryable` transition's side effect increments `identical_finding_counts_json` on the ledger, keyed by finding fingerprint (Section 11: stage, finding_code/rule_id, finding_class, normalized path, enclosing symbol, semantic category; never line number or prose). When a fingerprint's count exceeds the policy limit (default 2 identical occurrences, default 3 repair rounds total per Mission and gate type), the *next* would-be `pending -> running -> failed_retryable` transition is instead forced to `failed_terminal`, an Incident is opened, and automatic repair Attempts stop being scheduled for this Mission and gate type until a boss or project Decision (`mission_finding_waiver` or `project_policy_override`) explicitly clears it.

## Terminal states

`passed` is terminal for that specific Gate row but not final for the Mission's validation posture, since it can still be pushed to `invalidated` by a later checkpoint; in that sense `passed` is "terminal-until-invalidated," a deliberate exception explained below.
`failed_terminal`, `canceled`, and `invalidated` are hard-terminal: none of these rows ever transitions again, and any further validation of the Mission happens through a new Gate row.
`needs_decision` and `failed_retryable` are not terminal; they are explicitly designed to be revisited, but always by creating forward motion (a rerun against the same SHA, or a new Gate for a new SHA), never by resuming the same process that produced them.

## Invariants enforced by this state machine

- **Invariant 3** (no human wait retains a live Agent or validator): the `running -> needs_decision` transition is defined to happen only after the managed validation command has already exited; this state machine has no "waiting" state that corresponds to a live process, only `running` (process is actually active) and post-exit terminal-or-resumable states.
- **Invariant 16/17** (repair budgets span SHAs; new Gate creation cannot reset accounting): enforced by keying the Mission validation ledger off `(mission_id, gate_type)` rather than `gate_id`, and by the explicit statement above that the `failed_retryable -> pending` transition creates a new Gate row without touching the ledger's cumulative counters.
- **Invariant 18** (validation is tied to input SHA and policy hash): every transition's guard checks the input SHA, base SHA, and policy hash (the Gate's full identity tuple) match exactly; `needs_decision -> pending` explicitly refuses to proceed if either SHA has drifted, and `passed -> invalidated` fires on either the input checkpoint or the base branch moving.
- **Invariant 21** (poison data quarantines one entity, does not restart-loop the daemon): a malformed managed-validation event stream is handled as a `failed_terminal` classification for this one Gate (with an Incident), not as a daemon crash or infinite retry.
- **Invariant 22/23** (duplicate commands and external events are idempotent; reconciled by natural identity): a duplicate or stale event from an old `managed_run_id` is rejected by checking the run ID against the Gate's currently active run, mirroring the Attempt fencing-token pattern.

## Failure-mode traceability

- The Made grounding fork's confirmed finding is the direct origin of this entire state machine's core design constraint: `chain.parkForApproval` (`internal/orchestrator/workfunc.go`) calls `c.reviewDecisions.Wait(...)`, a genuine blocking channel read, holding an open worktree and daemon connection for as long as a human takes to answer, with the *only* unblock path being an interactive `made review` CLI reading stdin from inside that same daemon process. The `running -> needs_decision` transition's guard - that the managed command has already exited before this state is recorded - is written specifically to make that pattern structurally impossible in the new system: nothing Consigliere calls "Made" in managed mode is ever allowed to block.
- The Made grounding fork also confirmed `RunManager` is a pure in-memory `map[string]*run` with zero persistence and zero spool; a daemon restart today loses every pending finding unconditionally. This is why `needs_decision`'s side effects (findings persisted, Question opened, Mission blocker opened) are committed to the database in the same transaction that records the state transition, so a daemon restart mid-decision loses nothing.
- The Made grounding fork confirmed no `input_sha`/`policy_hash` concept exists anywhere in Made's current source (`grep` returned zero matches). Every guard in this table that checks SHA/policy-hash equality is new surface being deliberately specified here, not an extension of anything Made already enforces; `docs/protocols/made-managed-mode.md` is where this becomes a concrete CLI contract.
- `base_sha` was added to Gate identity after the Made-side managed-mode contract was revised (tracked in the parallel session doing Made-repo implementation work, per this project's `consigliere-made-work-split` decision to keep that work out of this repo). The reasoning carries over directly: Made's pipeline already has a rebase stage and diff-scoped review stages, so a Gate's identity was always implicitly base-relative even before this document said so explicitly; this update makes that dependency a named, guarded part of Gate identity instead of an unstated assumption.
- Legacy Consigliere's `cs-made-run-lib.sh` describing a parked Made run as holding a fleet slot "indefinitely" until `cs-teardown.sh` intervenes is the resource-leak-shaped version of the same underlying problem this state machine fixes: `running -> needs_decision`'s side effect explicitly releases the runner slot as part of the same operation that records the finding, so nothing downstream needs a teardown script to notice a stuck run.

## Open questions carried forward (not resolved here)

- Whether `invalidated` Gates should be retained indefinitely for audit purposes or subject to a retention policy; this document assumes indefinite retention since they are cheap rows and valuable history, but does not specify a cleanup policy.
- Exact policy defaults for the fingerprint occurrence limit and repair round limit (Section 11 suggests 2 and 3 respectively as starting points); left as configurable per project/gate-type rather than hardcoded in this state machine.
