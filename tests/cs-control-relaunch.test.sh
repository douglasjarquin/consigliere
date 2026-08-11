#!/usr/bin/env bash
# Behavior: the relaunch transaction (bin/cs-control.sh relaunch driving the real
# bin/cs-spawn.sh --relaunch), hermetically, with a fake herdr:
#   1. Every refusal happens before anything is written: the home's records and
#      the soldier's instructions stay BYTE-IDENTICAL.
#   2. The happy path prefers resume, journals the transaction to `done`, keeps
#      the task identity, and steers the note in (a resumed session does not
#      re-read its brief).
#   3. With nothing resumable it falls back to a cold launch that carries the
#      brief, and does not steer the note twice.
#   4. Uncommitted work is preserved untouched, and the journal records the head
#      and dirty count it preserved.
#   5. Postcondition failures are reported as failures: a pane still holding the
#      original process, and a cold launch that kept its agent session id.
#   6. A launch failure after the stop reports the concrete state and journals
#      `failed`, rather than claiming a running agent.
#   7. A journal left mid-transaction (the process was killed) makes the next
#      relaunch refuse instead of launching a second agent; --clear-journal
#      acknowledges it and sets it aside.
#   8. --model and --effort move the profile for this relaunch and are recorded
#      only once an agent is confirmed.
#   9. bin/cs-spawn.sh --relaunch refuses independently: a live agent, a pane
#      sitting elsewhere, an unreportable cwd, no metadata, and new-task flags.
set -u
# shellcheck source=tests/control-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/control-helpers.sh"

CONTROL="$ROOT/bin/cs-control.sh"
SPAWN="$ROOT/bin/cs-spawn.sh"
TMP=$(cs_test_tmproot cs-control-relaunch)
FAKEBIN=$(cs_fakebin "$TMP")
cs_control_fake_herdr "$FAKEBIN"
export PATH="$FAKEBIN:$PATH"
cs_git_identity
export CS_CONTROL_INTERRUPT_WAIT_SECS=2 CS_CONTROL_EXIT_WAIT_SECS=2 CS_CONTROL_EXIT_SETTLE=0
export CS_CONTROL_RESUME_WAIT_SECS=3 CS_CONTROL_RESUME_GRACE_SECS=1
export CS_SPAWN_LAUNCH_WAIT_SECS=3 CS_SEND_SETTLE=0

setup_home() { # <name> [meta key=value...] -> home with task t1 and a worktree
  local home="$TMP/home-$1"
  shift
  mkdir -p "$home/state" "$home/data/t1" "$home/proj"
  printf 'do the thing\n' > "$home/data/t1/brief.md"
  cs_git_init_commit "$home/wt" >/dev/null 2>&1
  cs_write_meta "$home/state/t1.meta" \
    "workspace=w1" "pane=w1:p1" "worktree=$home/wt" "project=$home/proj" \
    "model=default" "effort=default" "kind=ship" "mode=no-mistakes" "yolo=off" "harness=codex" "$@"
  printf '%s\n' "$home"
}

# A stable manifest of everything a refusal must not touch.
manifest() { # <home>
  local home=$1
  (cd "$home" && find state data -type f | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$f" "$(cksum < "$f")"
  done)
}

run_relaunch() { # <home> <state-dir> <log> -- <cs-control args...>
  local home=$1 state=$2 log=$3
  shift 3
  : > "$log"
  cs_control_set "$state" log "$log"
  env CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" CS_DATA_OVERRIDE="$home/data" \
    FAKE_STATE="$state" "$CONTROL" relaunch "$@" 2>&1
}

journal_field() { # <home> <key>
  sed -n "s/^$2=//p" "$1/state/t1.control-relaunch" | tail -1
}

# --- 1. refusals leave records and instructions byte-identical ---------------

home=$(setup_home refuse)
state=$(cs_control_state "$TMP/s-refuse" agent= status=idle cwd="$home/wt")
before=$(manifest "$home")

rc=0; out=$(run_relaunch "$home" "$state" "$TMP/l" nosuch --note n) || rc=$?
expect_code 1 "$rc" "an unknown task refuses"
rc=0; out=$(run_relaunch "$home" "$state" "$TMP/l" t1) || rc=$?
expect_code 2 "$rc" "a relaunch with no note refuses"
assert_contains "$out" "requires --note" "the refusal names the missing note"
rc=0; out=$(run_relaunch "$home" "$state" "$TMP/l" t1 --note "$(printf 'a\nb')") || rc=$?
expect_code 2 "$rc" "a multiline note refuses"
rc=0; out=$(run_relaunch "$home" "$state" "$TMP/l" t1 --note n --effort banana) || rc=$?
expect_code 2 "$rc" "an effort the harness rejects refuses"
assert_contains "$out" "is not a codex effort level" "the refusal names the harness"
rc=0; out=$(run_relaunch "$home" "$state" "$TMP/l" t1 --note n --model 'bad model!') || rc=$?
expect_code 2 "$rc" "a malformed model refuses"

