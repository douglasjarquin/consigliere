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
#
# The rotation itself is durable. A drain moves the queue into a batch file
# (CS_WAKE_BATCH_PREFIX, cs-wake-lib.sh) AFTER taking the queue lock and removes
# that batch BEFORE releasing it, so any batch still on disk while this drain
# holds the lock belongs to a drain that never committed: the turn died between
# the rotation and handling. Those records are otherwise unreachable - the queue
# is already empty and nothing else ever reads a batch file - so this drain
# adopts every orphan it finds, replays its records once under a labeled
# "wake replay:" line, and retires it in the same committed step. See
# docs/supervision.md for the placement of that adoption in the cycle.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-wake-lib.sh
. "$SCRIPT_DIR/cs-wake-lib.sh"
# shellcheck source=bin/cs-classify-lib.sh
. "$SCRIPT_DIR/cs-classify-lib.sh"
# shellcheck source=bin/cs-line-cap-lib.sh
. "$SCRIPT_DIR/cs-line-cap-lib.sh"
# Optional turn telemetry (off unless host/telemetry.conf enables it).
# shellcheck source=bin/cs-telemetry-lib.sh
. "$SCRIPT_DIR/cs-telemetry-lib.sh"

DRAIN_TMP=
DRAIN_LOCK_HELD=false
RAW_ROWS=
ORPHANS=()
REPLAYED_RECORDS=0

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
  # The answerer-closes hint, printed at exactly the moment an answer gets
  # written: the send that answers a listed decision also closes it, so closure
  # never depends on the soldier writing a matching resolved line (contract:
  # bin/cs-send.sh header). Printed only when the section itself printed.
  if [ "$printed" = true ]; then
    printf "  close one by answering it: bin/cs-send.sh <task> --resolve-key <key> '<answer>'\n"
  fi
  return 0
}

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
# Any batch this run adopted is deliberately left where it is: an orphan is only
# retired by the committed print below, so a failed drain leaves every adopted
# record exactly as reachable as it was when this run started.
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

# Adopt every orphaned batch (see the header): while this lock is held, a batch
# on disk can only belong to a drain that never committed.
for orphan in "$CS_WAKE_BATCH_PREFIX"*; do
  [ -f "$orphan" ] || continue
  ORPHANS+=("$orphan")
done
# A restore temp is only ever written under this lock, and it is written from a
# batch that is still on disk plus a queue that is still intact, so one left
# here is pure litter from an interrupted restore rather than reachable records.
for stale_restore in "$CS_WAKE_RESTORE_PREFIX"*; do
  [ -f "$stale_restore" ] || continue
  rm -f "$stale_restore" || true
done

if [ ! -s "$CS_WAKE_QUEUE" ] && [ "${#ORPHANS[@]}" -eq 0 ]; then
  : > "$CS_WAKE_QUEUE"
  cs_lock_release "$CS_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=false
  (print_open_decisions) || true
  assert_watcher_liveness
  exit 0
fi

DRAIN_TMP=$(cs_wake_new_batch) || exit 1
if [ -e "$CS_WAKE_QUEUE" ]; then
  mv "$CS_WAKE_QUEUE" "$DRAIN_TMP" || exit 1
fi
: > "$CS_WAKE_QUEUE" || exit 1

if [ "${#ORPHANS[@]}" -gt 0 ]; then
  REPLAYED_RECORDS=$(awk -F '\t' 'NF >= 5 { n++ } END { print n + 0 }' "${ORPHANS[@]}" 2>/dev/null) || REPLAYED_RECORDS=0
  case "$REPLAYED_RECORDS" in
    ''|*[!0-9]*) REPLAYED_RECORDS=0 ;;
  esac
fi
# Adopted records come first because they are older; dedupe over the union then
# gives a key carried by both its earliest position and its latest payload.
RAW_ROWS=$(cs_wake_print_deduped ${ORPHANS[@]+"${ORPHANS[@]}"} "$DRAIN_TMP") || exit "$?"
case "${CS_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT:-0}" in
  0) ;;
  ''|*[!0-9]*) ;;
  *) sleep "$CS_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT" ;;
esac
if [ "$REPLAYED_RECORDS" -gt 0 ]; then
  # Label the replay so the reading agent can tell recovered records from fresh
  # ones. They are handled identically - the rows below keep the canonical raw
  # shape - but a record that surfaces a second time reads as a duplicate wake
  # unless the drain says where it came from.
  printf 'wake replay: recovered %s wake record(s) from %s interrupted drain(s); an earlier turn emptied the queue but ended before handling them. They are deduped into the records below and will not be replayed again.\n' \
    "$REPLAYED_RECORDS" "${#ORPHANS[@]}" || exit "$?"
fi
if [ -n "$RAW_ROWS" ]; then
  # Print-before-delete is the deliberate at-least-once no-loss boundary: a
  # crash in this micro-gap may replay a wake, and annotations stay outside it.
  printf '%s\n' "$RAW_ROWS" || exit "$?"
fi
# Retiring the adopted orphans here, in the same committed step that printed
# them, is the whole loop guard: nothing is ever re-promoted into a new pending
# batch, so a drain that commits always ends the chain. Only a drain that dies
# before this point leaves a batch behind, and its records stay reachable in it.
rm -f ${ORPHANS[@]+"${ORPHANS[@]}"} "$DRAIN_TMP" || exit "$?"
DRAIN_TMP=
cs_lock_release "$CS_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=false

# Raw output and queue deletion are authoritative. Everything below is
# best-effort and cannot restore, duplicate, hide, or fail the consumed rows.
(cs_wake_print_annotations "$RAW_ROWS") || true
# TELEMETRY, measurement only: record which wake kinds actually caused this turn,
# so the turn-end emitter can attribute it to supervision and name its
# provenance. The vocabulary is the queue's own (cs_wake_append validates
# signal|stale|check|capo|heartbeat); nothing is re-classified here. Silent, and
# it cannot fail, print, or change what the drain already committed above.
record_wake_telemetry() {
  local _epoch _seq kind _key _payload
  while IFS="$(printf '\t')" read -r _epoch _seq kind _key _payload; do
    [ -n "$kind" ] || continue
    cs_telemetry_crumb wake "$kind"
  done <<EOF
$RAW_ROWS
EOF
}
record_wake_telemetry || true
(print_open_decisions) || true
assert_watcher_liveness
exit 0
