---
name: afk
description: >-
  Enter away-mode supervision when the boss invokes /afk, says they are going afk, `state/.afk` exists, an incoming message starts with `CS_INJECT_MARK`, or any `state/.subsuper-*` marker is involved.
  It sets a durable away-mode flag so the sub-supervisor daemon can self-handle routine wakes and escalate boss-relevant events plus bounded declared-external-wait rechecks as batched digests during walk-away stretches, then exits automatically when any real unmarked message returns consigliere to full per-wake responsiveness.
user-invocable: true
---

# afk

Away-mode supervision. When invoked, `/afk` makes the daemon's token-saving
tradeoff **consented** and **explicit**: the boss is stepping away, so the
sub-supervisor may triage routine wakes in bash instead of waking consigliere's
LLM for each one. Escalations still reach the boss, but as one pre-read,
batched digest rather than per-wake injections.

## What it does

1. **Enter through `bin/cs-afk-start.sh`, run from consigliere's own pane.**
   It refuses outside a herdr pane (`HERDR_PANE_ID` unset) because that pane
   id is the daemon's one injection target; it writes the durable
   `state/.afk` flag, records the pane in `state/.subsuper-target`, clears
   the prior away session's stale delivery artifacts on a fresh entry only,
   starts `bin/cs-daemon.sh` headless, and verifies the daemon came alive
   (rolling `state/.afk` back if it did not).
   Re-running while the daemon is alive is a refresh: the current session's
   buffered escalations are preserved.
   The flag survives a consigliere restart, so recovery re-enters afk when it
   is present.

2. **The daemon is presence-gated.**
   It injects escalations only while `state/.afk` exists, and stays quiet
   otherwise.

3. **Do not separately arm the watcher or a checkpoint.** The daemon manages
   `bin/cs-watch.sh` as its one-shot child; the watcher singleton lock no-ops
   a stray arm harmlessly, and while `state/.afk` exists the watcher queues
   and exits on every wake so the daemon owns triage.

4. **Acknowledge** in AGENTS.md section 9 language: "Boss, away mode is
   active; I will batch routine updates and surface only decisions, failures,
   credentials, or review-ready work until you return."

## How to exit afk

No `/back` is needed. The first genuine message is the return signal:

- A message **without** the sentinel marker and **not** starting with `/afk` -> the boss is back.
  Run `bin/cs-afk-return.sh` before acting on the message that brought the boss back.
  That script owns correct-ordered daemon shutdown (stop the daemon, then clear `state/.afk`), durable wake draining, escalation and wedge evidence, and the fail-closed return catch-up gate.
  If it reports a consigliere-actionable `blocked:` decision, remediate it immediately through the normal lifecycle, or explicitly reclassify it with a durable reason and close its decision key with `resolved [key=...]`, then run `bin/cs-afk-return.sh check`.
  Once the daemon stops, resume the normal foreground checkpoint cycle while blocker handling proceeds, so the gate never creates a blind wait.
  Do not perform any other ordinary boss work until the check exits successfully.
- A message **with** the sentinel marker (`CS_INJECT_MARK`, a bare leading U+2063 INVISIBLE SEPARATOR) -> it is a daemon escalation; stay afk and process it.
- Re-invoking `/afk` while already away -> stay afk (refresh the flag); this does **not** trigger an exit.

Bias ambiguous cases toward exit: a present boss beats token savings, and a
false exit is self-correcting (the boss re-runs `/afk`).

## Orthogonal to approval authority

afk changes how aggressively consigliere surfaces things, **not who approves
what**. "Away" never means "approves more." A PR ready for merge, a
needs-decision finding, or anything destructive, irreversible, or
security-sensitive still waits for the boss's explicit word - the daemon just
batches the notification.

## Sentinel marker contract

The daemon prefixes every injection with `CS_INJECT_MARK`, a bare leading
U+2063 INVISIBLE SEPARATOR that no normal keyboard produces and herdr
transports as UTF-8 text (`bin/cs-marker-lib.sh` is the single definition
site). This is how consigliere tells a daemon escalation apart from a real
boss message in the same pane. It is distinct from the from-consigliere
request marker, which begins with a human-readable label before its U+2063,
so the two cannot conflate.

## Busy-guard and composer guard

The daemon never injects into an in-use pane. Two checks run before every
injection:

- **Busy-guard** - herdr's native agent state must not read `busy` (mid-turn)
  or `blocked` (waiting on the human); `cs_herdr_agent_busy_state` corroborates
  an ambiguous native reading against the codex busy signature.
