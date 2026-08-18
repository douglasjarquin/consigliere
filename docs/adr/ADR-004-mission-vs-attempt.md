# ADR-004: Mission versus Attempt, and daemon-bound execution

## Status

Proposed.

## Context

Legacy Consigliere and Made both currently blur the line between "the authorized work" and "one execution attempt at that work," and both show concrete damage from that blurring.

Legacy Consigliere's `cs-made-lib.sh` / `cs-made-run-lib.sh` describe a Made run parked at `awaiting_approval` or `fix_review` as holding a fleet slot indefinitely, until `cs-teardown.sh`'s explicit abort call concludes it.
That is: a single execution attempt (one Made pipeline run) is treated as if its lifetime were the lifetime of the work itself, so a stuck or abandoned review decision strands a resource (a fleet slot, a workspace, a Soldier) with no automatic recovery path, only a manual teardown-time abort.
The same document confirms `cs-made-lib.sh`'s own header notes that several of the CLI subcommands it calls (`made axi status`, `made axi abort`, `made gate init`) do not exist yet in Made's actual CLI (confirmed independently against Made's `cmd/made/main.go`, whose dispatch switch has only `daemon start|stop|status`, `status`, `review`, `pr`, `doctor`); the integration contract was written ahead of Made implementing it, which is a second, related failure of the same root cause: treating an assumed future capability as though it were already a durable fact about how the work would proceed.

Symphony shows the structural half of this same problem from the coordinator side. `AgentRuntimeSupervisor` runs `Task.Supervisor` and `Orchestrator` under `:one_for_all` (`agent_runtime_supervisor.ex:14-33`); an Orchestrator (coordinator) crash restarts the sibling `Task.Supervisor`, which kills every in-flight agent Task and the Codex Port riding on it.
In this rewrite's vocabulary, a crash in the thing that tracks "is this Mission's work still authorized and making progress" currently takes down the thing that is "one execution attempt in progress" -- exactly backwards from what section 4.5 and section 7 require.

## Decision

Model the work itself as a Mission (durable, survives everything) and each execution against it as an Attempt (disposable, may be lost without the Mission being lost), per master-prompt section 4.5, with these concrete rules:

- A MissionCoordinator process rehydrates a Mission from projections, evaluates runnability, and monitors the active RunnerProcess, but owns no authoritative Question, Gate, Authorization, or Workspace state itself, and may restart without killing the RunnerProcess it was monitoring (the direct inverse of Symphony's `:one_for_all` coupling).
- A RunnerProcess is top-level and independent of any MissionCoordinator's lifetime; it owns the daemon side of the runner control channel, persists process identity through the runtime manifest protocol, and never interprets Mission policy.
- An Attempt is daemon-lifetime-bound: if the daemon is lost, the runner terminates the harness process group rather than adopting a still-running harness, and reconciliation on daemon restart classifies the Attempt as lost, checkpointed, or quarantined -- never left in an ambiguous "might still be running" state.
- A Mission's authorization, phase, and checkpoint history persist independent of any particular Attempt's fate; a lost, failed, or superseded Attempt triggers a new Attempt against the same Mission from the last imported checkpoint SHA, not a strand.

## Consequences

- The legacy failure mode ("a parked Made run holds a fleet slot until manual teardown") becomes structurally impossible: an Attempt that cannot make progress (blocked on a decision, crashed, lost) is bounded by the Attempt lifecycle, and the Mission it belongs to remains recoverable regardless of what happens to that Attempt.
- MissionCoordinator crashes (bugs, code deploys, supervisor restarts) no longer risk killing in-flight harness work, closing Symphony's `:one_for_all` gap directly; this is the property Phase 0 Spike B exists to prove.
- Because Attempts are explicitly disposable, "this Attempt is gone" is an ordinary, expected event with a defined recovery path (start a new Attempt from the last checkpoint), rather than an incident requiring manual intervention.
- This does add real complexity: two supervised process types (MissionCoordinator, RunnerProcess) instead of one, and a reconciliation protocol between them. That complexity is accepted because the alternative (one coupled process type, as in both the legacy system and Symphony) is the exact source of the stranding and cascading-crash failures found in grounding.

## Alternatives considered

**A single coordinator process that both tracks Mission state and directly owns the harness process** (Symphony's actual shape, and roughly legacy Consigliere's shape once cs-made-run-lib's parked-run handling is accounted for). Rejected directly on the evidence above: this is what produces both the stranded-run failure (no automatic Attempt-level recovery) and the cascading-crash failure (coordinator restart takes the harness down with it).

**Treating a Made run's lifetime as authoritative for Mission progress** (i.e., not distinguishing Mission from Attempt at all, and letting Made's own run state stand in for Mission state). Rejected: Made's `RunManager` is itself unpersisted in-memory state (see ADR-002), so anchoring Mission progress to it would mean Mission progress is also unpersisted, which directly contradicts the requirement that a Mission survive daemon restart.

## Revisit trigger

Reopen this ADR if Phase 0 Spike B (kill MissionCoordinator, confirm RunnerProcess and harness continue, confirm a restarted coordinator rehydrates and re-monitors without terminating anything) cannot be made to pass under the proposed supervision topology, or if the reconciliation protocol between MissionCoordinator and RunnerProcess proves too complex to implement reliably relative to the risk it is meant to eliminate.
