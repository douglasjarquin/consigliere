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
# SCOPE (host/activation.conf):
#   always    - activate whenever the queue has sat. THE DEFAULT, everywhere.
#   afk-only  - activate only while state/.afk is present.
#   off       - never.
# Absent = always.
#
# The main home was afk-only until 2026-08-11, because it is the pane the boss
# types into and the composer guard is check-then-act: a prompt can still land in
# a composer if the boss starts typing between the check and the send. The boss
# accepted that race, because the alternative turned out to be worse. Turns now
# END rather than re-arming a checkpoint forever (bin/cs-watch-checkpoint.sh), so
# an unattended queue in an afk-only main home would simply sit until the boss
# next typed - and a thread that cannot hear the boss is what this whole change
# exists to fix. The residual cost is a mangled draft, recoverable by clearing
# the composer. What remains asymmetric is the QUIET window below, which is
# longer in the pane a human uses so the check-then-act window is entered less
# often.
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
# BUSY-STRETCH TRIGGER. The queue-quiet check above waits for the queue to go
# still, but a queue that keeps refilling faster than QUIET never goes still -
# exactly the busiest stretch this exists to cover. state/.activate-busy-since
# tracks continuous non-emptiness (stamped once when first seen non-empty,
# cleared the moment it's seen empty) so a second, independent trigger -
# CS_ACTIVATE_BUSY_MAX_SECS of continuous business, regardless of quietness -
# fires activation anyway. Either trigger is sufficient.
#
# FAIL-VS-SUCCESS COOLDOWN. The 600s cooldown exists to avoid over-prompting a
# pane that is already healthily handling what it was told to do - that
# reasoning does not apply to a FAILED delivery, where nothing was actually
# communicated. state/.activate-fail-since tracks a continuous failing stretch
# (stamped on the first failure, cleared on success or an empty queue) and
# while it exists, the floor between attempts is the much shorter
# CS_ACTIVATE_RETRY_SECS instead of the full cooldown. Once continuous failure
# crosses CS_ACTIVATE_WEDGE_MAX_SECS, the wedge alarm (bin/cs-prompt-lib.sh,
# ported from the retired away-mode daemon) fires once per stretch and
# state/.subsuper-inject-wedged is written for bin/cs-afk-return.sh's existing
# catch-up evidence to read.
#
# Env:
#   CS_ACTIVATE_QUIET_SECS      queue must have been still this long (default 180
#                               in the main home, 60 in a capo home)
#   CS_ACTIVATE_COOLDOWN_SECS   min seconds between activations after a SUCCESS (default 600)
#   CS_ACTIVATE_BUSY_MAX_SECS   fire anyway after this much continuous business (default 300)
#   CS_ACTIVATE_RETRY_SECS      min seconds between attempts while FAILING (default 15)
#   CS_ACTIVATE_WEDGE_MAX_SECS  continuous failure age that fires the wedge alarm (default 300)
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
# cs_root_is_capo_home, for the quiet-window asymmetry below.
# shellcheck source=bin/cs-primary-scope-lib.sh
. "$SCRIPT_DIR/cs-primary-scope-lib.sh"

# Nobody types into a capo pane, so its queue can be picked up as soon as it
# settles. The main home is the pane the boss uses, so it waits longer: every
# second of quiet is a second the check-then-act composer race is not entered.
QUIET_DEFAULT=180
cs_root_is_capo_home "$CS_HOME" && QUIET_DEFAULT=60
QUIET=${CS_ACTIVATE_QUIET_SECS:-$QUIET_DEFAULT}
case "$QUIET" in ''|*[!0-9]*) QUIET=$QUIET_DEFAULT ;; esac
COOLDOWN=${CS_ACTIVATE_COOLDOWN_SECS:-600}
case "$COOLDOWN" in ''|*[!0-9]*) COOLDOWN=600 ;; esac
BUSY_MAX=${CS_ACTIVATE_BUSY_MAX_SECS:-300}
case "$BUSY_MAX" in ''|*[!0-9]*) BUSY_MAX=300 ;; esac
RETRY_SECS=${CS_ACTIVATE_RETRY_SECS:-15}
case "$RETRY_SECS" in ''|*[!0-9]*) RETRY_SECS=15 ;; esac
WEDGE_MAX=${CS_ACTIVATE_WEDGE_MAX_SECS:-300}
case "$WEDGE_MAX" in ''|*[!0-9]*) WEDGE_MAX=300 ;; esac

QUEUE="$STATE/.wake-queue"
LAST="$STATE/.last-activation"
BUSY_SINCE="$STATE/.activate-busy-since"
FAIL_SINCE="$STATE/.activate-fail-since"
WEDGED="$STATE/.subsuper-inject-wedged"
PANE_RECORD="$STATE/.home-pane"
STALLED="$STATE/.activation-stalled"
LOG="$STATE/.monitor.log"

