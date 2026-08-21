# Attempt state machine

## Purpose

An Attempt is one disposable execution against a Mission: a Soldier, a scout, a reviewer, a repairer, or a validator.
An Attempt may be lost, killed, superseded, or simply fail; the Mission it serves must remain recoverable regardless.
The Attempt state machine's entire job is to make that disposability safe: it must be impossible for a dead or fenced Attempt to keep mutating Mission or workspace state, and it must be impossible for the daemon to lose track of whether an Attempt's process group is actually dead.

An Attempt is daemon-lifetime-bound, not harness-lifetime-bound.
When the daemon loses control of the runner that hosts an Attempt, the Attempt does not get "adopted" back; it is either confirmed dead or explicitly quarantined, never left ambiguous.

## States

- `planned` - the Attempt row exists (mission_id, role, harness, workspace assignment decided) but no runner process has been spawned yet.
- `starting` - a RunnerProcess has been asked to spawn the harness; the daemon is waiting for the runner to report back PID, harness PID, pgid, and a fencing token.
- `running` - the runner has confirmed the harness process group is alive and the daemon is receiving framed events from it (or is within the silence-tolerance window described in the Failure-mode traceability section).
- `checkpoint_requested` - the daemon has asked the Attempt (via its capability channel) to commit its current work and report a SHA, because a blocking Question, a validation gate, cancellation, or Mission supersession requires the Attempt to stop.
- `checkpointed` - the Attempt reported a commit SHA, the runner has verified the harness process group is dead, and the daemon has begun (or completed) importing that SHA into the trusted mirror.
- `completed` - the Attempt finished its assigned unit of work normally, its final checkpoint (if any) was imported, and the runner confirmed process-group death.
- `failed` - the Attempt's harness process exited with a failure classification (non-zero exit, malformed final event, artifact hash mismatch) and process-group death is confirmed.
- `lost` - the daemon lost control of the runner (daemon restart, runner crash, control-channel EOF with no clean confirmation) and process-inventory evidence is required before this classification is allowed; output silence alone is never sufficient.
- `canceled` - the Attempt was explicitly canceled (Mission canceled, boss-issued interrupt) and process-group death is confirmed.
- `superseded` - a new Attempt has been started against the same Mission in this Attempt's place (retry, repair round, or continuation after a Question answer); the old Attempt's fencing token is invalidated as of this transition.

## Transition table

| From | To | Trigger | Guard | Side effects |
|---|---|---|---|---|
| (none) | `planned` | MissionCoordinator decides to schedule work | GlobalScheduler grants a slot; workspace ready or creatable | Attempt row inserted; fencing token minted |
| `planned` | `starting` | daemon asks RunnerDynamicSupervisor to spawn a RunnerProcess | none beyond `planned` | `attempt.spawn_requested` event |
| `starting` | `running` | runner reports PID/harness PID/pgid/fencing token, first normalized event received | fencing token matches what the daemon minted | runner identity fields persisted on Attempt row; `attempt.started` event; `started_at` set |
| `starting` | `failed` | runner reports spawn failure | none | `attempt.failed` event; `exit_classification = spawn_failed` |
| `running` | `running` | normalized events arrive (progress, artifact, usage) | fencing token on each event matches current Attempt's token | `last_event_at` updated; events appended to audit log; Question/Gate side effects per their own state machines |
| `running` | `checkpoint_requested` | blocking Question opened, Gate needs a fresh SHA, cancellation issued, or Mission superseded | Attempt is still `running` (not already terminal) | capability-scoped checkpoint request sent over control channel; `attempt.checkpoint_requested` event |
| `checkpoint_requested` | `checkpointed` | Attempt reports commit SHA via its capability, runner confirms process-group death, daemon imports the SHA | reported SHA's ancestry verified against workspace base; import succeeds | `current_checkpoint_sha` updated on Mission; workspace marked daemon-exclusive; `attempt.checkpointed` event |
| `checkpoint_requested` | `lost` | no checkpoint report arrives within the bounded interval and the runner cannot confirm death | process-inventory check (not silence alone) run before this transition is allowed | Incident opened if workspace death cannot be confirmed; `attempt.lost` event |
| `running` | `completed` | Attempt reports final completion, runner confirms process-group death | final artifact hashes match context pack expectations | `attempt.completed` event; `finished_at` set |
| `running` | `failed` | harness process exits non-zero, or emits a malformed terminal event | runner confirms process-group death before this is finalized | `attempt.failed` event; `exit_classification` recorded |
| `running`/`checkpoint_requested` | `lost` | daemon restarts, or control-channel EOF occurs without a clean runner-confirmed shutdown | reconciler requires positive process-inventory evidence (a live process-group scan, not absence of output) before finalizing this as `lost` rather than leaving it `starting`/`running` pending reconciliation | workspace quarantined unless death independently confirmed; `attempt.lost` event; Mission blocker of kind `incident` if workspace cannot be verified safe |
| `running` | `canceled` | boss-issued interrupt, or Mission canceled | control-plane `cancel` verb succeeds and runner confirms process-group death | `attempt.canceled` event |
| any non-terminal | `superseded` | MissionCoordinator starts a new Attempt to replace this one (retry, repair round, post-Decision continuation) | replacement Attempt's row references this Attempt as `retry_of_attempt_id` | fencing token invalidated; any events or capability calls still arriving from this Attempt after this point are rejected by fencing check; `attempt.superseded` event |

## Terminal states

`completed`, `failed`, `canceled`, `lost`, and `superseded` are all terminal for the Attempt row itself: none of them ever transitions again.
This is deliberate asymmetry with Gate and Mission: an Attempt is disposable by design, so once it stops, it stops for good, and any continuation is a brand new Attempt row with `retry_of_attempt_id` pointing back at it.
"Terminal" for an Attempt never means "safe to ignore" - `lost` and `failed` Attempts still require workspace quarantine/verification and Mission-level ledger bookkeeping before the Mission itself can proceed.

