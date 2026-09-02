---
name: afk
description: >-
  Enter away-mode supervision when the boss invokes /afk, says they are going afk, `state/.afk` exists, an incoming message classifies as `away-supervisor`, or any `state/.subsuper-*` marker is involved.
  It sets a durable away-mode flag that commits consigliere to batching routine updates and surfacing only decisions, failures, credentials, and review-ready work until the boss returns, and expands a `yolo` project's routine ask-user findings into recorded auto-decides (bossless mode) for as long as the flag holds. Supervision itself - the watcher, the monitor, and per-home activation - runs identically whether or not the flag is set.
user-invocable: true
---

# afk

Away-mode supervision. `/afk` is a reporting-posture and decision-authority
change, not a separate supervision mechanism: the same always-on
watch/monitor/activate triangle covers this home whether or not the boss is
present. What changes while the flag holds is how consigliere reports (batched,
less often) and, for a `yolo` project, how much it decides on its own (bossless
mode, below).

## What it does

1. **Enter through `bin/cs-afk-start.sh`.**
   It writes the durable `state/.afk` flag and clears the prior away
   session's stale delivery artifacts on a fresh entry only, then returns
   immediately: there is nothing to launch, since the triangle already
   supervises this home the same way it does an attended one.
   Re-running while already away is a refresh: the current session's
   buffered evidence is preserved.
   The flag survives a consigliere restart, so recovery re-enters afk when it
   is present.

2. **Acknowledge** in AGENTS.md section 8 language: "Boss, away mode is
   active; I will batch routine updates and surface only decisions, failures,
   credentials, or review-ready work until you return."
   If a `+yolo` project already reads acknowledged in `config/bossless-ack.md`
   (the file `bin/cs-afk-start.sh`'s own acknowledgment gate owns, not this
   step), name it in that same sentence per section 8's bossless-mode
   phrasing: append ", and `<project>` will make its own calls while you're
   away starting now - recorded for your review in its PR" for each such
   project.

3. **Do not separately arm the watcher or a checkpoint.** `bin/cs-watch.sh`,
   `bin/cs-monitor.sh`, and `bin/cs-activate.sh` all run exactly the same way
   regardless of `state/.afk` - there is no separate away-mode process to
   arm, and the monitor's own singleton lock no-ops a stray arm harmlessly.

## How to exit afk

No `/back` is needed. The first genuine message is the return signal:

- Input classified `boss` and not starting with `/afk` -> the boss is back.
  Run `bin/cs-afk-return.sh` before acting on the message that brought the boss back.
  That script owns clearing `state/.afk`, durable wake draining, escalation and wedge evidence, and the fail-closed return catch-up gate.
  If it reports a consigliere-actionable `blocked:` decision, remediate it immediately through the normal lifecycle, or explicitly reclassify it with a durable reason and close its decision key with `resolved [key=...]`, then run `bin/cs-afk-return.sh check`.
  The flag clears immediately, and the normal foreground checkpoint cycle resumes right away while any blocker handling proceeds under the fail-closed return catch-up gate, so the gate never creates a blind wait.
  Do not perform any other ordinary boss work until the check exits successfully.
- Input classified `away-supervisor` -> it is this home's own activation prompt (`bin/cs-activate.sh`), telling the agent its wake queue has sat unattended; stay afk and process it under the ordinary supervision protocol.
- Re-invoking `/afk` while already away -> stay afk (refresh the flag); this does **not** trigger an exit.

Bias ambiguous cases toward exit: a present boss beats token savings, and a
false exit is self-correcting (the boss re-runs `/afk`).

## Bossless mode - the one boundary this changes