gone_wt=$(setup_home gonewt)
rm -rf "$gone_wt/wt"
gone_before=$(manifest "$gone_wt")
rc=0; out=$(run_relaunch "$gone_wt" "$state" "$TMP/l" t1 --note n) || rc=$?
expect_code 1 "$rc" "a missing worktree refuses"
assert_contains "$out" "which is gone" "the refusal names the missing local copy"
[ "$(manifest "$gone_wt")" = "$gone_before" ] || fail "a missing-worktree refusal must change nothing"

notgit=$(setup_home notgit)
rm -rf "$notgit/wt/.git"
rc=0; out=$(run_relaunch "$notgit" "$state" "$TMP/l" t1 --note n) || rc=$?
expect_code 1 "$rc" "a worktree that is not a git root refuses"

nobrief=$(setup_home nobrief)
rm -f "$nobrief/data/t1/brief.md"
rc=0; out=$(run_relaunch "$nobrief" "$state" "$TMP/l" t1 --note n) || rc=$?
expect_code 1 "$rc" "a missing brief refuses"
assert_contains "$out" "no brief" "the refusal names the missing instructions"

dead=$(cs_control_state "$TMP/s-dead" agent= pane_absent=1 cwd="$home/wt")
rc=0; out=$(run_relaunch "$home" "$dead" "$TMP/l" t1 --note n) || rc=$?
expect_code 1 "$rc" "a dead endpoint refuses"

drifted=$(cs_control_state "$TMP/s-drifted" agent=codex status=idle cwd="$TMP")
rc=0; out=$(run_relaunch "$home" "$drifted" "$TMP/l" t1 --note n) || rc=$?
expect_code 1 "$rc" "a pane sitting outside the recorded worktree refuses BEFORE the stop"
assert_contains "$out" "is not in the recorded worktree" "the refusal names the drift"
assert_no_line "$(cat "$TMP/l")" 'send-text' "no agent is stopped on a drifted pane"

nodircwd=$(cs_control_state "$TMP/s-nodircwd" agent=codex status=idle cwd=)
rc=0; out=$(run_relaunch "$home" "$nodircwd" "$TMP/l" t1 --note n) || rc=$?
expect_code 1 "$rc" "an unreportable pane cwd refuses BEFORE the stop"
assert_contains "$out" "did not report a working directory" "the refusal distinguishes unknown from mismatched"

[ "$(manifest "$home")" = "$before" ] || {
  printf -- '--- before ---\n%s\n--- after ---\n%s\n' "$before" "$(manifest "$home")" >&2
  fail "every refusal must leave this home's records and the brief byte-identical"
}
assert_absent "$home/state/t1.control-relaunch" "a refused relaunch writes no journal"
pass "cs-control relaunch: every refusal leaves records and instructions byte-identical"

# --- 2. happy path: resume preferred, journalled, note steered ---------------

home=$(setup_home resume)
head_sha=$(git -C "$home/wt" rev-parse HEAD)
state=$(cs_control_state "$TMP/s-resume" agent=codex status=idle pid=100 session=sess-1 \
  cwd="$home/wt" on_enter=gone on_run=up)
out=$(run_relaunch "$home" "$state" "$TMP/l-resume" t1 --note 'you were rebasing; finish that first') ||
  fail "the happy path must succeed: $out"
