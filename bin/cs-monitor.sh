#!/usr/bin/env bash
# cs-monitor.sh - keep THIS home watched while its agent is busy.
#
# Why this exists: the bounded foreground checkpoint only exists while the agent
# is waiting on it. The instant the agent does real work instead of waiting,
# nothing polls this home, so a soldier or capo-worker event can sit unseen for
# as long as that turn lasts. Measured on the live fleet before this landed: a
# capo home went 2h10m with no poll while its agent worked, and a worker's
# `blocked:` event waited ten minutes and counting.
#
# What it is: a detached, self-healing supervisor that keeps a one-shot
# bin/cs-watch.sh running so wakes keep landing in the durable queue no matter
# what the agent is doing. It never injects, never reasons, and never talks to
# the boss. The durable queue is the whole handoff: the agent drains it at the
# start of its next wake-handling turn exactly as it already must.
#
# Ownership: while this monitor holds its lock it is the watcher's only owner,
# and bin/cs-watch-checkpoint.sh waits on the queue instead of running a watcher
# of its own. One owner, so there is no lock contention to arbitrate. An
# away-mode home (state/.afk) is covered exactly like an attended one: there is
# no separate away-mode supervisor left to defer to or arbitrate with.
#
# Self-replacement: this process outlives the code it started from, so it
# re-execs itself when bin/cs-monitor.sh changes on disk. Without that, a landed
# fix never reaches the monitor that needs it.
#
# Death is expected to be survivable, not impossible. A monitor that dies is
# revived by the next checkpoint (it re-launches on a stale beacon), so an
# unknown killer costs one checkpoint interval instead of a whole night. That is
# deliberate: the away-mode daemon died within a second of launch twice with no
# recoverable evidence, so this monitor refreshes state/.last-monitor-beat every
# cycle and appends its lifecycle to state/.monitor.log to leave a trail.
#
# Usage:
#   cs-monitor.sh            supervise until stopped
#   cs-monitor.sh --once     run one supervise cycle and exit (tests)
#
# Stop it by creating state/.monitor-stop; it exits within one cycle and removes
# the marker. A monitor whose home is gone exits rather than looping on nothing.
#
# Env:
#   CS_MONITOR_TICK        seconds between supervise cycles (default 5)
#   CS_MONITOR_LOG_MAX     bytes before the log is trimmed (default 262144)
#   CS_MONITOR_WATCH_BIN   watcher override (tests)
#   CS_MONITOR_ACTIVATE_BIN  per-home activation override (tests)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
# shellcheck source=bin/cs-wake-lib.sh
. "$SCRIPT_DIR/cs-wake-lib.sh"

# Captured before the arg loop consumes "$@", so a re-exec relaunches this
# monitor exactly as invoked. The array guards keep stock macOS Bash 3.2 from
# tripping over an empty array under `set -u`.
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
SELF_ARGS=()
if [ "$#" -gt 0 ]; then SELF_ARGS=("$@"); fi

# Content fingerprint of this script. cksum is portable and cheap enough to run
# every tick. It reports the STARTUP value whenever the file cannot be read, so
# a script that is missing or mid-replacement reads as UNCHANGED: the monitor
# keeps running rather than exec'ing something that is not there.
self_fingerprint() {
  local fp
  if [ -r "$SELF" ] && fp=$(cksum < "$SELF" 2>/dev/null) && [ -n "$fp" ]; then
    printf '%s\n' "$fp"
  else
    printf '%s\n' "${SELF_FP:-}"
  fi
}
SELF_FP=$(self_fingerprint)

ONCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --once) ONCE=1 ;;
    -h|--help)
      sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

WATCH="${CS_MONITOR_WATCH_BIN:-$SCRIPT_DIR/cs-watch.sh}"
# Per-home activation owner; see supervise_cycle. Overridable for tests.
ACTIVATE="${CS_MONITOR_ACTIVATE_BIN:-$SCRIPT_DIR/cs-activate.sh}"
[ -x "$WATCH" ] || { echo "error: watcher not found or not executable: $WATCH" >&2; exit 1; }

TICK=${CS_MONITOR_TICK:-5}
case "$TICK" in ''|*[!0-9]*|0) TICK=5 ;; esac
LOG_MAX=${CS_MONITOR_LOG_MAX:-262144}
case "$LOG_MAX" in ''|*[!0-9]*) LOG_MAX=262144 ;; esac

