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

Consigliere runs on exactly one harness (codex) and one terminal runtime (herdr); there is no adapter layer to consult.
The target's endpoint is recorded as `workspace=` and `pane=` in `state/<id>.meta` (`bin/cs-meta-lib.sh`), and `bin/cs-send.sh` is the fail-closed steer path - it requires an explicit `CS_HOME` and supports `--key Enter|Escape|C-c`.

## Session-start reconciliation for a dead ordinary direct report

This procedure covers ordinary `kind=ship` and `kind=scout` direct reports.
Load `capo-provisioning` instead for `kind=capo` recovery.

Treat the digest's endpoint result as a presence signal, not proof that the task's work or validation run is gone.
Read the targeted current state with `bin/cs-crew-state.sh <id>` before deciding to relaunch.
A no-mistakes run matched to the soldier's branch and current code remains authoritative when the endpoint is dead: handle a terminal or parked run through the normal lifecycle, and keep supervising an active run instead of creating a duplicate worker.

When no authoritative run accounts for the task, inspect only its recorded herdr inventory: the recorded `workspace=` and `pane=` through herdr, and the recorded `worktree=` on disk.
Do not sweep the herdr session for matching names or infer ownership from a label; reconcile only this home's recorded direct reports.

Before relaunch, prove that no live agent still owns the recorded task (`herdr agent get <pane>` via `bin/cs-herdr-lib.sh`'s corroborated status policy) and that the existing worktree remains available.
Preserve its uncommitted changes and commits, and keep the same task identity:

- A surviving worktree whose workspace is gone is recovered with `herdr worktree open --path <worktree> --label <id>` (docs/herdr.md), never recreated from scratch; record the fresh `workspace=` and `pane=` in `state/<id>.meta` (append; the last occurrence of a key wins per `bin/cs-meta-lib.sh`).
- Then relaunch codex in that pane with the same brief at `data/<id>/brief.md` plus a concise progress note, mirroring `bin/cs-spawn.sh`'s launch shape (its model/effort flags and the notify hook touching `state/<id>.turn-ended`).

Do not use a fresh `cs-spawn` while the recorded worktree is unaccounted for: it would refuse on the existing metadata, and allocating another worktree can split one task across two copies.
If the worktree or ownership cannot be reconciled safely, leave all state intact and report the task failed or blocked with the conflicting evidence.

## Live-endpoint escalation

Escalate in order:

1. Peek the pane with `bin/cs-peek.sh <id>`.
2. If the soldier is waiting on a question its brief already answers, answer in one line: `CS_HOME=<this-consigliere-home> bin/cs-send.sh <id> '<answer>'` from an active consigliere session unless `CS_HOME` is already set to the active consigliere home.
3. If the soldier is confused or looping, interrupt with Escape, then redirect with one corrective line:
   `CS_HOME=<this-consigliere-home> bin/cs-send.sh <id> --key Escape`, then a single `cs-send` steer.
4. If the soldier is genuinely wedged after redirection, exit the agent (`/exit` via `cs-send`, or close and reopen through the recovery path above) and relaunch codex in the same worktree with the same brief plus a `progress so far` note appended to it.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; codex auto-compacts and keeps going.
   The worktree and commits persist, so relaunch is cheap.
5. If a second relaunch fails too, write `failed` to the backlog and tell the boss the plain failure, preserved work, and consequence using `AGENTS.md` section 9; do not mention metadata, pane, or worktree unless the path itself is needed for action.
