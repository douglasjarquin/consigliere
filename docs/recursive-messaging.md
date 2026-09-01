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

## Existing mechanism inventory

| Mechanism | Classification | Reason |
|---|---|---|
| `bin/cs-send.sh` | reuse | Retains Herdr delivery, bounded text, and explicit target validation for directed prompts. |
| `bin/cs-pending-reply-lib.sh` | generalize | Retains parent-owned response obligations and bounded recovery while the removed nested-decision subtype is gone. |
| `bin/cs-wake-lib.sh` and `bin/cs-wake-drain.sh` | reuse | Retain the durable zero-token wake queue and atomic drain boundary. |
| `bin/cs-herdr-event-hook.sh` and `bin/cs-herdr-event-lib.sh` | reuse | Retain the tiny event transport and exact pane/workspace identity binding. |
| `bin/cs-report.sh` and `bin/cs-message-lib.sh` | generalize | Provide the common bounded parent/child message schema, publication, retry, and identity rules. |
| `bin/cs-inbox.sh` | generalize | Provides parent-scoped message handling, result verification, acknowledgement, and upward transfer. |
| `bin/cs-recover.sh` | generalize | Provides one bounded reconciliation path for startup, timeout, explicit recovery, and teardown. |
| Root-side nested Capo status scan | delete later | Removed after the generic recursive message path and replacement tests were proven. |
| `capo-decision-escalation` pending subtype and relay branch | delete later | Removed after generic recursive upward transfer covered the behavior. |
| Telemetry transcript reads | temporary fallback | Retained only as bounded measurement input, never as semantic supervision authority. |

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

The answer is recorded in the sender home's pending state before transport delivery, and a separate delivery marker makes a retry after a lost acknowledgement harmless.

An escalated response-required message uses `bin/cs-inbox.sh --escalate <message-id> --summary <bounded-summary>`.
The command creates one deterministic transfer message to the current parent's parent before closing and acknowledging the child obligation.
Repeating the escalation returns the existing transfer without another wake.

`bin/cs-status.sh` renders bounded open-message, pending-obligation, and malformed-message counts with exact inbox and recovery next actions.
`bin/cs-recover.sh` reports whether it re-woke recipients, refused a record, or found no work, and prints the next action for each outcome.

`bin/cs-recover.sh` is the cold backstop: it makes one bounded pass over durable pending and unacknowledged messages, revalidates the current endpoint, and either re-wakes the exact message ID or reports the concrete repair action.

Locked startup runs this recovery pass after draining the wake queue.
An otherwise quiet supervision checkpoint runs the same bounded pass when its wait expires.
Teardown runs it before cleanup and refuses to remove a task while its pending or unacknowledged message records remain unresolved.

Interactive worker launches also install a turn-end backstop that reports a terminal child without a semantic result as `failed` recovery evidence instead of treating terminal prose as success.

Event-driven lifecycle routing, recursive inbox draining, bounded cold reconciliation, recursive escalation, settled-child stop-hook recovery, and removal of the root-side Capo worker scan are implemented in the active slices above.
The heartbeat backstop and bounded telemetry transcript reads remain because they respectively protect against lost status edges and provide measurement rather than semantic supervision.
The nested real-Herdr canary remains a later phase.

No issue checkbox for a later phase is complete until its named real-surface evidence exists.
