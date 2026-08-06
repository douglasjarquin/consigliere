#!/usr/bin/env bash
# cs-activate.sh - make THIS home's own agent take a turn when its wake queue
# has sat unattended. The single owner of per-home activation policy.
#
# WHY THIS EXISTS. Watchers, monitors, and the away daemon can all OBSERVE, but
# only an agent can ACT, and an agent acts only when something starts a turn.
# Until now the only thing that started a turn in a capo home was the PARENT
# consigliere injecting into the capo's pane. So when the parent froze on
# 2026-08-01, both capo homes kept their watchers and monitors perfectly healthy,
# correctly queued 28 wakes between them, and drained exactly none of it for
# 8h11m. The observing half already works per-home; only activation was missing.
#
# This closes that by removing the parent from the loop: a home's own monitor
# calls this, and this prompts the home's own agent. No cross-home injection, and
# no session-lock change - the agent taking the turn is the pane's own agent,
# which already holds this home's lock.
#
# SCOPE IS DELIBERATELY ASYMMETRIC (host/activation.conf):
#   always    - activate whenever the queue has sat. The default for CAPO homes,
#               whose queues rot any time the parent is busy, not just overnight.
#   afk-only  - activate only while state/.afk is present. The default EVERYWHERE
#               ELSE, and specifically for the main home, because that is the pane
#               the boss actually types in: the composer guard is check-then-act,
#               so an always-on prompt into a pane a human is using has an
#               inherent race, and presence-gating is what removes it.
#   off       - never.
# Absent = afk-only. The safe direction is to do nothing.
#
# WHAT IT NEVER DOES. It starts a turn; it does not decide anything. The prompted
# turn is bound by the same approval boundaries as away mode: no merging, no
# answering ask-user findings, nothing destructive, irreversible, or
# security-sensitive. Those live in the agent's own contract, not here.
#
# Usage:
#   cs-activate.sh            evaluate this home and activate if due
#   cs-activate.sh --status   print the decision without acting
#
# Exit 0 whether or not it activated: "not due" is the normal case and must not
# look like a failure to the monitor that calls it every cycle.
#
# Env:
#   CS_ACTIVATE_QUIET_SECS      queue must have been still this long (default 60)
#   CS_ACTIVATE_COOLDOWN_SECS   min seconds between activations (default 600)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
# shellcheck source=bin/cs-wake-lib.sh
. "$SCRIPT_DIR/cs-wake-lib.sh"
# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-composer-lib.sh
. "$SCRIPT_DIR/cs-composer-lib.sh"
# shellcheck source=bin/cs-prompt-lib.sh
. "$SCRIPT_DIR/cs-prompt-lib.sh"

QUIET=${CS_ACTIVATE_QUIET_SECS:-60}
case "$QUIET" in ''|*[!0-9]*) QUIET=60 ;; esac
COOLDOWN=${CS_ACTIVATE_COOLDOWN_SECS:-600}
case "$COOLDOWN" in ''|*[!0-9]*) COOLDOWN=600 ;; esac

QUEUE="$STATE/.wake-queue"
LAST="$STATE/.last-activation"
PANE_RECORD="$STATE/.home-pane"
STALLED="$STATE/.activation-stalled"
LOG="$STATE/.monitor.log"

STATUS_ONLY=0
case "${1:-}" in
  '') ;;
  --status) STATUS_ONLY=1 ;;
  -h|--help) sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: cs-activate.sh [--status]" >&2; exit 2 ;;
esac

log() { printf '[%s] activate: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG" 2>/dev/null || true; }
decision() { [ "$STATUS_ONLY" = 1 ] && printf '%s\n' "$1"; return 0; }

# --- scope ------------------------------------------------------------------

mode=afk-only
if [ -f "$HOST_DIR/activation.conf" ]; then
  mode=$(awk 'NF && $0 !~ /^[[:space:]]*#/ { gsub(/[[:space:]]/, "", $0); print; exit }' "$HOST_DIR/activation.conf")
fi
case "$mode" in
  always|afk-only|off) ;;
  *) decision "refuse: host/activation.conf is '${mode:-<empty>}', expected always|afk-only|off"; exit 0 ;;
esac
[ "$mode" != off ] || { decision "off: activation disabled for this home"; exit 0; }
if [ "$mode" = afk-only ] && [ ! -e "$STATE/.afk" ]; then
  decision "idle: afk-only and the boss is present"
  exit 0
