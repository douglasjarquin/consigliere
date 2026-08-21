# ADR-007: Made exit-and-rerun managed mode

## Status

Proposed.

## Context

This ADR has the most direct grounding of the seven, because Made's actual current review-decision code path was read in full, not inferred.

`chain.parkForApproval` (`internal/orchestrator/workfunc.go:324-342`) is invoked from both the review and document stages whenever a stage reports pending findings:

```go
_ = c.rm.UpdatePendingFindings(c.runID, findings)
decision, err := c.reviewDecisions.Wait(c.ctx, c.runID, stage)
_ = c.rm.UpdatePendingFindings(c.runID, nil)
```

`ReviewDecisions.Wait` (`internal/daemon/reviewdecisions.go:61-80`) is a genuine blocking channel select, unblocked only by `Set()` (from `made review`'s interactive stdin prompt, `cmd/made/review.go:52-120`) or context cancellation.
This confirms directly, not speculatively, that Made today blocks a live goroutine -- holding an open worktree and daemon connection -- for the entire duration of a human review decision.

Three further facts, each confirmed by direct source inspection, define the shape of the gap this ADR must close:

- **Zero run persistence.** `RunManager` (`internal/daemon/runmanager.go:44-77`) is a `map[string]*run` behind a `sync.Mutex`; a repo-wide search for `sqlite|database/sql|bbolt|persist` and for `spool` returns nothing. A daemon restart while a decision is parked loses the run, the pending finding, and the parked decision simultaneously, with no recovery path.
- **No input-SHA or policy-hash plumbing exists.** A repo-wide search for `input_sha|InputSHA|inputSha` returns zero matches. Made ties nothing to an exact commit SHA today beyond ordinary ad hoc git plumbing inside individual stages.
- **No managed CLI command exists.** Made's current subcommands are `daemon start|stop|status`, `status [--json]`, `review [--run]`, `pr`, `doctor`, `gate init|admit-push|notify-push`. Nothing resembles a single-shot `made validate --managed --run-id --workspace --input-sha --policy-hash --decisions --json-events` invocation; building managed mode means adding a new, parallel command, not modifying the existing daemon+socket+long-lived-run invocation path.

One positive precedent was also confirmed: Made's PR stage structurally, and by an explicit test, never calls a merge-capable GitHub method (`plans/made-rewrite.md:699`), matching this rewrite's requirement that Made never own merge capability. That constraint should be preserved unchanged, not rebuilt.

Separately, legacy Consigliere's own `cs-made-lib.sh` documents (in its own header comments, verified against Made's actual `cmd/made/main.go` dispatch switch) that several subcommands it already calls -- `made axi status`, `made axi abort`, `made gate init` -- do not exist in Made's CLI yet, and are forward references to capability that has not been built. That is independent, corroborating evidence that an assumed-but-unbuilt integration contract is exactly the kind of drift this ADR's versioned, explicit managed-mode protocol is meant to prevent.

## Decision

Build a new, parallel command, `made validate --managed`, that does not modify or reuse the existing daemon/orchestrator/`parkForApproval` path.
The managed command is short-lived: it runs one validation pass against an explicit `--input-sha` and `--policy-hash`, emits structured JSON events (`--json-events`) for machine consumption, and exits with one of a fixed terminal-outcome vocabulary: `passed`, `needs_decision`, `failed_retryable`, `failed_terminal`, `infrastructure_error`, `canceled`.
On `needs_decision`, Made emits the structured findings and a decision request, then exits; it does not wait for an answer in-process, ever.
Consigliere's daemon persists the resulting Gate and Question, and only starts a new Made invocation (same input SHA, same policy hash, plus the durable Decision set) once an answer exists.
No checkpoint/resume support and no stage memoization are built in this first contract; a changed input requires a full rerun, and memoization is deferred until a cache key can be made environment-complete.
Made's existing merge-incapable PR stage behavior is preserved unchanged.

Consequently, since Made cannot durably own any of the following today, Consigliere's daemon must:

- Own Gate persistence and the Mission validation ledger (repair-round accounting spanning SHAs), since Made has no run persistence to build on.
- Own finding-fingerprint identity (`stage`, `finding_code`/`rule_id`, `finding_class`, normalized path, enclosing symbol) rather than relying on Made's current freeform `Description` strings, since no fingerprinting concept exists in Made today.
- Own Question routing and Decision durability entirely, since Made's `ReviewDecisions` is unpersisted in-memory state.
- Enforce input-SHA and policy-hash binding on every Gate itself, since Made has no such plumbing internally to lean on.

## Consequences

- Every human review decision against a Made validation becomes non-blocking by construction: Made exits, the daemon holds the Question durably, and validation resumes only on an explicit rerun, closing the exact "parked run holds a fleet slot indefinitely" stranding pattern documented in legacy Consigliere's `cs-made-run-lib.sh`.
- Made's standalone daemon behavior (the existing `daemon`/`review`/`pr` command set) is left in place unchanged for users who run Made outside of Consigliere; managed mode is strictly additive, not a replacement, which limits blast radius on Made's existing users.
- Because no memoization exists in the first contract, repeated validation reruns after a Decision cost a full re-run's wall-clock time; this is accepted deliberately, since a memoization cache with an incomplete cache key would risk silently reusing a stale result, which is a worse failure than a slower rerun.
- The integration contract between Consigliere and Made becomes an explicit, versioned CLI surface (flags, JSON event schema, terminal outcome vocabulary) rather than an assumed one; this directly prevents recurrence of the `cs-made-lib.sh` forward-reference drift found in legacy grounding, where Consigliere called subcommands Made had not yet implemented.

## Alternatives considered

**Modify the existing `parkForApproval`/`ReviewDecisions.Wait` path to add a timeout or a persistence layer underneath it.** Rejected: `ReviewDecisions` is shared by the interactive `made review` path, so any change there risks leaving a blocking path live for managed-mode callers by accident; a clean parallel command avoids that shared-state risk entirely.

**Have Consigliere poll Made's daemon/socket API instead of invoking a short-lived managed command.** Rejected: this would keep Made's daemon (and its unpersisted `RunManager`) in the authority position for run state, which conflicts directly with ADR-003's daemon-authoritative-state requirement; a short-lived exit-and-rerun command keeps Made stateless from Consigliere's perspective by construction.

**Build stage memoization into the first managed-mode contract**, to avoid full reruns after every Decision. Rejected for V1 per master-prompt section 12: an environment-complete cache key is nontrivial to get right, and a wrong one silently returns stale results, which is worse than the performance cost of always rerunning.

## Revisit trigger

Reopen this ADR if Phase 5's required tests (a `needs_decision` outcome must leave zero live validator process; a daemon restart must preserve the Question and Gate; a rerun against the same SHA must be idempotent; a changed SHA must invalidate a SHA-bound Decision) cannot be made to pass against the proposed managed-mode contract, or if Made's own roadmap independently adds native run persistence or input-SHA binding that would make part of this contract redundant.