STATUS_ONLY=0
case "${1:-}" in
  '') ;;
  --status) STATUS_ONLY=1 ;;
  -h|--help) sed -n '2,74p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: cs-activate.sh [--status]" >&2; exit 2 ;;
esac

log() { printf '[%s] activate: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG" 2>/dev/null || true; }
decision() { [ "$STATUS_ONLY" = 1 ] && printf '%s\n' "$1"; return 0; }

# --- scope ------------------------------------------------------------------

mode=always
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

if [ ! -s "$QUEUE" ]; then
  rm -f "$BUSY_SINCE" "$FAIL_SINCE" "$WEDGED" 2>/dev/null || true
  decision "idle: wake queue empty"
  exit 0
fi
if [ "$STATUS_ONLY" = 1 ]; then
  [ -f "$BUSY_SINCE" ] && busy_age=$(cs_path_age "$BUSY_SINCE") || busy_age=0
else
  [ -f "$BUSY_SINCE" ] || : > "$BUSY_SINCE"
  busy_age=$(cs_path_age "$BUSY_SINCE")
fi
case "$busy_age" in ''|*[!0-9]*) busy_age=0 ;; esac
queue_age=$(cs_path_age "$QUEUE")
case "$queue_age" in ''|*[!0-9]*) queue_age=0 ;; esac
if [ "$queue_age" -lt "$QUIET" ] && [ "$busy_age" -lt "$BUSY_MAX" ]; then
  # Still arriving, and not yet busy long enough to fire anyway. One burst of
  # wakes from one event should produce one turn, not one per wake - but a
  # queue that keeps refilling faster than QUIET must not starve forever.
  decision "idle: queue still settling (${queue_age}s < ${QUIET}s, busy ${busy_age}s < ${BUSY_MAX}s)"
  exit 0
fi

# --- cooldown, which is also the recursion guard -----------------------------
# The turn this starts will drain the queue and may append more wakes. Without a
# floor between activations that is a loop that feeds itself. While the last
# attempt failed, that floor is the much shorter RETRY_SECS instead - a failed
# delivery communicated nothing, so the healthy-pane reasoning behind the long
# cooldown does not apply.
floor=$COOLDOWN
[ -f "$FAIL_SINCE" ] && floor=$RETRY_SECS
if [ -e "$LAST" ]; then
  last_age=$(cs_path_age "$LAST")
  case "$last_age" in ''|*[!0-9]*) last_age=999999 ;; esac
  if [ "$last_age" -lt "$floor" ]; then
    decision "idle: attempted ${last_age}s ago (floor ${floor}s)"
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
# Stamp BEFORE prompting. A prompt that half-lands must still spend at least
# the (possibly shortened, see floor above) interval; retrying a
# possibly-delivered activation every cycle is worse than waiting one.
: > "$LAST"

body="Your wake queue has been unattended for ${queue_age}s. Drain it with bin/cs-wake-drain.sh and handle what it reports, under the ordinary supervision protocol. This is automated activation, not the boss: do not merge anything, do not answer an ask-user finding, and take no destructive, irreversible, or security-sensitive action."
msg=$("$SCRIPT_DIR/cs-operational-input.sh" encode away-supervisor <<EOF
$body
EOF
) || { log "could not encode the activation prompt"; exit 0; }

if cs_prompt_guarded "$pane" "$msg" log; then
  log "activated '$pane' after ${queue_age}s of queued work (mode=$mode)"
  rm -f "$FAIL_SINCE" "$WEDGED" 2>/dev/null || true
  exit 0
fi

# Deferred or unconfirmed: the queue is durable, so nothing is lost and the
# next attempt (per the shortened RETRY_SECS floor above) tries again.
log "activation not delivered this cycle; queue remains for the next attempt"
[ -f "$FAIL_SINCE" ] || : > "$FAIL_SINCE"
fail_age=$(cs_path_age "$FAIL_SINCE")
case "$fail_age" in ''|*[!0-9]*) fail_age=0 ;; esac
if [ "$fail_age" -ge "$WEDGE_MAX" ] && [ ! -e "$WEDGED" ]; then
  {
    printf 'cs activate WEDGED: %ss undelivered as of %s\n' "$fail_age" "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf "'%s' could not accept an activation prompt (queue has %ss of unattended work).\n" "$pane" "$queue_age"
  } > "$WEDGED" 2>/dev/null || true
  cs_wedge_alarm_notify log "consigliere: activation WEDGED" \
    "'$pane' has not accepted an activation prompt for ${fail_age}s (queue has ${queue_age}s of unattended work) - see $WEDGED"
fi
exit 0
