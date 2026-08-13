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
#
# Bossless acknowledgment / kill switch (config/bossless-ack.md):
#   Usage: cs-afk-start.sh ack <project>
#   Records a durable, boss-private, one-time acknowledgment that <project>
#   (a name under this home's projects/, e.g. "myrepo") runs fully bossless
#   for as long as its own yolo+afk condition holds (cs_bossless_active,
#   bin/cs-auto-decision-lib.sh). Entry (arming away mode) is NEVER blocked
#   by a missing acknowledgment; only that project's bossless auto-decide
#   stays off (narrower yolo behavior) until acknowledged. Once acknowledged,
#   later /afk entries never re-prompt for that project.
#   File format: one record per line, `<project> <status>[ <epoch>]`, status
#   is `acknowledged` (written by the `ack` subcommand, with the epoch it was
#   recorded) or `disabled` (the kill switch - a plain config-level hand-edit,
#   no epoch needed, no subcommand required). The LAST record for a project
#   wins, so appending a fresh line is how either state changes; the file is
#   never rewritten in place. Blank lines and `#` comments are ignored.
#   Fails closed as a WHOLE FILE: if any non-blank, non-comment line does not
#   parse as `<project> <status>[ <epoch>]` with a recognized status, or the
#   file exists but is unreadable, every project reads as unacknowledged
#   (narrower yolo behavior) rather than trusting a partially-corrupt file.
#   cs_bossless_ack_status is the one query function; cs_afk_bossless_unacked_projects
#   is what a fresh entry uses to name unacknowledged projects with live or
#   pending yolo=on ship work in THIS home (scanned from state/*.meta, never
#   from config/projects.md's advisory-only posture).
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
# shellcheck source=bin/cs-meta-lib.sh
. "$CS_AFK_START_DIR/cs-meta-lib.sh"

CS_BOSSLESS_ACK_FILE="${CS_BOSSLESS_ACK_OVERRIDE:-$CS_HOME/config/bossless-ack.md}"

cs_afk_start_usage() {
  sed -n '2,55p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# The last recorded status for <project> in the bossless-ack file:
# acknowledged|disabled|unacknowledged. Fails closed to "unacknowledged" for
# EVERY project the moment any line in the file fails to parse, or the file
# exists but cannot be read - a partially-corrupt file must never be trusted
# for the records that DID parse.
cs_bossless_ack_status() {  # <project>
  local project=$1 file=$CS_BOSSLESS_ACK_FILE line p status epoch result=unacknowledged
  [ -e "$file" ] || { printf 'unacknowledged'; return 0; }
  [ -f "$file" ] && [ -r "$file" ] || { printf 'unacknowledged'; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    # shellcheck disable=SC2086  # deliberate word split: exactly 2 or 3 tokens
    set -- $line
    p=${1:-}; status=${2:-}; epoch=${3:-}
    case "$#" in 2|3) ;; *) printf 'unacknowledged'; return 0 ;; esac
    case "$status" in
      acknowledged|disabled) ;;
      *) printf 'unacknowledged'; return 0 ;;
    esac
    if [ -n "${epoch:-}" ]; then
      case "$epoch" in *[!0-9]*) printf 'unacknowledged'; return 0 ;; esac
    fi
    [ "$p" = "$project" ] && result=$status
  done < "$file"
  printf '%s' "$result"
}

# Append a durable acknowledgment for <project>. Idempotent by construction:
# the file is append-only and the LAST record wins, so acknowledging twice is
# harmless, and this never touches any other project's record.
cs_bossless_ack_record() {  # <project>
  local project=$1 dir
  dir=$(dirname "$CS_BOSSLESS_ACK_FILE")
  mkdir -p "$dir" || return 1
  printf '%s acknowledged %s\n' "$project" "$(date +%s)" >> "$CS_BOSSLESS_ACK_FILE"
}

# Every project name with at least one kind=ship, yolo=on task recorded in
# THIS home's state/*.meta (never config/projects.md's advisory-only posture)
# whose bossless-ack status is not "acknowledged" - i.e. still on narrower
# yolo behavior. One name per line, no duplicates.
cs_afk_bossless_unacked_projects() {
  local meta kind yolo project name seen=''
  for meta in "$CS_AFK_STATE"/*.meta; do
    [ -e "$meta" ] || continue
    kind=$(cs_meta_get "$meta" kind 2>/dev/null || true)
    [ "$kind" = ship ] || continue
    yolo=$(cs_meta_get "$meta" yolo 2>/dev/null || true)
    [ "$yolo" = on ] || continue
    project=$(cs_meta_get "$meta" project 2>/dev/null || true)
    [ -n "$project" ] || continue
    name=$(basename "$project")
    case " $seen " in *" $name "*) continue ;; esac
    seen="$seen $name"
    [ "$(cs_bossless_ack_status "$name")" = acknowledged ] && continue
    printf '%s\n' "$name"
  done
  return 0
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

# Print one explicit, named prompt per project this arm would newly run
# bossless for. Never blocks or fails this script's own arm/refresh return -
# an unacknowledged project simply keeps narrower yolo behavior, which
# cs_bossless_active (bin/cs-auto-decision-lib.sh) independently enforces
# regardless of whether this print ever ran.
cs_afk_print_bossless_prompts() {
  local project
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    echo "afk: bossless mode would newly apply to project '$project' (yolo is on, away mode is now armed) - it stays on narrower yolo behavior until acknowledged: run 'cs-afk-start.sh ack $project' after the boss confirms."
  done < <(cs_afk_bossless_unacked_projects)
  return 0
}

cs_afk_start_main() {
  case "${1:-}" in
    '' ) ;;
    -h|--help) cs_afk_start_usage; return 0 ;;
    ack )
      local project=${2:-}
      if [ -z "$project" ] || [ "$#" -ne 2 ]; then
        echo "usage: $(basename "${BASH_SOURCE[0]}") ack <project>" >&2
        return 2
      fi
      cs_bossless_ack_record "$project" || { echo "error: could not record the acknowledgment" >&2; return 1; }
      echo "afk: bossless acknowledged for project '$project'"
      return 0
      ;;
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
    cs_afk_print_bossless_prompts
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
      cs_afk_print_bossless_prompts
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