fi

# --- is there work sitting? --------------------------------------------------

[ -s "$QUEUE" ] || { decision "idle: wake queue empty"; exit 0; }
queue_age=$(cs_path_age "$QUEUE")
case "$queue_age" in ''|*[!0-9]*) queue_age=0 ;; esac
if [ "$queue_age" -lt "$QUIET" ]; then
  # Still arriving. One burst of wakes from one event should produce one turn,
  # not one per wake.
  decision "idle: queue still settling (${queue_age}s < ${QUIET}s)"
  exit 0
fi

# --- cooldown, which is also the recursion guard -----------------------------
# The turn this starts will drain the queue and may append more wakes. Without a
# floor between activations that is a loop that feeds itself.
if [ -e "$LAST" ]; then
  last_age=$(cs_path_age "$LAST")
  case "$last_age" in ''|*[!0-9]*) last_age=999999 ;; esac
  if [ "$last_age" -lt "$COOLDOWN" ]; then
    decision "idle: activated ${last_age}s ago (cooldown ${COOLDOWN}s)"
    exit 0
  fi
fi

# --- resolve and REVALIDATE the target ---------------------------------------
# A recorded pane id is a durable hint, never an identity: herdr ids are
# recycled across restarts, and prompting a recycled id would drop supervision
# text into whatever now owns it - a soldier mid-implementation, which would act
# on it. So the record must still name a pane that exists, still runs an agent,
# and is still rooted in THIS home.
if [ ! -f "$PANE_RECORD" ]; then
  decision "refuse: no recorded home pane ($PANE_RECORD); session start records it"
  exit 0
fi
pane=$(tr -dc 'A-Za-z0-9:_-' < "$PANE_RECORD" 2>/dev/null)
[ -n "$pane" ] || { decision "refuse: recorded home pane is empty"; exit 0; }

pane_json=$(cs_herdr pane get "$pane" 2>/dev/null) || pane_json=
if [ -z "$pane_json" ]; then
  log "target pane '$pane' is gone; not prompting"
  decision "blocked: recorded pane '$pane' no longer exists"
  : > "$STALLED"
  exit 0
fi
pane_cwd=$(printf '%s' "$pane_json" | jq -r '.result.pane.cwd // empty' 2>/dev/null)
if [ -n "$pane_cwd" ] && [ "$pane_cwd" != "$CS_HOME" ]; then
  log "target pane '$pane' now roots at '$pane_cwd', not this home ('$CS_HOME'); refusing to prompt a recycled id"
  decision "blocked: recorded pane '$pane' belongs to another home now"
  : > "$STALLED"
  exit 0
fi
agent_kind=$(cs_herdr agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent // empty' 2>/dev/null)
if [ -z "$agent_kind" ]; then
  # A home whose agent died would otherwise rot in exactly the way this script
  # exists to prevent, and with the parent removed from the loop nobody else is
  # watching. Leave a durable marker so it surfaces instead of going quiet.
  log "no agent in target pane '$pane'; this home cannot self-activate"
  decision "blocked: no agent in '$pane' - the home needs recovery"
  : > "$STALLED"
  exit 0
fi
rm -f "$STALLED" 2>/dev/null || true

[ "$STATUS_ONLY" = 0 ] || { decision "due: would prompt '$pane' (${queue_age}s of queued work)"; exit 0; }

# --- activate ----------------------------------------------------------------
# Stamp BEFORE prompting. A prompt that half-lands must still spend the
# cooldown; retrying a possibly-delivered activation every cycle is worse than
# waiting one interval.
: > "$LAST"

body="Your wake queue has been unattended for ${queue_age}s. Drain it with bin/cs-wake-drain.sh and handle what it reports, under the ordinary supervision protocol. This is automated activation, not the boss: do not merge anything, do not answer an ask-user finding, and take no destructive, irreversible, or security-sensitive action."
msg=$("$SCRIPT_DIR/cs-operational-input.sh" encode away-supervisor <<EOF
$body
EOF
) || { log "could not encode the activation prompt"; exit 0; }

if cs_prompt_guarded "$pane" "$msg" log; then
  log "activated '$pane' after ${queue_age}s of queued work (mode=$mode)"
else
  # Deferred or unconfirmed: the queue is durable, so nothing is lost and the
  # next cycle past the cooldown tries again.
  log "activation not delivered this cycle; queue remains for the next attempt"
fi
exit 0
