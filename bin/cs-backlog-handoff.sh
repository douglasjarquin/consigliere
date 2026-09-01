#!/usr/bin/env bash
# Hand already-identified, in-scope backlog items off from the main consigliere
# backlog to a capo's own home backlog. Use this when a capo is created (or
# whenever an existing queued item should become its domain's work) so the
# capo owns its queue from day one instead of the item staying stranded in the
# main backlog.
#
# Scope-matching is consigliere's JUDGMENT: you pass the task-id keys you have
# already judged in-scope for the capo. This script performs only the
# fleet-level validation that the backlog backend cannot know, then DELEGATES
# the actual item move to `tasks-axi mv`, the single owner of the backlog
# format, so the format has exactly one parser and cannot drift.
#
# What this script owns (never delegated):
#   - resolving the capo home from host/capos.md;
#   - proving the destination is a genuine seeded capo home (.cs-capo-home
#     marker with a matching id, AGENTS.md + bin/, safe operational dirs),
#     never a project clone, the active home, or the consigliere repo;
#   - moving only `## Queued` items, refusing `## In flight` and historical
#     `## Done` records, which stay with their home for pruning or archiving;
#   - the multi-key classification and idempotent per-key reporting: a key
#     already present in the capo backlog is reported and skipped, and if any
#     key matches neither backlog nothing is moved.
#
# What `tasks-axi mv <id>... --to <dest>` owns: moving each full item BLOCK
# byte-exact (header, body lines, blank separators, indented pseudo-headings),
# preserving destination section placement, and moving a whole connected set
# (a blocker and its dependents) atomically with blocked-by links preserved.
# It refuses a move that would strand a dependency; that error is surfaced
# verbatim and nothing is moved.
#
# Item bodies must use at least two leading spaces. The helper refuses a
# selected item with a single-space or tab-indented continuation rather than
# risk leaving it orphaned. The move needs compatible tasks-axi on PATH
# (bin/cs-tasks-lib.sh owns the probe, including atomic multi-ID mv);
# `config/backlog-backend.conf=manual` governs only consigliere's own hand-editing,
# never this validated helper. Idempotent: re-running converges. Atomic: on
# any move failure nothing moves.
# After a successful move, durably wake the capo's recorded receiver when one
# exists; a failed wake leaves a retryable marker under state/.backlog-handoff-<id>.wake-pending.
# Usage:
#   cs-backlog-handoff.sh <capo-id> <item-key>...
#   cs-backlog-handoff.sh --resume-pending
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
# shellcheck source=bin/cs-capo-registry-lib.sh
. "$SCRIPT_DIR/cs-capo-registry-lib.sh"
REG="$HOST_DIR/capos.md"
MAIN_BACKLOG="$CONFIG/backlog.md"
# shellcheck source=bin/cs-tasks-lib.sh
. "$SCRIPT_DIR/cs-tasks-lib.sh"
# shellcheck source=bin/cs-pending-reply-lib.sh
. "$SCRIPT_DIR/cs-pending-reply-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"

RECEIVER_WAKE_MESSAGE='New routed work is in your backlog. Run bin/cs-session-start.sh now, then act on the routed task.'

receiver_wake_marker() { printf '%s/.backlog-handoff-%s.wake-pending' "$STATE" "$1"; }

receiver_wake_state_write() {
  local id=$1 value=$2 marker tmp
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$value" in
    pending|confirmed) ;;
    pending:*) printf '%s' "$value" | grep -Eq '^pending:[a-f0-9]{16}$' || return 1 ;;
    confirmed:*) printf '%s' "$value" | grep -Eq '^confirmed:[a-f0-9]{16}$' || return 1 ;;
    *) return 1 ;;
  esac
  marker=$(receiver_wake_marker "$id")
  tmp=$(umask 077; mktemp "$STATE/.backlog-handoff-wake.XXXXXX") || return 1
  if ! printf '%s\n' "$value" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$marker"; then
    rm -f -- "$tmp"
    return 1
  fi
}

