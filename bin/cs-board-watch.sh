#!/usr/bin/env bash
# cs-board-watch.sh - durable board sweeps: the record that outlives a session,
# and the poll that reopens one.
#
# A `contracts` or `casino` sweep used to exist only inside the conversation
# that started it. Nothing read the board on a cadence, so a Ready column that
# refilled after the sweep's one listing - a boss promotion, a new Inbox idea,
# a lane freed after the session ended - sat untouched until the boss asked
# again. This script is the durable half of that loop:
#
#   1. data/sweeps.md records the boss's standing intent to work a project's
#      board, with its lane cap. It survives session end, compaction, and
#      reboot, and is reported at every session start.
#   2. state/sweep-<project>.check.sh is a watcher poll armed from that record.
#      It reports column depth on the ordinary CS_CHECK_INTERVAL cadence, so a
#      refilled column produces a `check:` wake instead of silence.
#
# The two are kept convergent by `sync`, which re-arms any recorded sweep whose
# poll went missing and retires any poll whose record is gone. Session start
# runs it, so an interrupted arm or a wiped state/ heals itself rather than
# leaving the boss's standing intent half-applied.
#
# The poll NEVER moves a card, never dispatches, and never decides lane
# capacity: it reports depth and consigliere decides. It stays silent unless a
# column GREW since its last report or the resurface interval elapsed with work
# still sitting, so consigliere's own dispatch (which shrinks Ready) cannot
# wake anyone. It is silent on every error, so a failed board read can never be
# read as an empty column.
#
# The generated poll's bytes are bound by cs-check-register.sh, exactly like any
# other custom watcher check: editing state/sweep-<project>.check.sh by hand
# disarms it rather than changing what the watcher runs.
#
# Usage:
#   cs-board-watch.sh arm <project> [--lanes <n>] [--resurface <secs>]
#                                          record the sweep and arm its poll;
#                                          re-arming an existing sweep updates
#                                          its lane cap and resurface interval
#   cs-board-watch.sh disarm <project>     drop the record and retire the poll
#   cs-board-watch.sh list                 active sweeps, arm state, and drift
#   cs-board-watch.sh sync                 converge polls to records; prints
#                                          only what it changed or cannot fix
#
# Defaults: --lanes 3 (the contracts skill's per-project concurrency cap),
# --resurface 1800 (seconds before a still-full column is reported again).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root

# shellcheck source=bin/cs-pr-lib.sh
. "$SCRIPT_DIR/cs-pr-lib.sh"
# shellcheck source=bin/cs-check-lib.sh
. "$SCRIPT_DIR/cs-check-lib.sh"

SWEEPS="$DATA/sweeps.md"
BOARD="$SCRIPT_DIR/cs-board.sh"

DEFAULT_LANES=${CS_BOARD_SWEEP_LANES:-3}
DEFAULT_RESURFACE=${CS_BOARD_SWEEP_RESURFACE:-1800}

die() { echo "cs-board-watch: $*" >&2; exit 1; }

# Staged-file cleanup. The trap names this function rather than an expanded
# path, so a CS_HOME containing a quote cannot break the trap string. Pipeline
# subshells reset EXIT traps, so a function that stages a file inside one
# installs its own (see sweeps_write).
CS_BW_TMP=
bw_cleanup() { [ -z "$CS_BW_TMP" ] || rm -f -- "$CS_BW_TMP"; }

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"
}

# A project name reaches the generated poll's source, its check id, and its
# state paths, so it is validated once here and never sanitized downstream.
# The leading-character rule keeps a name from producing a dotfile or an
# option-looking argument.
valid_project() {
  local p=${1-}
  local LC_ALL=C
  case "$p" in
    ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#p}" -le 48 ]
}

valid_number() {
  local n=${1-}
  case "$n" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$n" -ge 1 ]
}

sweep_id() { printf 'sweep-%s\n' "$1"; }

