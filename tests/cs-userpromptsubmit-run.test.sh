#!/usr/bin/env bash
# Behavior: the UserPromptSubmit hook router bin/cs-userpromptsubmit-run.sh.
#
# Reproduces the escalation gap AGENTS.md section 7 used to leave open: a
# capo's blocked:/needs-decision: status line can sit in a task's status file
# with no queued wake record to trigger a drain, so a routine conversational
# reply turn - one nothing classifies as "wake-handling" - never surfaced it.
# This hook removes the judgment call by running bin/cs-wake-drain.sh on
# EVERY user prompt in a primary session, so the OPEN DECISIONS fold (which
# scans every state/*.status file regardless of queue state) reaches the
# model's context on the very next turn.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset NO_MISTAKES_GATE CS_TASK_ID
unset CS_ROOT_OVERRIDE CS_HOME CS_STATE_OVERRIDE CS_DATA_OVERRIDE CS_CONFIG_OVERRIDE CS_HOST_OVERRIDE

TMP=$(cs_test_tmproot cs-userpromptsubmit-run)
RUN="$ROOT/bin/cs-userpromptsubmit-run.sh"

# new_primary_home <name>: a primary-scoped consigliere home (capo-marker
# force-include, same fixture shape tests/cs-turnend-guard.test.sh uses) so no
# real git checkout is required.
new_primary_home() {
  local name=$1 dir
  dir="$TMP/$name"
  mkdir -p "$dir/bin" "$dir/state"
  printf 'testcapo\n' > "$dir/.cs-capo-home"
  printf '# fixture\n' > "$dir/AGENTS.md"
  printf '%s\n' "$dir"
}

run_hook() {  # <home> <payload>
  local home=$1 payload=$2
  (cd "$home" && printf '%s' "$payload" | CS_ROOT_OVERRIDE="$home" CS_HOME="$home" "$RUN")
}

PROMPT_PAYLOAD='{"hook_event_name":"UserPromptSubmit","prompt":"how are things going"}'

# --- the escalation-gap regression: a buried blocked line with no queued wake
#     record still surfaces, because the OPEN DECISIONS fold scans status
#     files directly, not the wake queue.
home=$(new_primary_home buried-decision)
{
  printf 'working: starting the migration\n'
  printf 'blocked [key=risky]: need a go/no-go on the schema change\n'
  printf 'working: unrelated churn after the blocker\n'
} > "$home/state/mytask.status"
out=$(run_hook "$home" "$PROMPT_PAYLOAD")
assert_contains "$out" "OPEN DECISIONS" "an ordinary prompt turn must fold open decisions"
assert_contains "$out" "need a go/no-go on the schema change" \
  "the buried blocked line must reach context even though nothing queued a wake"
pass "an ordinary user-prompt turn surfaces a buried blocked/needs-decision status line"

# --- an empty queue and no open decisions stays silent (cheap no-op) ----------
home=$(new_primary_home quiet)
out=$(run_hook "$home" "$PROMPT_PAYLOAD")
[ -z "$out" ] || fail "a quiet home with nothing to report must stay silent, got: $out"
pass "a quiet home produces no hook output"

# --- foreign (Cursor-shaped) payload never runs the drain ---------------------
home=$(new_primary_home foreign-host)
printf 'blocked [key=risky]: need a go/no-go\n' > "$home/state/mytask.status"
out=$(run_hook "$home" '{"hook_event_name":"UserPromptSubmit","cursor_version":"1.2.3","prompt":"hi"}')
[ -z "$out" ] || fail "a Cursor-shaped payload must not run the wake drain, got: $out"
pass "a foreign-host payload is silent"

# --- a soldier's linked task worktree is never primary-scoped -----------------
SOLDIER_PRIMARY="$TMP/soldier-primary"
SOLDIER_WORKTREE="$TMP/soldier-worktree"
cs_git_worktree "$SOLDIER_PRIMARY" "$SOLDIER_WORKTREE" cs/soldier
mkdir -p "$SOLDIER_PRIMARY/bin" "$TMP/soldier-home/state"
: > "$SOLDIER_PRIMARY/AGENTS.md"
SOLDIER_HOME="$TMP/soldier-home"
printf 'blocked [key=risky]: need a go/no-go\n' > "$SOLDIER_HOME/state/mytask.status"
out=$(cd "$SOLDIER_WORKTREE" && printf '%s' "$PROMPT_PAYLOAD" \
  | CS_ROOT_OVERRIDE="$SOLDIER_PRIMARY" CS_HOME="$SOLDIER_HOME" \
    CS_STATE_OVERRIDE="$SOLDIER_HOME/state" CS_TASK_ID=some-task "$RUN")
[ -z "$out" ] || fail "a soldier task worktree must not run the fleet-wide drain, got: $out"
pass "a soldier's linked task worktree is silent"

# --- a made-gate agent never drains the home it is validating -----------------
home=$(new_primary_home gate-agent)
printf 'blocked [key=risky]: need a go/no-go\n' > "$home/state/mytask.status"
out=$(cd "$home" && printf '%s' "$PROMPT_PAYLOAD" \
  | CS_ROOT_OVERRIDE="$home" CS_HOME="$home" NO_MISTAKES_GATE=1 "$RUN")
[ -z "$out" ] || fail "a made-gate agent must not drain the fleet queue, got: $out"
pass "a made-gate agent is silent"
