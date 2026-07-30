#!/usr/bin/env bash
# tests/cs-monitor.test.sh - bin/cs-monitor.sh, the persistent per-home watcher
# owner. The property under test is the one the bounded foreground checkpoint
# could never provide: a home stays watched while its agent is busy, so an event
# raised with nobody waiting still lands in the durable queue.
#
# Hermetic: reuses the offline cs-watch fixtures (fake herdr + fake
# cs-crew-state.sh). Every wait is a poll for a positive condition, never a
# fixed sleep, and every monitor started here is stopped through its own marker
# so no detached process outlives the test.
set -u
# shellcheck source=tests/cs-watch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/cs-watch-helpers.sh"
# cs_path_mtime, for the beacon-freshness assertions.
# shellcheck source=bin/cs-wake-lib.sh
CS_STATE_OVERRIDE="${TMPDIR:-/tmp}" . "$ROOT/bin/cs-wake-lib.sh"

MONITOR="$ROOT/bin/cs-monitor.sh"
TMP_ROOT=$(cs_test_tmproot cs-monitor)

# Start a monitor detached, exactly as a checkpoint would.
monitor_bg() {  # <state> <fakebin> [env...]
  local state=$1 fakebin=$2
  shift 2
  env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
    CS_CREW_STATE_BIN="$fakebin/cs-crew-state.sh" CS_HERDR_EVENTS_FORCE=0 \
    CS_POLL=1 CS_SIGNAL_GRACE=1 CS_HEARTBEAT=999999 CS_MONITOR_TICK=1 \
    "$@" "$MONITOR" >>"$state/.monitor.out" 2>&1 &
}

# Stop through the documented marker and confirm the monitor honored it.
monitor_stop() {  # <state> <pid>
  local state=$1 pid=$2
  touch "$state/.monitor-stop"
  wait_until 60 sh -c "! kill -0 $pid 2>/dev/null" || {
    kill "$pid" 2>/dev/null || true
    fail "the monitor ignored its stop marker"
  }
  [ ! -e "$state/.monitor-stop" ] || fail "the monitor must remove its own stop marker"
}

# 1. The whole point: an event raised while nothing is waiting still reaches the
#    durable queue, and the monitor keeps a fresh liveness beacon while it runs.
test_event_reaches_the_queue_with_nobody_waiting() {
  local dir state fakebin pid
  dir=$(make_case unattended); state="$dir/state"; fakebin="$dir/fakebin"
  printf 'blocked: needs a decision\n' > "$state/t1.status"
  monitor_bg "$state" "$fakebin"
  pid=$!
  wait_until 100 test -s "$state/.wake-queue" || {
    kill "$pid" 2>/dev/null || true
    cat "$state/.monitor.log" 2>/dev/null
    fail "no monitor caught the event while nothing was waiting on a checkpoint"
  }
  grep -F 't1.status' "$state/.wake-queue" >/dev/null || fail "the queued wake must name the status that raised it"
  [ -e "$state/.last-monitor-beat" ] || fail "the monitor must publish a liveness beacon"
  grep -F 'monitor starting' "$state/.monitor.log" >/dev/null || fail "the monitor must log its own lifecycle"
  grep -F 'watcher started' "$state/.monitor.log" >/dev/null || fail "the monitor must log the watcher it owns"
  monitor_stop "$state" "$pid"
  pass "an event raised with nobody waiting still reaches the durable queue"
}

# 2. A standing event must not grow the queue without bound: the watcher is
#    one-shot and the monitor restarts it, so a suppressor that failed to hold
#    would re-enqueue every cycle forever.
test_standing_event_does_not_grow_the_queue() {
  local dir state fakebin pid first second
  dir=$(make_case standing); state="$dir/state"; fakebin="$dir/fakebin"
  printf 'blocked: standing block\n' > "$state/t1.status"
  monitor_bg "$state" "$fakebin"
  pid=$!
  wait_until 100 test -s "$state/.wake-queue" || {
    kill "$pid" 2>/dev/null || true
    fail "the standing event never reached the queue"
  }
  first=$(wc -l < "$state/.wake-queue" | tr -d ' ')
  sleep 6
  second=$(wc -l < "$state/.wake-queue" | tr -d ' ')
  [ "$second" -le $((first + 1)) ] \
    || fail "a standing event grew the queue from $first to $second rows across cycles"
  monitor_stop "$state" "$pid"
  pass "a standing event does not grow the queue cycle after cycle"
}

