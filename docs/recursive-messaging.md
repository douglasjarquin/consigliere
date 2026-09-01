# Herdr-native recursive messaging decision

Issue #143 establishes the active Consigliere direction on `main`.

Consigliere remains a Bash, Markdown, Git, and Herdr system with one boss-facing root, optional Capos, and recursively nested workers.

PR #141 and the Elixir rewrite branches remain historical engineering evidence and are not merged into `main`.

The active product does not include the daemon, SQLite authority, socket protocol, Go client, Go runner, Mission or Attempt state machines, or a global scheduler.

Herdr owns panes, workspaces, processes, agent detection, lifecycle facts, and directed prompts.

Small repository-owned files own durable task identity, one immediate parent edge, message inboxes, pending obligations, and acknowledgements.

Markdown owns briefs, reports, decisions, and review evidence.

Git owns code identity and delivery evidence.

The agent hierarchy owns judgment, delegation, summarization, and escalation.

The human boss owns merge authority.

The first implementation slice adds exact parent-edge metadata, a generic bounded durable message record, and a parent-scoped inbox drain.

The message is atomically published to the immediate parent's inbox before a bounded Herdr wake reference is sent.

Duplicate message IDs are idempotent when the bytes match and fail closed when they conflict.

The message primitive uses a versioned flat key/value record because the repository already validates flat metadata this way and no new parser or runtime is required.

`bin/cs-inbox.sh` is the parent-side operation: it emits only unacknowledged messages addressed to the current task, rejects malformed or stale sender and receiver generations, and acknowledges a message only through an explicit `--ack` operation after handling.

Event-driven lifecycle routing, recursive inbox draining, bounded cold reconciliation, polling reduction, and the nested Herdr canary remain later phases.

No issue checkbox for a later phase is complete until its named real-surface evidence exists.