# Single-quote an arbitrary string for the generated poll. Project names are
# already restricted to a safe alphabet, but CS_HOME-derived paths are not.
shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# --- data/sweeps.md ---------------------------------------------------------
#
# One record per line: "<project> <lanes> <resurface> <armed-utc>". Blank lines
# and '#' comments are ignored so the file reads as ordinary markdown, matching
# config/boards.md. This script is the only writer.

SWEEPS_HEADER='# Active board sweeps. Owned by bin/cs-board-watch.sh; do not hand-edit.
# <project> <lane-cap> <resurface-secs> <armed-utc>'

sweep_records() {
  [ -f "$SWEEPS" ] || return 0
  awk '/^[[:space:]]*#/ {next} NF >= 1 {print}' "$SWEEPS"
}

sweep_record_of() {
  local project=$1
  sweep_records | awk -v p="$project" '$1==p {print; exit}'
}

sweep_projects() {
  sweep_records | awk '{print $1}'
}

# Rewrite the whole file from a record list on stdin, atomically.
sweeps_write() {
  local tmp
  mkdir -p "$DATA" || die "cannot create $DATA"
  tmp=$(mktemp "$DATA/.cs-sweeps.XXXXXX") || die "cannot stage $SWEEPS"
  CS_BW_TMP=$tmp
  trap bw_cleanup EXIT
  printf '%s\n' "$SWEEPS_HEADER" > "$tmp" || die "cannot write $SWEEPS"
  cat >> "$tmp" || die "cannot write $SWEEPS"
  mv -f -- "$tmp" "$SWEEPS" || die "cannot publish $SWEEPS"
  CS_BW_TMP=
  trap - EXIT
}

sweeps_put() {
  local project=$1 lanes=$2 resurface=$3 stamp
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  {
    sweep_records | awk -v p="$project" '$1!=p'
    printf '%s %s %s %s\n' "$project" "$lanes" "$resurface" "$stamp"
  } | sort | sweeps_write
}

sweeps_drop() {
  local project=$1
  sweep_records | awk -v p="$project" '$1!=p' | sweeps_write
}

# --- poll arming ------------------------------------------------------------

poll_armed() {
  local project=$1 id
  id=$(sweep_id "$project")
  cs_custom_check_registered "$STATE" "$id"
}

# Emit the poll source for a project. Only the project name, the lane cap, the
# resurface interval, and this home's absolute paths are interpolated; the
# logic below them is identical for every sweep.
poll_source() {
  local project=$1 lanes=$2 resurface=$3 id=$4
  cat <<EOF
#!/usr/bin/env bash
# GENERATED by cs-board-watch.sh for the '$project' board sweep.
# Do not edit: these bytes are bound by state/$id.check-trust, and any change
# disarms the poll instead of altering what the watcher runs. Re-run
# 'cs-board-watch.sh arm $project' to regenerate and rebind it.
set -u
LC_ALL=C
export LC_ALL
CS_DATA_OVERRIDE=$(shell_quote "$DATA")
export CS_DATA_OVERRIDE
project=$(shell_quote "$project")
board=$(shell_quote "$BOARD")
seen=$(shell_quote "$STATE/$id.board-seen")
lanes=$lanes
resurface=$resurface
EOF
  cat <<'EOF'

# One item-list round trip for both columns. Any failure is silence, never a
# reported-empty board.
out=$("$board" counts "$project" 2>/dev/null) || exit 0

ready=
inbox=
while IFS= read -r line; do
  case "$line" in
    ready=*) ready=${line#ready=} ;;
    inbox=*) inbox=${line#inbox=} ;;
  esac
done <<COUNTS
$out
COUNTS

case "$ready" in ''|*[!0-9]*) exit 0 ;; esac
case "$inbox" in ''|*[!0-9]*) exit 0 ;; esac

# Both columns clear is the healthy end state of a sweep: stay silent.
[ "$ready" -gt 0 ] || [ "$inbox" -gt 0 ] || exit 0