# 3. Singleton: a second monitor in one home would double every wake.
test_second_monitor_noops() {
  local dir state fakebin pid out rc
  dir=$(make_case singleton); state="$dir/state"; fakebin="$dir/fakebin"
  monitor_bg "$state" "$fakebin"
  pid=$!
  wait_until 60 test -e "$state/.last-monitor-beat" || {
    kill "$pid" 2>/dev/null || true
    fail "the first monitor never became live"
  }
  set +e
  out=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
    CS_CREW_STATE_BIN="$fakebin/cs-crew-state.sh" CS_HERDR_EVENTS_FORCE=0 \
    CS_MONITOR_TICK=1 "$MONITOR" --once 2>&1); rc=$?
  set -e
  expect_code 0 "$rc" "a second monitor should no-op, not fail"
  assert_contains "$out" "already running" "the second monitor names the running one"
  monitor_stop "$state" "$pid"
  pass "a second monitor in the same home no-ops through its singleton lock"
}

# 4. Away mode's FLAG is not its daemon. Deferring to an owner that is not there
#    left a home unwatched with the flag present and the daemon gone - the exact
#    combination observed on 2026-07-30.
test_away_flag_without_a_live_daemon_is_covered() {
  local dir state fakebin pid
  dir=$(make_case afk-orphan); state="$dir/state"; fakebin="$dir/fakebin"
  : > "$state/.afk"
  # A pid that cannot be alive: away mode flagged, nobody home.
  printf '999999\n' > "$state/.subsuper-daemon.pid"
  printf 'blocked: needs a decision\n' > "$state/t1.status"
  monitor_bg "$state" "$fakebin"
  pid=$!
  wait_until 100 test -s "$state/.wake-queue" || {
    kill "$pid" 2>/dev/null || true
    cat "$state/.monitor.log" 2>/dev/null
    fail "an unattended away flag must not stop the monitor from covering the home"
  }
  grep -F 'daemon is NOT alive' "$state/.monitor.log" >/dev/null \
    || fail "the monitor must say why it covered instead of standing down"
  monitor_stop "$state" "$pid"
  pass "an away flag with no live daemon is covered, not deferred to"
}

# 5. With a LIVE daemon the stand-down still holds, or two supervisors would
#    both drive the watcher.
test_away_flag_with_a_live_daemon_still_stands_down() {
  local dir state fakebin pid sleeper
  dir=$(make_case afk-live); state="$dir/state"; fakebin="$dir/fakebin"
  : > "$state/.afk"
  sleep 120 & sleeper=$!
  printf '%s\n' "$sleeper" > "$state/.subsuper-daemon.pid"
  printf 'blocked: would wake a watcher\n' > "$state/t1.status"
  monitor_bg "$state" "$fakebin"
  pid=$!
  wait_until 60 test -e "$state/.last-monitor-beat" || {
    kill "$pid" "$sleeper" 2>/dev/null || true
    fail "a stood-down monitor must still publish its beacon"
  }
  sleep 4
  [ ! -s "$state/.wake-queue" ] || {
    kill "$pid" "$sleeper" 2>/dev/null || true
    fail "the monitor ran a watcher while a LIVE away daemon owned it"
  }
  monitor_stop "$state" "$pid"
  kill "$sleeper" 2>/dev/null || true
  pass "a live away daemon still gets the watcher to itself"
}

test_event_reaches_the_queue_with_nobody_waiting
test_standing_event_does_not_grow_the_queue
test_second_monitor_noops
test_away_flag_without_a_live_daemon_is_covered
test_away_flag_with_a_live_daemon_still_stands_down

pass "cs-monitor persistent supervision contract"
