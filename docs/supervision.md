# Supervision

Consigliere has exactly one supervision protocol: the bounded foreground checkpoint. It is identical across harnesses (codex and claude); only the Stop-hook registration differs.
Codex cannot reason during a foreground tool call, so a background watcher that "notifies" the model has no wake semantics; the checkpoint returns control at a bound instead.

## The cycle

1. Drain first: `bin/cs-wake-drain.sh` at the start of every wake-handling turn.
   The drain also prints bounded fleet-wide open-decision context, including on an empty queue, and stays silent when no decisions remain open.
   That scan is cursor-backed (`state/.decision-cursor-<task>`), so each drain folds only status bytes appended since the previous drain instead of every task's whole lifetime log.
2. Run one checkpoint, and only one this turn: `bin/cs-watch-checkpoint.sh --seconds "${CS_WATCH_CHECKPOINT:-180}"`.
   It ensures `bin/cs-monitor.sh` is alive for this home, reviving it on a stale `state/.last-monitor-beat`, then waits for `state/.wake-queue` to carry something.
3. Actionable wake (`signal:` / `stale:` / `check:` / `heartbeat`): drain, handle, report, end the turn.
4. Quiet checkpoint (`checkpoint:` line, exit 124): drain anyway, process any queued boss message, end the turn.
5. Never `&`, never background tasks, never a second cycle beside a healthy one.
6. Failure or missing cycle only: drain, inspect, start a fresh checkpoint.

## One checkpoint per turn

The checkpoint is bounded, but nothing bounded the number of them a turn could run, and the contract said to start the next one in the same turn.
The harness only delivers queued boss input at a turn boundary, so that rule made supervision and reachability mutually exclusive and always resolved it toward supervision: measured across this project's own transcripts, 61 consecutive checkpoints over 6.2 hours with nothing said to the boss, in a session that could not have received a message if one had been sent.

The rule is now the opposite - handle the wake and end the turn - and it is enforced in code rather than in prose, because prose is what got reinterpreted.
`bin/cs-watch-checkpoint.sh` writes `state/.checkpoint-turn` on entry and exits 3 without waiting if it is already there; `bin/cs-turnend-guard.sh` clears it at every turn end, and `bin/cs-session-start.sh` clears a marker left by a turn that died mid-flight.
The refusal still ensures a monitor first, so the home stays watched whatever the agent does next.

Ending the turn is safe because supervision stopped living in the turn when the persistent monitor and per-home activation shipped: the monitor keeps watching, the wake queue is durable, and `bin/cs-activate.sh` starts the next turn when something sits in it.
A turn that dies mid-handling is recovered by the drain's own orphan-batch replay, so the shorter turns this produces do not widen that window.
The checkpoint keeps one legitimate use inside a turn: a single bounded wait for a result expected within seconds, such as an acknowledgement after steering a worker.

`bin/cs-watch.sh` is the zero-token classifier: it absorbs benign wakes in bash (no model turn) and exits with a reason line only for actionable ones.
`bin/cs-monitor.sh` owns that watcher and outlives any single turn, which is the property the checkpoint alone could never provide: a checkpoint exists only while its agent waits on it, so before monitors a home went unwatched the moment its agent started working (2h10m observed on a live capo home).
The monitor never injects and never reasons - the durable queue is the entire handoff - and it covers an away-mode home exactly like an attended one, with no separate away-mode supervisor to defer to.
A flag deferred to a dead owner cost 8h11m of unwatched fleet on 2026-08-01, before that owner was retired.
The monitor also re-execs itself when `bin/cs-monitor.sh` changes on disk, because it runs for days and would otherwise keep executing whatever code existed when it started - that same incident ran a monitor 13 hours older than the fix that would have caught it.

Long-lived supervision processes must be started through `bin/cs-detach.py`, never `nohup ... & disown`.
The monitor is launched from inside an agent's bounded tool call, and `nohup` does not survive that call's process-group teardown.
The monitor learned this on 2026-07-30 (213 revivals in seven hours); the away daemon was left on `nohup` until 2026-08-01 and died within a second of arming on all five recorded away sessions.
A monitor that dies is revived from both ends of a turn - the next checkpoint and the turn-end guard, which share `bin/cs-monitor-lib.sh` - so an unexplained death costs one interval rather than a session; if no monitor can be started at all, the checkpoint says so and watches inline for that bound.
Wakes are appended durably to `state/.wake-queue` before detector state advances, so a missed process exit is recovered by the next drain.

## Drain durability

The queue only covers wakes that are still queued.
The window the queue cannot cover on its own runs from the moment a drain rotates records out of it to the moment the agent has handled them: a turn that dies in there (crash, context loss, kill) leaves an empty queue and records nothing would ever read again.
The drain closes that window with the rotation batch itself.

A drain moves the queue into a batch file (`state/.wake-queue.drain.*`) after taking the queue lock and removes that batch before releasing it.
So while a drain holds the lock, any batch it finds on disk belongs to a drain that never committed, with no liveness check needed to prove it.
The drain adopts every such orphan, deduping its records into the same view as the freshly rotated queue - oldest file first, so a key carried by both keeps its earliest position and its latest payload - and prints a `wake replay:` line naming how many records came back and from how many interrupted drains.
The replayed rows keep the canonical raw shape and are handled exactly like fresh ones; the label exists so a record that surfaces a second time does not read as a duplicate wake of unknown origin.

