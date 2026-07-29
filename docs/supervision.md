# Supervision

Consigliere has exactly one supervision protocol: the bounded foreground checkpoint. It is identical across harnesses (codex and claude); only the Stop-hook registration differs.
Codex cannot reason during a foreground tool call, so a background watcher that "notifies" the model has no wake semantics; the checkpoint returns control at a bound instead.

## The cycle

1. Drain first: `bin/cs-wake-drain.sh` at the start of every wake-handling turn.
2. Run one checkpoint: `bin/cs-watch-checkpoint.sh --seconds "${CS_WATCH_CHECKPOINT:-180}"`.
3. Actionable wake (`signal:` / `stale:` / `check:` / `heartbeat`): drain, handle, start the next checkpoint in the same turn.
4. Quiet checkpoint (`checkpoint:` line, exit 124): drain anyway, process any queued boss message, start the next checkpoint.
5. Never `&`, never background tasks, never a second cycle beside a healthy one.
6. Failure or missing cycle only: drain, inspect, start a fresh checkpoint.

`bin/cs-watch.sh` is the zero-token classifier under the checkpoint: it absorbs benign wakes in bash (no model turn) and exits with a reason line only for actionable ones.
Wakes are appended durably to `state/.wake-queue` before detector state advances, so a missed process exit is recovered by the next drain.

## Wake vocabulary

- `signal: <files>` - status/turn-end signals; surfaced when a listed status has a boss-relevant verb OR a no-verb signal's soldier is not provably working.
- `stale: <pane>` - endpoint went quiet; absorb-only-when-provably-working, wedge escalation past `CS_STALE_ESCALATE_SECS` with an escalation count and a `demand-deep-inspection` marker at `CS_WEDGE_DEMAND_INSPECT_COUNT` consecutive escalations.
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

## Repair

A forced watcher repair is home-scoped: kill only the pid recorded in this home's `state/.watch.lock`, then start a fresh foreground checkpoint.
Never broadly kill watchers by process name; sibling capo homes run their own.
