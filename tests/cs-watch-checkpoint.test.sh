#!/usr/bin/env bash
# Behavior: characterization tests for bin/cs-watch-checkpoint.sh, the one
# bounded foreground supervision wait. It runs bin/cs-watch.sh under a timeout
# and translates the outcome:
#
# Contract (from the script header/usage + code):
#   Usage: cs-watch-checkpoint.sh [--seconds <n>]. Default seconds come from
#   $CS_WATCH_CHECKPOINT (else 180). Argument validation exits 2:
#     --seconds with no value, a non-positive-integer value, or 0; any unknown
#     argument (also reprints usage). -h/--help prints usage and exits 0.
#   Runtime outcomes:
#     - an actionable watcher wake (stdout matching
#       ^(signal:|stale:|check:|heartbeat) ) -> pass the watcher output through,
#       exit 0.
#     - a quiet checkpoint (watcher timed out, RC 124) -> print
#       "checkpoint: no actionable wake within <n>s" and exit 124.
#     - queued wakes are printed WITHOUT being consumed (bin/cs-wake-drain.sh
#       owns draining), and a home with no startable monitor still watches
#       inline for the bound rather than not at all.
#
# Hermetic: reuses the offline cs-watch fixtures (fake herdr + fake
# cs-crew-state.sh) so the real cs-watch.sh runs with no live backend. The
# runtime cases keep --seconds tiny and assert exit codes / printed markers,
# never wall-clock timing.
set -u
# shellcheck source=tests/cs-watch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/cs-watch-helpers.sh"

CHECKPOINT="$ROOT/bin/cs-watch-checkpoint.sh"
TMP_ROOT=$(cs_test_tmproot cs-watch-checkpoint)

# --- argument validation (no watcher is ever launched) -----------------------

# 1. --help prints usage and exits 0.
out=$("$CHECKPOINT" --help 2>&1); rc=$?
expect_code 0 "$rc" "--help should exit 0"
assert_contains "$out" "Usage: cs-watch-checkpoint.sh" "--help prints usage"
pass "cs-watch-checkpoint --help prints usage and exits 0"

# 2. --seconds 0 -> exit 2.
set +e
out=$("$CHECKPOINT" --seconds 0 2>&1); rc=$?
set -e
expect_code 2 "$rc" "--seconds 0 should exit 2"
assert_contains "$out" "must be greater than zero" "zero seconds is rejected"
pass "cs-watch-checkpoint rejects --seconds 0 with exit 2"

# 3. --seconds <non-integer> -> exit 2.
set +e
out=$("$CHECKPOINT" --seconds abc 2>&1); rc=$?
set -e
expect_code 2 "$rc" "non-integer seconds should exit 2"
assert_contains "$out" "must be a positive integer" "non-integer seconds is rejected"
pass "cs-watch-checkpoint rejects a non-integer --seconds with exit 2"

# 4. --seconds with no value -> exit 2.
set +e
out=$("$CHECKPOINT" --seconds 2>&1); rc=$?
set -e
expect_code 2 "$rc" "--seconds with no value should exit 2"
assert_contains "$out" "requires a value" "missing --seconds value is rejected"
pass "cs-watch-checkpoint rejects --seconds with no value (exit 2)"

# 5. unknown argument -> exit 2, reprints usage.
set +e
out=$("$CHECKPOINT" --bogus 2>&1); rc=$?
set -e
expect_code 2 "$rc" "unknown argument should exit 2"
assert_contains "$out" "unknown argument" "unknown argument is named"
assert_contains "$out" "Usage: cs-watch-checkpoint.sh" "unknown argument reprints usage"
pass "cs-watch-checkpoint rejects an unknown argument with exit 2 and usage"

# --- runtime: quiet checkpoint -----------------------------------------------

