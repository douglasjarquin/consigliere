#!/usr/bin/env bash
# Behavior: bin/cs-control.sh's interrupt and exit verbs, hermetically, with a
# fake herdr (no real agent):
#   1. The verb list is closed and targeting is exact: an unknown verb, a missing
#      id, an unknown task, and a wrong-verb flag are all refused.
#   2. CS_HOME must be explicit, like bin/cs-send.sh.
#   3. A capo target refuses exit and relaunch and allows interrupt; a headless
#      scout refuses every verb.
#   4. An endpoint herdr cannot positively confirm is refused, dead or unknown.
#   5. interrupt: a positively idle agent is idempotent success, a stopped turn
#      is success, a turn observed still running is reported unconfirmed, native
#      blocked is reported as such, a husk pane is reported agent-gone rather
#      than idle - including the stale-belief shape where `agent get` still
#      reports an agent whose process has left - an uncorroborated state is
#      reported state-unknown rather than idle or still-working, and the key is
#      delivered EXACTLY once in every case.
#   6. exit: already-gone is idempotent success, the harness's own exit command
#      is sent verbatim with no operational-input marker, a busy target is
#      interrupted first, unsent composer text is flushed with exactly one Enter
#      before the command is typed, and an agent that stays is reported
#      unconfirmed.
set -u
# shellcheck source=tests/control-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/control-helpers.sh"
# shellcheck source=bin/cs-marker-lib.sh
. "$ROOT/bin/cs-marker-lib.sh"

CONTROL="$ROOT/bin/cs-control.sh"
TMP=$(cs_test_tmproot cs-control)
FAKEBIN=$(cs_fakebin "$TMP")
cs_control_fake_herdr "$FAKEBIN"
export PATH="$FAKEBIN:$PATH"
# Keep the failure paths quick: the stub answers instantly, so the only cost of
# these bounds is how long an UNCONFIRMED postcondition takes to report.
export CS_CONTROL_INTERRUPT_WAIT_SECS=2 CS_CONTROL_EXIT_WAIT_SECS=2 CS_CONTROL_EXIT_SETTLE=0
export CS_CONTROL_FLUSH_SETTLE=0

setup_home() { # <name> [meta key=value...] -> home path with a `t1` task recorded
  # The name is explicit because every call runs in a command substitution, so a
  # shared counter would increment only inside the subshell and every home would
  # be the same directory.
  local home="$TMP/home-$1"
  shift
  mkdir -p "$home/state" "$home/data/t1"
  printf 'do the thing\n' > "$home/data/t1/brief.md"
  cs_write_meta "$home/state/t1.meta" \
    "workspace=w1" "pane=w1:p1" "worktree=$home/wt" "project=$home/proj" \
    "kind=ship" "mode=no-mistakes" "yolo=off" "harness=codex" "$@"
  printf '%s\n' "$home"
}

run_control() { # <home> <state-dir> <log> -- <args...>
  local home=$1 state=$2 log=$3
  shift 3
  : > "$log"
  cs_control_set "$state" log "$log"
  env CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" CS_DATA_OVERRIDE="$home/data" \
    FAKE_STATE="$state" "$CONTROL" "$@" 2>&1
}

# --- 1/2. usage, allowlist, exact targeting ---------------------------------

out=$("$CONTROL" --help 2>&1) || fail "--help must exit 0"
assert_contains "$out" "cs-control.sh interrupt <task-id>" "--help prints the usage"
assert_contains "$out" "There is no arbitrary-text and no raw-key entry point" "--help states the closed surface"
pass "cs-control: --help documents the closed verb surface"

home=$(setup_home usage)
state=$(cs_control_state "$TMP/s-usage" agent=codex status=idle)
rc=0
out=$(env CS_HOME= CS_STATE_OVERRIDE="$home/state" FAKE_STATE="$state" "$CONTROL" interrupt t1 2>&1) || rc=$?
expect_code 1 "$rc" "an empty CS_HOME refuses"
assert_contains "$out" "CS_HOME is not set" "the refusal names the missing home"

for bad in "send" "kill" "resume"; do
  rc=0
  out=$(run_control "$home" "$state" "$TMP/l" "$bad" t1) || rc=$?
  expect_code 2 "$rc" "'$bad' is not a verb"
  assert_contains "$out" "is not a lifecycle verb" "the refusal names the allowlist for '$bad'"
