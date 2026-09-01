#!/usr/bin/env bash
# Run one bounded foreground supervision checkpoint. Codex cannot reason during
# a foreground tool call, so a wait must be bounded: the checkpoint returns
# control at the bound instead of holding the turn open indefinitely.
#
# ONE PER TURN, ENFORCED HERE. A second invocation in the same turn is refused,
# because the turn is the only channel the boss has: the harness delivers queued
# boss input at a turn boundary, so a turn that keeps re-arming a checkpoint is a
# thread that cannot be spoken to. Measured on the live fleet before this refusal
# existed: 61 consecutive checkpoints, 6.2 hours, no reply possible. The rule was
# prose for months and prose is what got reinterpreted, so the counter lives in
# code: state/.checkpoint-turn is written here and cleared by the harness Stop
# hook (bin/cs-turnend-guard.sh) at every turn end.
#
# Ending the turn is safe because supervision does not live in the turn:
# bin/cs-monitor.sh keeps watching this home, the wake queue is durable, and
# bin/cs-activate.sh starts the next turn when something lands in it.
#
# The checkpoint does NOT own the watcher. bin/cs-monitor.sh does, so this home
# stays watched while the agent is working instead of only while it waits here.
# This checkpoint therefore (1) makes sure a monitor is alive, reviving it when
# its liveness beacon is stale, and (2) waits for the durable wake queue to
# become non-empty. Queued rows are shown, never consumed: bin/cs-wake-drain.sh
# remains the one owner of draining.
#
# Fallback, deliberately preserved: if no monitor can be started, the checkpoint
# runs a watcher inline for the bound exactly as it did before monitors existed.
# A monitor that cannot launch degrades supervision to the old behavior rather
# than to no supervision at all.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECONDS_ARG=${CS_WATCH_CHECKPOINT:-180}
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
# Queue reader plus cs_path_mtime; also the one owner of the queue's location.
# shellcheck source=bin/cs-wake-lib.sh
. "$SCRIPT_DIR/cs-wake-lib.sh"
# Monitor liveness and revival, shared with the turn-end guard.
# shellcheck source=bin/cs-monitor-lib.sh
. "$SCRIPT_DIR/cs-monitor-lib.sh"
# Optional turn telemetry (off unless host/telemetry.conf enables it).
# shellcheck source=bin/cs-telemetry-lib.sh
. "$SCRIPT_DIR/cs-telemetry-lib.sh"

QUEUE="${CS_WAKE_QUEUE:-$STATE/.wake-queue}"
TURN_MARK="$STATE/.checkpoint-turn"

usage() {
  cat <<'EOF'
Usage: cs-watch-checkpoint.sh [--seconds <n>]

Ensure a persistent watcher (bin/cs-monitor.sh) is alive for this home, then
wait up to <n> seconds for the durable wake queue to become non-empty.
On queued wakes, print them (without consuming) and exit 0.
On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 124.
One checkpoint per turn: a second invocation in the same turn exits 3 without
waiting, and the harness turn-end hook clears the counter when the turn ends.
Queued wakes are drained by bin/cs-wake-drain.sh, never by this checkpoint.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --seconds)
      [ "$#" -gt 1 ] || { echo "error: --seconds requires a value" >&2; exit 2; }
      SECONDS_ARG=$2
      shift 2
      ;;
    --seconds=*)
      SECONDS_ARG=${1#--seconds=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SECONDS_ARG" in
  ''|*[!0-9]*) echo "error: --seconds must be a positive integer" >&2; exit 2 ;;
  0) echo "error: --seconds must be greater than zero" >&2; exit 2 ;;
esac

# The per-turn refusal. It comes before the telemetry crumb because a refused
# checkpoint supervised nothing and must not be counted as one, and before any
# wait because the whole point is to hand the turn back immediately. Ensuring the
# monitor first keeps the one side effect that still matters: whatever the agent
# does next, this home stays watched.
if [ -e "$TURN_MARK" ]; then
  cs_monitor_ensure "$STATE" || true
  cat >&2 <<'EOF'
checkpoint: refused - this turn already ran one. End the turn now.
Supervision continues without you: the monitor keeps watching this home, queued wakes are durable, and this home starts its own next turn when one lands.
EOF
  exit 3
fi
: > "$TURN_MARK" 2>/dev/null || true

# TELEMETRY, measurement only: a turn that ran a checkpoint supervised something,
# whether or not the checkpoint went on to return a wake or time out quietly.
# Recorded once here, ahead of every return path, so the quiet checkpoint - the
# "worker is still working, keep monitoring" turn this whole measurement exists
# to size - is never the one case that goes uncounted. Silent and unfailable.
cs_telemetry_crumb checkpoint || true

OUT=$(mktemp "${TMPDIR:-/tmp}/cs-watch-checkpoint.out.XXXXXX") || exit 1
ERR=$(mktemp "${TMPDIR:-/tmp}/cs-watch-checkpoint.err.XXXXXX") || {
  rm -f "$OUT"
  exit 1
}
trap 'rm -f "$OUT" "$ERR"' EXIT

run_with_perl_timeout() {
  perl -e '
    my $seconds = shift;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!\n";
    }
    local $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      select undef, undef, undef, 0.2;
      kill "KILL", -$pid;
      exit 124;
    };
    alarm $seconds;
    waitpid $pid, 0;
    exit($? >> 8);
  ' "$SECONDS_ARG" "$SCRIPT_DIR/cs-watch.sh"
}

run_watcher_inline() {  # fallback only: no monitor could be started
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout "$SECONDS_ARG" "$SCRIPT_DIR/cs-watch.sh" >"$OUT" 2>"$ERR"
    RC=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$SECONDS_ARG" "$SCRIPT_DIR/cs-watch.sh" >"$OUT" 2>"$ERR"
    RC=$?
  else
    run_with_perl_timeout >"$OUT" 2>"$ERR"
    RC=$?
  fi
  set -e

  if grep -E '^(signal:|stale:|check:|capo:|heartbeat($|:))' "$OUT" >/dev/null 2>&1; then
    cat "$OUT"
    [ ! -s "$ERR" ] || cat "$ERR" >&2
    exit 0
  fi
  if [ "$RC" -eq 124 ]; then
    printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG"
    exit 124
  fi
  [ ! -s "$OUT" ] || cat "$OUT"
  [ ! -s "$ERR" ] || cat "$ERR" >&2
  exit "$RC"
}

if ! cs_monitor_ensure "$STATE"; then
  echo "checkpoint: no persistent monitor could be started; watching inline for this checkpoint only" >&2
  run_watcher_inline
fi

# Wait for the durable queue to carry something. Rows are shown, never removed:
# bin/cs-wake-drain.sh is the one owner of draining and of drain-time dedupe.
WAITED=0
while [ "$WAITED" -lt "$SECONDS_ARG" ]; do
  if [ -s "$QUEUE" ]; then
    cs_wake_print_deduped "$QUEUE" | while IFS=$(printf '\t') read -r _epoch _seq kind key payload; do
      [ -n "$kind" ] || continue
      printf '%s: %s %s\n' "$kind" "$key" "$payload"
    done
    exit 0
  fi
  # A monitor that dies mid-wait is revived here too, so a long checkpoint can
  # never sit out the rest of its bound with nothing watching.
  cs_monitor_alive "$STATE" || cs_monitor_ensure "$STATE" || true
  sleep 1
  WAITED=$((WAITED + 1))
done

printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG"
exit 124
