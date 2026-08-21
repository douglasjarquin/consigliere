# Runtime topology

This document formalizes the consigliere-next application supervision tree.
The tree is intentionally flat for V1.
It is not an umbrella application, and it does not create a separate GenServer for every noun in the domain model.
Every component below exists because a concurrency or lifetime boundary requires it, not because the domain model has a matching entity.

## Top-level shape

```text
Consigliere.ApplicationSupervisor              :one_for_one
├─ Consigliere.Repo
├─ Consigliere.DatabaseWriter
├─ Consigliere.EventBus
├─ Consigliere.OutboxDispatcher
├─ Consigliere.RunnerDynamicSupervisor
│  └─ RunnerProcess(attempt_id)
│     └─ Port → cs-runner → harness process group
├─ Consigliere.MissionDynamicSupervisor
│  └─ MissionCoordinator(mission_id)
├─ Consigliere.GlobalScheduler
├─ Consigliere.Reconciler
├─ Consigliere.NotificationDispatcher
└─ Consigliere.ApiSupervisor
```

The top supervisor's strategy is `:one_for_one`.
Every child below it is restarted independently on crash.
This single choice is the mechanical fix for the most important failure mode found in the Symphony reference codebase during Phase 0 grounding: Symphony's `AgentRuntimeSupervisor` (`elixir/lib/symphony_elixir/agent_runtime_supervisor.ex:14-33`) supervises its `Task.Supervisor` and its `Orchestrator` GenServer under `:one_for_all`.
Because of that strategy, any crash in Symphony's Orchestrator (a coordination-layer process) restarts the sibling `Task.Supervisor`, and restarting a `Task.Supervisor` kills every `Task` running under it, including every in-flight Codex agent run and its open Port (`orchestrator.ex:954-958`).
In Symphony, a coordinator bug takes down all currently running agent work as a side effect of its own supervision tree shape, not as a deliberate design decision.
Consigliere-next's `:one_for_one` top-level tree, plus the deliberate separation of `RunnerDynamicSupervisor` from `MissionDynamicSupervisor` described below, exists specifically so that a MissionCoordinator crash cannot reach a RunnerProcess through the supervision tree at all.
This is invariant 4 in the failure corpus and the master architecture: MissionCoordinator failure never terminates the top-level runner.

## Component-by-component

### Consigliere.Repo

Ecto's own supervised connection pool for the SQLite database.
Holds no domain state of its own beyond open connection handles.
On crash and restart, Ecto reconnects; no data is lost because SQLite itself is the durable store, not the Repo process.

### Consigliere.DatabaseWriter

The single serialized write path required by the SQLite operational rules (see `database.md`).
It is a GenServer whose mailbox is the only path by which any other process performs a write transaction against the database.
It holds no long-lived domain state in memory; every call is a short `Repo.transaction/1` that reads what it needs, mutates, and returns.
On crash, any in-flight caller receives an error and retries; because every write is one short transaction, a crash mid-write leaves the database in the state of the last committed transaction, never a partially applied one.
This is the concrete implementation of the master architecture's "one serialized write path" and "no long-lived read/write transaction" rules.

### Consigliere.EventBus

Publishes domain events after they are committed by the DatabaseWriter, for the benefit of in-process consumers (for example, a MissionCoordinator that wants to react promptly to a change instead of waiting for its own poll interval).
The EventBus is a convenience for internal reactivity, not a durability mechanism.
Domain events are already durable because they were written to the `domain_event` table by the DatabaseWriter before the EventBus republishes them in memory.
If the EventBus process crashes, no event is lost, because the event already exists as a row; a restarted EventBus (or a MissionCoordinator that missed a beat) recovers by polling the event table by id, per the "event tailing polls by event ID" rule.

### Consigliere.OutboxDispatcher

Drains the `outbox_item` table and performs external side effects (GitHub calls, notification delivery, and so on) with per-destination reconciliation.
Holds only short-lived in-memory state describing what it is currently attempting; the outbox row itself is authoritative for what has been attempted, how many times, and what the last error was.
A crash mid-dispatch leaves the outbox row in whatever status it last had committed (queued or leased with a `leased_until`), and a restarted dispatcher resumes by scanning for due items, never by trusting anything held only in the dead process's memory.

### Consigliere.RunnerDynamicSupervisor and RunnerProcess

A `DynamicSupervisor` whose children are one `RunnerProcess` per active Attempt.
Each `RunnerProcess` owns the daemon side of the control channel to one `cs-runner` external process, which in turn owns one harness process group.
A `RunnerProcess` is deliberately not a child of a `MissionCoordinator`.
It lives directly under `RunnerDynamicSupervisor`, at the same level as `MissionDynamicSupervisor`, so that killing or restarting a `MissionCoordinator` (which lives in the sibling tree) cannot touch it.
Per the master architecture's Attempt section, a `RunnerProcess`:
- is top-level, independent of any `MissionCoordinator`'s lifetime,
- owns the daemon side of the runner control channel,
- receives framed runner events and persists process identity through the runtime manifest protocol (see `protocols/runner.md`),
- requests cancellation and reports exit,
- never interprets Mission policy (retry counts, repair budgets, phase transitions are not its concern).

If the daemon itself dies, the external `cs-runner` process (not the `RunnerProcess` GenServer, which dies with the BEAM) detects control-channel EOF and independently terminates its harness process group. This is covered in full in `protocols/runner.md`; it is called out here because it is the reason `RunnerProcess` can be a thin, restartable-on-daemon-boot GenServer rather than something that must itself survive a BEAM crash.

### Consigliere.MissionDynamicSupervisor and MissionCoordinator

