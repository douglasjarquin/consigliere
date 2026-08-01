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
#       starts bin/cs-daemon.sh DETACHED through bin/cs-detach.py, then checks
#       it came up (daemon lock held by a live pid). A daemon that never comes
#       up rolls back state/.afk and exits non-zero.
#
# Coming up is NOT being armed. This script cannot certify away mode, because
# it runs inside the agent tool call that launched the daemon and therefore
# cannot observe a death caused by that call's own teardown - the failure that
# cost five away sessions. bin/cs-afk-verify.sh, run as a SEPARATE later step,
# is what arms away mode or rolls it back. This one always says "not yet
# certified" on success.
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
CS_AFK_DETACH="${CS_AFK_DETACH:-$CS_AFK_START_DIR/cs-detach.py}"

# shellcheck source=bin/cs-wake-lib.sh
. "$CS_AFK_START_DIR/cs-wake-lib.sh"

cs_afk_start_usage() {
  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
        "$state/.subsuper-inject-wedged" 2>/dev/null
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

# The daemon's completed-pass counter, or empty when it has written none.
# bin/cs-daemon.sh owns the file's contract; only a CHANGED value proves a pass.
# "Not written yet" is the normal state for the first second of a daemon's life
# and must read as empty, not as an error: under `set -e` a failed redirect here
# would abort the caller mid-certification.
cs_afk_daemon_beat() {
  local beat="$CS_AFK_STATE/.subsuper-daemon-beat"
  [ -r "$beat" ] || return 0
  tr -dc '0-9' < "$beat" 2>/dev/null || true
}

# Stop a daemon that could not be certified. Leaving a wedged one holding the
# lock would make every later arm take the refresh path and report success.
cs_afk_daemon_stop_uncertified() {
  local owner pid
  owner=$(cs_afk_daemon_lock_owner) || return 0
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  cs_pid_alive "$pid" || return 0
  cs_afk_daemon_pid_matches "$pid" "$owner" || return 0
  kill "$pid" 2>/dev/null || true
  local i=0
  while [ "$i" -lt 50 ]; do
    cs_pid_alive "$pid" || return 0
    sleep 0.1
    i=$((i + 1))
  done
  kill -9 "$pid" 2>/dev/null || true
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
    # A refresh is still an arm, so it gets the same certification the fresh
    # path does. Trusting a live pid here was its own instance of the bug this
    # file exists to close: a daemon wedged off its loop kept every later /afk
    # reporting success while nothing supervised.
    echo "afk: daemon already running pid=$pid; certify it with cs-afk-verify.sh before walking away"
    return 0
  fi

  # A dead holder's lock is stale; remove it so the fresh daemon can claim.
  if [ -n "$pid" ] && ! cs_pid_alive "$pid"; then
    cs_lock_remove_path "$CS_AFK_LOCK" 2>/dev/null || true
  fi

  # Fresh start: clear the previous away session's stale delivery artifacts
  # before the new daemon can surface them.
  cs_afk_clear_stale_artifacts "$CS_AFK_STATE"

  # Start the daemon in its OWN session, not merely immune to SIGHUP.
  #
  # THIS IS THE BUG THAT COST FIVE AWAY SESSIONS. `nohup ... & disown` does not
  # survive teardown of the launching process group, and cs-afk-start.sh always
  # runs inside an agent's bounded tool call - precisely such a group. The
  # daemon was killed with the tool call, seconds after arming, every time: no
  # `daemon shutting down` line because the TERM handler never ran, and
  # .subsuper-last-housekeep never written because it died inside pass one. The
  # scratch-home reproduction looked healthy because a plain shell has no tool
  # call to tear down.
  #
  # bin/cs-detach.py double-forks through setsid(2) and already fixed exactly
  # this for the persistent monitor (bin/cs-watch-checkpoint.sh); the away
  # daemon was simply never moved over. Same fallback rule as the monitor: if
  # python3 is missing, the old launch is degraded, not absent - and the
  # out-of-band certification in bin/cs-afk-verify.sh is what catches the
  # degraded case rather than letting it arm silently.
  if [ -x "$CS_AFK_DETACH" ] && command -v python3 >/dev/null 2>&1; then
    python3 "$CS_AFK_DETACH" --stdout "$CS_AFK_STATE/.subsuper-daemon.err" \
      -- "$CS_AFK_DAEMON" "$HERDR_PANE_ID" >/dev/null 2>&1
  else
    nohup "$CS_AFK_DAEMON" "$HERDR_PANE_ID" \
      >> "$CS_AFK_STATE/.subsuper-daemon.err" 2>&1 &
    disown 2>/dev/null || true
  fi

  # The daemon must at least come up. This is a startup check, NOT the
  # certification: it runs in the same process group that launched the daemon,
  # so it cannot see a death caused by that group's teardown. Away mode is not
  # armed until bin/cs-afk-verify.sh says so from a later, separate call.
  local i=0
  while [ "$i" -lt "${CS_AFK_START_WAIT_TICKS:-50}" ]; do
    if cs_afk_daemon_alive; then
      pid=$(cs_afk_daemon_lock_pid 2>/dev/null || true)
      echo "afk: daemon started pid=$pid, target pane $HERDR_PANE_ID; NOT yet certified - run cs-afk-verify.sh as a separate step before walking away"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  rm -f "$CS_AFK_STATE/.afk"
  echo "error: daemon did not come alive; away mode rolled back (see $CS_AFK_STATE/.subsuper-daemon.err and $CS_AFK_STATE/.subsuper-daemon.log)" >&2
  return 1
}

# Run only when executed, not when sourced (tests source the helpers).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cs_afk_start_main "$@"
fi
