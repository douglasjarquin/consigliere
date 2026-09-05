#!/usr/bin/env bash
# Behavior: the push-based turn-end Stop-hook guard.
#
# Two properties, and they pull in opposite directions.
#
# It defers to the session that actually holds the home lock. The guard scopes to
# a PRIMARY checkout but that does not tell it whether THIS session is the
# supervisor; cs-session-start.sh already turns "another live consigliere session
# holds the fleet lock" into a read-only session, so the guard must step aside
# (exit 0) instead of nagging a secondary session to drive a fleet it does not
# own.
#
# And it blocks a stop only when this home could not WAKE ITSELF. Ending a turn
# is now the required thing to do - a turn that never ends cannot receive a boss
# message - so the old "work is under way and no watcher is live" predicate is
# gone. What survives is the case an ended turn really would lose: no monitor, no
# recorded pane, a record naming someone else's pane, or an activation stall.
#
# It also clears state/.checkpoint-turn, since a Stop hook is the one component
# that observes a turn boundary.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset CS_TASK_ID CS_ROOT_OVERRIDE CS_HOME CS_STATE_OVERRIDE CS_DATA_OVERRIDE

TMP_ROOT=$(cs_test_tmproot cs-turnend-guard)

# Widen the harness ancestry match so cs-lock.sh status recognizes the fake
# holders this test controls (a backgrounded sleep, and the test shell itself)
# as live "harness" processes - the same widening tests/cs-lock.test.sh uses.
GUARD_HARNESS_RE='sleep|bash|zsh|codex|claude'

BLOCK_BANNER='THIS HOME CANNOT WAKE ITSELF'

# make_primary_home <name>: a genuine primary-scoped consigliere home with one
# in-flight task and NO recorded home pane, so the wake-up predicate fails. A
# capo-home marker force-includes it so the fixture needs no real git checkout;
# AGENTS.md, bin/, and state/ satisfy the rest of cs_primary_scope_matches.
make_primary_home() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/bin" "$dir/state"
  printf 'testcapo\n' > "$dir/.cs-capo-home"
  printf '# fixture\n' > "$dir/AGENTS.md"
  cs_write_meta "$dir/state/task.meta" "window=consigliere:cs-task" "kind=ship"
  printf '%s\n' "$dir"
}

# make_wakeable_home <name>: the same home, but able to start its own next turn -
# a fresh monitor beacon and a recorded pane that matches this session's.
make_wakeable_home() {
  local dir
  dir=$(make_primary_home "$1")
  touch "$dir/state/.last-monitor-beat"
  printf 'w1:p1\n' > "$dir/state/.home-pane"
  printf '%s\n' "$dir"
}

# run_guard <home> [env...]: feed the Stop payload and run the guard scoped to
# <home>. Echoes combined stdout+stderr; the caller reads $? for the exit code.
# A monitor binary that cannot exist keeps the fixtures from detaching a real
# monitor into a temporary directory.
run_guard() {
  local home=$1; shift
  (
    cd "$home" && printf '{"stop_hook_active":false}' | \
      env CS_ROOT_OVERRIDE="$home" \
      CS_HOME="$home" \
      CS_GUARD_GRACE=999 \
      CS_LOCK_HARNESS_RE="$GUARD_HARNESS_RE" \
      CS_MONITOR_BIN="$home/no-such-monitor" \
      HERDR_PANE_ID=w1:p1 \
      "$@" "$ROOT/bin/cs-turnend-guard.sh" 2>&1
  )
}

test_defers_when_another_live_session_holds_lock() {
  local home out rc holder
  home=$(make_primary_home foreign-holder)

  # A live process that is NOT in the guard's ancestry holds the lock.
  sleep 300 &
  holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"

  out=$(run_guard "$home")
  rc=$?

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  expect_code 0 "$rc" "guard must defer (exit 0) when another live session holds the lock"
  assert_not_contains "$out" "$BLOCK_BANNER" \
    "guard must not print the block banner when it is not the lock holder"
  pass "cs-turnend-guard: defers when another live session holds the home lock"
}

test_permits_a_stop_when_the_home_can_wake_itself() {
  local home out rc
  home=$(make_wakeable_home wakeable)
  # Work in flight, lock free, and no checkpoint held: this is the ordinary turn
  # end the old predicate blocked and the whole change exists to allow.
  out=$(run_guard "$home")
  rc=$?

  expect_code 0 "$rc" "a home that can wake itself must be allowed to end its turn"
  [ -z "$out" ] || fail "a permitted turn end must print nothing, got:"$'\n'"$out"
  pass "cs-turnend-guard: permits an ordinary turn end while work is in flight"
}

test_blocks_when_no_monitor_can_be_started() {
  local home out rc
  home=$(make_wakeable_home dead-monitor)
  # The beacon is what proves a monitor is alive; without one, and with no
  # monitor binary to revive, nothing is watching after this turn.
  rm -f "$home/state/.last-monitor-beat"

  out=$(run_guard "$home")
  rc=$?

  expect_code 2 "$rc" "a dead, unrevivable monitor must block the stop"
  assert_contains "$out" "$BLOCK_BANNER" "the block must name the real problem"
  assert_contains "$out" "no watcher is running" "the block must say the monitor is gone"
  pass "cs-turnend-guard: blocks when the monitor is dead and cannot be revived"
}

