#!/usr/bin/env bash
# bin/cs-afk-start.sh - enter away mode and start the sub-supervisor daemon.
#
# Usage: cs-afk-start.sh
#   Must run inside consigliere's own herdr pane (HERDR_PANE_ID set); refuses
#   otherwise, because that pane id IS the daemon's injection target. Then:
#     - writes the durable away-mode flag state/.afk;
#     - records the supervisor pane id in state/.subsuper-target;
#     - if the daemon lock is already held by a live daemon, prints
#       "afk: daemon already running pid=<pid>" and exits 0 (a REFRESH: the
#       current session's buffered escalations are preserved);
#     - otherwise clears the PRIOR away session's stale delivery artifacts and
#       starts bin/cs-daemon.sh nohup'd headless, then certifies it in TWO
#       steps: the daemon lock must be held by a live pid, AND the daemon's
#       pass counter (state/.subsuper-daemon-beat) must then ADVANCE. A daemon
#       that fails either step is stopped, state/.afk is rolled back, and this
#       exits non-zero, so away mode is never armed without its engine.
#
# Why two steps: a live pid only proves the process started. Every recorded
# arm passed that check and then died before finishing one loop pass, which
# left the flag up and the home unwatched for the whole night. Only an advancing
# counter proves the daemon came back around its loop and is really supervising.
#
# This file is sourceable: the BASH_SOURCE guard keeps main from running while
# exposing the lock helpers and cs_afk_clear_stale_artifacts for tests.
#
# Stale-artifact lifecycle: state/.subsuper-escalations, its .since sidecar,
# and state/.subsuper-inject-wedged are session-scoped delivery artifacts, not
# the durable work record. A FRESH entry clears them (anything still true is
# re-derived by the daemon's heartbeat catch-all and the durable wake-queue
# replay); a refresh never does.
set -eu

CS_AFK_START_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$CS_AFK_START_DIR/cs-root-lib.sh"
cs_resolve_root
CS_AFK_STATE="$STATE"
CS_AFK_LOCK="$CS_AFK_STATE/.subsuper-daemon.lock"
CS_AFK_DAEMON="${CS_AFK_DAEMON:-$CS_AFK_START_DIR/cs-daemon.sh}"

# shellcheck source=bin/cs-wake-lib.sh
. "$CS_AFK_START_DIR/cs-wake-lib.sh"

cs_afk_start_usage() {
  sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# cs_afk_clear_stale_artifacts: on a FRESH away-session entry, drop the
# previous session's leftover escalation-delivery artifacts so they cannot
# surface as stale escalations under the new session. Never drops genuinely
# pending work: the buffer is a transient delivery cache, and any condition
# still true (a soldier still blocked, a check still firing) is re-derived by
# the new daemon's catch-all scan and the durable wake-queue replay.
cs_afk_clear_stale_artifacts() {  # <state-dir>
  local state=$1
  rm -f "$state/.subsuper-escalations" \
        "$state/.subsuper-escalations.since" \
        "$state/.subsuper-inject-wedged" \
        "$state/.subsuper-daemon-beat" 2>/dev/null
}

cs_afk_daemon_lock_owner() {
  local owner
  if [ -L "$CS_AFK_LOCK" ]; then
    owner=$(readlink "$CS_AFK_LOCK" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) printf '%s\n' "$owner" ;;
      *) printf '%s/%s\n' "$(dirname "$CS_AFK_LOCK")" "$owner" ;;
    esac
    return 0
  fi
  [ -d "$CS_AFK_LOCK" ] || return 1
  printf '%s\n' "$CS_AFK_LOCK"
}

cs_afk_daemon_pid_matches() {  # <pid> <owner-dir>
  local pid=$1 owner=$2 identity current command
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    current=$(cs_pid_identity "$pid") || return 1
    [ "$current" = "$identity" ]
    return
  fi
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$CS_AFK_DAEMON"*|*"cs-daemon.sh"*) return 0 ;;
  esac
  return 1
}

cs_afk_daemon_lock_pid() {
  local owner
  owner=$(cs_afk_daemon_lock_owner) || return 1
  cat "$owner/pid" 2>/dev/null || true
}

cs_afk_daemon_alive() {
  local owner pid
  owner=$(cs_afk_daemon_lock_owner) || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  cs_pid_alive "$pid" || return 1
  cs_afk_daemon_pid_matches "$pid" "$owner"
}

