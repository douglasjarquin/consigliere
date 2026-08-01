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
# of its own. One owner, so there is no lock contention to arbitrate. While away
# mode holds (state/.afk) AND its daemon is provably supervising, that daemon
# owns the watcher, so this monitor stands down to a quiet tick rather than
# double-watching. The flag alone never earns the stand-down: see
# away_daemon_alive.
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
#   CS_AFK_BEAT_STALE      seconds before the away daemon's completed-pass
#                          counter reads stale and this monitor covers the home
#                          instead of standing down (default 180)
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
      sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

WATCH="${CS_MONITOR_WATCH_BIN:-$SCRIPT_DIR/cs-watch.sh}"
[ -x "$WATCH" ] || { echo "error: watcher not found or not executable: $WATCH" >&2; exit 1; }

TICK=${CS_MONITOR_TICK:-5}
case "$TICK" in ''|*[!0-9]*|0) TICK=5 ;; esac
LOG_MAX=${CS_MONITOR_LOG_MAX:-262144}
case "$LOG_MAX" in ''|*[!0-9]*) LOG_MAX=262144 ;; esac
BEAT_STALE=${CS_AFK_BEAT_STALE:-180}
case "$BEAT_STALE" in ''|*[!0-9]*|0) BEAT_STALE=180 ;; esac

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

# Is away mode's daemon actually SUPERVISING? A pid is not that question's
# answer: it stays alive through a recycled pid and through a daemon wedged off
# its loop, and either one buys a stand-down that lasts all night. The daemon's
# completed-pass counter must also be fresh. bin/cs-daemon.sh writes it only at
# the BOTTOM of a pass, so its early-continue paths - pane gone, watcher crash
# backoff - correctly read as not supervising and this monitor covers the home.
# The bound sits above the daemon's own 60s crash backoff so a daemon that is
# legitimately backing off is never mistaken for a dead one.
away_daemon_alive() {
  local pid beat_age
  pid=$(cat "$STATE/.subsuper-daemon.pid" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  # cs_path_age (cs-wake-lib) reports 999999 for a missing file, so a daemon
  # that never wrote a counter fails this exactly as a dead one does.
  beat_age=$(cs_path_age "$STATE/.subsuper-daemon-beat")
  case "$beat_age" in ''|*[!0-9]*) return 1 ;; esac
  [ "$beat_age" -le "$BEAT_STALE" ]
}

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

  # Liveness first, so a monitor that is alive but standing down (away mode) is
  # still visibly alive and never revived on top of itself.
  touch "$BEAT" 2>/dev/null || true

  # A monitor runs for days, so it outlives the code it started from and a fix
  # landing in the meantime never reaches the process that needs it. On
  # 2026-08-01 a monitor started 13 hours before the away-mode liveness gate was
  # written kept the old flag-only stand-down and left the home unwatched for
  # 8h11m, refreshing its own beacon the whole time so nothing else could tell.
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

  # Stand down for away mode ONLY while its daemon is actually alive. The flag
  # alone is not enough: the away daemon has died seconds after arming on every
  # recorded occasion, and deferring to a dead owner left the home with nobody
  # watching at all - flag present, daemon gone, monitor politely idle. Verified
  # the hard way on 2026-07-30, when the main home sat unwatched until the flag
  # was removed by hand.
  if [ -e "$STATE/.afk" ] && away_daemon_alive; then
    if watcher_alive; then
      kill "$WATCHER_PID" 2>/dev/null || true
      wait "$WATCHER_PID" 2>/dev/null || true
      WATCHER_PID=""
      log "standing down: away mode holds and its daemon (pid $(cat "$STATE/.subsuper-daemon.pid" 2>/dev/null)) owns the watcher"
    fi
    return 0
  fi
  if [ -e "$STATE/.afk" ]; then
    # Away mode is flagged but unattended. Cover the home rather than defer to a
    # supervisor that is not there; the daemon reclaims the watcher through the
    # singleton lock if it ever comes back.
    if [ ! -e "$STATE/.monitor-afk-orphan" ]; then
      : > "$STATE/.monitor-afk-orphan"
      log "away mode is flagged but its daemon is NOT alive; covering the home instead of standing down"
    fi
  elif [ -e "$STATE/.monitor-afk-orphan" ]; then
    rm -f "$STATE/.monitor-afk-orphan" 2>/dev/null || true
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