receiver_wake_mark_pending() {
  local id=$1 marker value corr rec
  marker=$(receiver_wake_marker "$id")
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    value=$(cat "$marker" 2>/dev/null || true)
    case "$value" in
      pending:*) return 0 ;;
      pending) ;;
      confirmed|confirmed:*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  corr=$(cs_pending_reply_create "$CS_HOME" "$STATE" "$id" "$RECEIVER_WAKE_MESSAGE") || return 1
  receiver_wake_state_write "$id" "pending:$corr"
}

wake_capo_receiver() {
  local id=$1 corr=$2 meta="$STATE/$1.meta" out rc=0
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    printf 'error: handed off work to capo %s, but no live receiver endpoint is recorded; the destination backlog is durable and the receiver was not woken\n' "$id" >&2
    return 1
  fi
  [ "$(cs_meta_get "$meta" kind 2>/dev/null || true)" = capo ] || {
    printf 'error: capo %s has non-capo endpoint metadata; backlog is durable but the receiver was not woken\n' "$id" >&2
    return 1
  }
  out=$(CS_HOME="$CS_HOME" CS_STATE_OVERRIDE="$STATE" CS_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$SCRIPT_DIR/cs-send.sh" "$id" "$RECEIVER_WAKE_MESSAGE" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    printf 'error: backlog delivery to capo %s succeeded, but its receiver wake failed; rerun this handoff or cs-backlog-handoff.sh --resume-pending to retry the wake\n' "$id" >&2
    return 1
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}

wake_pending_capo_receiver() {
  local id=$1 marker value corr rec delivered
  marker=$(receiver_wake_marker "$id")
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  [ -f "$marker" ] && [ ! -L "$marker" ] || {
    printf 'error: receiver wake state for capo %s is unsafe or invalid\n' "$id" >&2
    return 1
  }
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in
    confirmed|confirmed:*) return 0 ;;
    pending) receiver_wake_mark_pending "$id" || return 1; value=$(cat "$marker" 2>/dev/null || true) ;;
  esac
  case "$value" in
    pending:*) corr=${value#pending:} ;;
    *)
      printf 'error: receiver wake state for capo %s is unsafe or invalid\n' "$id" >&2
      return 1
      ;;
  esac
  rec=$(cs_pending_reply_path "$STATE" "$corr")
  [ -f "$rec" ] && [ ! -L "$rec" ] \
    && [ "$(cs_pending_reply_get "$rec" task_id)" = "$id" ] || return 1
  cs_pending_reply_reconcile_delivery "$STATE" "$corr" >/dev/null 2>&1 || true
  delivered=$(cs_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    cs_pending_reply_corr_reusable "$STATE" "$corr" "$id" || {
      printf 'error: receiver wake delivery for capo %s is unresolved; refusing to resend correlation %s\n' "$id" "$corr" >&2
      return 1
    }
    wake_capo_receiver "$id" "$corr" || return 1
    cs_pending_reply_reconcile_delivery "$STATE" "$corr" >/dev/null 2>&1 || true
    delivered=$(cs_pending_reply_get "$rec" delivered_epoch)
  fi
  [ -n "$delivered" ] || return 1
  receiver_wake_state_write "$id" "confirmed:$corr" || return 1
  rm -f -- "$marker"
}