done
rc=0
out=$(run_control "$home" "$state" "$TMP/l" interrupt) || rc=$?
expect_code 2 "$rc" "a verb with no task id refuses"
rc=0
out=$(run_control "$home" "$state" "$TMP/l" interrupt w1:p1) || rc=$?
expect_code 2 "$rc" "an explicit pane id is not a target"
assert_contains "$out" "is a pane id" "targeting is by recorded task id only"
rc=0
out=$(run_control "$home" "$state" "$TMP/l" interrupt nosuch) || rc=$?
expect_code 1 "$rc" "an unknown task refuses"
rc=0
out=$(run_control "$home" "$state" "$TMP/l" interrupt t1 --note x) || rc=$?
expect_code 2 "$rc" "--note is refused outside relaunch"
assert_contains "$out" "--note applies only to relaunch" "flags are scoped to their verb"
pass "cs-control: closed verb list, exact task targeting, per-verb flags"

# --- 3. refused target kinds ------------------------------------------------

capo_home=$(setup_home capo "kind=capo" "mode=capo" "home=$TMP/capo")
state=$(cs_control_state "$TMP/s-capo" agent=codex status=idle on_esc=idle)
rc=0
out=$(run_control "$capo_home" "$state" "$TMP/l" exit t1) || rc=$?
expect_code 1 "$rc" "exit on a capo refuses"
assert_contains "$out" "capo-provisioning" "the exit refusal points at the owning skill"
rc=0
out=$(run_control "$capo_home" "$state" "$TMP/l" relaunch t1 --note n) || rc=$?
expect_code 1 "$rc" "relaunch on a capo refuses"
assert_contains "$out" "capo-provisioning" "the relaunch refusal points at the owning skill"
rc=0
out=$(run_control "$capo_home" "$state" "$TMP/l" interrupt t1) || rc=$?
expect_code 0 "$rc" "interrupt on a capo is allowed"
pass "cs-control: a capo refuses exit and relaunch, and accepts interrupt"

headless_home=$(setup_home headless "kind=scout" "headless=1")
for verb in interrupt exit; do
  rc=0
  out=$(run_control "$headless_home" "$state" "$TMP/l" "$verb" t1) || rc=$?
  expect_code 1 "$rc" "$verb on a headless scout refuses"
  assert_contains "$out" "headless scout" "the $verb refusal names the reason"
done
rc=0
out=$(run_control "$headless_home" "$state" "$TMP/l" relaunch t1 --note n) || rc=$?
expect_code 1 "$rc" "relaunch on a headless scout refuses"
assert_contains "$out" "headless scout" "the relaunch refusal names the reason"
pass "cs-control: a headless scout refuses every lifecycle verb"

# --- 4. the endpoint must be positively confirmed ---------------------------

home=$(setup_home codex)
dead=$(cs_control_state "$TMP/s-dead" agent=codex pane_absent=1)
rc=0
out=$(run_control "$home" "$dead" "$TMP/l" interrupt t1) || rc=$?
expect_code 1 "$rc" "a confirmed-absent pane refuses"
assert_contains "$out" "no endpoint left" "a dead pane is reported as gone"
garbage=$(cs_control_state "$TMP/s-garbage" agent=codex pane_garbage=1)
rc=0
out=$(run_control "$home" "$garbage" "$TMP/l" interrupt t1) || rc=$?
expect_code 1 "$rc" "an unreachable herdr refuses"
assert_contains "$out" "could not confirm pane" "an unknown presence is never read as an answer"
pass "cs-control: dead and unknown endpoints are refused, and told apart"

# --- 5. interrupt postconditions -------------------------------------------

esc_count() { grep -c -- 'send-keys w1:p1 esc' "$1" || true; }

idle=$(cs_control_state "$TMP/s-idle" agent=codex status=idle)
out=$(run_control "$home" "$idle" "$TMP/l-idle" interrupt t1) || fail "interrupt on an idle agent must succeed: $out"
assert_contains "$out" "no turn was running" "an idle target is idempotent success"
[ "$(esc_count "$TMP/l-idle")" -eq 0 ] || fail "an idle target must not be sent the interrupt key"

stops=$(cs_control_state "$TMP/s-stops" agent=codex status=working on_esc=idle)
out=$(run_control "$home" "$stops" "$TMP/l-stops" interrupt t1) || fail "a stopped turn must succeed: $out"
assert_contains "$out" "turn stopped, agent still running" "a cancelled turn is reported as stopped"
[ "$(esc_count "$TMP/l-stops")" -eq 1 ] || fail "the interrupt key must be delivered exactly once"

wedged=$(cs_control_state "$TMP/s-wedged" agent=codex status=working)
rc=0
out=$(run_control "$home" "$wedged" "$TMP/l-wedged" interrupt t1) || rc=$?
expect_code 1 "$rc" "a turn that will not stop is a failure"
assert_contains "$out" "NOT confirmed" "an unconfirmed interrupt says so"
[ "$(esc_count "$TMP/l-wedged")" -eq 1 ] || fail "an unconfirmed interrupt must not re-send the key"