now=$(date +%s 2>/dev/null) || exit 0
case "$now" in ''|*[!0-9]*) exit 0 ;; esac

last_ready=0
last_inbox=0
last_at=0
if [ -f "$seen" ] && [ ! -L "$seen" ]; then
  { exec 3< "$seen"; } 2>/dev/null || exit 0
  IFS= read -r f1 <&3 || f1=
  IFS= read -r f2 <&3 || f2=
  IFS= read -r f3 <&3 || f3=
  exec 3<&-
  case "$f1" in ''|*[!0-9]*) f1=0 ;; esac
  case "$f2" in ''|*[!0-9]*) f2=0 ;; esac
  case "$f3" in ''|*[!0-9]*) f3=0 ;; esac
  last_ready=$f1
  last_inbox=$f2
  last_at=$f3
fi

# Report when a column GREW - a boss promotion into Ready, a new Inbox idea -
# or when the resurface interval has elapsed with work still sitting. A
# shrinking column is consigliere's own dispatch and must never wake anyone.
# A last_at in the future means the clock moved; report rather than suppress.
if [ "$ready" -le "$last_ready" ] \
  && [ "$inbox" -le "$last_inbox" ] \
  && [ "$last_at" -le "$now" ] \
  && [ "$((now - last_at))" -lt "$resurface" ]; then
  exit 0
fi

# Record BEFORE reporting: a failed write must not produce a wake that would
# repeat every interval.
umask 077
tmp=$(mktemp "$seen.XXXXXX" 2>/dev/null) || exit 0
{
  printf '%s\n%s\n%s\n' "$ready" "$inbox" "$now" > "$tmp" \
    && chmod 0600 "$tmp" \
    && mv -f -- "$tmp" "$seen"
} 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; exit 0; }

printf '%s ready, %s inbox on the %s board (lane cap %s)\n' \
  "$ready" "$inbox" "$project" "$lanes"
exit 0
EOF
}

arm_poll() {
  local project=$1 lanes=$2 resurface=$3 id check tmp
  id=$(sweep_id "$project")
  cs_pr_task_id_valid "$id" || die "internal: '$id' is not a usable check id"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  check="$STATE/$id.check.sh"

  umask 077
  tmp=$(mktemp "$STATE/.cs-board-watch.XXXXXX") || die "cannot stage the sweep poll"
  CS_BW_TMP=$tmp
  trap bw_cleanup EXIT
  poll_source "$project" "$lanes" "$resurface" "$id" > "$tmp" || die "cannot write the sweep poll"
  chmod 0700 "$tmp" || die "cannot set the sweep poll mode"
  mv -f -- "$tmp" "$check" || die "cannot publish the sweep poll"
  CS_BW_TMP=
  trap - EXIT

  # A fresh arm starts with no memory, so the first cycle reports whatever is
  # already sitting in the columns instead of inheriting a stale suppression.
  rm -f -- "$STATE/$id.board-seen"

  "$SCRIPT_DIR/cs-check-register.sh" "$id" >/dev/null \
    || die "could not bind the sweep poll to its trust record"
}

retire_poll() {
  local project=$1 id
  id=$(sweep_id "$project")
  rm -f -- "$STATE/$id.check.sh" "$STATE/$id.check-trust" "$STATE/$id.board-seen"
}

# --- commands ---------------------------------------------------------------

cmd_arm() {
  local project=$1 lanes=$DEFAULT_LANES resurface=$DEFAULT_RESURFACE
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lanes) [ "$#" -ge 2 ] || die "--lanes needs a value"; lanes=$2; shift 2 ;;
      --resurface) [ "$#" -ge 2 ] || die "--resurface needs a value"; resurface=$2; shift 2 ;;
      *) die "unknown option '$1' (--lanes <n>, --resurface <secs>)" ;;
    esac
  done
  valid_project "$project" || die "invalid project name '$project'"
  valid_number "$lanes" || die "--lanes must be a positive integer, got '$lanes'"
  valid_number "$resurface" || die "--resurface must be a positive integer, got '$resurface'"
  # Fail closed on an unmapped board rather than arming a poll that can only
  # ever be silent. cs-board.sh owns the boards.md format, so it answers this.
  "$BOARD" mapped "$project" >/dev/null \
    || die "no board mapping for '$project' is usable (see any error above); add or fix its line in $CONFIG/boards.md"

  sweeps_put "$project" "$lanes" "$resurface"
  arm_poll "$project" "$lanes" "$resurface"
  printf 'armed: %s board sweep (lane cap %s, resurface %ss)\n' "$project" "$lanes" "$resurface"
}