- **Composer guard** - `bin/cs-composer-lib.sh` classifies the codex composer
  from an ANSI pane capture as `empty`/`pending`/`unknown`, and only an
  affirmatively `empty` verdict permits injection.
  It strips ANSI de-emphasis (dim/faint and dark-truecolor runs) before
  judging, so codex's idle ghost suggestion after the bare `›` prompt reads as
  empty instead of wedging every escalation (the 2026-07-08 upstream
  ghost-text incident, docs/codex.md).
  `pending` protects a half-typed boss line or a previous injection's
  swallowed text; `unknown` protects unreadable panes and bare dead-shell
  prompts (typing into a shell could execute the digest). Both defer.
  If the transport strips ANSI, ghost text is indistinguishable from typed
  input and classifies `pending` - the failure direction is defer plus the
  max-defer alarm, never a wrong injection.

Either guard failing defers the injection; the buffered escalation survives in
`state/.subsuper-escalations` and is retried on the next housekeeping tick.

**Max-defer escape (the daemon must never silently wedge).**
If anything stays buffered past `CS_MAX_DEFER_SECS` (default 300), the daemon
attempts one normal flush, which still requires an idle pane and an
affirmatively empty composer. If that submit cannot be confirmed, it raises a
loud, rate-limited wedge alarm: an ERROR in the daemon log, a durable
`state/.subsuper-inject-wedged` marker (surfaced by the return catch-up), and
a configurable active alert (`config/wedge-alarm`: `off`, `auto`, `osascript`,
`herdr`, or `command:<cmd>`; absent means auto, a macOS Notification Center
banner, so the alarm is never silent). A guard false-positive becomes a
visible stall, never an unbounded silent no-op.

## Submit model

The digest is typed **once** (`herdr pane send-text`, literal and
non-submitting), then submitted with Enter and **verified natively**:
`cs_herdr_agent_wait`/`cs_herdr_submit_confirm` confirms the receiving turn
actually started (idle -> working). Enter is retried - Enter only, never a
retype, since retyping would concatenate two marked digests - up to
`CS_INJECT_CONFIRM_RETRIES` times. An unconfirmed submit counts as
undelivered, so the buffer is preserved rather than cleared.

## Classification policy

The daemon wraps `bin/cs-watch.sh`, runs the watcher as a one-shot child,
classifies each printed wake reason in bash, and self-handles the routine
majority without consuming a consigliere turn. Boss-relevant events, plus a
bounded recheck of a declared external wait that remains idle, escalate as one
pre-read, single-line, batched digest. The classification predicates (the
boss-relevant verb set, declared-pause vocabulary, and fleet scan) live in the
shared `bin/cs-classify-lib.sh`, the same library the always-on watcher uses,
so the two modes apply one identical policy and the daemon never duplicates
the verb vocabulary.

- `signal` with a terminal boss verb (`done:`, `needs-decision:`, `blocked:`,
  `failed:`) -> escalate. A nonterminal progress verb never escalates merely
  because its prose contains a legacy free-text token. Other signals -> self-handle.
- `signal` or `stale` for a declared `paused:` external wait -> self-handle
  and track the pause; if it stays declared and idle past
  `CS_PAUSE_RESURFACE_SECS` (default 3600), housekeeping sends one
  awaiting-external recheck and resets the window.
- `check` -> always escalate (check scripts print only when actionable).
- `stale` with a terminal status -> escalate. Non-terminal -> record a marker
  and self-handle; still idle past `CS_STALE_ESCALATE_SECS` (default 240),
  housekeeping escalates a possible wedge. Bounded latency, never a loss.
- `heartbeat` -> self-handle; the daemon's own catch-all scan
  (`scan_boss_relevant_statuses`) runs every `CS_HEARTBEAT_SCAN_SECS`
  (default 300) as the fail-safe backstop.
- Unknown reason, or any uncertainty -> escalate fail-safe.

Escalations buffer up to `CS_ESCALATE_BATCH_SECS` (default 90; 0 = immediate)
and flush as ONE single-line digest prefixed with the sentinel marker.
`CS_INJECT_SKIP` (default `heartbeat`) force-self-handles matching reason
prefixes, overriding classification; use it sparingly.

## Stale-artifact lifecycle

Treat `state/.subsuper-escalations`, its `.since` sidecar, and
`state/.subsuper-inject-wedged` as session-scoped delivery artifacts, not the
durable work record. Enter through `bin/cs-afk-start.sh`, which clears
prior-session artifacts only on a fresh entry and preserves the current
session's buffer on refresh. Exit through `bin/cs-afk-return.sh`, which keeps
`state/.afk` present through the daemon's shutdown flush, clears it after the
stop, and prints the surviving buffer as catch-up evidence before clearing the
artifacts.

## Reliability properties

These properties must hold:

- Nothing is lost. The durable queue plus `bin/cs-wake-drain.sh` recover any
  missed or crashed injection.
- Wedge detection is bounded-latency, not lossy.
- Declared external waits are rechecked on a separate, bounded cadence rather
  than being mislabeled as wedges.
- The catch-all scan backs up the keyword classifier.
- The daemon preserves a single-instance portable lock (`bin/cs-wake-lib.sh`,
  no flock), crash-loop backoff, a pane-gone guard, and a signal-trapped
  shutdown that flushes buffered escalations before exit.