assert_contains "$out" "agent replaced via resume" "the report names the launch path"
assert_contains "$out" "pid 100 -> 101" "the report proves a different process owns the pane"
assert_contains "$out" "progress note steered" "a resumed session is told the note"
[ "$(journal_field "$home" phase)" = 'done' ] || fail "the journal must end at done"
[ "$(journal_field "$home" launch_path)" = resume ] || fail "the journal must record the launch path"
[ "$(journal_field "$home" head)" = "$head_sha" ] || fail "the journal must record the preserved head"
[ "$(journal_field "$home" pre_pid)" = 100 ] || fail "the journal must record the stopped process"
[ "$(journal_field "$home" post_pid)" = 101 ] || fail "the journal must record the replacement process"
assert_grep 'you were rebasing' "$home/data/t1/brief.md" "the note is appended to the instructions"
assert_grep "Progress note (relaunch" "$home/data/t1/brief.md" "the note is stamped"
assert_grep 'do the thing' "$home/data/t1/brief.md" "the original brief is preserved"
[ "$(grep -c '^model=' "$home/state/t1.meta")" -eq 1 ] || fail "an unchanged profile must not be re-recorded"
log=$(cat "$TMP/l-resume")
assert_line "$log" 'pane send-text w1:p1 /quit' "the old agent is stopped with the harness exit command"
assert_line "$log" 'pane run w1:p1 codex resume --last' "the replacement resumes the soldier's own session"
assert_line "$log" 'pane run w1:p1 .*you were rebasing' "the note is delivered as one steer"
assert_no_line "$log" 'encode launch-brief' "a resume must not re-deliver the brief as a prompt"
pass "cs-control relaunch: resume is preferred, journalled to done, and the note is steered in"

# --- 3. cold fallback when nothing is resumable -----------------------------

home=$(setup_home cold)
state=$(cs_control_state "$TMP/s-cold" agent=codex status=idle pid=200 session=sess-old \
  cwd="$home/wt" on_enter=gone on_run=second run_session=sess-new)
out=$(run_relaunch "$home" "$state" "$TMP/l-cold" t1 --note 'start from the failing test') ||
  fail "the cold fallback must succeed: $out"
assert_contains "$out" "agent replaced via cold" "the report names the cold path"
assert_contains "$out" "progress note carried-in-the-brief" "a cold launch reads the note from the brief"
[ "$(journal_field "$home" launch_path)" = cold ] || fail "the journal must record the cold path"
log=$(cat "$TMP/l-cold")
assert_line "$log" 'pane run w1:p1 codex resume --last' "resume is attempted first"
assert_line "$log" 'encode launch-brief' "the cold launch carries the brief"
assert_grep 'start from the failing test' "$home/data/t1/brief.md" "the brief carries the note the cold launch reads"
assert_no_line "$log" 'pane run w1:p1 .*start from the failing test' "the note is not also steered"
pass "cs-control relaunch: it falls back to a cold launch only once the pane is agent-free again"

# --- 4. uncommitted work is preserved --------------------------------------

home=$(setup_home dirty)
printf 'work in progress\n' > "$home/wt/wip.txt"
printf 'edited\n' >> "$home/wt/README.md"
state=$(cs_control_state "$TMP/s-dirty" agent=codex status=idle pid=300 cwd="$home/wt" \
  on_enter=gone on_run=up)
out=$(run_relaunch "$home" "$state" "$TMP/l-dirty" t1 --note keep) || fail "a dirty worktree must relaunch: $out"
[ "$(cat "$home/wt/wip.txt")" = "work in progress" ] || fail "an uncommitted file must survive untouched"
assert_grep edited "$home/wt/README.md" "an uncommitted edit must survive untouched"
[ "$(journal_field "$home" dirty)" = 2 ] || fail "the journal must record the uncommitted count, got $(journal_field "$home" dirty)"
assert_contains "$out" "2 uncommitted file(s)" "the report states what was preserved"
pass "cs-control relaunch: uncommitted work is preserved and recorded, never discarded"

# --- 5. postcondition failures are reported as failures --------------------

home=$(setup_home samepid)
state=$(cs_control_state "$TMP/s-samepid" agent=codex status=idle pid=400 run_pid=400 \
  cwd="$home/wt" on_enter=gone on_run=up)
rc=0
out=$(run_relaunch "$home" "$state" "$TMP/l-samepid" t1 --note n) || rc=$?
expect_code 1 "$rc" "a pane still holding the original process is a failure"
assert_contains "$out" "still holds the ORIGINAL agent process" "the failure names what it observed"
[ "$(journal_field "$home" phase)" = failed ] || fail "a failed verification must journal failed"
[ "$(journal_field "$home" failed_phase)" = verifying ] || fail "the journal must name the failed phase"

home=$(setup_home samesession)
state=$(cs_control_state "$TMP/s-samesession" agent=codex status=idle pid=500 session=sess-x \
  cwd="$home/wt" on_enter=gone on_run=second)
rc=0
out=$(run_relaunch "$home" "$state" "$TMP/l-samesession" t1 --note n) || rc=$?
expect_code 1 "$rc" "a cold launch that kept its session id is a failure"
assert_contains "$out" "same agent session id" "the failure explains the evidence"
pass "cs-control relaunch: an unproven replacement is reported as a failure, not a success"

