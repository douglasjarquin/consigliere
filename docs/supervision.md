# Supervision

Consigliere has exactly one supervision protocol: the bounded foreground checkpoint. It is identical across harnesses (codex and claude); only the Stop-hook registration differs.
Codex cannot reason during a foreground tool call, so a background watcher that "notifies" the model has no wake semantics; the checkpoint returns control at a bound instead.

## The cycle

1. Drain first: `bin/cs-wake-drain.sh` at the start of every wake-handling turn.
   The drain also prints bounded fleet-wide open-decision context, including on an empty queue, and stays silent when no decisions remain open.
   That scan is cursor-backed (`state/.decision-cursor-<task>`), so each drain folds only status bytes appended since the previous drain instead of every task's whole lifetime log.
2. Run one checkpoint: `bin/cs-watch-checkpoint.sh --seconds "${CS_WATCH_CHECKPOINT:-180}"`.
   It ensures `bin/cs-monitor.sh` is alive for this home, reviving it on a stale `state/.last-monitor-beat`, then waits for `state/.wake-queue` to carry something.
3. Actionable wake (`signal:` / `stale:` / `check:` / `heartbeat`): drain, handle, start the next checkpoint in the same turn.
4. Quiet checkpoint (`checkpoint:` line, exit 124): drain anyway, process any queued boss message, start the next checkpoint.
5. Never `&`, never background tasks, never a second cycle beside a healthy one.
6. Failure or missing cycle only: drain, inspect, start a fresh checkpoint.

`bin/cs-watch.sh` is the zero-token classifier: it absorbs benign wakes in bash (no model turn) and exits with a reason line only for actionable ones.
`bin/cs-monitor.sh` owns that watcher and outlives any single turn, which is the property the checkpoint alone could never provide: a checkpoint exists only while its agent waits on it, so before monitors a home went unwatched the moment its agent started working (2h10m observed on a live capo home).
The monitor never injects and never reasons - the durable queue is the entire handoff - and it stands down while away mode holds, because that daemon owns the watcher instead.
That stand-down is earned, not assumed: the daemon needs a live pid AND a completed-pass counter (`state/.subsuper-daemon-beat`) refreshed within `CS_AFK_BEAT_STALE`, or the monitor covers the home itself and records `state/.monitor-afk-orphan`.
A flag with a dead owner behind it cost 8h11m of unwatched fleet on 2026-08-01.
The monitor also re-execs itself when `bin/cs-monitor.sh` changes on disk, because it runs for days and would otherwise keep executing whatever code existed when it started - that same incident ran a monitor 13 hours older than the fix that would have caught it.

Long-lived supervision processes must be started through `bin/cs-detach.py`, never `nohup ... & disown`.
Both the monitor and the away daemon are launched from inside an agent's bounded tool call, and `nohup` does not survive that call's process-group teardown.
The monitor learned this on 2026-07-30 (213 revivals in seven hours); the away daemon was left on `nohup` until 2026-08-01 and died within a second of arming on all five recorded away sessions.
A monitor that dies is revived by the next checkpoint, so an unexplained death costs one checkpoint interval rather than a session; if no monitor can be started at all, the checkpoint says so and watches inline for that bound.
Wakes are appended durably to `state/.wake-queue` before detector state advances, so a missed process exit is recovered by the next drain.

## Wake vocabulary

- `signal: <files>` - status/turn-end signals; surfaced when a listed status has a boss-relevant verb OR a no-verb signal's soldier is not provably working.
- `stale: <pane>` - endpoint went quiet; absorb-only-when-provably-working, wedge escalation past `CS_STALE_ESCALATE_SECS` with an escalation count and a `demand-deep-inspection` marker at `CS_WEDGE_DEMAND_INSPECT_COUNT` consecutive escalations.
  A pane that stays *busy* is bounded too: past `CS_BUSY_TURN_MAX_SECS` (default 3600) with no completed turn it enters the same wedge timer, because a busy signal alone cannot distinguish real work from a hung foreground tool call.
  The escalation is for inspection only and never interrupts or restarts the soldier; any completed turn resets the age.
- `check: <script>: <out>` - authenticated poll output (PR merge poll, registered custom checks); always actionable. Unauthenticated state checks are rejected without execution.
- `capo: <capo>/<worker>: <line>` - a boss-relevant status a worker inside one of this home's capo homes raised, read directly by this watcher rather than waited on.
  A capo home is polled only while its own agent sits idle on a checkpoint, so an event there can otherwise wait as long as that agent's turn lasts.
  The wake reports that the event exists; the capo still owns the lane.
  Discovery is from this home's own `state/<id>.meta` records with `kind=capo`, and a recorded home is read only when it still carries the `.cs-capo-home` marker.
  Dedup is per capo and worker on the surfaced line (`state/.capo-surfaced-<capo>__<worker>`), so a standing block wakes the parent once.
- `heartbeat` - fleet-scan backstop found an unsurfaced boss-relevant status.

`bin/cs-classify-lib.sh` is the single owner of the verb vocabulary shared with the away-mode daemon and delegates machine-input typing to `bin/cs-operational-input.sh`.
`bin/cs-crew-state.sh` is the authoritative current-state read (no-mistakes run-step first, then native agent status, then status-log fallback).

## Busy evidence policy

Native herdr `agent get` status drives busy detection: `working` is trusted outright and `blocked` surfaces immediately.
Native `idle`/`unknown` is corroborated against the `esc to interrupt` rendered-banner signature (shared by codex and claude) before a soldier is declared not-working, because `agent.get` can read idle during a long foreground tool call (docs/herdr.md).

## Event push splice

When the herdr socket is capable, the watcher replaces its poll sleep with a bounded native event wait (`bin/cs-herdr-events.py`, a raw AF_UNIX subscriber for `pane.agent_status_changed`), surfacing `blocked` sub-second.
The poll loop remains live every cycle as the permanent fail-closed backstop.

## Structural backstop

The harness Stop hook registers `bin/cs-turnend-guard.sh` (`.codex/hooks.json` for codex; `.claude/settings.json` at the repo root for a claude root/capo, and a launch-scoped `--settings` file for claude soldiers): when tasks are in flight and no live watcher holds this home's lock with a fresh beacon, the stop is blocked once (exit 2), with `stop_hook_active` as the loop guard (both harnesses carry that field).
Its continuation is typed `turn-end-guard`, so it cannot be confused with boss input after rewording.
The guard scopes itself to a genuine primary home (main checkout or marked capo home) via `bin/cs-primary-scope-lib.sh`; soldier task worktrees are exempt.
It is a backstop, never permission to omit the live cycle.

## Optional measurement

The drain, the bounded checkpoint, and this Stop-hook guard are instrumented for the optional turn telemetry in `docs/telemetry.md`, which is off unless a home's `host/telemetry.conf` enables it.
It is measurement only and changes no supervision decision: `tests/cs-telemetry-invariants.test.sh` runs each of those three paths with telemetry off and on and fails on any difference in exit status or output.

## Repair

A forced watcher repair is home-scoped: kill only the pid recorded in this home's `state/.watch.lock`, then start a fresh foreground checkpoint.
Never broadly kill watchers by process name; sibling capo homes run their own.
