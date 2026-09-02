#!/usr/bin/env bash
# tests/cs-watch-signal-wait.test.sh - issue #152: replacing cs-watch.sh's
# 500ms CS_EVENT_SPOOL_TICK poll with a SIGUSR1 doorbell from
# bin/cs-herdr-event-hook.sh into an interruptible `sleep & wait`.
#
# Two levels, deliberately kept separate:
#   - hermetic function-level tests (source cs-watch.sh, call
#     cs_watch_block_for_wake and cs_watcher_lock_current_pid directly) prove
#     the interruptible-wait mechanics and the PID-identity safety checks in
#     isolation, fast and without a real subprocess per case;
#   - a real end-to-end subprocess test launches an actual cs-watch.sh
#     background process (reusing tests/cs-watch-helpers.sh's watch_bg) with
#     real events capable, appends a spool record, and invokes the REAL
#     bin/cs-herdr-event-hook.sh - not a stand-in - to prove the whole chain
#     wakes the watcher fast instead of waiting out the bounded budget.
set -u

# shellcheck source=tests/cs-watch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/cs-watch-helpers.sh"

WATCH="$ROOT/bin/cs-watch.sh"
HOOK="$ROOT/bin/cs-herdr-event-hook.sh"
TMP_ROOT=$(cs_test_tmproot cs-watch-signal-wait)

# --- 1. cs_watch_block_for_wake: interruptible, reaps its own child --------

test_block_for_wake_interrupted_by_signal() {
  local dir=$TMP_ROOT/interrupt out
  dir=$TMP_ROOT/interrupt
  out=$dir/out
  mkdir -p "$dir"
  cat > "$dir/driver.sh" <<EOF
#!/usr/bin/env bash
set -u
CS_HERDR_EVENTS_FORCE=0
# shellcheck source=/dev/null
. "$WATCH"
# Sourcing only loads the function; the real watcher installs this trap in
# its executed-only runtime section, so a driver testing the function alone
# must install it too, exactly as cs-watch.sh does, or SIGUSR1's default
# disposition (terminate) kills this whole process instead of interrupting
# the wait.
trap 'CS_WATCH_WAKE_GENERATION=\$((CS_WATCH_WAKE_GENERATION + 1))' USR1
start=\$SECONDS
cs_watch_block_for_wake 30
elapsed=\$((SECONDS - start))
echo "elapsed=\$elapsed generation=\$CS_WATCH_WAKE_GENERATION"
EOF
  chmod +x "$dir/driver.sh"
  "$dir/driver.sh" > "$out" &
  local pid=$!
  sleep 1
  kill -USR1 "$pid"
  wait "$pid"
  local result
  result=$(cat "$out")
  local elapsed
  elapsed=$(printf '%s' "$result" | sed -n 's/elapsed=\([0-9]*\).*/\1/p')
  [ -n "$elapsed" ] || fail "driver produced no elapsed reading: $result"
  [ "$elapsed" -lt 5 ] || fail "cs_watch_block_for_wake was not interrupted by SIGUSR1: waited ${elapsed}s of a 30s budget ($result)"
  assert_contains "$result" "generation=1" "the USR1 trap must bump CS_WATCH_WAKE_GENERATION exactly once"
  pass "cs_watch_block_for_wake returns immediately on SIGUSR1 instead of waiting the full budget"
}

test_block_for_wake_full_timeout_when_unsignaled() {
  local dir=$TMP_ROOT/timeout out
  dir=$TMP_ROOT/timeout
  out=$dir/out
  mkdir -p "$dir"
  cat > "$dir/driver.sh" <<EOF
#!/usr/bin/env bash
set -u
CS_HERDR_EVENTS_FORCE=0
# shellcheck source=/dev/null
. "$WATCH"
start=\$SECONDS
cs_watch_block_for_wake 1
elapsed=\$((SECONDS - start))
echo "elapsed=\$elapsed generation=\$CS_WATCH_WAKE_GENERATION"
EOF
  chmod +x "$dir/driver.sh"
  local result
  result=$("$dir/driver.sh")
  assert_contains "$result" "elapsed=1" "an unsignaled wait must run its full budget, not return early"
  assert_contains "$result" "generation=0" "no signal means the generation counter must not move"
  pass "cs_watch_block_for_wake with no signal blocks the full requested duration"
}

