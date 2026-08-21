# Runner protocol

This document specifies the external process runner for consigliere-next.
The runner ships as `runner/cs-runner`, added to this repository (in-place, not a separate `consigliere-next` repo) once Phase 2 begins.
The daemon itself is an Elixir/OTP application under `daemon/`, added in Phase 1, on the same rewrite branch.
Elixir remains provisional per ADR-001 until the Phase 0 spikes referenced below pass.

## Why an external runner exists at all

The daemon must be free to crash, restart, and redeploy without killing a running coding harness, and the harness's OS process group must be terminated reliably the moment the daemon can no longer supervise it.
Neither property holds if the harness is owned directly by a BEAM process.

Symphony's `Codex.AppServer` is the cautionary example: it opens an Erlang `Port` running the harness directly from the Task that dispatched it (`agent_runner.ex`, `app_server.ex`), with session state (`thread_id`, the port itself) living only in that Task's memory.
Because `AgentRuntimeSupervisor` runs its `Task.Supervisor` and `Orchestrator` under `:one_for_all`, an orchestrator crash restarts the `Task.Supervisor` too, and every live harness Port dies with it.
There is no external record of the harness's PID, process group, or session identity outside the BEAM, so a killed node has no way to find and reap orphaned harness processes, and no way to prove a harness has died before reusing its workspace.

A Port-per-harness design is rejected for consigliere-next for exactly this reason: it collapses "coordinator crashed" and "harness must die" into the same event, which invariant #4 (coordinator failure never terminates a runner) and invariant #5 (loss of runner control terminates and verifies the process group) require to be independent events with independent, externally-observable outcomes.

## Language choice: Go, not Elixir

The runner is a small, single-purpose Go binary, per master-prompt section 8's default and section 4.3's Elixir-provisional framing.
Reasons specific to this component, not just deference to the master prompt:

- Process groups, session leaders, signal delivery, and hard-kill-then-verify are OS-level concerns with mature, boring Go stdlib and `syscall` support (`Setsid`, `Setpgid`, `syscall.Kill(-pgid, ...)`). Doing this from a BEAM Port loses the ability to independently outlive the node that spawned it, which is the entire point.
- The runner must keep running after the daemon that spawned it has been `kill -9`'d, until it independently observes control-channel EOF. A Go process with no parent-child coupling to the BEAM VM (started via a supervisor-neutral launcher, not as a linked Port) satisfies this trivially. An Erlang Port is, by construction, tied to the owning process's lifetime unless deliberately unlinked, and even then the model fights the platform instead of using it.
- A daemon-side Elixir process still owns the daemon side of the control channel (a GenServer per Attempt under `Csd.RunnerDynamicSupervisor`) and treats the runner as an ordinary external process it talks to over a socket, not a BEAM primitive. This keeps the OTP side of the system uniform (supervision trees, monitors, `{:DOWN, ...}`) while pushing all of the “must survive the supervisor's death” logic into the one place designed for it.