Acknowledgement is the committed print, not a later signal.
A drain that prints its records has put them in front of the agent, and it retires every adopted orphan in that same step; a drain that dies before printing retires nothing, so its batch - including anything it had adopted - is still there for the next drain.
This is deliberately not a turn-level or checkpoint-level acknowledgement.
The checkpoint is the obvious alternative acknowledger, since it structurally runs after handling, but a turn is free to drain twice with a checkpoint between and free to end without one at all, so keying retirement to it would replay handled records in the ordinary case and delete unhandled ones when a turn starts with a checkpoint instead of a drain.
Keying it to the print is the one boundary the drain can observe by itself.

Nothing is ever re-promoted into a new pending batch, which is what keeps repeated adoption from feeding itself: a drain that commits ends the chain outright, and consecutive dying drains accumulate batches whose contents dedupe away the moment one of them commits.
Restoring an interrupted drain's queue removes the batch it restored from, because those records are back in the queue and a leftover copy would be adopted as a loss that never happened.

## Wake vocabulary

- `signal: <files>` - status/turn-end signals; surfaced when a listed status carries a boss-relevant verb anywhere in its unread appended span OR a no-verb signal's soldier is not provably working.
  The span read (not last-line-wins) is what keeps a decision, blocker, failure, or finish visible when a later routine append lands inside the coalescing grace.
  A no-verb wake carrying only turn-end markers is also absorbed when the task's pane content changed since the previous poll, so a harness with no verified busy source does not surface a contentless wake at every turn boundary; a stopped soldier's now-static pane still surfaces through the staleness backbone.
  The drain presents every unread status line since its per-task presentation cursor, so an older `note:` is never dropped because a newer line followed it, and this home's own bookkeeping closes (a `cs-send --resolve-key` resolved line) advance the seen marker over exactly their own bytes and do not re-wake the session that wrote them.
- `stale: <pane>` - endpoint went quiet; absorb-only-when-provably-working, wedge escalation past `CS_STALE_ESCALATE_SECS` with an escalation count and a `demand-deep-inspection` marker at `CS_WEDGE_DEMAND_INSPECT_COUNT` consecutive escalations.
  A pane that stays *busy* is bounded too: past `CS_BUSY_TURN_MAX_SECS` (default 3600) with no completed turn it enters the same wedge timer, because a busy signal alone cannot distinguish real work from a hung foreground tool call.
  The escalation is for inspection only and never interrupts or restarts the soldier; any completed turn resets the age.
- `check: <script>: <out>` - authenticated poll output (PR merge poll, registered custom checks); always actionable. Unauthenticated state checks are rejected without execution.
- `heartbeat` - fleet-scan backstop found an unsurfaced boss-relevant status.

`bin/cs-classify-lib.sh` is the single owner of the verb vocabulary and delegates machine-input typing to `bin/cs-operational-input.sh`.
`bin/cs-crew-state.sh` is the authoritative current-state read (no-mistakes run-step first, then native agent status, then status-log fallback).

## Busy evidence policy

Native herdr `agent get` status drives busy detection: `working` is trusted outright and `blocked` surfaces immediately.
Native `idle`/`unknown` is corroborated against the `esc to interrupt` rendered-banner signature (shared by codex and claude) before a soldier is declared not-working, because `agent.get` can read idle during a long foreground tool call (docs/herdr.md).

## Event push splice

When this home's herdr event plugin is installed, the watcher replaces its poll sleep with a bounded wait on the spool that plugin feeds, surfacing `blocked` sub-second.
herdr itself runs the hook (`bin/cs-herdr-event-hook.sh`) on every `pane.agent_status_changed` edge, so edges that fire while no watcher is running are still waiting in `state/.herdr-events` when one starts; `bin/cs-herdr-event-plugin.sh` owns the install and `bin/cs-herdr-event-lib.sh` the spool contract.
A machine without the plugin has no spool and simply keeps polling, and the poll loop remains live every cycle as the permanent fail-closed backstop either way.

## Structural backstop

The harness Stop hook registers `bin/cs-turnend-guard.sh` (`.codex/hooks.json` for codex; `.claude/settings.json` at the repo root for a claude root/capo, and a launch-scoped `--settings` file for claude soldiers).
Its predicate is whether this home can WAKE ITSELF once the turn ends, not whether work is under way: with work in flight it blocks the stop once (exit 2) when no monitor could be started, when no pane is recorded in `state/.home-pane`, when that record names a different pane than the one running this session, or when `state/.activation-stalled` says activation already found the target unusable.
Those are the local records `bin/cs-activate.sh` needs; that script owns the live revalidation, and the guard deliberately reads no backend, because it runs on every turn of the primary and must never hang one.
Anything else is an ordinary turn end and the guard stays silent.
`stop_hook_active` remains the loop guard (both harnesses carry that field), so a home that genuinely cannot wake itself costs one forced continuation per turn rather than a wedged session.
Its continuation is typed `turn-end-guard`, so it cannot be confused with boss input after rewording.
The guard scopes itself to a genuine primary home (main checkout or marked capo home) via `bin/cs-primary-scope-lib.sh`; soldier task worktrees are exempt.
The same scope test is what makes the guard the one component able to observe a turn boundary, which is why clearing `state/.checkpoint-turn` lives here too.

## Optional measurement

The drain, the bounded checkpoint, and this Stop-hook guard are instrumented for the optional turn telemetry in `docs/telemetry.md`, which is off unless a home's `host/telemetry.conf` enables it.
It is measurement only and changes no supervision decision: `tests/cs-telemetry-invariants.test.sh` runs each of those three paths with telemetry off and on and fails on any difference in exit status or output.

## Repair

A forced watcher repair is home-scoped: kill only the pid recorded in this home's `state/.watch.lock`, then start a fresh foreground checkpoint.
Never broadly kill watchers by process name; sibling capo homes run their own.
