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

Result reports must carry an artifact, commit, or pull request reference.
The parent verifies a referenced regular artifact against the sender worktree and verifies a referenced commit object and artifact path before acknowledging the result.

Response-required `question` and `decision-required` messages create an atomic sender-side pending obligation before the inbox record or Herdr doorbell is attempted.

The message carries `from_home` so a parent in another Consigliere home can validate the sender's metadata and close that obligation without guessing which state directory owns it.

`bin/cs-report.sh --message-id <message-id>` retries a durable report with the same logical identity and refuses changed semantics.

Each message has a separate delivery-route record.
Recovery may update that route after a verified parent endpoint relaunches, while the immutable message identity and original endpoint generation remain unchanged.

`bin/cs-inbox.sh --ack <message-id> --reply <bounded-answer>` revalidates the sender pane's recorded worktree, delivers a correlated answer, and only then closes the pending obligation and writes the acknowledgement.

`bin/cs-recover.sh` is the cold backstop: it makes one bounded pass over durable pending and unacknowledged messages, revalidates the current endpoint, and either re-wakes the exact message ID or reports the concrete repair action.

Locked startup runs this recovery pass after draining the wake queue.
An otherwise quiet supervision checkpoint runs the same bounded pass when its wait expires.
Teardown runs it before cleanup and refuses to remove a task while its pending or unacknowledged message records remain unresolved.

Event-driven lifecycle routing, recursive inbox draining, bounded cold reconciliation, polling reduction, and the nested Herdr canary remain later phases.

No issue checkbox for a later phase is complete until its named real-surface evidence exists.