# --- 6. a launch failure after the stop reports the concrete state ----------

home=$(setup_home nolaunch)
state=$(cs_control_state "$TMP/s-nolaunch" agent=codex status=idle pid=600 cwd="$home/wt" \
  on_enter=gone)
rc=0
out=$(run_relaunch "$home" "$state" "$TMP/l-nolaunch" t1 --note 'mid-rebase') || rc=$?
expect_code 1 "$rc" "a launch that brings up no agent is a failure"
assert_contains "$out" "did NOT come up" "the failure says no replacement is running"
assert_contains "$out" "work is preserved" "the failure says where the work is"
[ "$(journal_field "$home" phase)" = failed ] || fail "the journal must record the failure"
[ "$(journal_field "$home" failed_phase)" = launching ] || fail "the journal must name the launching phase"
assert_grep 'mid-rebase' "$home/data/t1/brief.md" "the note stays in the brief for the next recovery"
[ "$(grep -c '^model=' "$home/state/t1.meta")" -eq 1 ] || fail "a failed launch must not rewrite the profile"

home=$(setup_home nostop)
state=$(cs_control_state "$TMP/s-nostop" agent=codex status=working cwd="$home/wt")
rc=0
out=$(run_relaunch "$home" "$state" "$TMP/l-nostop" t1 --note n) || rc=$?
expect_code 1 "$rc" "an agent that cannot be stopped blocks the relaunch"
assert_contains "$out" "NOTHING was relaunched" "the failure is unambiguous"
[ "$(journal_field "$home" failed_phase)" = stopping ] || fail "the journal must name the stopping phase"
assert_no_line "$(cat "$TMP/l-nostop")" 'pane run' "no launch is attempted while the old agent is up"
pass "cs-control relaunch: a failure after the stop reports the concrete state"

# --- 7. a journal killed mid-transaction blocks the next relaunch -----------

home=$(setup_home killed)
state=$(cs_control_state "$TMP/s-killed" agent=codex status=idle pid=700 cwd="$home/wt" \
  on_enter=gone on_run=up)
printf 'phase=stopped\ntask=t1\npane=w1:p1\npre_pid=699\n' > "$home/state/t1.control-relaunch"
rc=0
out=$(run_relaunch "$home" "$state" "$TMP/l-killed" t1 --note n) || rc=$?
expect_code 1 "$rc" "an unfinished journal blocks the next relaunch"
assert_contains "$out" "stopped at phase 'stopped'" "the refusal names the phase it stopped at"
assert_contains "$out" "--clear-journal" "the refusal names how to proceed"
assert_no_line "$(cat "$TMP/l-killed")" 'pane run' "a blocked relaunch launches nothing"
[ "$(journal_field "$home" pre_pid)" = 699 ] || fail "the unfinished journal must be left intact"

out=$(run_relaunch "$home" "$state" "$TMP/l-cleared" t1 --note n --clear-journal) ||
  fail "--clear-journal must let the transaction proceed: $out"
assert_contains "$out" "agent replaced via" "the acknowledged transaction runs"
assert_present "$home/state/t1.control-relaunch.abandoned" "the acknowledged journal is kept for post-mortem"
assert_grep 'pre_pid=699' "$home/state/t1.control-relaunch.abandoned" "the kept journal is the old one"
[ "$(journal_field "$home" phase)" = 'done' ] || fail "the fresh transaction journals its own outcome"

badeffort=$(setup_home badeffort "harness=claude" "effort=ultra")
printf 'phase=stopped\ntask=t1\npane=w1:p1\npre_pid=799\n' > "$badeffort/state/t1.control-relaunch"
badeffort_before=$(manifest "$badeffort")
badstate=$(cs_control_state "$TMP/s-badeffort" agent=claude status=idle cwd="$badeffort/wt" on_run=up)
rc=0
out=$(run_relaunch "$badeffort" "$badstate" "$TMP/l-badeffort" t1 --note n --clear-journal) || rc=$?
expect_code 1 "$rc" "an unusable recorded effort refuses even with --clear-journal"
assert_contains "$out" "does not accept" "the refusal names the unusable recorded effort"
[ "$(manifest "$badeffort")" = "$badeffort_before" ] ||
  fail "a refusal after --clear-journal must still leave records byte-identical, including the stale journal"
