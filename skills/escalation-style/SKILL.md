---
name: escalation-style
description: >-
  Agent-only reference owning the exact internal-to-boss-facing translation
  table and the reach-the-boss-immediately list.
  Load before any boss-facing message that reports internal state or an
  outcome.
user-invocable: false
---

# escalation-style

`AGENTS.md` section 8 states the always-loaded nugget (translate before it reaches chat; never relay verbatim; the exact `Boss, taken care of.` phrase; always include full PR URLs).
This skill owns the exact translation table and the escalation list.

## Talk in outcomes, not mechanics

Use the boss's nouns: the investigation, the scout, the fix, the PR, the review, the decision, the blocker, the credential, the local copy, the worker, or the project.
Do not expose internal terms such as startup machinery, locks, watchers, polling, soldiers, task ids, briefs, worktrees, checkouts, status or metadata files, teardown, promotion, workspace ids, context budgets, delivery-mode names, autonomy flags, wake types, status prefixes, decision holds, pipeline step names, validation-state labels, or compressed safety labels such as fail-closed or fail-open.
Scout and capo are accepted house vocabulary and do not need translation when they naturally name that work or role.
When evidence uses an internal label, rewrite it before sending:

- worktree, checkout, primary checkout, or local-main -> local copy, isolated copy, or local branch, only if the location matters.
- teardown -> cleanup.
- wake, watcher, heartbeat, stale, signal, or check -> notification, monitoring, waiting too long, or stopped responding.
- hold, gate, ask-user, needs-decision, needs-review, blocked, or paused -> the concrete decision, wait, approval, blocker, or external delay.
- done, failed, fix-review, checks-passed, cancelled, validation step, or pipeline state -> the concrete result, review finding, passing checks, failed check, or stopped validation.
- brief -> instructions.
- soldier -> worker, only when naming the helper matters.
- status file, metadata, state, task id, or raw path -> durable record, local record, or omit it unless the boss needs the file path to act.
- fail-closed or refuses loudly -> stops safely when something goes wrong, or reports the concrete missing requirement.
- fail-open -> steps aside and lets work continue when the check cannot complete.
- bossless mode -> the project running fully on its own while the boss is away, with every judgment call recorded for review in the PR.
- auto-decided -> decided it myself and recorded why.
- acknowledgment or kill switch -> never surfaced verbatim; describe the effect instead - "this project will make its own calls while you're away starting now" when it turns on, or "this project no longer makes its own calls without you" when it turns off.

Never relay soldier reports, status lines, tool output, validation-state labels, or decision records verbatim into boss chat.
Read them as evidence, then send the plain-English outcome and consequence.
Private evidence reports may retain exact identifiers, paths, status lines, validation labels, and internal terms when they are useful, but the boss-facing chat summary that points to the report still follows this translation rule.

Every escalation must stand alone and remain concise.
Lead directly with concrete evidence, then the consequence, options when applicable, and a recommendation.
Use the same evidence-first form for objections or clarifying challenges rather than unsupported deference.

## Reach the boss immediately for

- Work ready for their review, with the full PR URL.
- Finished investigation findings, relayed as findings rather than only a completion notice.
- Gate findings that require their decision under the configured authority.
- A real blocker or failure after the relevant playbook is exhausted.
- Anything destructive, irreversible, or security-sensitive.
- A needed credential or login.

Do not surface automatic fixes, retries, routine progress, or internal supervision mechanics.
When a routine operational update's specific event requires no action but a response must be sent, reply exactly `Boss, taken care of.` without characterizing the visible session's unrelated decisions.
Batch non-urgent updates into the next natural reply.
Use plain chat for a yes-or-no decision and `lavish-axi` only when several options or a structured report benefit from a visual surface.
Whenever a PR is mentioned, include its full `https://...` URL before any shorthand reference.
Mention cost as a courtesy when unusually much work is running, but never block on it.
