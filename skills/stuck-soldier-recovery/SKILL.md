---
name: stuck-soldier-recovery
description: >-
  Agent-only playbook for stuck or missing ordinary Consigliere direct reports.
  Use when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no workspace, or after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive soldier, or a failed steer.
  Reconciles recorded work before escalating from targeted inspection through safe relaunch or failure.
user-invocable: false
---

# stuck-soldier-recovery

Use this playbook when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no workspace, or when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.

Two channels reach a live soldier, and this playbook uses both deliberately.
`bin/cs-send.sh` is the data plane: one line of conversational text for the soldier to read.
`bin/cs-control.sh` is the control plane: the allowlisted lifecycle verbs `interrupt`, `exit`, and `relaunch`, each addressed to an exact task id and each verifying its own postcondition.
Never hand-drive lifecycle through herdr, a raw key, or a typed exit command: a routing-marked lifecycle command arrives as chat the agent reasons about, and an unverified stop or relaunch is the failure this plane exists to prevent.
`docs/agent-control.md` owns the mechanism and `bin/cs-control.sh --help` owns the exact flags; both scripts fail closed without an explicit `CS_HOME`.

The target's endpoint is recorded as `workspace=` and `pane=` in `state/<id>.meta` (`bin/cs-meta-lib.sh`), with its harness as `harness=`.

## Session-start reconciliation for a dead ordinary direct report

This procedure covers ordinary `kind=ship` and `kind=scout` direct reports.
Load `capo-provisioning` instead for `kind=capo` recovery.

Treat the digest's endpoint result as a presence signal, not proof that the task's work or validation run is gone.
Read the targeted current state with `bin/cs-crew-state.sh <id>` before deciding to relaunch.
A no-mistakes run matched to the soldier's branch and current code remains authoritative when the endpoint is dead: handle a terminal or parked run through the normal lifecycle, and keep supervising an active run instead of creating a duplicate worker.

When no authoritative run accounts for the task, inspect only its recorded herdr inventory: the recorded `workspace=` and `pane=` through herdr, and the recorded `worktree=` on disk.
Do not sweep the herdr session for matching names or infer ownership from a label; reconcile only this home's recorded direct reports.

A surviving worktree whose workspace is gone is recovered with `herdr worktree open --path <worktree> --label <id>` (docs/herdr.md), never recreated from scratch; record the fresh `workspace=` and `pane=` in `state/<id>.meta` (append; the last occurrence of a key wins per `bin/cs-meta-lib.sh`).
Once the endpoint is recorded again, bring the soldier back with `CS_HOME=<this-home> bin/cs-control.sh relaunch <id> --note '<one line of progress so far>'`.
It preserves the same task identity, prefers resuming the soldier's own session so its context survives, and falls back to the brief only when no session is resumable.

Never use a fresh `cs-spawn` while the recorded worktree is unaccounted for: it refuses on the existing metadata, and allocating another worktree can split one task across two copies.
If the worktree or ownership cannot be reconciled safely, leave all state intact and report the task failed or blocked with the conflicting evidence.

## Live-endpoint escalation

Escalate in order:

1. Peek the pane with `bin/cs-peek.sh <id>`.
   Then settle the question a peek cannot answer: is the agent still THERE?
   `bin/cs-crew-state.sh <id>` reports `source: pane-process` with a `husk` detail when the pane survived its agent, so a wedge and a dead agent stop looking alike.
   A husk is not recoverable by redirection - there is nothing running to redirect - so skip straight to the relaunch step below.
   "Could not read the process table" is never reported as a husk, so absence of that detail is not evidence the agent is alive.
2. If the soldier is waiting on a question its brief already answers, answer in one line: `CS_HOME=<this-home> bin/cs-send.sh <id> '<answer>'`.
   When that question is an open keyed decision or blocker in its status ledger, add `--resolve-key <key>` before the answer so the delivered answer also closes it (`bin/cs-send.sh`'s header owns that contract).
3. If the soldier is confused or looping, stop the turn with `CS_HOME=<this-home> bin/cs-control.sh interrupt <id>`, then redirect with a single `cs-send` steer.
   The interrupt reports whether the turn actually stopped and whether the composer is clear; a steer sent into a composer that still holds text would be submitted as part of that text.
4. If the soldier is genuinely wedged after redirection, relaunch it: `CS_HOME=<this-home> bin/cs-control.sh relaunch <id> --note '<one line of progress so far>'`.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; both harnesses auto-compact and keep going.
   The worktree, its commits, and its uncommitted changes persist across a relaunch, so it is cheap.
   The note is required because the replacement inherits the local copy and none of the conversation.
   Read the reported result rather than assuming it: the relaunch names which path it took (`resume` keeps the soldier's own context, `cold` re-reads the brief), proves a different agent process now owns the pane, and reports a failure plainly instead of claiming a running agent.
   If it refuses before stopping the old agent, nothing changed and the refusal names what to fix; if it fails after stopping it, no agent is running and the message names where the work is preserved.
   When herdr's own reading disagrees with what the pane appears to be doing, `cs_herdr_agent_explain` (`bin/cs-herdr-lib.sh`) names the detection rule that decided it, so the disagreement is explained rather than guessed at.
5. If `exit` or `relaunch` reports that it could not stop the agent, do not force it and do not tear the task down to get past it.
   Read the concrete state it reported (unsent text in the composer, a turn that would not cancel, an unreadable process table), clear that specific obstacle, and try the verb again.
   Unsent composer text already gets one submit-and-cancel attempt inside the verb, so a `composer` refusal means the text survived that: read the pane with `bin/cs-peek.sh <id>` and settle what is actually sitting there before trying again.
   A pane whose agent cannot be stopped at all is recovered by closing the pane and reopening the surviving worktree with `herdr worktree open --path`, which is endpoint replacement, not work discard.
6. If a second relaunch fails too, write `failed` to the backlog and tell the boss the plain failure, preserved work, and consequence using `AGENTS.md` section 9; do not mention metadata, pane, or worktree unless the path itself is needed for action.
