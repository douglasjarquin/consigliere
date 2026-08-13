#!/usr/bin/env bash
# bin/cs-afk-start.sh - enter away mode.
#
# Usage: cs-afk-start.sh
#   Writes the durable away-mode flag state/.afk and returns immediately.
#   There is nothing to launch: the existing bin/cs-watch.sh (triage, unvaried
#   by the flag) / bin/cs-monitor.sh (keeps the watcher running while the agent
#   is busy) / bin/cs-activate.sh (starts a turn when the queue sits
#   unattended, with its own busy-stretch trigger and wedge alarm) triangle
#   already supervises this home the same way it does an attended one, so
#   arming has no separate coming-up-vs-certified race to resolve. A call
#   while already armed is a REFRESH: the current session's buffered
#   escalation-delivery evidence is preserved rather than cleared.
#
# This file is sourceable: the BASH_SOURCE guard keeps main from running while
# exposing cs_afk_clear_stale_artifacts and the bossless-ack helpers for tests.
#
# Stale-artifact lifecycle: state/.subsuper-escalations, its .since sidecar,
# and state/.subsuper-inject-wedged are session-scoped delivery artifacts, not
# the durable work record. A FRESH entry clears them (anything still true is
# re-derived by cs-watch.sh's heartbeat backstop and the durable wake-queue
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

# shellcheck source=bin/cs-wake-lib.sh
. "$CS_AFK_START_DIR/cs-wake-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$CS_AFK_START_DIR/cs-meta-lib.sh"

cs_afk_start_usage() {
  sed -n '2,55p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Recomputed on every call, deliberately never a fixed variable snapshotted
# once at source time: CS_HOME and CS_BOSSLESS_ACK_OVERRIDE can both differ
# per call in a long-lived process (this file is sourced once by
# bin/cs-auto-decision-lib.sh, whose whole cs_bossless_active contract is
# "never cached"), so a stale path computed at load time would silently keep
# reading the FIRST caller's file forever.
cs_bossless_ack_file_path() {
  printf '%s' "${CS_BOSSLESS_ACK_OVERRIDE:-$CS_HOME/config/bossless-ack.md}"
}

# The last recorded status for <project> in the bossless-ack file:
# acknowledged|disabled|unacknowledged. Fails closed to "unacknowledged" for
# EVERY project the moment any line in the file fails to parse, or the file
# exists but cannot be read - a partially-corrupt file must never be trusted
# for the records that DID parse.
cs_bossless_ack_status() {  # <project>
  local project=$1 file line p status epoch result=unacknowledged
  file=$(cs_bossless_ack_file_path)
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
  local project=$1 dir file
  file=$(cs_bossless_ack_file_path)
  dir=$(dirname "$file")
  mkdir -p "$dir" || return 1
  printf '%s acknowledged %s\n' "$project" "$(date +%s)" >> "$file"
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
# cs-watch.sh's heartbeat backstop and the durable wake-queue replay.
cs_afk_clear_stale_artifacts() {  # <state-dir>
  local state=$1
  rm -f "$state/.subsuper-escalations" \
        "$state/.subsuper-escalations.since" \
        "$state/.subsuper-inject-wedged" 2>/dev/null
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

  mkdir -p "$CS_AFK_STATE"
  local fresh=1
  [ -e "$CS_AFK_STATE/.afk" ] && fresh=0
  date '+%s' > "$CS_AFK_STATE/.afk"

  if [ "$fresh" -eq 1 ]; then
    # Fresh entry: clear the previous away session's stale delivery artifacts
    # rather than let a resolved stretch bleed into this one's evidence.
    cs_afk_clear_stale_artifacts "$CS_AFK_STATE"
    echo "afk: away mode armed"
  else
    echo "afk: away mode refreshed; already armed"
  fi
  cs_afk_print_bossless_prompts
  return 0
}

# Run only when executed, not when sourced (tests source the helpers).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cs_afk_start_main "$@"
fi
