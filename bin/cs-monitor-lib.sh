#!/usr/bin/env bash
# cs-monitor-lib.sh - one owner of "is this home's persistent monitor alive, and
# start one if it is not". Sourced, never executed. Requires cs-wake-lib.sh to be
# sourced first (cs_path_mtime).
#
# Two callers sit at the two ends of a turn and need the same answer:
# bin/cs-watch-checkpoint.sh, which must not wait on a queue nobody is filling,
# and bin/cs-turnend-guard.sh, for which a dead monitor is now the main condition
# that still makes ending a turn unsafe. Reviving from both ends is what keeps a
# monitor death costing one interval rather than the rest of the session.
#
# Env:
#   CS_MONITOR_BIN         monitor override (tests); default bin/cs-monitor.sh
#   CS_MONITOR_DETACH_BIN  detacher override (tests); default bin/cs-detach.py
#   CS_MONITOR_STALE_SECS  a beacon older than this is no monitor at all; default 60

CS_MONITOR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# cs_monitor_alive <state-dir>
# A monitor refreshes state/.last-monitor-beat every cycle (default 5s), so a
# beacon older than the stale bound is treated as no monitor at all.
cs_monitor_alive() {
  local beat="$1/.last-monitor-beat" stale m now
  stale=${CS_MONITOR_STALE_SECS:-60}
  case "$stale" in ''|*[!0-9]*|0) stale=60 ;; esac
  [ -e "$beat" ] || return 1
  m=$(cs_path_mtime "$beat" 2>/dev/null) || return 1
  [ -n "$m" ] || return 1
  now=$(date +%s)
  [ "$(( now - m ))" -lt "$stale" ]
}

# cs_monitor_ensure <state-dir>
# 0 when a monitor is alive by the time this returns; 1 when none could be
# started. Revival on a stale or absent beacon is the whole durability story.
cs_monitor_ensure() {
  local state=$1 monitor detach i=0
  cs_monitor_alive "$state" && return 0
  monitor=${CS_MONITOR_BIN:-$CS_MONITOR_LIB_DIR/cs-monitor.sh}
  detach=${CS_MONITOR_DETACH_BIN:-$CS_MONITOR_LIB_DIR/cs-detach.py}
  [ -x "$monitor" ] || return 1
  # Start it in its OWN session, not merely immune to SIGHUP. `nohup ... &
  # disown` does not survive teardown of the enclosing tool call's process
  # group, and both callers always run inside one: measured over a night, a
  # monitor launched that way died and was revived 213 times in seven hours in
  # one home, while the same binary with a surviving parent ran 9h20m without a
  # single restart. bin/cs-detach.py double-forks through setsid(2), which macOS
  # exposes no binary for. If python3 is missing (doctor reports it) fall back to
  # the old launch: degraded to the churn above, never to no monitor at all.
  if [ -x "$detach" ] && command -v python3 >/dev/null 2>&1; then
    python3 "$detach" --stdout "$state/.monitor.err" -- "$monitor" >/dev/null 2>&1
  else
    nohup "$monitor" >>"$state/.monitor.err" 2>&1 &
    disown 2>/dev/null || true
  fi
  while [ "$i" -lt 30 ]; do
    cs_monitor_alive "$state" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
