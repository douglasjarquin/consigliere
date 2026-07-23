---
name: rundown
description: Give a light, session-only recap of what happened in the current chat since the boss last spoke. Use when the boss invokes /rundown or asks for a recap, "what just happened", or "catch me up on this chat".
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
4. If a prior real boss message exists, recap only what happened after that message and before the current invocation.
   Include concrete outcomes, landed work, failures, decisions made, new decisions needed, and work still running only when they appear in the visible history.
   Use the boss-facing outcome language required by `AGENTS.md` section 9.
   Preserve every full `https` PR URL present in the interval.
5. On the recap branch, use session history only.
   Do not load `the-books`, run shell commands, gather fleet or task status, use GitHub or browser clients, call tools, read or write files, create a report, persist anything, or guess beyond the last visible event.
6. If nothing happened after the previous boss message, say so directly in one sentence.

## Boundaries

- The current `/rundown` message is outside the recap interval.
- A previous `/rundown` is a real boss message and may be the interval boundary.
- If context compaction makes the prior boundary unavailable, say that the exact session boundary is unavailable and summarize only visibly supported events.
- Fall back to `the-books` only when this is genuinely the first real boss message.