blocked=$(cs_control_state "$TMP/s-blocked" agent=codex status=blocked)
rc=0
out=$(run_control "$home" "$blocked" "$TMP/l-blocked" interrupt t1) || rc=$?
expect_code 1 "$rc" "a human-blocked agent is not interruptible"
assert_contains "$out" "waiting on a human" "native blocked is reported as itself"
[ "$(esc_count "$TMP/l-blocked")" -eq 0 ] || fail "a blocked agent must not be sent the interrupt key"

vanished=$(cs_control_state "$TMP/s-vanished" agent=codex status=working on_esc=gone)
rc=0
out=$(run_control "$home" "$vanished" "$TMP/l-vanished" interrupt t1) || rc=$?
expect_code 1 "$rc" "an agent that left with the turn is not a clean interrupt"
assert_contains "$out" "no longer holds an agent" "interrupt never reports an exit as an interrupt"

huski=$(cs_control_state "$TMP/s-huski" agent= status=idle)
rc=0
out=$(run_control "$home" "$huski" "$TMP/l-huski" interrupt t1) || rc=$?
expect_code 1 "$rc" "a husk pane is not an idle agent"
assert_contains "$out" "no longer holds an agent" "a husk is reported as agent-gone, not idle"
[ "$(esc_count "$TMP/l-huski")" -eq 0 ] || fail "a husk must not be sent the interrupt key"

unreadable=$(cs_control_state "$TMP/s-unreadable" agent= status=idle procinfo_fail=1)
rc=0
out=$(run_control "$home" "$unreadable" "$TMP/l-unreadable" interrupt t1) || rc=$?
expect_code 1 "$rc" "an unreadable agent state is not an idle agent"
assert_contains "$out" "cannot be positively read" "cannot-tell is reported as state-unknown, not idle"
[ "$(esc_count "$TMP/l-unreadable")" -eq 0 ] || fail "an unreadable state must not be sent the interrupt key"

stale=$(cs_control_state "$TMP/s-stale" agent=codex status=idle proc_absent=1)
rc=0
out=$(run_control "$home" "$stale" "$TMP/l-stale" interrupt t1) || rc=$?
expect_code 1 "$rc" "herdr's belief without an agent process is not an idle agent"
assert_contains "$out" "no longer holds an agent" "a stale-belief husk is reported agent-gone, not idle"
[ "$(esc_count "$TMP/l-stale")" -eq 0 ] || fail "a stale-belief husk must not be sent the interrupt key"

murky=$(cs_control_state "$TMP/s-murky" agent=codex status=working on_esc=idle procinfo_fail=1)
rc=0
out=$(run_control "$home" "$murky" "$TMP/l-murky" interrupt t1) || rc=$?
expect_code 1 "$rc" "a stop that cannot be corroborated is not confirmed"
assert_contains "$out" "cannot be positively read" "an uncorroborated final reading is state-unknown, not still-working"
[ "$(esc_count "$TMP/l-murky")" -eq 1 ] || fail "the murky case still delivers the key exactly once"
pass "cs-control: every interrupt outcome is verified, and the key is sent once"

# --- 6. exit postconditions -------------------------------------------------

husk=$(cs_control_state "$TMP/s-husk" agent= status=idle)
out=$(run_control "$home" "$husk" "$TMP/l-husk" exit t1) || fail "exit on a husk must succeed: $out"
assert_contains "$out" "agent gone from pane" "an already-stopped agent is idempotent success"
assert_no_line "$(cat "$TMP/l-husk")" 'send-text' "nothing is typed into a pane with no agent"

stale_husk=$(cs_control_state "$TMP/s-stalehusk" agent=codex status=idle proc_absent=1)
out=$(run_control "$home" "$stale_husk" "$TMP/l-stalehusk" exit t1) ||
  fail "exit on a stale-belief husk must succeed - relaunching a husk is the main recovery case: $out"
assert_contains "$out" "agent gone from pane" "a stale-belief husk is idempotent exit success"
assert_no_line "$(cat "$TMP/l-stalehusk")" 'send-text' "nothing is typed into a stale-belief husk"

quits=$(cs_control_state "$TMP/s-quits" agent=codex status=idle on_enter=gone)
out=$(run_control "$home" "$quits" "$TMP/l-quits" exit t1) || fail "exit must succeed when the agent leaves: $out"
assert_contains "$out" "agent gone from pane" "a stopped agent is reported gone"
assert_contains "$out" "uncommitted change untouched" "exit states what it preserved"
sent=$(grep -- 'send-text' "$TMP/l-quits")
[ "$sent" = "pane send-text w1:p1 /quit --session default" ] ||
  fail "codex must be sent exactly /quit, got: $sent"
case "$sent" in
  *"$CS_FROMCONS_MARK"*|*$'⁣'*) fail "a lifecycle command must carry no operational-input marker: $sent" ;;