test_block_for_wake_reaps_its_sleep_child() {
  local dir=$TMP_ROOT/reap out
  dir=$TMP_ROOT/reap
  out=$dir/out
  mkdir -p "$dir"
  # cs_watch_block_for_wake called PLAIN (never backgrounded, matching real
  # usage - see its own header on why backgrounding it would defeat the
  # signal path the same way command substitution does). The sleep duration
  # is suffixed with this driver's own future pid (known only once launched
  # below, substituted via a second heredoc pass) so pgrep can find exactly
  # this test's child and nothing else that happens to be sleeping on the
  # machine, while still being a value `sleep` accepts.
  cat > "$dir/driver.sh.tmpl" <<'EOF'
#!/usr/bin/env bash
set -u
CS_HERDR_EVENTS_FORCE=0
# shellcheck source=/dev/null
. "__WATCH__"
trap 'CS_WATCH_WAKE_GENERATION=$((CS_WATCH_WAKE_GENERATION + 1))' USR1
cs_watch_block_for_wake 30.$$
echo done
EOF
  sed "s#__WATCH__#$WATCH#" "$dir/driver.sh.tmpl" > "$dir/driver.sh"
  chmod +x "$dir/driver.sh"
  "$dir/driver.sh" > "$out" &
  local pid=$!
  wait_until 30 pgrep -f "sleep 30.$pid" || { reap "$pid"; fail "the sleep child never appeared"; }
  kill -USR1 "$pid"
  wait "$pid" 2>/dev/null
  sleep 0.3
  pgrep -f "sleep 30.$pid" >/dev/null 2>&1 && fail "a sleep child from cs_watch_block_for_wake outlived the interrupted wait"
  assert_contains "$(cat "$out")" "done" "the driver must still complete after the interrupted wait"
  pass "cs_watch_block_for_wake leaves no leaked sleep child after an interrupted wait"
}

# --- 2. cs_watcher_lock_current_pid: the hook's own safety gate -------------

fake_watcher_start() {  # <lockdir> -> pid on stdout; the trap file is
                        # <lockdir>/usr1-received. Uses sleep+wait, NOT a
                        # foreground sleep: a foreground sleep defers its
                        # trap until the sleep itself completes (verified
                        # empirically), which would make every signal test
                        # here falsely pass by coincidence at full timeout.
                        #
                        # Explicitly redirects the backgrounded script's own
                        # stdin/stdout/stderr to /dev/null before returning
                        # this pid via `echo` - empirically necessary: a
                        # caller that captures this function's own output via
                        # `$(...)` forks a subshell for it, the background
                        # script inherits THAT subshell's stdout (the
                        # substitution's own pipe), and command substitution
                        # blocks until every fd referencing that pipe closes -
                        # not just the immediate subshell exiting. Without the
                        # redirect here, `pid=$(fake_watcher_start ...)`
                        # hangs until the fake watcher itself exits, which
                        # defeats the entire point of backgrounding it.
  local lockdir=$1 script
  script=$lockdir/../fake-watcher.sh
  cat > "$script" <<EOF
#!/usr/bin/env bash
trap 'echo GOT_USR1 >> "$lockdir/usr1-received"' USR1
sleep 30 &
sp=\$!
wait "\$sp"
EOF
  chmod +x "$script"
  "$script" </dev/null >/dev/null 2>&1 &
  echo $!
}

install_watcher_lock() {  # <state> <pid>
  local state=$1 pid=$2
  mkdir -p "$state/.watch.lock"
  echo "$pid" > "$state/.watch.lock/pid"
  # shellcheck source=bin/cs-session-pid-lib.sh
  . "$ROOT/bin/cs-session-pid-lib.sh"
  cs_pid_identity "$pid" > "$state/.watch.lock/pid-identity"
}

test_lock_current_pid_valid_watcher() {
  local dir=$TMP_ROOT/valid-pid state
  dir=$TMP_ROOT/valid-pid
  state=$dir/state
  mkdir -p "$state"
  local pid
  pid=$(fake_watcher_start "$state")
  sleep 0.3
  install_watcher_lock "$state" "$pid"
  # shellcheck source=bin/cs-wake-lib.sh
  . "$ROOT/bin/cs-wake-lib.sh"
  local result
  result=$(cs_watcher_lock_current_pid "$state")
  [ "$result" = "$pid" ] || fail "expected pid $pid, got '$result'"
  kill "$pid" 2>/dev/null
  pass "a valid, live, identity-matched watcher lock resolves to its pid"
}

test_lock_current_pid_missing_lock() {
  local dir=$TMP_ROOT/missing state
  dir=$TMP_ROOT/missing
  state=$dir/state
  mkdir -p "$state"
  # shellcheck source=bin/cs-wake-lib.sh
  . "$ROOT/bin/cs-wake-lib.sh"
  cs_watcher_lock_current_pid "$state" >/dev/null 2>&1 && fail "a missing .watch.lock must not resolve to any pid"
  pass "a missing endpoint (no .watch.lock) resolves to nothing"
}

