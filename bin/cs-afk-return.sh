#!/usr/bin/env bash
# bin/cs-afk-return.sh - deterministic away-mode return catch-up gate.
#
# Usage:
#   cs-afk-return.sh          Stop away mode, drain catch-up, and open/check gate.
#   cs-afk-return.sh begin    Same as the default command.
#   cs-afk-return.sh check    Re-drain and close the gate only after blockers resolve.
#   cs-afk-return.sh guard    Read-only refusal while away or catch-up is pending.
#
# Ordered shutdown: stop the daemon FIRST (its TERM trap flushes what it can;
# an unflushable buffer survives in state/.subsuper-escalations), clear
# state/.afk only after the daemon is confirmed stopped, then drain the
# durable wake queue and print every buffered escalation and wedge marker as
# durable catch-up evidence.
#
# Fail-closed catch-up gate: `blocked:` is the soldier protocol's
# consigliere-actionable verb. Every live task's open blocked decision (the
# keyed status fold in bin/cs-classify-lib.sh, not the last line) must be
# remediated and closed with `resolved [key=...]`, or explicitly reclassified
# in the status stream with a durable reason, before ordinary boss work may
# proceed. `needs-decision:` is boss-owned and deliberately not part of this
# gate; normal reporting surfaces it.
#
# The durable state/.afk-return-catchup file is written BEFORE any lifecycle
# mutation, so a crash between stopping, draining, and blocker handling fails
# closed. It retains the drained-wake, buffered-escalation, and wedge-marker
# evidence until every live open blocker is closed and `check` succeeds.
# Repeated begin/check calls are idempotent. `guard` never mutates state and
# is suitable for ordinary read entrypoints.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CS_ROOT="${CS_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CS_HOME="${CS_HOME:-${CS_ROOT_OVERRIDE:-$CS_ROOT}}"
STATE="${CS_STATE_OVERRIDE:-$CS_HOME/state}"
GATE="$STATE/.afk-return-catchup"
LOCK="$STATE/.afk-return-catchup.lock"
DAEMON_LOCK="$STATE/.subsuper-daemon.lock"
DAEMON_PIDFILE="$STATE/.subsuper-daemon.pid"