# The daemon's pass counter, or empty when it has not written one yet. A
# CHANGED value is the only evidence that a full supervision pass completed;
# bin/cs-daemon.sh owns the file's contract.
cs_afk_daemon_beat() {
  cat "$CS_AFK_STATE/.subsuper-daemon-beat" 2>/dev/null | tr -dc '0-9'
}

# Roll back a daemon this arm started but could not certify. Leaving a wedged
# daemon holding the lock would make every later arm report "already running"
# and re-enter the same silent gap.
cs_afk_daemon_stop_started() {
  local owner pid
  owner=$(cs_afk_daemon_lock_owner) || return 0
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  cs_pid_alive "$pid" || return 0
  cs_afk_daemon_pid_matches "$pid" "$owner" || return 0
  kill "$pid" 2>/dev/null || true
}

cs_afk_start_main() {
  case "${1:-}" in
    '' ) ;;
    -h|--help) cs_afk_start_usage; return 0 ;;
    * ) echo "usage: $(basename "${BASH_SOURCE[0]}")" >&2; return 2 ;;
  esac

  # The daemon injects into the pane consigliere itself runs in; only the
  # herdr pane env proves where that is. Refuse anywhere else rather than
  # guessing an injection target.
  if [ -z "${HERDR_PANE_ID:-}" ]; then
    echo "error: not inside a herdr pane (HERDR_PANE_ID is unset); run cs-afk-start.sh from consigliere's own pane so the daemon knows its injection target" >&2
    return 1
  fi

  mkdir -p "$CS_AFK_STATE"
  date '+%s' > "$CS_AFK_STATE/.afk"
  printf '%s\n' "$HERDR_PANE_ID" > "$CS_AFK_STATE/.subsuper-target"

  local pid
  pid=$(cs_afk_daemon_lock_pid 2>/dev/null || true)
  if cs_afk_daemon_alive; then
    echo "afk: daemon already running pid=$pid"
    return 0
  fi

  # A dead holder's lock is stale; remove it so the fresh daemon can claim.
  if [ -n "$pid" ] && ! cs_pid_alive "$pid"; then
    cs_lock_remove_path "$CS_AFK_LOCK" 2>/dev/null || true
  fi

  # Fresh start: clear the previous away session's stale delivery artifacts
  # before the new daemon can surface them.
  cs_afk_clear_stale_artifacts "$CS_AFK_STATE"

  nohup "$CS_AFK_DAEMON" "$HERDR_PANE_ID" \
    >> "$CS_AFK_STATE/.subsuper-daemon.err" 2>&1 &
  disown 2>/dev/null || true

  # Verify the daemon came alive: its lock must be held by a live pid within
  # the startup window. Fail closed - away mode without its engine is a
  # silent supervision gap, so roll the flag back.
  local i=0
  local came_alive=0
  while [ "$i" -lt "${CS_AFK_START_WAIT_TICKS:-50}" ]; do
    if cs_afk_daemon_alive; then
      came_alive=1
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if [ "$came_alive" -eq 1 ]; then
    # Alive is not the same as supervising. Every recorded arm passed this
    # check and then died before finishing one loop pass, leaving the flag up
    # and the home unwatched all night. Require PROOF OF A COMPLETED PASS: the
    # daemon's beat counter must advance at least once, which it can only do by
    # coming back around the loop.
    local first second
    first=$(cs_afk_daemon_beat)
    i=0
    while [ "$i" -lt "${CS_AFK_START_PASS_WAIT_TICKS:-100}" ]; do
      second=$(cs_afk_daemon_beat)
      if [ -n "$second" ] && [ -n "$first" ] && [ "$second" != "$first" ] && cs_afk_daemon_alive; then
        pid=$(cs_afk_daemon_lock_pid 2>/dev/null || true)
        echo "afk: away mode armed; daemon running pid=$pid (completed pass $second), injecting into pane $HERDR_PANE_ID"
        return 0
      fi
      [ -n "$first" ] || first=$second
      sleep 0.1
      i=$((i + 1))
    done
  fi
  rm -f "$CS_AFK_STATE/.afk"
  cs_afk_daemon_stop_started
  if [ "$came_alive" -eq 1 ]; then
    echo "error: daemon started but never completed a supervision pass; away mode rolled back (see $CS_AFK_STATE/.subsuper-daemon.err and $CS_AFK_STATE/.subsuper-daemon.log)" >&2
  else
    echo "error: daemon did not come alive; away mode rolled back (see $CS_AFK_STATE/.subsuper-daemon.err and $CS_AFK_STATE/.subsuper-daemon.log)" >&2
  fi
  return 1
}

# Run only when executed, not when sourced (tests source the helpers).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cs_afk_start_main "$@"
fi