test_lock_current_pid_malformed_fields() {
  local dir=$TMP_ROOT/malformed state
  dir=$TMP_ROOT/malformed
  state=$dir/state
  mkdir -p "$state/.watch.lock"
  # shellcheck source=bin/cs-wake-lib.sh
  . "$ROOT/bin/cs-wake-lib.sh"
  echo "not-a-pid" > "$state/.watch.lock/pid"
  echo "some-identity" > "$state/.watch.lock/pid-identity"
  cs_watcher_lock_current_pid "$state" >/dev/null 2>&1 && fail "a non-numeric pid must be rejected"
  echo "0" > "$state/.watch.lock/pid"
  cs_watcher_lock_current_pid "$state" >/dev/null 2>&1 && fail "pid 0 must be rejected"
  echo "1" > "$state/.watch.lock/pid"
  cs_watcher_lock_current_pid "$state" >/dev/null 2>&1 && fail "pid 1 must be rejected"
  pass "malformed or forbidden pid values (non-numeric, 0, 1) are all rejected"
}

test_lock_current_pid_dead_pid() {
  local dir=$TMP_ROOT/dead state
  dir=$TMP_ROOT/dead
  state=$dir/state
  mkdir -p "$state"
  local pid
  pid=$(fake_watcher_start "$state")
  sleep 0.3
  install_watcher_lock "$state" "$pid"
  kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  sleep 0.2
  # shellcheck source=bin/cs-wake-lib.sh
  . "$ROOT/bin/cs-wake-lib.sh"
  cs_watcher_lock_current_pid "$state" >/dev/null 2>&1 && fail "a dead pid must not resolve"
  pass "a pid that no longer exists is rejected"
}

test_lock_current_pid_reused_pid_rejected() {
  local dir=$TMP_ROOT/reused state
  dir=$TMP_ROOT/reused
  state=$dir/state
  mkdir -p "$state"
  local pid
  pid=$(fake_watcher_start "$state")
  sleep 0.3
  mkdir -p "$state/.watch.lock"
  echo "$pid" > "$state/.watch.lock/pid"
  # A stale identity that does not match this live pid's REAL identity - the
  # exact PID-reuse shape: the recorded pid is alive, but it is not the same
  # process the lock was written for.
  echo "stale-identity-from-a-different-process" > "$state/.watch.lock/pid-identity"
  # shellcheck source=bin/cs-wake-lib.sh
  . "$ROOT/bin/cs-wake-lib.sh"
  cs_watcher_lock_current_pid "$state" >/dev/null 2>&1 && fail "a live pid whose stored identity does not match must be rejected (PID reuse)"
  kill "$pid" 2>/dev/null
  pass "a live pid recorded under a stale/mismatched identity is rejected, not signaled as if current"
}

test_lock_current_pid_rejects_symlink_and_oversized() {
  local dir=$TMP_ROOT/symlink state
  dir=$TMP_ROOT/symlink
  state=$dir/state
  mkdir -p "$state/.watch.lock" "$dir/elsewhere"
  printf 'secret\n' > "$dir/elsewhere/target"
  ln -s "$dir/elsewhere/target" "$state/.watch.lock/pid"
  echo "x" > "$state/.watch.lock/pid-identity"
  # shellcheck source=bin/cs-wake-lib.sh
  . "$ROOT/bin/cs-wake-lib.sh"
  cs_watcher_lock_current_pid "$state" >/dev/null 2>&1 && fail "a symlinked pid record must be rejected, not followed"

  rm -f "$state/.watch.lock/pid"
  local pid
  pid=$(fake_watcher_start "$state")
  sleep 0.3
  echo "$pid" > "$state/.watch.lock/pid"
  cs_pid_identity() { :; }  # unused; identity file below is what matters
  yes x 2>/dev/null | head -c 1000 > "$state/.watch.lock/pid-identity"
  cs_watcher_lock_current_pid "$state" >/dev/null 2>&1 && fail "an oversized pid-identity record must be rejected"
  kill "$pid" 2>/dev/null
  pass "a symlinked or oversized record file is rejected without being read as trusted"
}

# --- 3. real end-to-end: the actual hook signals a real running watcher ----