## Invariants enforced by this state machine

- **Invariant 4** (MissionCoordinator failure never terminates the top-level runner): this state machine's transitions are driven by RunnerProcess and the Attempt's own capability calls, not by MissionCoordinator identity; a MissionCoordinator crash and restart re-reads the Attempt row and re-subscribes to the same RunnerProcess without causing any transition here.
- **Invariant 5** (loss of runner control terminates and verifies the harness process group): the `-> lost` transitions explicitly gate on process-inventory evidence, and the runner's own responsibility (see `docs/protocols/runner.md`) is to have already terminated the process group by the time this transition is recorded.
- **Invariant 6** (a workspace is reused only after previous process-group death is confirmed): every terminal transition above that releases a workspace does so only after runner-confirmed death; `checkpoint_requested -> lost` explicitly does not release the workspace for reuse, it quarantines it.
- **Invariant 7/8** (every resumable checkpoint is an imported committed SHA; uncommitted files are not durable): `checkpoint_requested -> checkpointed` is the only path that advances `current_checkpoint_sha`, and it requires the import step, not merely a reported SHA string.
- **Invariant 10** (a stale fencing token cannot create authoritative state): every event and capability call in the `running` self-loop, and the terminal transitions, check the fencing token; `superseded` exists precisely to invalidate that token deterministically at one point in time.
- **Invariant 11/12** (output silence alone never marks an Attempt lost; process-inventory evidence is required): stated explicitly as a guard on both `-> lost` transitions above, not left implicit.
- **Invariant 28** (sleep and wake do not cause false Attempt loss): the "bounded interval" and "silence-tolerance window" referenced in the `running` state description must be defined generously enough, and re-anchored on wall-clock evidence from the runner (not the daemon's own possibly-suspended timers), that a macOS sleep/wake cycle does not silently accumulate as apparent silence; this is a runner-protocol concern (see `docs/protocols/runner.md`) that this state machine depends on but does not itself implement.

## Failure-mode traceability

- Firstmate's and Consigliere's shell-based "busy/idle/unknown/dead" classification (`fm-busy-lib.sh`, `cs-classify-lib.sh`, 798 lines) exists because pane/process liveness was the only signal available and was known to be an imperfect proxy for task liveness ("unknown never promoted to busy" as a defensive patch).
This state machine replaces that entire classification layer with a single authoritative source: the runner's own process-group inventory, reported through a typed protocol, persisted as one Attempt row.
There is no "unknown" state here because the runner is required to answer definitively (see `docs/protocols/runner.md` reconciliation requirements) rather than leaving the daemon to infer liveness from output patterns.
- The Made grounding fork confirmed `ReviewDecisions.Wait` blocks a live goroutine on a human decision with zero persistence.
The `running -> checkpoint_requested -> checkpointed` sequence is the direct structural fix: an Attempt waiting on a human decision is never left running, it is checkpointed and terminated, and the Mission blocker (not a blocked process) carries the wait.
- Legacy Consigliere's incident of "213 monitor revivals in 7 hours" and "the away-mode daemon died within a second of arming on all five recorded away sessions," both traced to `nohup ... & disown` not surviving a bounded tool call's process-group teardown, is direct evidence for why this state machine requires the RunnerProcess to be a genuinely independent top-level process (per §7/§8 of the master architecture), not a subprocess whose lifetime is coupled to whatever spawned it; `starting -> running` explicitly requires the runner to report identity fields that only a properly detached, session-leading process can reliably produce.
- Symphony's Task-based dispatch (`Task.Supervisor.start_child`, no per-run DynamicSupervisor, retry state held only in an in-memory map) is why `retry_of_attempt_id` and the fencing token are persisted fields on the Attempt row rather than in-memory correlation: a Symphony-style node kill loses which retries had already happened, while this design can always answer "was this Attempt superseded, by what, and when" from the row itself.

## Open questions carried forward (not resolved here)

- Whether `failed` should carry a sub-classification distinguishing "harness bug" from "policy violation" (e.g. artifact hash mismatch) for repair-routing purposes, or whether `exit_classification` as a free-form field is sufficient for Phase 1-3 and can be refined later.

## Decision (2026-08-19): default numeric bounds for the silence-tolerance and checkpoint-timeout windows

- **`running` silence-tolerance window: 15 minutes.** Coding-agent harnesses routinely go quiet for several minutes mid-turn (a single large reasoning/tool-use burst can emit no framed event at all); 15 minutes is generous enough to absorb that pattern without misreading it as death, while still being short enough that a genuinely wedged runner is caught in a reasonable time.
- **`checkpoint_requested -> lost` bounded interval: 5 minutes.** This window can be much tighter than the general silence tolerance, because a checkpoint request is the daemon proactively asking an Attempt it has *already confirmed is running* to wrap up and report a SHA -- it is not waiting on open-ended harness "thinking," just a bounded commit-and-report. 5 minutes is generous enough to cover a large working tree's commit/artifact-hash work without being so long that reconciliation stalls on a checkpoint that was never going to arrive.
- Both windows are **wall-clock intervals re-anchored on the runner's own timestamps** (the runner's last-observed-alive evidence, not the daemon's own possibly-suspended interval timers), per Invariant 28 above -- a macOS sleep/wake cycle must not silently accumulate as apparent silence in either window.
- These are Phase 1 schema defaults, not immutable constants: per the original open-question note, they remain revisable per-harness in Phase 3's harness conformance suite once real harness behavior under load is observed.
