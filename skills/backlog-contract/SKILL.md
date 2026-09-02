---
name: backlog-contract
description: >-
  Agent-only reference owning tasks-axi mechanics, decision-hold filing, and
  dispatch/completion transitions for the durable backlog.
  Load before filing, updating, or reconciling a backlog entry by hand.
user-invocable: false
---

# backlog-contract

`AGENTS.md` section 9 states the always-loaded nugget (`config/backlog.md` is the durable work-item queue; capos never appear in it).
This skill owns everything else.

`config/backlog.md` is the durable queue.
It tracks work items only, never agents; persistent capos never appear as backlog items.
Work routed to a capo is recorded in that capo home's own backlog, not the main backlog.
When a main-side thread such as a pending boss decision or relay reminder is worth durable tracking, file it as its own work item; use `tasks-axi hold <id> --reason "<reason>" --kind captain` for a boss-gated thread.
Unresolved decisions discovered by investigations or visual reviews follow `decision-hold-lifecycle`, which owns their mandatory backlog lifecycle.
Dispatch and completion transitions ride with the physical change itself: pass the item to `bin/cs-spawn.sh --backlog-item <id>` so dispatch marks it in flight and successful teardown records it done, and update the backlog by hand only for decisions and whenever those scripts print a reminder instead.
Re-evaluate queued work after every teardown and heartbeat, dispatching items only when dependencies and time gates have cleared.

`.tasks.toml`, `docs/configuration.md`, and current `tasks-axi --help` own the backlog schema, compatibility, retention, and routine command syntax.
Use compatible `tasks-axi` when the configured backend selects it and the documented manual path otherwise; keep only the configured recent Done entries.
`capo-provisioning` and `bin/cs-backlog-handoff.sh` own cross-home handoff safety.

Keep free-form notes free of temporary paths, moving versions, ephemeral identifiers, and copied state that will rot.
Inspect the current task note before replacing its considered body, and archive the superseded body when recoverability matters rather than appending by default.
Verify volatile details against their authoritative config, live system, or API before acting, and correct or delete stale prose immediately.
Preserve durable structured identifiers, dependencies, and completion artifact links, and route reusable knowledge to `project-management`'s placement rules rather than scattering it through task notes.
