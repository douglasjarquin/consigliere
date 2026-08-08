#!/usr/bin/env bash
# Atomically drain durable watcher wake records, optionally annotate validated
# signal status keys after raw consumption commits, print the fleet-wide OPEN
# DECISIONS section, then assert liveness. The OPEN DECISIONS section folds
# every state/*.status file on EVERY drain (including the empty-queue fast
# path), so a still-open decision buried under later unrelated status appends
# reaches consigliere even when the last-line wake annotation no longer shows it.
# The fold is cursor-backed (scan_open_decisions_incremental), so each drain
# reads only bytes appended since the previous drain, not every task's whole
# lifetime status log.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-wake-lib.sh
. "$SCRIPT_DIR/cs-wake-lib.sh"
# shellcheck source=bin/cs-classify-lib.sh
. "$SCRIPT_DIR/cs-classify-lib.sh"
# shellcheck source=bin/cs-line-cap-lib.sh
. "$SCRIPT_DIR/cs-line-cap-lib.sh"

DRAIN_TMP=
DRAIN_LOCK_HELD=false
RAW_ROWS=

# Defense in depth for the supervision chain: this script runs at the top of
# every wake-handling and recovery turn, so assert watcher liveness here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script (cs-peek/cs-send/...) happens to run.
# Reuse cs-guard.sh's existing graced, beacon-based alarm (CS_GUARD_GRACE) - do
# not duplicate the beacon math. Because the watcher touches its beacon every
# poll cycle, a normal fire leaves a recent beacon well inside grace and stays
# silent; only a genuine stale-beyond-grace lapse with work in flight warns. Call
# after the queue is emptied so guard never re-prints its own queued-wakes notice
# for the records this run just drained, and never let a guard hiccup change the
# drain's exit status.
assert_watcher_liveness() {
  "$SCRIPT_DIR/cs-guard.sh" || true
}

# Print the fleet-wide OPEN DECISIONS section from the durable status fold
# (via cs-classify-lib.sh's cursor-backed scan_open_decisions_incremental
# wrapper). This runs on every drain so a needs-decision/needs-review/blocked
# line that later, unrelated status appends pushed off the last line still
# surfaces here instead of going silently missed. Best-effort context like the
# annotations: it never touches the queue and cannot fail the drain. Not a
# pure read: the incremental wrapper persists a per-status-file byte cursor
# (state/.decision-cursor-<task>) so this per-drain scan folds only bytes
# appended since the previous drain instead of every task's whole lifetime
# log. Output is bounded the same way the enrichment phase is - at most
# CS_OPEN_DECISIONS_CAP decisions are listed and any remainder is reported as
# omitted, never silently dropped - so a large fleet cannot turn a drain into
# an unbounded output fan-out. No open decisions prints nothing.
print_open_decisions() {
  local rows cap=${CS_OPEN_DECISIONS_CAP:-32} shown=0 omitted=0
  local task key verb note printed=false
  case "$cap" in
    ''|*[!0-9]*|0*) cap=32 ;;
  esac
  rows=$(scan_open_decisions_incremental "$STATE") || return 0
  [ -n "$rows" ] || return 0
  while IFS="$(printf '\t')" read -r task key verb note; do
    [ -n "$task" ] || continue
    if [ "$shown" -ge "$cap" ]; then
      omitted=$((omitted + 1))
      continue
    fi
    if [ "$printed" = false ]; then
      printf 'OPEN DECISIONS (still open, may be buried above the last status line):\n'
      printed=true
    fi
    shown=$((shown + 1))
    # A note is agent-written and unbounded; cut each item with the shared
    # per-line cap (cs-line-cap-lib.sh) so this section and the session-start
    # status tails carry one truncation marker. The lede keeps the task id that
    # names the durable state/<id>.status source for the full text.
    cs_cap_line_var "$task [key=$key] $verb: $note"
    printf '  %s\n' "$CS_LINE_CAP_LINE"
  done <<EOF
$rows
EOF
  if [ "$omitted" -gt 0 ]; then
    printf '  ... %s more open decision(s) omitted (open-decisions cap)\n' "$omitted"
  fi
  return 0
}

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ "$DRAIN_LOCK_HELD" = true ] && [ -n "$DRAIN_TMP" ] && [ -e "$DRAIN_TMP" ]; then
    cs_wake_restore_queue "$DRAIN_TMP" || true
  fi
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    cs_lock_release "$CS_WAKE_QUEUE_LOCK"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cs_lock_acquire_wait "$CS_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=true

if [ ! -s "$CS_WAKE_QUEUE" ]; then
  : > "$CS_WAKE_QUEUE"
  cs_lock_release "$CS_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=false
  (print_open_decisions) || true
  assert_watcher_liveness
  exit 0
fi

DRAIN_TMP="$STATE/.wake-queue.drain.$(cs_current_pid)"
rm -f "$DRAIN_TMP"
mv "$CS_WAKE_QUEUE" "$DRAIN_TMP" || exit 1
: > "$CS_WAKE_QUEUE" || exit 1

RAW_ROWS=$(cs_wake_print_deduped "$DRAIN_TMP") || exit "$?"
case "${CS_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT:-0}" in
  0) ;;
  ''|*[!0-9]*) ;;
  *) sleep "$CS_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT" ;;
esac
if [ -n "$RAW_ROWS" ]; then
  # Print-before-delete is the deliberate at-least-once no-loss boundary: a
  # crash in this micro-gap may replay a wake, and annotations stay outside it.
  printf '%s\n' "$RAW_ROWS" || exit "$?"
fi
rm -f "$DRAIN_TMP" || exit "$?"
DRAIN_TMP=
cs_lock_release "$CS_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=false

# Raw output and queue deletion are authoritative. Everything below is
# best-effort and cannot restore, duplicate, hide, or fail the consumed rows.
(cs_wake_print_annotations "$RAW_ROWS") || true
(print_open_decisions) || true
assert_watcher_liveness
exit 0