cmd_disarm() {
  local project=$1
  valid_project "$project" || die "invalid project name '$project'"
  if [ -z "$(sweep_record_of "$project")" ] && ! poll_armed "$project"; then
    printf 'no active sweep for %s\n' "$project"
    return 0
  fi
  sweeps_drop "$project"
  retire_poll "$project"
  printf 'disarmed: %s board sweep\n' "$project"
}

cmd_list() {
  local found=0 project lanes resurface stamp state check id
  while read -r project lanes resurface stamp; do
    [ -n "$project" ] || continue
    found=1
    if poll_armed "$project"; then state=armed; else state='NOT ARMED (run sync)'; fi
    printf '%s lanes=%s resurface=%ss armed=%s poll=%s\n' \
      "$project" "$lanes" "$resurface" "$stamp" "$state"
  done <<EOF
$(sweep_records)
EOF
  [ "$found" -eq 1 ] || printf '(no active board sweeps)\n'

  # Drift the other way: a poll with no record would keep waking the fleet for
  # a sweep the boss already ended.
  for check in "$STATE"/sweep-*.check.sh; do
    [ -e "$check" ] || continue
    id=$(basename "$check" .check.sh)
    project=${id#sweep-}
    [ -z "$(sweep_record_of "$project")" ] || continue
    printf 'ORPHAN poll with no record: %s (run sync to retire it)\n' "$check"
  done
}

cmd_sync() {
  local changed=0 project lanes resurface stamp check id
  # sync runs inside the session-start digest, where a missing state directory
  # is a bootstrap problem with its own owner. Report and step aside rather than
  # failing the digest.
  if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
    printf 'cs-board-watch: no usable state directory at %s; sweeps left unconverged\n' "$STATE" >&2
    return 0
  fi
  while read -r project lanes resurface stamp; do
    [ -n "$project" ] || continue
    : "$stamp"
    if ! valid_project "$project" || ! valid_number "$lanes" || ! valid_number "$resurface"; then
      printf 'cs-board-watch: unusable sweep record for "%s" in %s; fix or remove that line\n' \
        "$project" "$SWEEPS" >&2
      changed=1
      continue
    fi
    poll_armed "$project" && continue
    if arm_poll "$project" "$lanes" "$resurface"; then
      printf 're-armed the %s board sweep poll (record present, poll missing)\n' "$project"
      changed=1
    fi
  done <<EOF
$(sweep_records)
EOF

  for check in "$STATE"/sweep-*.check.sh; do
    [ -e "$check" ] || continue
    id=$(basename "$check" .check.sh)
    project=${id#sweep-}
    [ -z "$(sweep_record_of "$project")" ] || continue
    retire_poll "$project"
    printf 'retired the %s board sweep poll (no record in %s)\n' "$project" "$SWEEPS"
    changed=1
  done

  [ "$changed" -eq 1 ] || return 0
}

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
  arm)     [ "$#" -ge 2 ] || die "usage: cs-board-watch.sh arm <project> [--lanes <n>] [--resurface <secs>]"; shift; cmd_arm "$@" ;;
  disarm)  [ "$#" -ge 2 ] || die "usage: cs-board-watch.sh disarm <project>"; cmd_disarm "$2" ;;
  list)    cmd_list ;;
  sync)    cmd_sync ;;
  *) die "unknown command '$1' (arm|disarm|list|sync)" ;;
esac