A `DynamicSupervisor` whose children are one `MissionCoordinator` per Mission that is currently active enough to need in-memory coordination (typically: has an open Attempt, or is waiting on something that benefits from prompt reaction rather than polling).
A `MissionCoordinator`:
- rehydrates one Mission's state from projections (the `mission`, `mission_blocker`, `gate`, `authorization`, and `workspace` tables) on start; it does not reconstruct anything from the event log,
- evaluates whether the Mission is runnable given its phase, open blockers, and authorization,
- submits scheduling requests to `GlobalScheduler`,
- monitors (via `Process.monitor/1`) the `RunnerProcess` of its Mission's active Attempt, purely to react promptly to its exit, not to own it,
- reacts to durable state changes (new Decision answered, new Gate result, workspace released) by re-evaluating runnability,
- holds no authoritative Question, Gate, Authorization, or Workspace state in its own process memory; every one of those is a database row, and the `MissionCoordinator`'s in-memory copy (if any, for a hot path) is a cache that can be thrown away and rebuilt at any time,
- may crash and restart at any point without affecting a running Attempt, because it does not own the `RunnerProcess` and does not hold any state that isn't already durable.

The clean separation between "what MissionCoordinator holds in memory" (a rehydratable, disposable view) and "what is authoritative" (the database) is what makes MissionCoordinator restarts free of the coupling problem documented above for Symphony.

### Consigliere.GlobalScheduler

Enforces global concurrency limits (starting at a global concurrency of 1 for the Phase 1 durable kernel, expanding to per-project lanes only after Phase 8 cutover per the master architecture's staged rollout).
Holds in-memory bookkeeping of currently granted slots, which is intentionally a cache: on restart, it can rebuild its view of "what's currently running" by querying the `attempt` table for rows in `running`/`starting`/`checkpoint_requested` status.

### Consigliere.Reconciler

Runs at daemon boot and periodically thereafter.
Its job is to resolve ambiguity that can only be created by the daemon itself having been gone: attempts marked as active in the database that have no live `RunnerProcess`, workspaces whose previous process death is unconfirmed, outbox items whose external side effect may or may not have completed while the daemon was down.
It is intentionally not a supervisor of anything; it is a batch-style reconciliation pass over projections, matching the master architecture's "process-inventory evidence is required for loss classification" invariant.

### Consigliere.NotificationDispatcher

A best-effort delivery path layered on the outbox (added in Phase 4).
Its failures are visible as retriable outbox rows, never as a lost Question; the Question and its blocker already exist as durable rows before any notification is even attempted, so `NotificationDispatcher` crashing or a downstream notification provider being unreachable cannot cause the boss to lose the ability to eventually see the Question through `cs inbox` / `cs return`.

### Consigliere.ApiSupervisor

Owns the Unix socket listener and per-connection worker processes for the CLI/API protocol.
Holds no domain state; every command it receives is validated (protocol version, capability, fencing token, idempotency key) and handed to the DatabaseWriter or another owning component. A crashed connection worker affects only that one client connection.

## Why no separate coordinators for Question, Gate, Workspace, Project, or Lane

The master architecture explicitly forbids creating separate GenServers for `QuestionCoordinator`, `GateCoordinator`, `WorkspaceCustodian`, `ProjectMemory`, and `LaneManager` in V1.
The reasoning, made concrete here: none of these currently have a concurrency requirement that a plain function operating inside a `DatabaseWriter` transaction cannot satisfy.

- Opening a Question is: validate the Attempt's capability and fencing token, validate the Mission relationship, deduplicate by `request_id`, insert the Question row and its blocker row, append an audit event, all inside one short transaction. There is no reason this needs a dedicated process holding state between calls; the "state" is the row.
- Gate lifecycle is driven by Made's exit-and-rerun managed-mode contract (see `protocols/made-managed-mode.md`): each Made invocation is a short-lived external process, and the Gate row it produces is written by the same transactional pattern as everything else. There is no live Gate process to coordinate.
- Workspace custody is a set of invariants enforced at specific transition points (checkpoint import, reuse, quarantine); see `workspaces-and-git.md`. These are called from the RunnerProcess/MissionCoordinator/Reconciler as needed, not owned by a dedicated process.
- Project policy and any future distilled "Capo memory" are explicitly out of scope for V1 (post-cutover, per the master architecture's phase 24.1); when that work starts, if a genuine concurrency reason emerges (for example, a long-running advisory reasoning session that must serialize against itself per project), a process boundary can be introduced then. Introducing it now would be exactly the kind of speculative abstraction the master architecture forbids.
- Multiple concurrent lanes per project are explicitly deferred until Phase 8 shows real workload evidence; a `LaneManager` process today would be scheduling against a concurrency model (multiple simultaneous Missions per Project) that V1 does not have.

The unifying rule: a GenServer is justified by a concurrency or lifetime boundary (something must run independently, monitor something independently, or hold state across calls that cannot simply be a database row).
Everything in this section is instead a transactional module: plain functions, called from whichever process needs them, that read and write projections inside `DatabaseWriter` transactions.
If a future phase discovers a genuine concurrency need (for example, Question routing logic that must debounce across many events, or Gate scheduling that must coordinate multiple in-flight Made invocations against a single Mission's repair budget under real contention), that is the trigger to introduce a process, evidenced by measured contention, not by symmetry with the domain model.

## Open questions flagged during drafting

- Whether `GlobalScheduler` should itself be a `DynamicSupervisor`-adjacent process versus a plain GenServer is not fully resolved; a plain GenServer is assumed here since Phase 1 only needs a global concurrency of 1, but this should be revisited once per-project lanes exist.
- The exact mechanism by which `MissionCoordinator` "reacts to durable state changes" (EventBus subscription versus periodic re-evaluation versus both) is left underspecified pending the Phase 1 spike; this document assumes EventBus-driven reactivity with a periodic fallback poll, but that fallback interval is not yet chosen.