# 6. an empty fleet produces a quiet checkpoint: the watcher finds nothing to do
#    within the bound, so the checkpoint times out (exit 124) and says so.
dir=$(make_case quiet); state="$dir/state"; fakebin="$dir/fakebin"
set +e
out=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
  CS_CREW_STATE_BIN="$fakebin/cs-crew-state.sh" CS_HERDR_EVENTS_FORCE=0 \
  CS_POLL=1 "$CHECKPOINT" --seconds 1 2>&1); rc=$?
set -e
expect_code 124 "$rc" "a quiet checkpoint should exit 124"
assert_contains "$out" "checkpoint: no actionable wake within 1s" "quiet checkpoint reports the bound"
pass "cs-watch-checkpoint exits 124 with a quiet-checkpoint message when nothing is actionable"

# --- runtime: actionable wake passthrough ------------------------------------

# 7. a boss-relevant signal makes the watcher wake; the checkpoint passes the
#    watcher output through and exits 0.
dir=$(make_case actionable); state="$dir/state"; fakebin="$dir/fakebin"
printf 'working: setup\nneeds-decision: pick A or B\n' > "$state/task.status"
set +e
out=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
  CS_CREW_STATE_BIN="$fakebin/cs-crew-state.sh" CS_HERDR_EVENTS_FORCE=0 \
  CS_POLL=1 CS_SIGNAL_GRACE=1 "$CHECKPOINT" --seconds 20 2>&1); rc=$?
set -e
expect_code 0 "$rc" "an actionable wake should exit 0"
assert_contains "$out" "signal:" "actionable wake passes the watcher signal reason through"
assert_contains "$out" "task.status" "actionable wake names the status file that woke it"
pass "cs-watch-checkpoint passes an actionable watcher wake through and exits 0"

# --- runtime: the queue is shown, never consumed ------------------------------

# 8. a wake already sitting in the durable queue returns immediately, and the
#    queue still holds it afterwards: draining belongs to cs-wake-drain.sh, so a
#    checkpoint that consumed rows would lose wakes the agent never saw.
dir=$(make_case prequeued); state="$dir/state"; fakebin="$dir/fakebin"
printf '%s\t1\tsignal\ttask.status\tsignal: /tmp/task.status\n' "$(date +%s)" > "$state/.wake-queue"
set +e
out=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
  CS_CREW_STATE_BIN="$fakebin/cs-crew-state.sh" CS_HERDR_EVENTS_FORCE=0 \
  CS_POLL=1 "$CHECKPOINT" --seconds 5 2>&1); rc=$?
set -e
expect_code 0 "$rc" "an already-queued wake should exit 0"
assert_contains "$out" "signal: task.status" "the queued wake is reported"
[ -s "$state/.wake-queue" ] || fail "the checkpoint must not consume the queue"
pass "cs-watch-checkpoint reports queued wakes without consuming them"

# --- runtime: no startable monitor still watches inline ----------------------

# 9. when no monitor can be started the checkpoint says so and falls back to
#    watching inline for this bound. Degrading to the old behavior is the point:
#    a monitor that cannot launch must not mean nothing is watching.
dir=$(make_case no-monitor); state="$dir/state"; fakebin="$dir/fakebin"
printf 'needs-decision: pick A or B\n' > "$state/task.status"
set +e
out=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
  CS_CREW_STATE_BIN="$fakebin/cs-crew-state.sh" CS_HERDR_EVENTS_FORCE=0 \
  CS_CHECKPOINT_MONITOR_BIN="$dir/no-such-monitor" \
  CS_POLL=1 CS_SIGNAL_GRACE=1 "$CHECKPOINT" --seconds 20 2>&1); rc=$?
set -e
expect_code 0 "$rc" "the inline fallback should still surface an actionable wake"
assert_contains "$out" "no persistent monitor could be started" "the fallback is announced, never silent"
assert_contains "$out" "signal:" "the inline fallback still passes the wake through"
pass "cs-watch-checkpoint falls back to inline watching when no monitor can start"

pass "cs-watch-checkpoint bounded-checkpoint behavior characterized"