If a Phase 0 spike shows the Go-runner-plus-Elixir-daemon split adds more real complexity than a single Go daemon (per ADR-001's revisit clause), reconsider a single-language Go implementation. Do not reconsider a Port-based, BEAM-owned harness process; that option is closed by the reasoning above regardless of language choice.

## Runner responsibilities

One runner process instance is spawned per Attempt.
On launch it must, in order:

1. Spawn the harness with `setsid()` (or platform equivalent) applied to it, making the harness itself the new session leader and process group leader -- not the runner. This keeps the runner outside the harness's own process group, so the runner can `kill(-pgid, ...)` that group during termination without ever signaling itself, and can go on to write a final manifest after the group is gone. (Spike C: implemented in `runner/cs-runner/spawn.go`.)
2. Write the runtime manifest (below) before or during harness spawn, using the crash-safe write protocol.
3. Exec the harness within that new process group, as the group's leader.
4. Report runner PID, harness PID, process-group ID, harness executable identity (path + a content hash, to detect a swapped binary across restarts), start timestamp, `attempt_id`, `mission_id`, and `fencing_token` to the daemon over the control channel.
5. Frame the harness's stdout and stderr and forward them over the control channel, preserving native ordering (one writer per stream, no interleaved buffering across streams).
6. Monitor the daemon control channel for liveness.
7. On control-channel EOF (daemon gone, socket closed, or explicit disconnect), execute the termination sequence (below).
8. Reject any control-channel command carrying a stale `fencing_token`.
9. Expose enough state, via the runtime manifest and a local status query, for another process (a restarted daemon, an operator, `cs doctor`) to reconstruct what this runner is doing without asking the daemon.

The runner never interprets Mission policy: it does not decide whether to retry, whether a finding is acceptable, or what "done" means. It only starts, frames, and stops a process group, and reports facts about it.

## Runtime manifest protocol

The runtime manifest is the durable, crash-safe record of "this runner is running this harness for this Attempt," independent of both the daemon's database and the runner's own liveness.
It exists so that a restarted daemon, or an operator running `cs doctor`, can discover an orphaned runner even if the daemon's SQLite state is unavailable or predates the runner's launch (the daemon-death-before-persistence race, covered in Phase 2's required tests).

Location: `runners/<attempt_id>/manifest.json`, under a daemon-owned runtime directory the harness itself never has a path into (it is not inside any Mission workspace).

Format:

```json
{
  "schema_version": 1,
  "attempt_id": "01J...",
  "mission_id": "01J...",
  "fencing_token": "f3a9...",
  "runner_pid": 51234,
  "harness_pid": 51235,
  "pgid": 51234,
  "harness_executable_path": "/usr/local/bin/claude",
  "harness_executable_sha256": "9b2f...",
  "started_at": "2026-08-18T21:04:11.203Z",
  "control_socket_path": "/var/run/csd/attempts/01J.../control.sock",
  "state": "running",
  "last_state_change_at": "2026-08-18T21:04:11.203Z",
  "exit_code": null,
  "termination_reason": null,
  "verified_dead_at": null
}
```

`state` is one of `starting`, `running`, `terminating`, `dead_verified`, `dead_unverified`. `dead_unverified` is written only when the runner could not confirm the process group is gone (kill signal sent, no confirmation received before the runner itself had to exit); this state is what forces workspace quarantine per invariant #6, since a `dead_unverified` manifest cannot license reuse.

Write sequence (this is the mechanism invariants #7 through #9 depend on, so it is specified exactly):

1. Serialize the new manifest content to a temp file in the same directory (`manifest.json.tmp-<random>`), never in a different filesystem (must be same-volume for the rename to be atomic).
2. `fsync` the temp file's file descriptor.
3. `rename(2)` the temp file onto `manifest.json`. Rename is atomic on POSIX filesystems within the same directory; a reader never observes a partially written manifest.
4. `fsync` the containing directory's file descriptor, so the rename itself is durable across a host crash, not just visible to other processes.

Every manifest transition (spawn, each state change, exit) repeats this full sequence. The manifest is never edited in place.

## Control channel wire protocol

One Unix domain socket per Attempt, at the `control_socket_path` recorded in the manifest, created by the runner before it reports readiness.
Framing: newline-delimited JSON (NDJSON), one JSON object per line, both directions. NDJSON over length-prefixing is chosen for operability (`nc`, `socat`, and a human with `jq` can all read the stream directly during an incident) at a cost of requiring the daemon and runner to reject any line containing an embedded newline in a string field before framing (standard JSON string escaping already forbids raw newlines inside string values, so this is not an extra constraint in practice).

Daemon-to-runner message types:

```json
{"type": "cancel", "attempt_id": "01J...", "fencing_token": "f3a9...", "reason": "boss_canceled"}
{"type": "checkpoint_request", "attempt_id": "01J...", "fencing_token": "f3a9..."}
{"type": "ping", "attempt_id": "01J...", "fencing_token": "f3a9..."}
```

Runner-to-daemon message types, corresponding to master-prompt section 8 items 4-10:

```json
{"type": "runner_started", "runner_pid": 51234, "harness_pid": 51235, "pgid": 51234, "harness_executable_path": "...", "harness_executable_sha256": "...", "started_at": "...", "attempt_id": "...", "mission_id": "...", "fencing_token": "..."}
{"type": "stdout_chunk", "attempt_id": "...", "native_sequence": 42, "data": "..."}
{"type": "stderr_chunk", "attempt_id": "...", "native_sequence": 43, "data": "..."}
{"type": "harness_exited", "attempt_id": "...", "exit_code": 0, "signaled": false}
{"type": "termination_complete", "attempt_id": "...", "verified_dead": true, "termination_reason": "control_eof"}
{"type": "pong", "attempt_id": "..."}
```

Every runner-to-daemon message carries the `fencing_token` the runner was launched with; the daemon rejects (logs and ignores, does not act on) any message whose fencing token does not match the currently active token for that Attempt. This is the mechanism behind invariant #10 (a stale fencing token cannot create authoritative state): if a Mission superseded an Attempt and minted a new token for its replacement, the old runner's messages are inert even if that runner is still technically alive during its termination sequence.

`native_sequence` is a per-stream, monotonically increasing counter the runner assigns; the daemon uses it to detect and drop duplicate or out-of-order frames from a reconnecting runner, and to detect a stale runner that reconnects with a lower sequence than the daemon has already seen (a symptom of two runners believing they own the same Attempt, which should never happen given fencing but is defended anyway).

## Termination sequence

Triggered by control-channel EOF (daemon socket closed or connection lost) or by receiving a `cancel` message.

1. Send `SIGTERM` to the full process group (`kill(-pgid, SIGTERM)`).
2. Wait up to **5 seconds** for the harness process (and, best-effort, any children) to exit. Five seconds is chosen as long enough for a coding harness to flush a partially written file or abort a subprocess cleanly, short enough that an operator watching `cs why` is not left wondering whether the system has hung.
3. If any process in the group remains, send `SIGKILL` to the full process group.
4. Wait up to **2 seconds**, then verify: scan `/proc` (Linux) or use `proc_listpids`/`kinfo_proc` (macOS) for any process whose process group matches `pgid`. Two seconds is enough for the kernel to reap a `SIGKILL`'d process under normal load; it is not a correctness boundary, only a bound on how long termination is allowed to take before the runner escalates to reporting `dead_unverified` rather than hanging indefinitely.
5. If verification finds no surviving process in the group, update the manifest to `state: dead_verified`, record `verified_dead_at`, and send `termination_complete` with `verified_dead: true`.
6. If verification finds a surviving process (a process that ignored `SIGKILL` is not supposed to be possible on POSIX, but a zombie awaiting reap by an unexpected parent, or a process the runner cannot signal due to a permissions change, both occur in practice), write `state: dead_unverified`, send `termination_complete` with `verified_dead: false`, and exit anyway. The daemon's reconciler is responsible for treating `dead_unverified` as "quarantine the workspace, do not reuse, raise an incident," not for retrying the kill itself (the runner process that could retry is the one exiting).
7. Exit.

The runner does not wait indefinitely at any step; every wait above is bounded, and the runner always eventually exits and writes a final manifest state, because a runner that never exits defeats the entire purpose of daemon-independent termination.

## Restart and reconciliation contract

On daemon startup (fresh boot or restart after crash), the daemon's `Csd.Reconciler` process:

1. Lists every `runners/<attempt_id>/manifest.json` in the runtime directory.
2. For each manifest, cross-references the Attempt row in SQLite.
3. If the manifest says `dead_verified` and the Attempt row is not already terminal, mark the Attempt `lost` (if no checkpoint was ever reported) or `checkpointed` (if a checkpoint commit was already imported before the runner died), and release any lease/fencing token so a continuation can be scheduled.
4. If the manifest says `running` or `starting` but the recorded `runner_pid` is not present in the OS process table at all (the runner itself died, not just the harness, e.g. the host rebooted), the daemon cannot trust the manifest's last known state. It attempts to verify independently, by process-group inspection, whether `pgid` has any surviving members. If none are found, treat as `dead_verified` after the fact and proceed as in step 3. If the process group is still alive (the runner died but the harness did not), the daemon spawns a fresh runner instance pointed at the same `pgid` in "adopt and kill" mode: its only job is to send the termination sequence to that process group, verify death, and then exit. Per master-prompt section 8, this system never adopts a still-running harness into a new supervised session; the only thing an orphaned-but-alive harness is used for is being killed.
5. If the manifest says `dead_unverified`, the workspace tied to that Attempt is quarantined (never reused) and an incident is created, per invariant #6.
6. Manifests older than a configurable retention window and in a terminal state are archived (moved, not deleted, to preserve incident evidence) out of the live runtime directory.

No step in this sequence involves a long-lived read transaction against SQLite or a blocking wait on an external process; each manifest is reconciled independently and the reconciler makes forward progress even if one manifest is corrupt (a corrupt manifest is treated as `dead_unverified`, i.e. quarantine-and-incident, never as a reason to halt reconciliation of the others, satisfying invariant #21).

## Open questions for Phase 0 spikes

- Spike C (daemon-bound runner) must empirically confirm the 5s/2s timeout budget above is workable under real harness shutdown behavior; these numbers are a starting proposal, not yet measured.
- The exact mechanism for "daemon dies between runner spawn and database persistence" (master-prompt Phase 2 test 16) needs the manifest write to happen before the daemon's own Attempt-row insert commits, or a compensating reconciliation path that discovers a manifest with no matching Attempt row at all and treats it as adoptable-for-kill; this document assumes the latter and Phase 2 must verify it against the actual daemon transaction boundary.
