# ADR-001: Language and runtime for the consigliere-next daemon

## Status

Proposed.
Elixir/OTP is the working selection, but it remains provisional until Phase 0 spikes B and C pass (see Revisit trigger below).

## Context

The rewrite requires one daemon-authoritative control plane that supervises long-running external harness processes (Soldiers), tolerates its own coordinator crashing without killing those processes, and tolerates the whole daemon being killed while still guaranteeing the harness process group is terminated and verified dead.
This is fundamentally a supervision-tree problem: many independently-failing units, each needing an owner that can restart without taking the others down with it.

Two prior-art data points were investigated directly rather than assumed.

Symphony (github.com/openai/symphony, Elixir/OTP, ~26k stars) is a close analog: it drives autonomous coding runs against an issue tracker using Task.Supervisor and an Orchestrator GenServer.
It proves the mechanical fit is real: `Process.monitor/1` on a spawned Task, `{:DOWN, ...}` handling, an Erlang Port wrapping the coding-agent subprocess (Codex app-server) over JSON-RPC-over-stdio, and a poll-driven reconciliation loop against the external tracker (`orchestrator.ex`, `reconcile_running_issues/1`, `reconcile_blocked_issues/1`).
These are exactly the primitives this rewrite needs: process boundaries, monitors, dynamic dispatch, Ports for subprocess control.

But Symphony's actual instance is also the clearest available negative case for how *not* to wire those primitives.
Its `AgentRuntimeSupervisor` runs `Task.Supervisor` and `Orchestrator` under `:one_for_all` (`agent_runtime_supervisor.ex:14-33`).
Because of that restart strategy, an Orchestrator crash restarts the sibling `Task.Supervisor`, which kills every in-flight agent Task and the Codex Port riding on it.
In this rewrite's vocabulary, that is a coordinator crash taking down every running Attempt: precisely the failure invariant #4 ("MissionCoordinator failure never terminates the top-level runner") exists to rule out.
Symphony also keeps all Attempt-equivalent state (`running`, `blocked`, `retry_attempts`, session ids) in a single GenServer's `%State{}` (`orchestrator.ex:24-45`), with zero disk persistence anywhere in the codebase.
A killed BEAM node loses all of it; the only thing that survives is whatever the external tracker still reports, which the Orchestrator re-derives from scratch on the next boot.
That is not durability, it is external-system-shaped amnesia, and it is exactly the "in-memory Attempt state masquerading as durable" pattern this rewrite must not repeat (see ADR-002, ADR-004).

The alternative considered is a single Go daemon (absorbing what would otherwise be a separate external runner) plus Made, avoiding a second language and runtime in the stack entirely.
Go has no direct process-supervision-tree primitive equivalent to OTP; process monitoring, restart policy, and per-Attempt isolation would all have to be hand-built (goroutines, channels, explicit supervisor loops) rather than provided by the language runtime.
Symphony demonstrates that OTP's primitives are the right shape for this problem when the restart topology is designed correctly (per-Attempt DynamicSupervisor, not shared-fate `:one_for_all`); it does not demonstrate that Go could not also do the job, only that doing it in Go means reimplementing supervision-tree semantics by hand.

Two decisions specific to this attempt at the rewrite were made by the boss on 2026-08-18 and are recorded here as they affect the practical shape of this ADR, not the underlying supervision reasoning:

1. The rewrite happens in-place inside the existing `consigliere` repository, on a rewrite branch, with `daemon/` and `runner/` directories added starting in Phase 1/2 -- not in a separate `consigliere-next` repository as master-prompt section 4.1 literally specifies. This is a deliberate deviation from the master prompt's stated default, made explicitly by the boss given the state of the repo today (a single-repo fleet already exists and branch-based isolation was judged sufficient). It does not change any invariant in this ADR; it only changes where the code lives.
2. Earlier the same day, a different attempt at this same rewrite produced a branch `made-daemon-rewrite` (commit `7076209`) that scaffolded an Elixir application (`Csd.Application`, `Csd.Repo`, `Csd.DatabaseWriter`) and proved a serialized-SQLite-write spike (25 concurrent writers, no `SQLITE_BUSY`, plus a manual cross-process durability check). The boss explicitly chose to start over clean rather than resume that branch. It is left in place as a dangling, unmerged branch for historical reference only; nothing in this rewrite is built on it, and its existence should not be read as an endorsement or as work already credited toward this Phase 0 pass.