test_blocks_when_activation_is_stalled() {
  local home out rc
  home=$(make_wakeable_home stalled)
  : > "$home/state/.activation-stalled"

  out=$(run_guard "$home")
  rc=$?

  expect_code 2 "$rc" "a stalled activation must block the stop"
  assert_contains "$out" "$BLOCK_BANNER" "a stalled home must be told it cannot wake itself"
  assert_contains "$out" "activation-stalled" "the block must name the durable marker"
  pass "cs-turnend-guard: blocks on state/.activation-stalled"
}

test_blocks_when_no_pane_is_recorded() {
  local home out rc
  home=$(make_wakeable_home no-pane)
  rm -f "$home/state/.home-pane"

  out=$(run_guard "$home")
  rc=$?

  expect_code 2 "$rc" "with no recorded pane nothing can start the next turn"
  assert_contains "$out" "no pane is recorded" "the block must name the missing record"
  pass "cs-turnend-guard: blocks when no home pane is recorded"
}

test_blocks_when_the_recorded_pane_is_someone_else() {
  local home out rc
  home=$(make_wakeable_home wrong-pane)
  # A recycled or stale record points activation at a pane this session does not
  # live in, so a wake would be delivered to whoever owns that pane now.
  printf 'w9:p9\n' > "$home/state/.home-pane"

  out=$(run_guard "$home")
  rc=$?

  expect_code 2 "$rc" "a record naming another pane must block the stop"
  assert_contains "$out" "not this one" "the block must say the record names another pane"
  pass "cs-turnend-guard: blocks when the recorded pane is not this session's"
}

test_no_work_in_flight_is_always_permitted() {
  local home out rc
  home=$(make_primary_home idle-home)
  # Nothing in flight and nothing armed: there is nothing riding on the wake-up
  # path, so none of the conditions above matter.
  rm -f "$home/state/task.meta"

  out=$(run_guard "$home")
  rc=$?

  expect_code 0 "$rc" "an idle home must always be allowed to end its turn"
  [ -z "$out" ] || fail "an idle turn end must print nothing, got:"$'\n'"$out"
  pass "cs-turnend-guard: an idle home ends its turn without a word"
}

test_away_mode_permits_a_stop_when_the_home_can_wake_itself() {
  local home out rc
  home=$(make_wakeable_home afk-wakeable)
  touch "$home/state/.afk"

  out=$(run_guard "$home")
  rc=$?

  expect_code 0 "$rc" "an away-mode home that can wake itself must be allowed to end its turn"
  [ -z "$out" ] || fail "a permitted away-mode turn end must print nothing, got:"$'\n'"$out"
  pass "cs-turnend-guard: away mode permits an ordinary turn end while the home can still wake itself"
}

# There is no separate away-mode supervisor left to fall back on: an away-mode
# home is covered by the exact same watch/monitor/activate triangle as an
# attended one, so a home that cannot wake itself must block the stop while
# away exactly as it would while attended. state/.afk once exempted this
# check entirely, on the reasoning that an away-mode daemon (with its own,
# separately-guarded liveness check) restarted turns instead - both the
# daemon and its liveness check are gone.
test_away_mode_blocks_when_the_home_cannot_wake_itself() {
  local home out rc
  home=$(make_primary_home afk-unwakeable)
  touch "$home/state/.afk"

  out=$(run_guard "$home")
  rc=$?

  expect_code 2 "$rc" "an away-mode home with no recorded pane must still block the stop"
  assert_contains "$out" "$BLOCK_BANNER" "an unwakeable away-mode home must be told it cannot wake itself"
  assert_contains "$out" "no pane is recorded" "the block must name the missing record"
  pass "cs-turnend-guard: away mode blocks the stop exactly like an attended home when it cannot wake itself"
}

test_clears_the_per_turn_checkpoint_marker() {
  local home
  # The Stop hook is the one component that observes a turn boundary, so it is
  # what releases the next turn's checkpoint. It must clear the marker on a
  # permitted stop AND on a blocked one, since a blocked stop continues the turn
  # precisely so the agent can supervise.
  home=$(make_wakeable_home clears-marker)
  : > "$home/state/.checkpoint-turn"
  run_guard "$home" >/dev/null
  assert_absent "$home/state/.checkpoint-turn" \
    "a permitted turn end must release the next turn's checkpoint"

  home=$(make_wakeable_home clears-marker-blocked)
  rm -f "$home/state/.last-monitor-beat"
  : > "$home/state/.checkpoint-turn"
  run_guard "$home" >/dev/null || true
  assert_absent "$home/state/.checkpoint-turn" \
    "a blocked stop must still release the checkpoint it is telling the agent to run"

  # Out of scope (no capo marker, not a plain checkout) means this is not a
  # primary home's turn boundary at all, so the marker is left alone.
  home=$(make_wakeable_home keeps-marker-out-of-scope)
  rm -f "$home/.cs-capo-home"
  : > "$home/state/.checkpoint-turn"
  run_guard "$home" >/dev/null
  assert_present "$home/state/.checkpoint-turn" \
    "a turn end outside the primary scope must not touch this home's counter"
  pass "cs-turnend-guard: clears the per-turn checkpoint marker at a primary turn boundary"
}

test_defers_when_another_live_session_holds_lock
test_permits_a_stop_when_the_home_can_wake_itself
test_blocks_when_no_monitor_can_be_started
test_blocks_when_activation_is_stalled
test_blocks_when_no_pane_is_recorded
test_blocks_when_the_recorded_pane_is_someone_else
test_no_work_in_flight_is_always_permitted
test_away_mode_permits_a_stop_when_the_home_can_wake_itself
test_away_mode_blocks_when_the_home_cannot_wake_itself
test_clears_the_per_turn_checkpoint_marker
