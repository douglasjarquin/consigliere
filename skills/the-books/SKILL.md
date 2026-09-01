---
name: the-books
description: Open the books with a full "pick up where I left off" status report from consigliere's live fleet state. Use when the boss invokes /the-books or asks for a bearings report, morning brief, status report, catch-up, "where did I leave off", or "what's in the works". Read-mostly; never tears down, merges, or mutates task state as a side effect of producing the brief.
---

# The Books

Produce a scannable catch-up brief from durable fleet state, then surface a concise version in chat.

## Procedure

1. Read the live fleet in one pass: `bin/cs-fleet-view.sh` (the read-only review: backlog headlines, every task with endpoint liveness and authoritative current state, open keyed decisions, PR and report pointers, registered capos).
2. Only when the boss asked about PRs or review-readiness, enrich with `gh-axi pr list` per active project; otherwise stay local-only and fast.
3. Compose the report to `data/status-report-<YYYY-MM-DD>.md`:
   - **Needs the boss** first: open decisions, review-ready PRs (full https URLs), real blockers, credential needs.
   - **In flight**: one line per task in the boss's nouns (the fix, the investigation, the PR) - never internal labels.
   - **Recently done** and **queued next** from the backlog.
   - **Capos**: one line each - domain, healthy/idle, anything routed and outstanding.
4. Surface the concise version in chat following AGENTS.md section 9 (outcomes, not mechanics; full PR URLs; no internal vocabulary).
5. Mutate nothing: no teardown, no merge, no backlog rewrites beyond optionally filing a boss-decision hold the report itself surfaced (via `bin/cs-decision-hold.sh`, only when the boss asks).

## Clearing the open decisions

A flat list of open decisions tends to stay open, so work them one at a time instead of leaving the pile with the boss.

After the brief, when the report surfaced at least one open decision, pick the single one you judge most consequential and put only that one to the boss.
Say plainly that the order is your judgment about what matters most right now, not a computed ranking.
Give it escalation-quality context per `AGENTS.md` section 9: the decision, why it matters, the options, and your recommendation.
When the boss answers, present the next most consequential decision the same way, and keep going one at a time until none are left.

Use only the fleet view already read for the brief; never gather fresh state to feed this flow.
Never open the flow when there are no open decisions - end with the brief.
