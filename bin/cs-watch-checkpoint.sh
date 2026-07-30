#!/usr/bin/env bash
# Run one bounded foreground supervision checkpoint. Codex cannot reason during
# a foreground tool call, so this is consigliere's ONLY supervision wait shape:
# the checkpoint returns control regularly so queued wakes and boss messages
# are handled without background-task wake semantics.
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

MONITOR="${CS_CHECKPOINT_MONITOR_BIN:-$SCRIPT_DIR/cs-monitor.sh}"
DETACH="${CS_CHECKPOINT_DETACH_BIN:-$SCRIPT_DIR/cs-detach.py}"
MONITOR_BEAT="$STATE/.last-monitor-beat"
# A monitor refreshes its beacon every cycle (default 5s). Treat a beacon older
# than this as no monitor at all and revive.
MONITOR_STALE=${CS_MONITOR_STALE_SECS:-60}
QUEUE="${CS_WAKE_QUEUE:-$STATE/.wake-queue}"

usage() {
  cat <<'EOF'
Usage: cs-watch-checkpoint.sh [--seconds <n>]

Ensure a persistent watcher (bin/cs-monitor.sh) is alive for this home, then
wait up to <n> seconds for the durable wake queue to become non-empty.
On queued wakes, print them (without consuming) and exit 0.
On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 124.
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

path_age() {  # <path> - seconds since mtime, very large when missing
  local p=$1 m now
  m=$(cs_path_mtime "$p" 2>/dev/null) || { echo 999999; return; }
  [ -n "$m" ] || { echo 999999; return; }
  now=$(date +%s)
  echo $(( now - m ))
}

monitor_alive() {
  [ -e "$MONITOR_BEAT" ] || return 1
  [ "$(path_age "$MONITOR_BEAT")" -lt "$MONITOR_STALE" ]
}

# Revive on a stale or absent beacon. This is the whole durability story: a
# monitor killed by anything at all is restarted by the next checkpoint, so an
# unexplained death costs one checkpoint rather than the rest of the session.
ensure_monitor() {
  monitor_alive && return 0
  [ -x "$MONITOR" ] || return 1
  # Start it in its OWN session, not merely immune to SIGHUP. `nohup ... &
  # disown` does not survive teardown of this tool call's process group, and a
  # checkpoint always runs inside one: measured over a night, a monitor launched
  # that way died and was revived 213 times in seven hours in one home, while
  # the same binary with a surviving parent ran 9h20m without a single restart.
  # bin/cs-detach.py double-forks through setsid(2), which macOS exposes no
  # binary for. If python3 is missing (doctor reports it) fall back to the old
  # launch: degraded to the churn above, never to no monitor at all.
  if [ -x "$DETACH" ] && command -v python3 >/dev/null 2>&1; then
    python3 "$DETACH" --stdout "$STATE/.monitor.err" -- "$MONITOR" >/dev/null 2>&1
  else
    nohup "$MONITOR" >>"$STATE/.monitor.err" 2>&1 &
    disown 2>/dev/null || true
  fi
  local i=0
  while [ "$i" -lt 30 ]; do
    monitor_alive && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

if ! ensure_monitor; then
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
  monitor_alive || ensure_monitor || true
  sleep 1
  WAITED=$((WAITED + 1))
done

printf 'checkpoint: no actionable wake within %ss\n' "$SECONDS_ARG"
exit 124
