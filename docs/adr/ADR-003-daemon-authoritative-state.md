# ADR-003: Daemon-authoritative state

## Status

Proposed.

## Context

Legacy Consigliere's supervision model is built from shell watchers, append-only status files, PID/lock files, and marker files, coordinated by a persistent monitor process (`cs-monitor.sh`) plus a bash watcher (`cs-watch.sh`) that classifies wakes and writes to a durable `state/.wake-queue` before advancing detector state.
`docs/architecture.md` (legacy, at commit `81612c3`) contains a documented, named defect at line 34: "Crew status files are append-only wake-event logs, not current-state fields... can bury an earlier still-open needs-decision/blocked under later unrelated appends."
The fix applied was a separate cursor-folded "OPEN DECISIONS" re-derivation pass layered on top, not a change to the underlying primitive; the append-only log itself remained the source of record, with a patch computing "current state" from it after the fact.

Firstmate, Consigliere's direct architectural predecessor, shows the same primitive at greater scale and with a longer failure history: `state/` holds dozens of loose per-task sidecar marker files (`.hash-default_wH_p*`, `.seen-*_turn-ended`, `.stale-default_w*`, `.count-*`, `.hb-surfaced-*`, `.subsuper-seen-*`), each a hand-rolled dedup/debounce mechanism with no schema and no transactionality.
Of Firstmate's most recent ~300 commits, at least 45 are `fix(...)` commits directly about liveness, wedge, race, staleness, or orphan-class bugs; the `watch`/`wake`/`status` category alone accounts for roughly 15,000 of the ~52,500 total lines across its ten largest scripts.
This is not "the old code was messy"; it is a sustained, multi-hundred-commit stream of the same failure class -- shell-process-liveness-as-correctness -- that a database-authoritative model is intended to make structurally impossible rather than incrementally better-patched.

Legacy Consigliere's own incident record confirms the same class of failure recurring even after the append-only-log defect was documented and patched.
A 2026-08-01 incident recorded 8 hours 11 minutes of unwatched fleet time, root-caused to "a flag deferred to a dead owner" -- an away-mode daemon that was supposed to supervise but had itself been silently retired.
A separate incident recorded 213 monitor revivals in 7 hours, and all five recorded away-mode daemon-arm attempts on 2026-08-01 died within one second of arming; both were traced to launching a long-lived process via `nohup ... & disown` from inside a bounded agent tool call, where `nohup` does not survive that call's process-group teardown.
None of these are bugs in the classification logic; they are consequences of making a shell process, rather than a database row, the thing that is authoritative for "is this being supervised right now."

## Decision

The daemon and its SQLite database (ADR-002) are the only authoritative source of state for Mission, Attempt, Question, Gate, Authorization, and Workspace status.
No other component may be authoritative for any of it, specifically:

- A root Consigliere model conversation, a Capo conversation, or a Soldier process: advisory or execution only, never authoritative (see ADR-005 for the authority-channel split this requires).
- A terminal pane, Herdr, or any process-liveness signal derived from watching a shell: diagnostic only.
- Made's in-memory run state, a GitHub pull request, Linear, or any other external tracker: an integration to reconcile against, never the source of truth for internal state.
- Shell status prose, JSON status files, or marker files of any kind: diagnostic hints, explicitly not authority, per master-prompt section 9.5.

Concretely, this means: a Mission's phase, an Attempt's status, a Question's answer state, and a Gate's outcome are each a row (or set of rows) in the database, mutated only through the serialized writer (ADR-002), and nothing else in the system is permitted to compute or claim a competing notion of "current state" for any of them.

## Consequences

- "Is this Mission blocked, and why" becomes a deterministic query (`cs why`) over projections, not a re-derivation pass over an append-only log, closing the exact gap legacy Consigliere's own architecture.md names as a defect.
- Restarting any component (coordinator, daemon, monitor-equivalent) cannot lose or corrupt state, because no component other than the database ever held authoritative state to lose.
- External integrations (Herdr, Made, Linear, GitHub) can fail, lag, or disagree with the daemon's projections without that failure ever becoming ambiguous about what the daemon itself believes; reconciliation logic exists precisely to detect and correct such disagreement (see the Outbox and Reconciler components in the runtime architecture doc), not to treat the external system as truth.
- This forecloses an entire category of legacy failure (dead-owner handoffs, nohup/disown detachment races, append-only-log misreads) at the architecture level, rather than requiring each instance to be separately caught and patched, which is what happened repeatedly in both Firstmate and legacy Consigliere.

## Alternatives considered

**Shell-watcher-plus-marker-file model, ported to a new language.** Rejected directly: this is precisely the pattern the master prompt (section 3) warns against recreating "under new names" (wake queues as database rows, status prose as JSON, bash watchers as GenServers). The problem was never the implementation language; it was treating process liveness and append-only text as if they were state.

**Event-log-as-current-state, with a cursor-folding read pattern** (i.e., keep doing what legacy Consigliere's "OPEN DECISIONS" patch does, just make the log a database table). Rejected: this still requires re-deriving current state from history on every read, and still risks the same "later append buries an earlier open item" class of bug if the fold logic has an edge case. A dedicated current-state projection, updated transactionally at write time, removes the need for any fold at read time.

**Making Herdr or an external tracker authoritative for liveness or supervision state** (mirroring Symphony's tracker-re-derivation model). Rejected per master-prompt section 4.9 and 4.7: Herdr provides visibility only, and trackers own only their own external records; neither may determine whether an Attempt exists, is alive, or can recover.

## Revisit trigger

Reopen this ADR if a real operational need emerges for state that must survive even total loss of the SQLite database (e.g., a requirement for multi-daemon replication or geographic failover), which would require introducing a genuinely different durability model rather than a single authoritative embedded database.
Absent such a requirement, this decision should not be revisited merely because a particular projection is inconvenient to query; that is a schema problem, not a reason to introduce a second source of truth.
