---
name: rundown
description: Give a light, session-only recap of what happened in the current chat since the boss last spoke, plus any visibly unanswered boss decisions. Use when the boss invokes /rundown or asks for a recap, "what just happened", or "catch me up on this chat".
user-invocable: true
---

# Rundown

Recap only the events already visible in the current conversation.

## Procedure

1. Inspect only the conversation history already visible to the current consigliere.
   Do not gather fresh state.
2. Find the most recent real boss-authored message before the current `/rundown` invocation.
   System, developer, tool, watcher or monitoring, turn-end-guard (turn-end guard), away-supervisor (away-mode daemon), launch-brief (launch instruction), session-start (session-start nudge), and `from-consigliere` routing messages are operational input, not boss messages.
3. If no prior real boss message exists, load [`../the-books/SKILL.md`](../the-books/SKILL.md) and follow it exactly.
   Do not restate its contract or combine its output with a session recap.
4. If a prior real boss message exists, preserve the ordinary recap interval: recap what happened after that message and before the current invocation.
   Include concrete outcomes, landed work, failures, decisions made, new decisions needed, and work still running only when they appear in that visible interval.
   Use the boss-facing outcome language required by `AGENTS.md` section 9.
   Preserve every full `https` PR URL present in the interval.
5. Additionally inspect the entire session history visible to the current consigliere before the current invocation for every explicit boss decision that remains unanswered, including decisions raised before the ordinary recap boundary.
   A later unrelated boss message establishes a recap boundary but does not close an earlier decision.
   Treat a decision as closed only when a later visible response substantively resolves it, chooses an option, declines it, grants or denies the requested approval, or otherwise directly addresses that decision.
   Include every visibly supported open decision once, and deduplicate by the decision's substance when the ordinary interval recap already represents it or its wording differs.
6. On the recap branch, use session history only.
   Do not load `the-books`, run shell commands, gather fleet or task status, use GitHub or browser clients, call tools, read or write files, create a report, persist anything, or guess beyond the last visible event.
7. If no ordinary events occurred after the previous boss message but an older visibly open decision exists, report that decision instead of claiming nothing happened.
   If neither ordinary events nor visibly open decisions exist, say directly in one sentence that nothing happened after the previous boss message.

## Boundaries

- The current `/rundown` message is outside the recap interval.
- A previous `/rundown` is a real boss message and may be the interval boundary.
- If context compaction makes the prior boundary unavailable, say that the exact session boundary is unavailable and summarize only visibly supported events.
- Compacted history supports an open decision only when both its request and its still-unanswered status are visible; report uncertainty instead of reconstructing hidden requests or answers.
- Fall back to `the-books` only when this is genuinely the first real boss message.
