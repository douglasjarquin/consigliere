# ADR-002: SQLite operational model

## Status

Proposed.

## Context

The rewrite requires that a Mission survive the loss of any Attempt, any coordinator, and the daemon itself, which means the daemon needs a real embedded database, not an in-memory structure that happens to get checkpointed occasionally.

Two concrete negative cases were found during grounding, and both point at the same underlying mistake: treating process memory as if it were durable storage.

Made's `RunManager` (`internal/daemon/runmanager.go:44-77`) is a `map[string]*run` guarded by a `sync.Mutex`, entirely in memory.
A grep across the whole Made repository for `sqlite|database/sql|bbolt|persist` turns up no real persistence layer at all.
`ReviewDecisions`' `entries`/`.waiters` maps (`internal/daemon/reviewdecisions.go:22-26`) are the same shape.
The consequence, confirmed directly: any Made daemon restart loses every run, every pending finding, and every parked decision, unconditionally, with no spool and no replay path (`grep -rln "spool"` across the repo returns nothing).

Symphony's `Orchestrator` GenServer keeps `running`, `blocked`, `retry_attempts`, and session state in a single in-memory `%State{}` (`orchestrator.ex:24-45`), with the same consequence: a node kill loses all of it, and the only thing that "survives" is whatever the external issue tracker still reports, which is re-derived from a cold start, not restored from a durable local record.

Both systems independently demonstrate the same failure: an in-memory map is not a substitute for a database, no matter how good the polling-based reconciliation logic layered on top of it is.
The rewrite's Attempt/Mission/Question/Gate rows must not repeat this pattern.

## Decision

Use SQLite in WAL mode as the daemon's durable store, accessed through Ecto (per ADR-001's Elixir selection), with the following non-negotiable operational rules:

- One serialized write path. All mutations go through a single writer process (the `Csd.DatabaseWriter` equivalent), never concurrent uncoordinated writers.
- Short transactions only. No external process, Git, network, model, or filesystem operation may run inside a database transaction.
- `busy_timeout` set explicitly, and foreign keys enabled.
- Projections (current-state rows: Mission, Attempt, Question, Gate, etc.) are operational truth. Domain events are audit history only; there is no event-sourcing replay subsystem that rehydrates state from events.
- No long-lived read transactions; event tailing polls by event ID rather than holding a cursor transaction open.
- An explicit WAL checkpoint policy, not an implicit "it happens eventually."
- Backup exclusively through SQLite's backup API or `VACUUM INTO`; never copy the live database file while ignoring its WAL file, since a naive file copy of `.db` without `.db-wal` can silently produce a torn, inconsistent backup.

## Consequences

- Every Mission, Attempt, Question, and Gate row is durable the instant its write transaction commits, independent of any Elixir process's continued existence, closing the exact gap that both Made's in-memory `RunManager` and Symphony's `%State{}` leave open.
- The single serialized writer becomes a real (if narrow) throughput bottleneck; this is accepted deliberately, since the alternative (concurrent writers racing on SQLite) is what produces the `SQLITE_BUSY` failures the Phase 0 spike is specifically designed to rule out.
- Because events are audit-only, a bug that corrupts event history does not corrupt operational state, and a bug that corrupts a projection cannot be silently masked by "replaying from events" as if that were a recovery mechanism; this forces read-repair problems to be fixed at the projection layer directly.
- No party outside the database (the model, a Capo, a Soldier, Herdr, Made, a tracker) can be authoritative for state that lives in these tables, which is the load-bearing precondition for ADR-003.

## Alternatives considered

**In-memory state with periodic snapshotting**, as both Made and Symphony currently do (a full snapshot dump or reliance on external-system re-derivation). Rejected directly on the evidence above: both produce total state loss on restart, which is the exact failure this rewrite must eliminate for Missions and Questions.

**A client-server database (Postgres, MySQL)** was not seriously pursued for V1: the master prompt's product shape is a single-daemon, single-user-facing control plane with no requirement for a separately-operated database server, and SQLite in WAL mode is materially simpler to package and back up for that shape. This could be revisited if multi-daemon or multi-host operation becomes a real requirement, but that is explicitly out of scope until well past cutover.

**Event sourcing as the primary rehydration mechanism** (rebuild projections by replaying the event log). Rejected per master-prompt section 4.4 directly: it adds a whole replay subsystem's worth of complexity and failure modes (replay correctness, event schema evolution, replay performance at scale) in exchange for a property (full historical reconstruction) that this system does not need, since projections already are the operational truth and events exist purely for audit.

## Revisit trigger

Reopen this ADR if Phase 0 Spike A (SQLite serialized writes, concurrent reads, `busy_timeout`, WAL checkpoint, crash recovery, poison-row quarantine, `VACUUM INTO` backup/restore) fails to prove any of those properties under WAL mode with Ecto, or if real operational load reveals the single-writer path is a throughput bottleneck that cannot be addressed by batching or backpressure within the serialized-writer model.