esac
assert_line "$(cat "$TMP/l-quits")" 'send-keys w1:p1 Enter' "the exit command is submitted"

claude_home=$(setup_home claude "harness=claude")
cquits=$(cs_control_state "$TMP/s-cquits" agent=claude status=idle on_enter=gone)
out=$(run_control "$claude_home" "$cquits" "$TMP/l-cquits" exit t1) || fail "claude exit must succeed: $out"
sent=$(grep -- 'send-text' "$TMP/l-cquits")
[ "$sent" = "pane send-text w1:p1 /exit --session default" ] ||
  fail "claude must be sent exactly /exit, got: $sent"
pass "cs-control: exit sends the harness's own unmarked exit command and verifies the agent left"

# Unsent text: herdr has no clear key, so the verb SUBMITS it with one Enter and
# cancels whatever turn that starts, before typing the exit command.
flushed=$(cs_control_state "$TMP/s-flushed" agent=codex status=idle \
  composer='❯ queued steer' on_enter_composer='❯' gone_at_enter=2)
out=$(run_control "$home" "$flushed" "$TMP/l-flushed" exit t1) ||
  fail "a composer the flush clears must not block the exit: $out"
assert_contains "$out" "agent gone from pane" "the exit proceeds once the composer is flushed"
order=$(grep -E 'send-keys w1:p1 Enter|send-text' "$TMP/l-flushed" | head -2 | tr '\n' '|')
case "$order" in
  "pane send-keys w1:p1 Enter --session default|pane send-text w1:p1 /quit --session default|") : ;;
  *) fail "the composer must be flushed BEFORE the exit command is typed, got: $order" ;;
esac

# An agent that leaves ON the flush leaves a husk whose bare shell would run the
# exit command as a shell command; the pre-send check reports the idempotent
# success instead of typing into it.
fgone=$(cs_control_state "$TMP/s-fgone" agent=codex status=idle \
  composer='❯ queued steer' gone_at_enter=1)
out=$(run_control "$home" "$fgone" "$TMP/l-fgone" exit t1) ||
  fail "an agent that exits on the flush is idempotent success: $out"
assert_contains "$out" "agent gone from pane" "the postcondition is already met"
assert_no_line "$(cat "$TMP/l-fgone")" 'send-text' "nothing is typed into a pane the agent left mid-attempt"

# A row that survives the flush is not unsent input - a submit would have cleared
# it - and the classifier reads `pending` for rows that only look like a composer
# (docs/claude.md), so the command is typed anyway and the postcondition decides.
stubborn=$(cs_control_state "$TMP/s-stubborn" agent=codex status=idle \
  composer='❯ not really a composer' gone_at_enter=2)
out=$(run_control "$home" "$stubborn" "$TMP/l-stubborn" exit t1) ||
  fail "a stubborn composer reading must not block recovery: $out"
assert_contains "$out" "agent gone from pane" "the exit proceeds and is verified"
assert_line "$(cat "$TMP/l-stubborn")" 'send-text w1:p1 /quit' "the exit command is still typed"

stays=$(cs_control_state "$TMP/s-stays" agent=codex status=idle)
rc=0
out=$(run_control "$home" "$stays" "$TMP/l-stays" exit t1) || rc=$?
expect_code 1 "$rc" "an agent that stays is a failure"
assert_contains "$out" "NOT confirmed" "an unverified exit says so"

busy_exit=$(cs_control_state "$TMP/s-busyexit" agent=codex status=working on_esc=idle on_enter=gone)
out=$(run_control "$home" "$busy_exit" "$TMP/l-busyexit" exit t1) || fail "a busy agent must be interruptible then exited: $out"
assert_contains "$out" "agent gone from pane" "a busy target is stopped"
order=$(grep -E 'send-keys w1:p1 esc|send-text' "$TMP/l-busyexit" | head -2 | tr '\n' '|')
case "$order" in
  "pane send-keys w1:p1 esc --session default|pane send-text w1:p1 /quit --session default|") : ;;
  *) fail "a busy target must be interrupted BEFORE the exit command, got: $order" ;;
esac

nostop=$(cs_control_state "$TMP/s-nostop" agent=codex status=working on_enter=gone)
rc=0
out=$(run_control "$home" "$nostop" "$TMP/l-nostop" exit t1) || rc=$?
expect_code 1 "$rc" "a turn that will not cancel blocks the exit"
assert_contains "$out" "only queued as input mid-turn" "the refusal explains why the command was withheld"
assert_no_line "$(cat "$TMP/l-nostop")" 'send-text' "no exit command is queued into a running turn"
pass "cs-control: exit interrupts first, flushes unsent text, and never claims an unverified stop"

pass "cs-control behaviors"