## Decision

Select Elixir/OTP as the daemon's implementation language and runtime, conditioned on Phase 0 spikes B (coordinator-independent runner) and C (daemon-bound runner) passing as specified in the master rewrite prompt, section 15.
Concretely: MissionCoordinator processes are OTP GenServers under a `MissionDynamicSupervisor` restarted `:one_for_one`, never `:one_for_all` with anything that owns a live runner; RunnerProcess is a top-level, independently supervised process (also `:one_for_one`) whose lifetime is decoupled from any MissionCoordinator, exactly the opposite restart topology from Symphony's `AgentRuntimeSupervisor`.
The recommendation is made on total-system-complexity grounds: OTP supervision trees are a load-bearing simplification for "many independently-failing long-running things, each needing isolated restart," and Symphony's negative case shows what happens when that isolation is wired wrong, not that the isolation itself is a bad idea.

## Consequences

- The daemon gets supervision-tree semantics (monitors, restart strategies, DynamicSupervisor-per-Attempt) as language/runtime primitives rather than hand-rolled goroutine/channel bookkeeping.
- The team takes on an additional language in the stack (Elixir alongside Made's Go and the external runner's Go), which must be justified by the spikes, not assumed.
- Symphony's `:one_for_all` mistake becomes a concrete negative test case: Phase 0 spike B must explicitly assert that killing a MissionCoordinator does not kill its RunnerProcess, the inverse of Symphony's actual behavior.
- Because Symphony's durability model is proven unsafe to copy, this ADR only borrows Symphony's process-supervision mechanics, not its persistence (or lack thereof); durability is entirely SQLite's responsibility (ADR-002, ADR-003).

## Alternatives considered

**Single Go daemon plus Made, no Elixir.** Rejected for now, not permanently: a Go implementation is architecturally viable and is the explicit fallback per the revisit trigger below. It was not selected as the default because it requires reimplementing supervision-tree semantics that OTP provides natively, and because Symphony's mechanical patterns (Ports, monitors, dynamic dispatch) already demonstrate the Elixir side of this problem is well-trodden, if not always well-wired.

**Copying Symphony's supervision topology as-is.** Rejected outright. Its `:one_for_all` AgentRuntimeSupervisor and in-memory-only `%State{}` are named failure modes this rewrite exists to eliminate (see ADR-002, ADR-004), not patterns to inherit under a new name.

**Umbrella Elixir application.** Rejected for V1 per master-prompt section 4.3; a single application is simpler and sufficient until concurrency or deployment requirements prove otherwise.

## Revisit trigger

Reopen this ADR and fall back to a single Go daemon plus Made if any of the following occurs during Phase 0:

- Spike B (MissionCoordinator crash must not terminate a live RunnerProcess) fails and cannot be made to pass with a correctly-wired DynamicSupervisor topology.
- Spike C (daemon `kill -9` must result in the external runner observing control-channel EOF, terminating the full process group, and verifying death) fails.
- SQLite-via-Ecto operational simplicity (Spike A) turns out to require nontrivial NIF-level workarounds or unstable driver behavior under WAL mode.
- LaunchAgent packaging and startup (Spike E) prove materially harder to make reliable in Elixir than the equivalent Go binary packaging.
- The architecture that emerges from Phase 2 requires a large native-process layer, interactive PTYs, or extensive cross-language glue such that a single Go implementation would be materially simpler end to end.

Any one of these is sufficient grounds to reopen; this is a provisional selection, not a settled one, until the spikes say otherwise.
