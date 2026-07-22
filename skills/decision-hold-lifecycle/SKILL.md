---
name: decision-hold-lifecycle
description: >-
  Agent-only policy for completing investigations and visual reviews without losing unresolved boss decisions.
  Load before treating an investigation, scout report, structured review, or Lavish review as complete, before ending a visual review that exposed a decision, and when recording or routing the boss's answer.
user-invocable: false
---

# Durable unresolved-decision lifecycle

This skill is the single policy owner for unresolved boss decisions discovered by an investigation or visual review.

## Policy

Every unresolved decision that belongs to the boss and is discovered while producing, reading, presenting, or ending an investigation or visual review must become a structured boss-held work item in the authoritative backlog of the home that owns the originating work before that work or review may be treated as complete.
The agent performs the semantic inventory because scripts must not infer decisions from report prose, visual-review artifacts, terminal output, or chat.
Give each distinct unresolved decision a stable privacy-safe key, register it through `bin/cs-decision-hold.sh hold`, and use the same key on retry so registration is idempotent while different decisions retain different durable identities.
After inventorying the whole report and review surface, run `bin/cs-decision-hold.sh complete` with every unresolved key, or with `--none` only when the reviewed surface contains no unresolved boss decision.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
Run the command in the originating work's authoritative `CS_HOME`; main-home work creates main-home holds, and capo-owned work creates holds in that capo home's backlog rather than copying them into the main backlog.
Do not close a hold merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
The hold remains the authoritative boss-decision item until the boss's answer is durably recorded, dependent work is created in the same backlog and blocked by that hold, and `bin/cs-decision-hold.sh resolve` routes the answer by clearing those dependency edges before closing the hold.
Resolved findings, recommendations that need no boss choice, and prose that merely sounds decision-like do not create holds.
The fleet review (`bin/cs-fleet-view.sh`) and any status brief read the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that require the boss.
3. For each choice, choose a stable key and use the script's `hold` command with a concise title, reason, and repository.
4. Run the script's `complete` command with the full unresolved-key inventory for that review pass.
5. Relay the choices to the boss as decisions under `AGENTS.md` section 9; do not use the word hold in boss chat.
6. After the boss decides, record dependent work with normal tasks-axi commands and block it by the hold identity.
7. Put the boss's exact durable decision in a file and use the script's `resolve` command with every routed task.
8. Confirm the fleet review no longer shows the closed hold and that routed work remains in structured backlog state.

`bin/cs-decision-hold.sh --help` owns command syntax, identity construction, completion attestation, retry behavior, and close ordering.