assert_absent "$badeffort/state/t1.control-relaunch.abandoned" "no journal is displaced by a refused relaunch"
pass "cs-control relaunch: an interrupted transaction is reported, never launched over"

# --- 8. profile overrides ---------------------------------------------------

home=$(setup_home profile)
state=$(cs_control_state "$TMP/s-profile" agent=codex status=idle pid=800 cwd="$home/wt" \
  on_enter=gone on_run=up)
out=$(run_relaunch "$home" "$state" "$TMP/l-profile" t1 --note n --model gpt-5.6-sol --effort low) ||
  fail "a profile override must succeed: $out"
assert_contains "$out" "model gpt-5.6-sol effort low" "the report names the launched profile"
log=$(cat "$TMP/l-profile")
assert_line "$log" "pane run w1:p1 codex resume --last --model 'gpt-5.6-sol'" "the override reaches the launch line"
assert_line "$log" "model_reasoning_effort=\"low\"" "the effort override reaches the launch line"
[ "$(sed -n 's/^model=//p' "$home/state/t1.meta" | tail -1)" = gpt-5.6-sol ] ||
  fail "a confirmed relaunch records the new model"
[ "$(sed -n 's/^effort=//p' "$home/state/t1.meta" | tail -1)" = low ] ||
  fail "a confirmed relaunch records the new effort"
[ "$(journal_field "$home" prior_model)" = default ] || fail "the journal must record the prior profile"
pass "cs-control relaunch: --model and --effort move the profile and are recorded on success"

# --- 9. cs-spawn --relaunch refuses on its own ------------------------------

run_spawn() { # <home> <state-dir> -- <spawn args...>
  local home=$1 state=$2
  shift 2
  env CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" CS_DATA_OVERRIDE="$home/data" \
    FAKE_STATE="$state" "$SPAWN" "$@" 2>&1
}

home=$(setup_home spawn)
live=$(cs_control_state "$TMP/s-live" agent=codex status=idle pid=900 cwd="$home/wt" on_run=up)
rc=0; out=$(run_spawn "$home" "$live" --relaunch t1) || rc=$?
expect_code 1 "$rc" "a live agent blocks an adopting launch"
assert_contains "$out" "not positively agent-free" "the refusal names the obstacle"

elsewhere=$(cs_control_state "$TMP/s-elsewhere" agent= cwd="$TMP" on_run=up)
rc=0; out=$(run_spawn "$home" "$elsewhere" --relaunch t1) || rc=$?
expect_code 1 "$rc" "a pane sitting somewhere else blocks the launch"
assert_contains "$out" "is not in" "the refusal names the directory mismatch"

nocwd=$(cs_control_state "$TMP/s-nocwd" agent= cwd= on_run=up)
rc=0; out=$(run_spawn "$home" "$nocwd" --relaunch t1) || rc=$?
expect_code 1 "$rc" "an unreportable cwd blocks the launch"
assert_contains "$out" "did not report a working directory" "the refusal distinguishes unknown from mismatched"

ok=$(cs_control_state "$TMP/s-ok" agent= cwd="$home/wt" on_run=up)
rc=0; out=$(run_spawn "$home" "$ok" --relaunch nosuchtask) || rc=$?
expect_code 1 "$rc" "a task with no metadata cannot be relaunched"
assert_contains "$out" "no metadata" "the refusal names what is missing"
# The recorded harness is the authority for a relaunch: an effort it accepts
# must not be refused against the machine's root pin, which may have moved
# since the task was dispatched.
rootmoved=$(cs_control_state "$TMP/s-rootmoved" agent= cwd="$home/wt" on_run=up)
rc=0; out=$(CS_HARNESS_OVERRIDE=claude run_spawn "$home" "$rootmoved" --relaunch t1 --effort ultra) || rc=$?
expect_code 0 "$rc" "a relaunch validates effort against the recorded harness, not the root pin: $out"
assert_contains "$out" "effort=ultra" "the recorded codex harness accepts the effort the root pin would refuse"

rc=0; out=$(run_spawn "$home" "$ok" --relaunch t1 --mode direct-PR) || rc=$?
expect_code 2 "$rc" "a new-task flag is refused rather than ignored"
assert_contains "$out" "does not apply to --relaunch" "the refusal explains the recorded posture owns it"
rc=0; out=$(run_spawn "$home" "$ok" --relaunch t1 "$home/proj") || rc=$?
expect_code 2 "$rc" "a relaunch takes exactly one positional"
pass "cs-spawn --relaunch: it refuses independently rather than trusting its caller"

pass "cs-control relaunch behaviors"
