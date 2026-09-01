#!/usr/bin/env bash
# tests/cs-monitor.test.sh - bin/cs-monitor.sh, the persistent per-home watcher
# owner. The property under test is the one the bounded foreground checkpoint
# could never provide: a home stays watched while its agent is busy, so an event
# raised with nobody waiting still lands in the durable queue.
#
# Hermetic: reuses the offline cs-watch fixtures (fake herdr + fake
# cs-crew-state.sh), and every monitor started here is stopped through its own
# marker so no detached process outlives the test.
#
# Every wait FOR something is a poll for that positive condition, never a fixed
# sleep. The two fixed sleeps below are the opposite shape and are deliberate:
# each one asserts that something did NOT happen across a window of several
# monitor cycles (a standing event not re-queued, a torn script not exec'd). A
# window is the assertion there, so those must not be converted into polls - a
# slow machine runs fewer cycles inside them, which makes them weaker, never
# falsely red.
set -u
# shellcheck source=tests/cs-watch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/cs-watch-helpers.sh"

MONITOR="$ROOT/bin/cs-monitor.sh"
TMP_ROOT=$(cs_test_tmproot cs-monitor)

# cs_path_mtime, for the beacon-freshness assertions. The override is this suite's
# OWN temp root, never the shared temp base: pointing a state override at the base
# aims a whole home's worth of machinery at a directory every other suite and the
# boss's live fleet also use, and this exact line is what failed CI on 2026-07-29
# when it read a bare $TMPDIR under `set -u` on a runner that has none.
# shellcheck source=bin/cs-wake-lib.sh
CS_STATE_OVERRIDE="$TMP_ROOT" . "$ROOT/bin/cs-wake-lib.sh"

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

# 4. An away-mode home is covered exactly like an attended one - there is no
#    separate away-mode supervisor left to defer to.
test_away_flag_is_covered_like_an_attended_home() {
  local dir state fakebin pid
  dir=$(make_case afk-covered); state="$dir/state"; fakebin="$dir/fakebin"
  : > "$state/.afk"
  printf 'blocked: needs a decision\n' > "$state/t1.status"
  monitor_bg "$state" "$fakebin"
  pid=$!
  wait_until 100 test -s "$state/.wake-queue" || {
    kill "$pid" 2>/dev/null || true
    cat "$state/.monitor.log" 2>/dev/null
    fail "an away-mode home must be covered exactly like an attended one"
  }
  monitor_stop "$state" "$pid"
  pass "an away-mode home is covered by its own watcher exactly like an attended one"
}

# Shared fixture for the self-replacement cases: a private bin/ whose
# cs-monitor.sh is a real copy, libraries symlinked, so only the monitor's own
# bytes change under the running process.
# Sets MON_BINDIR and MON_PID; never run under command substitution, which
# would strand both in a subshell.
MON_BINDIR=""
MON_PID=""
start_monitor_from_private_bin() {  # <dir> <state> <fakebin>
  local dir=$1 state=$2 fakebin=$3 f
  MON_BINDIR="$dir/bin"; mkdir -p "$MON_BINDIR"
  for f in "$ROOT"/bin/*; do ln -s "$f" "$MON_BINDIR/$(basename "$f")"; done
  rm -f "$MON_BINDIR/cs-monitor.sh"
  cp "$ROOT/bin/cs-monitor.sh" "$MON_BINDIR/cs-monitor.sh"
  chmod +x "$MON_BINDIR/cs-monitor.sh"
  env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
    CS_CREW_STATE_BIN="$fakebin/cs-crew-state.sh" CS_HERDR_EVENTS_FORCE=0 \
    CS_POLL=1 CS_SIGNAL_GRACE=1 CS_HEARTBEAT=999999 CS_MONITOR_TICK=1 \
    "$MON_BINDIR/cs-monitor.sh" >>"$state/.monitor.out" 2>&1 &
  MON_PID=$!
  wait_until 60 test -e "$state/.last-monitor-beat" || {
    kill "$MON_PID" 2>/dev/null || true
    fail "the monitor never published its beacon"
  }
}

# 7. A monitor runs for days, outliving the code it started from. On 2026-08-01
#    one started 13 hours before the away-mode liveness gate landed kept the old
#    stand-down and left the home unwatched 8h11m, beacon fresh throughout.
test_monitor_reexecs_when_its_script_changes() {
  local dir state fakebin bindir
  dir=$(make_case self-replace); state="$dir/state"; fakebin="$dir/fakebin"
  start_monitor_from_private_bin "$dir" "$state" "$fakebin"
  bindir=$MON_BINDIR

  # Replace by atomic rename, as a settled checkout leaves it.
  sed 's|^# cs-monitor.sh - .*|&  (replaced under the running process)|' \
    "$bindir/cs-monitor.sh" > "$dir/monitor.new"
  chmod +x "$dir/monitor.new"
  mv -f "$dir/monitor.new" "$bindir/cs-monitor.sh"

  wait_until 60 grep -q "re-executing to pick it up" "$state/.monitor.log" || {
    kill "$MON_PID" 2>/dev/null || true
    fail "the monitor kept running stale code after its script changed on disk"
  }
  kill -0 "$MON_PID" 2>/dev/null || fail "the monitor died instead of re-executing in place"
  monitor_stop "$state" "$MON_PID"
  pass "a monitor whose script changes on disk re-executes onto the new code"
}

# 8. `git checkout` does not write working-tree files atomically, so the
#    fingerprint can catch a half-written script. Exec'ing that would part-run a
#    truncated program with the lock already released.
test_monitor_does_not_exec_a_torn_script() {
  local dir state fakebin bindir
  dir=$(make_case self-replace-torn); state="$dir/state"; fakebin="$dir/fakebin"
  start_monitor_from_private_bin "$dir" "$state" "$fakebin"
  bindir=$MON_BINDIR

  # Changed bytes, syntactically invalid: exactly what a half-written file looks
  # like. Written in place, not renamed, to mimic a torn write.
  printf 'if [ 1 -eq 1 ]; then\n' >> "$bindir/cs-monitor.sh"

  sleep 4
  assert_no_grep "re-executing to pick it up" "$state/.monitor.log" \
    "the monitor exec'd a syntactically invalid script instead of waiting for it to settle"
  kill -0 "$MON_PID" 2>/dev/null || fail "the monitor died on a torn script instead of carrying on"
  monitor_stop "$state" "$MON_PID"
  pass "a torn (unparseable) script is left alone until it settles"
}

test_event_reaches_the_queue_with_nobody_waiting
test_standing_event_does_not_grow_the_queue
test_second_monitor_noops
test_away_flag_is_covered_like_an_attended_home
test_monitor_reexecs_when_its_script_changes
test_monitor_does_not_exec_a_torn_script

pass "cs-monitor persistent supervision contract"
