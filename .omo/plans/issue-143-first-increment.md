# Issue 143 first increment

## Scope

This increment establishes the first complete vertical slice of the Herdr-native recursive protocol.

It adds one durable parent edge to task metadata and one generic, bounded, atomic, idempotent message contract addressed to that immediate parent.

The existing Herdr lifecycle and wake queue remain in place while later event routing and cold reconciliation are built on this contract.

The Elixir, SQLite, Go daemon, socket, custom runner, and scheduler directions remain historical evidence only.

## Ordered work

1. Add failing portable tests for the message library's valid publication, duplicate identity, conflicting duplicate, malformed schema, size bounds, and atomic-write behavior.
2. Add failing portable tests for root and explicitly nested parent metadata, plus missing, wrong-home, stale-generation, and ambiguous-parent refusals.
3. Implement `bin/cs-message-lib.sh` as the sole owner of the versioned flat key/value message schema, field bounds, atomic publication, message identity, and acknowledgement records.
4. Implement `bin/cs-report.sh` as the child-facing command that resolves only the recorded immediate parent, publishes before waking, and sends a bounded Herdr doorbell containing only the message ID.
5. Extend `bin/cs-spawn.sh` and `bin/cs-meta-lib.sh` to record the exact parent task, parent home, parent pane, endpoint generation, and child endpoint generation before brief delivery.
6. Update the owning script help and `docs/configuration.md` with pointers to the schema and exact mechanics.
7. Add a concise architecture decision document that records the Phase 0 pivot, preserved historical branches, green baseline, and explicitly deferred later phases.
8. Run targeted tests, ShellCheck, the complete portable suite, and the auxiliary CLI scenario against a temporary home with a fake Herdr command.
9. Re-read the final diff and record evidence and cleanup receipts before any issue progress is changed.

## Evidence gates

- The message test must fail before `bin/cs-message-lib.sh` exists and pass after implementation.
- The metadata test must fail before parent fields are emitted and pass after implementation.
- The CLI scenario must show one complete parent inbox record, one acknowledgement path, and no leftover temporary process or staging file.
- No issue checkbox is checked unless its exact test, command, or artifact has passed and been recorded.

## Deferred

Herdr event-to-parent routing, recursive inbox draining, bounded cold reconciliation, deletion of redundant polling, and the nested real-Herdr canary are separate increments.

They must not be marked complete from this slice's portable evidence.