resume_pending_capo_wakes() {
  local marker id failed=0
  shopt -s nullglob
  for marker in "$STATE"/.backlog-handoff-*.wake-pending; do
    id=${marker##*/}
    id=${id#.backlog-handoff-}
    id=${id%.wake-pending}
    wake_pending_capo_receiver "$id" || failed=1
  done
  shopt -u nullglob
  return "$failed"
}

finish_handoff_wake() {
  local id=$1
  receiver_wake_mark_pending "$id" || {
    echo "error: handed off work to capo $id, but durable receiver wake state could not be recorded" >&2
    return 1
  }
  wake_pending_capo_receiver "$id"
}

if [ "${1:-}" = --resume-pending ]; then
  [ "$#" -eq 1 ] || { echo "usage: cs-backlog-handoff.sh --resume-pending" >&2; exit 1; }
  resume_pending_capo_wakes
  exit $?
fi

[ $# -ge 2 ] || { echo "usage: cs-backlog-handoff.sh <capo-id> <item-key>..." >&2; exit 1; }
ID=$1
shift

# bin/cs-capo-registry-lib.sh owns the parse: it validates the id charset,
# refuses a missing, unreadable, or symlinked registry, matches the id
# literally (so a dotted id such as `a.b` cannot resolve to `axb`'s home), and
# refuses a duplicated id instead of quietly taking the last row.
capo_home() {
  local id=$1
  cs_capo_registry_field "$REG" "$id" home || {
    echo "error: ${CS_CAPO_REGISTRY_ERROR:-capo $id is not registered in $REG}" >&2
    return 1
  }
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] && [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: capo home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

validate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: capo $name directory must resolve inside the capo home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: capo $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: capo $name directory must resolve inside the capo home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: capo $name directory cannot be inside the active consigliere home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: capo $name directory cannot be inside the consigliere repo: $dir" >&2
      return 1
    fi
  done
}

validate_capo_home() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$CS_HOME")
  abs_root=$(resolved_existing_dir "$CS_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: capo home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ] || [ "$abs_home" = "$abs_root" ]; then
    echo "error: capo home cannot be the active consigliere home or repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home" || path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: capo home cannot be inside the active consigliere home or repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home" || path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: capo home cannot be an ancestor of the active consigliere home or repo: $home" >&2
    return 1
  fi
  validate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/.cs-capo-home" ]; then
    echo "error: consigliere home $home is not a seeded capo home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/.cs-capo-home" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: consigliere home $home is marked for capo ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a consigliere home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a consigliere home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_backlog_file() {
  local label=$1 path=$2
  if [ -L "$path" ]; then
    echo "error: $label must not be a symlink: $path" >&2
    return 1
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    echo "error: $label is not a regular file: $path" >&2
    return 1
  fi
}

# Classify a single key by the section it lives under (## In flight /
# ## Queued / ## Done), or return non-zero if no `- [ ] <key>` / `- [x] <key>`
# header exists in the file. Reads only section headings and item header lines
# - never item bodies - so it drives the fleet-level classification without
# re-implementing the block/body move semantics tasks-axi mv owns.
backlog_key_section() {
  local file=$1 key=$2
  [ -f "$file" ] || return 1
  awk -v key="$key" '
    BEGIN { section = "## Queued" }
    /^##[[:space:]]+/ {
      section = $0
      sub(/^##[[:space:]]+/, "## ", section)
      sub(/[[:space:]]+$/, "", section)
      next
    }
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (id == key) { print section; found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

backlog_key_noncanonical_body_lines() {
  local file=$1 key=$2
  awk -v key="$key" '
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (capturing) exit
      if (id == key) { capturing = 1 }
      next
    }
    capturing && /^##[[:space:]]+/ { exit }
    capturing && /^[[:space:]]/ && !/^  / && /[^[:space:]]/ { print }
  ' "$file"
}

RAW_HOME=$(capo_home "$ID") || exit 1
[ -n "$RAW_HOME" ] || { echo "error: capo $ID has no home in $REG" >&2; exit 1; }
CAPO_HOME=$(validate_capo_home "$ID" "$RAW_HOME") || exit 1
CAPO_BACKLOG="$CAPO_HOME/config/backlog.md"
validate_backlog_file "main backlog" "$MAIN_BACKLOG" || exit 1
validate_backlog_file "capo backlog" "$CAPO_BACKLOG" || exit 1

# Classify every key before changing anything: move-from-main, already-in-capo,
# or missing. Abort with no changes if any key matches neither backlog.
TO_MOVE=()
ALREADY=()
MISSING=()
IN_FLIGHT=()
DONE=()
NOT_QUEUED=()
for key in "$@"; do
  if backlog_key_section "$CAPO_BACKLOG" "$key" >/dev/null; then
    ALREADY+=("$key")
  elif section=$(backlog_key_section "$MAIN_BACKLOG" "$key"); then
    case "$section" in
      "## Queued") TO_MOVE+=("$key") ;;
      "## In flight") IN_FLIGHT+=("$key") ;;
      "## Done") DONE+=("$key") ;;
      *) NOT_QUEUED+=("$key") ;;
    esac
  else
    MISSING+=("$key")
  fi
done

FAILED=0
if [ "${#IN_FLIGHT[@]}" -gt 0 ]; then
  echo "error: refusing to hand off in-flight backlog items: ${IN_FLIGHT[*]}" >&2
  FAILED=1
fi
if [ "${#DONE[@]}" -gt 0 ]; then
  echo "error: refusing to hand off Done (historical) backlog items: ${DONE[*]}; handoffs move in-scope queued work only - Done records stay with their home and are pruned/archived." >&2
  FAILED=1
fi
if [ "${#NOT_QUEUED[@]}" -gt 0 ]; then
  echo "error: refusing to hand off non-queued backlog items: ${NOT_QUEUED[*]}; handoffs move in-scope queued work only." >&2
  FAILED=1
fi
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "error: no backlog item matched these keys in $MAIN_BACKLOG: ${MISSING[*]}" >&2
  FAILED=1
fi
if [ "$FAILED" -ne 0 ]; then
  echo "       nothing was moved." >&2
  exit 1
fi

if [ "${#TO_MOVE[@]}" -eq 0 ]; then
  echo "nothing to move: ${ALREADY[*]:-no keys} already present in $CAPO_BACKLOG"
  if [ -e "$(receiver_wake_marker "$ID")" ]; then
    wake_pending_capo_receiver "$ID" || exit 1
  fi
  exit 0
fi

FAILED=0
for key in "${TO_MOVE[@]}"; do
  while IFS= read -r line; do
    printf 'error: refusing to hand off %s: non-2-space continuation line: %s\n' \
      "$key" "$line" >&2
    FAILED=1
  done < <(backlog_key_noncanonical_body_lines "$MAIN_BACKLOG" "$key")
done
if [ "$FAILED" -ne 0 ]; then
  echo "       nothing was moved." >&2
  exit 1
fi

if ! cs_tasks_axi_compatible; then
  echo "error: a compatible tasks-axi (atomic multi-ID mv) is required to move backlog items; bin/cs-deps-lib.sh owns its version floor" >&2
  exit 1
fi

# Seed the destination with the standard three-section scaffold when it does
# not exist yet, so the moved item lands under the right section.
mkdir -p "$CAPO_HOME/data"
CAPO_CREATED=0
if [ ! -f "$CAPO_BACKLOG" ]; then
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$CAPO_BACKLOG"
  CAPO_CREATED=1
fi

# Delegate the move to tasks-axi. Passing the whole in-scope set to one call
# is a single atomic transaction, so a connected set (blocker + dependents)
# moves together and, on any failure, neither backlog's content changes - the
# only cleanup is a scaffold we just created. tasks-axi writes both its
# success and error output to stdout, so capture it and surface it only on
# failure.
if ! MV_OUT=$(tasks-axi mv "${TO_MOVE[@]}" --file "$MAIN_BACKLOG" --to "$CAPO_BACKLOG" 2>&1); then
  if [ "$CAPO_CREATED" -eq 1 ]; then
    rm -f "$CAPO_BACKLOG"
  fi
  if [ -n "$MV_OUT" ]; then
    printf '%s\n' "$MV_OUT" >&2
  fi
  echo "error: tasks-axi mv failed; nothing was moved." >&2
  exit 1
fi

echo "handed off ${#TO_MOVE[@]} item(s) to $ID: ${TO_MOVE[*]}"
echo "  into $CAPO_BACKLOG"
finish_handoff_wake "$ID" || exit 1
if [ "${#ALREADY[@]}" -gt 0 ]; then
  echo "  already present (skipped): ${ALREADY[*]}"
fi