Away-mode is normally orthogonal to approval authority: "away" means
consigliere surfaces things less often, never that it approves more.
That changes only for a project whose `yolo` posture is on, for exactly as
long as `state/.afk` holds on it: every ask-user finding for that project -
including destructive, irreversible, and genuinely security-sensitive ones -
is classified by the unchanged `ask-user-authority` procedure and then
auto-decided with a recorded recommendation instead of escalating.
This is a standing, explicit exception the boss made once, for this feature,
to the "yolo never overrides the stronger boundaries" rule; it does not
generalize to any other rule consigliere applies to itself.
Merge is never included: the PR-merge gate is untouched, and it becomes the
only remaining checkpoint for that project's work while this mode is active.
The moment away mode ends, the project reverts to today's narrower yolo
behavior - routine auto-decide only, stronger-boundary findings escalate live
again - and any decision already auto-recorded stays as recorded, never
retroactively re-opened.
A capo never independently enters this mode; it has no away-mode state of its
own.
The decision is always made by whichever home currently owns the finding
under the unchanged `ask-user-authority` procedure - a capo for its own
soldiers, main consigliere for its own - and what changes is only the
terminal action that home takes once its own `state/.afk` is the active one:
for a capo-nested finding relayed to main, main decides at the moment it
would otherwise relay to the boss.
Every auto-decision is durably recorded and attached to the resulting PR
(`bin/cs-auto-decision-lib.sh`) - the boss reviews it there, not live.
The first time this mode would engage for a given project in a session,
`bin/cs-afk-start.sh` names it explicitly and requires a one-time durable
acknowledgment before applying it (see that script's own header for the exact
mechanism and its kill-switch override).

## Operational-input contract

`bin/cs-operational-input.sh` constructs `bin/cs-activate.sh`'s activation
prompt with the `away-supervisor` kind, unconditionally - the same marking
applies whether or not `state/.afk` is set, since the prompt is always a
machine nudge, never the boss.
The wire retains `CS_INJECT_MARK`, a bare leading U+2063 INVISIBLE SEPARATOR
that no normal keyboard produces and herdr transports as UTF-8 text, then adds
the versioned kind header before the body.
The byte-compatible `from-consigliere` form instead begins with its visible
label before U+2063, so the two cannot conflate.

## Triage, delivery, and the wedge alarm

One triage engine, always active: `bin/cs-watch.sh` absorbs benign wakes and
enqueues actionable ones the same way regardless of `state/.afk` - see
`docs/supervision.md` for the full classification policy (boss-relevant verbs,
declared-pause handling, the stale/wedge escalation ladder). There is no
separate away-mode classification or batched digest anymore: a queued wake is
delivered by `bin/cs-activate.sh` prompting this home's own agent to run
`bin/cs-wake-drain.sh` and handle whatever it reports - raw drain output plus
annotations, not one curated sentence.

Delivery shares the same busy-guard and composer guard every guarded-prompt
caller uses (`bin/cs-prompt-lib.sh`'s `cs_prompt_guarded`): herdr's native
agent state must not read `busy` or `blocked`, and the agent composer
(`bin/cs-composer-lib.sh`) must classify affirmatively `empty` before anything
is typed into the pane. Either guard failing defers delivery; the queue is
durable, so nothing is lost.

A continuous failing-delivery stretch past `CS_ACTIVATE_WEDGE_MAX_SECS`
(default 300) fires the wedge alarm exactly once per stretch: a durable
`state/.subsuper-inject-wedged` marker (surfaced by the return catch-up) and a
configurable active alert (`config/wedge-alarm.conf`: `off`, `auto`,
`osascript`, `herdr`, or `command:<cmd>`; absent means auto, a macOS
Notification Center banner, so the alarm is never silent). `bin/cs-activate.sh`
also retries a failing delivery on a much shorter floor
(`CS_ACTIVATE_RETRY_SECS`, default 15) than its ordinary 600s success cooldown,
and fires its own busy-stretch trigger (`CS_ACTIVATE_BUSY_MAX_SECS`, default
300) for a queue that keeps refilling faster than it ever goes quiet. See that
script's own header and `docs/configuration.md` for the complete mechanism.

## Stale-artifact lifecycle

Treat `state/.subsuper-escalations`, its `.since` sidecar, and
`state/.subsuper-inject-wedged` as session-scoped delivery artifacts, not the
durable work record. Enter through `bin/cs-afk-start.sh`, which clears
prior-session artifacts only on a fresh entry and preserves the current
session's buffer on refresh. Exit through `bin/cs-afk-return.sh`, which prints
the surviving buffer as catch-up evidence before clearing the artifacts.

## Reliability properties

These properties must hold:

- Nothing is lost. The durable queue plus `bin/cs-wake-drain.sh` recover any
  missed or crashed delivery.
- Wedge detection is bounded-latency, not lossy.
- Declared external waits are rechecked on a separate, bounded cadence rather
  than being mislabeled as wedges.
- The watcher's fleet-scan heartbeat backs up the per-wake classifier.