test_real_hook_wakes_real_watcher_fast() {
  local dir state fakebin out pane home
  dir=$(make_case real-hook-wake); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  # shellcheck disable=SC2100  # false positive: a plain string assignment, not arithmetic
  pane=pane-real-1
  # cs_meta_validate_parent_values requires parent_state to be EXACTLY
  # "$parent_home/state" - home is the fixture's HOME root, not its state
  # subdirectory (spool_append in cs-watch-triage.test.sh computes the same
  # thing as ${state%/state}).
  home=${state%/state}
  cat > "$state/$pane.meta" <<EOF
task_id=$pane
kind=ship
home=$home
worktree=$state
workspace=ws-real
pane=$pane
harness=codex
parent_task_id=root
parent_home=$home
parent_state=$state
parent_pane=unknown
parent_generation=event-parent-generation
endpoint_generation=event-generation
herdr_session=default
EOF
  # A long POLL: if the hook's signal is what wakes it, the fast side of this
  # assertion (elapsed well under POLL) is unambiguous, not an artifact of a
  # short poll interval.
  watch_bg "$state" "$fakebin" "$out" env CS_HERDR_EVENTS_FORCE=1 CS_POLL=30
  local pid=$!
  wait_until 30 test -e "$state/.watch.lock/pid-identity" \
    || { reap "$pid"; fail "watcher did not publish its lock/identity in time"; }

  local before=$SECONDS
  HERDR_PLUGIN_EVENT=pane.agent_status_changed \
    HERDR_PLUGIN_EVENT_JSON="{\"pane_id\":\"$pane\",\"workspace_id\":\"ws-real\",\"agent_status\":\"blocked\",\"agent\":\"codex\"}" \
    "$HOOK" "$state"

  wait_for_exit "$pid" 50 >/dev/null 2>&1
  local elapsed=$((SECONDS - before))
  [ "$elapsed" -lt 10 ] || fail "the real hook -> real watcher signal path took ${elapsed}s against a 30s POLL - the doorbell is not interrupting the wait"
  assert_contains "$(cat "$out")" "$pane" "the surfaced record must name the pane the hook reported blocked"
  pass "the real event hook signals a real running watcher and wakes it well inside the POLL budget"
}

# --- 4. the acceptance criterion itself: idle process launches drop --------
# "Idle watcher process launches fall from roughly 240/minute/home to fewer
# than 5/minute/home" (issue #152 acceptance criteria). Proving this against
# a real wall-clock minute would be slow and flaky (ambient system load); the
# equivalent, deterministic proof is that ONE bounded idle wait spawns
# exactly ONE sleep child regardless of how long that wait is, where the old
# CS_EVENT_SPOOL_TICK design spawned one every 0.5s. A 3-second idle wait
# under the old design cost ~6 sleep + ~6 stat launches; under this design it
# costs exactly 1 sleep launch, a >80% reduction confirmed directly rather
# than extrapolated, and the same ratio holds at any wait length since the
# new design's cost is O(1) per wait instead of O(timeout).
test_idle_wait_spawns_exactly_one_sleep_child() {
  local dir=$TMP_ROOT/idle-count out
  dir=$TMP_ROOT/idle-count
  out=$dir/out
  mkdir -p "$dir"
  cat > "$dir/driver.sh.tmpl" <<'EOF'
#!/usr/bin/env bash
set -u
CS_HERDR_EVENTS_FORCE=0
# shellcheck source=/dev/null
. "__WATCH__"
trap 'CS_WATCH_WAKE_GENERATION=$((CS_WATCH_WAKE_GENERATION + 1))' USR1
cs_watch_block_for_wake "3.$$"
echo done
EOF
  sed "s#__WATCH__#$WATCH#" "$dir/driver.sh.tmpl" > "$dir/driver.sh"
  chmod +x "$dir/driver.sh"
  "$dir/driver.sh" > "$out" &
  local pid=$!
  wait_until 30 pgrep -f "sleep 3.$pid" || { reap "$pid"; fail "the sleep child never appeared"; }
  # Sample repeatedly across the 3s wait: at every sample, exactly one
  # matching sleep pid should exist - never zero (it would mean the wait
  # already ended early) and never more than one (it would mean a second
  # sleep was spawned mid-wait, the old tick-loop shape this replaces).
  local i seen max_seen=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    seen=$(pgrep -f "sleep 3.$pid" 2>/dev/null | wc -l | tr -d '[:space:]')
    [ "$seen" -gt "$max_seen" ] && max_seen=$seen
    [ "$seen" -le 1 ] || fail "expected at most one sleep child during the idle wait, saw $seen at sample $i"
    sleep 0.2
  done
  [ "$max_seen" -eq 1 ] || fail "expected to observe exactly one sleep child during the idle wait, saw a maximum of $max_seen"
  wait_for_exit "$pid" 50 >/dev/null 2>&1
  assert_contains "$(cat "$out")" "done" "the driver must complete once its one sleep child finishes naturally"
  pass "one 3-second idle wait spawns exactly one sleep child throughout, never re-spawning every tick"
}

test_block_for_wake_interrupted_by_signal
test_block_for_wake_full_timeout_when_unsignaled
test_block_for_wake_reaps_its_sleep_child
test_lock_current_pid_valid_watcher
test_lock_current_pid_missing_lock
test_lock_current_pid_malformed_fields
test_lock_current_pid_dead_pid
test_lock_current_pid_reused_pid_rejected
test_lock_current_pid_rejects_symlink_and_oversized
test_real_hook_wakes_real_watcher_fast
test_idle_wait_spawns_exactly_one_sleep_child

pass "cs-watch.sh signal-driven wait (issue #152)"