usage() {
  sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

append_evidence() {  # <kind> <text> <file>
  local kind=$1 text=$2 file=$3 clean record line
  [ -n "$text" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    clean=$(printf '%s' "$line" | clean_field)
    record=$(printf 'evidence\t%s\t%s' "$kind" "$clean")
    grep -Fqx "$record" "$file" 2>/dev/null || printf '%s\n' "$record" >> "$file"
  done <<EOF
$text
EOF
}

preserve_evidence() {  # <destination>
  [ -f "$GATE" ] || return 0
  grep '^evidence'"$(printf '\t')" "$GATE" >> "$1" 2>/dev/null || true
}

scan_open_blockers() {  # -> tab-separated blocker rows
  local meta id status key verb summary clean_summary
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta")
    id=${id%.meta}
    status="$STATE/$id.status"
    [ -f "$status" ] || continue
    while IFS="$(printf '\t')" read -r key verb summary; do
      [ "$verb" = blocked ] || continue
      clean_summary=$(printf '%s' "$summary" | clean_field)
      printf 'blocker\t%s\t%s\t%s\n' "$id" "$key" "$clean_summary"
    done <<EOF
$(status_open_decisions "$status")
EOF
  done
}

write_pending_seed() {  # fail-closed marker before any lifecycle mutation
  local pending started
  mkdir -p "$STATE" || return 1
  started=$(awk -F '\t' '$1 == "started" { print $2; exit }' "$GATE" 2>/dev/null || true)
  [ -n "$started" ] || started=$(date +%s)
  pending=$(mktemp "$STATE/.afk-return-catchup.pending.XXXXXX") || return 1
  {
    printf 'schema\tcs-afk-return.v1\n'
    printf 'started\t%s\n' "$started"
    printf 'phase\tstopping-and-draining\n'
    preserve_evidence /dev/stdout
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$GATE"
}

write_gate() {  # <evidence-file> <blockers-file>
  local evidence=$1 blockers=$2 pending started
  pending=$(mktemp "$STATE/.afk-return-catchup.pending.XXXXXX") || return 1
  started=$(awk -F '\t' '$1 == "started" { print $2; exit }' "$GATE" 2>/dev/null || true)
  [ -n "$started" ] || started=$(date +%s)
  {
    printf 'schema\tcs-afk-return.v1\n'
    printf 'started\t%s\n' "$started"
    printf 'phase\tblocked\n'
    cat "$evidence" 2>/dev/null || true
    cat "$blockers" 2>/dev/null || true
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$GATE"
}

print_evidence() {  # <file>
  local tag kind text
  while IFS="$(printf '\t')" read -r tag kind text; do
    [ "$tag" = evidence ] || continue
    printf 'catch-up %s: %s\n' "$kind" "$text"
  done < "$1"
}

print_blockers() {  # <file>
  local tag id key summary
  while IFS="$(printf '\t')" read -r tag id key summary; do
    [ "$tag" = blocker ] || continue
    printf 'consigliere-actionable blocker: %s [key=%s] %s\n' "$id" "$key" "$summary"
  done < "$1"
}

clear_delivery_artifacts() {
  rm -f \
    "$STATE/.subsuper-escalations" \
    "$STATE/.subsuper-escalations.since" \
    "$STATE/.subsuper-inject-wedged"
}

daemon_pid() {
  local pid
  pid=$(cat "$DAEMON_PIDFILE" 2>/dev/null || true)
  [ -n "$pid" ] || pid=$(cat "$DAEMON_LOCK/pid" 2>/dev/null || true)
  printf '%s' "$pid"
}

# Stop the daemon and wait for it to exit. 0 = stopped (or was not running);
# 1 = still alive after the wait (lifecycle failure; state preserved).
stop_daemon() {
  local pid i
  pid=$(daemon_pid)
  cs_pid_alive "$pid" || return 0
  kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt "${CS_AFK_STOP_WAIT_TICKS:-100}" ]; do
    cs_pid_alive "$pid" || return 0
    sleep 0.1
    i=$((i + 1))
  done
  cs_pid_alive "$pid" || return 0
  return 1
}

return_guard() {
  if [ -e "$STATE/.afk" ]; then
    printf 'cs-afk-return: away mode is still active; run bin/cs-afk-return.sh before ordinary boss work\n' >&2
    return 3
  fi
  if [ -e "$GATE" ]; then
    printf 'cs-afk-return: return catch-up is pending; remediate or durably reclassify every listed blocker, then run bin/cs-afk-return.sh check\n' >&2
    print_blockers "$GATE" >&2
    return 3
  fi
  return 0
}

return_reconcile() {
  local evidence blockers drained wedge escalations lifecycle_ok=1
  evidence=$(mktemp "$STATE/.afk-return-evidence.XXXXXX") || return 1
  blockers=$(mktemp "$STATE/.afk-return-blockers.XXXXXX") || { rm -f "$evidence"; return 1; }
  preserve_evidence "$evidence"

  # Ordered shutdown: stop the daemon first (its trap flushes what it can),
  # then clear the away flag only once the daemon is confirmed stopped.
  if ! stop_daemon; then
    lifecycle_ok=0
    append_evidence lifecycle 'away-mode daemon shutdown failed; lifecycle state preserved for retry' "$evidence"
  else
    rm -f "$STATE/.afk"
  fi

  drained=$("$SCRIPT_DIR/cs-wake-drain.sh") || {
    append_evidence lifecycle 'durable wake drain failed; retry catch-up before ordinary work' "$evidence"
    lifecycle_ok=0
    drained=""
  }
  append_evidence wake "$drained" "$evidence"

  if [ -s "$STATE/.subsuper-inject-wedged" ]; then
    wedge=$(head -1 "$STATE/.subsuper-inject-wedged" 2>/dev/null || true)
    append_evidence wedge "$wedge" "$evidence"
  fi
  if [ -s "$STATE/.subsuper-escalations" ]; then
    escalations=$(cat "$STATE/.subsuper-escalations" 2>/dev/null || true)
    append_evidence escalation "$escalations" "$evidence"
  fi

  scan_open_blockers > "$blockers"
  if [ "$lifecycle_ok" -ne 1 ] || [ -s "$blockers" ]; then
    write_gate "$evidence" "$blockers" || { rm -f "$evidence" "$blockers"; return 1; }
    printf 'cs-afk-return: catch-up must finish before the boss request\n' >&2
    print_evidence "$GATE" >&2
    print_blockers "$GATE" >&2
    printf 'cs-afk-return: handle each blocker now, or close it with resolved [key=...] and append a durable reclassification reason, then run bin/cs-afk-return.sh check\n' >&2
    rm -f "$evidence" "$blockers"
    return 3
  fi

  print_evidence "$evidence"
  rm -f "$GATE"
  clear_delivery_artifacts
  rm -f "$evidence" "$blockers"
  printf 'cs-afk-return: catch-up clear; ordinary boss work may proceed\n'
  return 0
}

main() {
  local mode=${1:-begin} rc
  case "$mode" in
    begin|check) ;;
    guard) return_guard; return ;;
    -h|--help|help) usage; return 0 ;;
    *) usage >&2; return 2 ;;
  esac

  # The mutating begin/check paths need locks and the keyed status fold.
  # `guard` returned above without sourcing cs-wake-lib.sh, whose
  # initialization creates the state directory, so the advertised read-only
  # guard is literal.
  # shellcheck source=bin/cs-wake-lib.sh
  . "$SCRIPT_DIR/cs-wake-lib.sh"
  # shellcheck source=bin/cs-classify-lib.sh
  . "$SCRIPT_DIR/cs-classify-lib.sh"

  mkdir -p "$STATE" || return 1
  cs_lock_acquire_wait "$LOCK"
  trap 'cs_lock_release "$LOCK"' EXIT
  write_pending_seed || { cs_lock_release "$LOCK"; trap - EXIT; return 1; }
  return_reconcile
  rc=$?
  cs_lock_release "$LOCK"
  trap - EXIT
  return "$rc"
}

main "$@"