LOCK="$STATE/.monitor.lock"
BEAT="$STATE/.last-monitor-beat"
STOP="$STATE/.monitor-stop"
LOG="$STATE/.monitor.log"

mkdir -p "$STATE" 2>/dev/null || { echo "error: state directory is unavailable: $STATE" >&2; exit 1; }

log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$LOG_MAX" ]; then
    tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null
    rm -f "$LOG.tmp" 2>/dev/null || true
  fi
}

# Singleton: a second monitor in the same home would double every wake.
if ! cs_lock_try_acquire "$LOCK"; then
  if [ -n "${CS_LOCK_HELD_PID:-}" ]; then
    echo "monitor: already running pid $CS_LOCK_HELD_PID"
  else
    echo "monitor: already running"
  fi
  exit 0
fi

WATCHER_PID=""
cleanup() {
  if [ -n "${WATCHER_PID:-}" ]; then
    kill "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi
  cs_lock_release "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'log "monitor stopping on signal"; exit 0' HUP INT TERM

log "monitor starting (pid ${BASHPID:-$$}); home=$CS_HOME; tick=${TICK}s; watcher=$WATCH"

watcher_alive() {
  [ -n "${WATCHER_PID:-}" ] && kill -0 "$WATCHER_PID" 2>/dev/null
}

# One supervise cycle. Returns 1 when the monitor should stop.
supervise_cycle() {
  if [ -e "$STOP" ]; then
    rm -f "$STOP" 2>/dev/null || true
    log "monitor stopping on request marker"
    return 1
  fi
  if [ ! -d "$STATE" ]; then
    log "monitor stopping: state directory is gone"
    return 1
  fi

  touch "$BEAT" 2>/dev/null || true

  # A monitor runs for days, so it outlives the code it started from and a fix
  # landing in the meantime never reaches the process that needs it. On
  # 2026-08-01 a monitor started 13 hours before a liveness fix landed kept
  # running the stale logic and left a home unwatched for 8h11m, refreshing its
  # own beacon the whole time so nothing else could tell.
  #
  # `bash -n` before exec, because `git checkout` does NOT write working-tree
  # files atomically: a fingerprint read mid-write would otherwise exec a
  # truncated script, which bash will happily part-execute. A syntactically
  # invalid read is treated as "not settled yet" and retried next tick.
  #
  # Note this converges on whatever is on disk, including OLDER code if the home
  # switches to an older branch. That is deliberate: a home runs the code in its
  # checkout, and the alternative - never converging - is the incident above.
  if [ -x "$SELF" ] && [ "$(self_fingerprint)" != "$SELF_FP" ] && bash -n "$SELF" 2>/dev/null; then
    log "monitor script changed on disk; re-executing to pick it up"
    if [ -n "${WATCHER_PID:-}" ]; then
      kill "$WATCHER_PID" 2>/dev/null || true
      wait "$WATCHER_PID" 2>/dev/null || true
      WATCHER_PID=""
    fi
    # The lock is keyed on pid and exec keeps ours, so the replacement would
    # find the lock held by a live pid - itself - and exit as a duplicate.
    # Release first. Losing the microsecond race to another monitor is benign:
    # that one runs current code, which is the whole point.
    cs_lock_release "$LOCK" 2>/dev/null || true
    exec "$SELF" ${SELF_ARGS[@]+"${SELF_ARGS[@]}"}
  fi

  # Per-home activation. The monitor does NOT decide anything here and does not
  # inject: bin/cs-activate.sh owns scope, debounce, target validation, and the
  # guards, and it exits 0 and fast in the overwhelmingly common "not due" case.
  # Keeping the policy out of this file preserves the property that makes this
  # monitor safe to run everywhere - it never injects, never reasons, and so
  # needs no arbitration with anything else.
  if [ -x "$ACTIVATE" ]; then
    "$ACTIVATE" >/dev/null 2>&1 || true
  fi

  if ! watcher_alive; then
    # The watcher is one-shot: it exits after enqueuing an actionable wake. Its
    # stdout is discarded on purpose - the wake is already durable in the queue,
    # and this monitor has no one to report a reason to.
    "$WATCH" >/dev/null 2>>"$STATE/.monitor.watcher.err" &
    WATCHER_PID=$!
    log "watcher started pid $WATCHER_PID"
  fi
  return 0
}

if [ "$ONCE" = 1 ]; then
  supervise_cycle || exit 0
  exit 0
fi

while :; do
  supervise_cycle || exit 0
  sleep "$TICK"
done
