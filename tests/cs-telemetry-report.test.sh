#!/usr/bin/env bash
# Behavior: bin/cs-telemetry-report.sh - the read-only aggregate over recorded
# turns, in both its text and --json forms.
#
# The report is what the boss actually reads, so the properties under test are
# the ones a decision would rest on: the totals and shares must be arithmetically
# right, the opportunity numbers must be labelled as estimates rather than
# savings, an absent or damaged file must still produce a clean zero-exit report,
# and nothing on disk may change as a side effect of reporting.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-telemetry-report)
REPORT="$ROOT/bin/cs-telemetry-report.sh"

make_home() { # <name> - an enabled home with a telemetry directory
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/host" "$dir/state" "$dir/data/telemetry"
  printf 'enabled true\n' > "$dir/host/telemetry.conf"
  printf '%s\n' "$dir"
}

# record <home> <role> <purpose> <outcome> <wake> <total-tokens> [count]
# Append <count> (default 1) records with the given classification.
record() {
  local home=$1 role=$2 purpose=$3 outcome=$4 wake=$5 tokens=$6 count=${7:-1} i
  for i in $(seq 1 "$count"); do
    jq -cn --arg role "$role" --arg purpose "$purpose" --arg outcome "$outcome" \
      --arg wake "$wake" --argjson tokens "$tokens" --arg id "$role-$purpose-$i-$RANDOM" '
      {schema: 1, timestamp: "2026-08-08T12:00:00Z", event_id: $id,
       role: $role, kind: null, home: "h", project: null, task_id: null,
       harness: "codex", model: "m", effort: "high", purpose: $purpose,
       wake_kind: (if $wake == "" then null else $wake end),
       outcome: (if $outcome == "" then null else $outcome end),
       duration_ms: 1000, session_id: "s",
       usage: (if $tokens < 0 then
                 {input_tokens: null, cached_input_tokens: null, output_tokens: null,
                  reasoning_tokens: null, total_tokens: null}
               else
                 {input_tokens: ($tokens - 10), cached_input_tokens: 0, output_tokens: 10,
                  reasoning_tokens: null, total_tokens: $tokens}
               end)}' >> "$home/data/telemetry/turns.jsonl"
  done
}

run_report() { CS_HOME="$1" CS_TELEMETRY_DISABLE='' "$REPORT" "${@:2}"; }

test_absent_file_is_a_clean_zero_exit() {
  local home out rc
  home="$TMP_ROOT/never-enabled"
  mkdir -p "$home/host" "$home/state" "$home/data"
  out=$(run_report "$home" 2>&1)
  rc=$?
  expect_code 0 "$rc" "reporting on a home with no telemetry must exit 0"
  assert_contains "$out" 'No telemetry recorded yet' "an absent file must say so plainly"
  assert_contains "$out" 'Telemetry: disabled' "the report must state the enablement it found"
  assert_absent "$home/data/telemetry" "a read-only report must not create the storage directory"
  pass "cs-telemetry-report: an absent telemetry file is informative, not an error"
}

test_report_never_mutates_anything() {
  local home before after
  home=$(make_home readonly)
  record "$home" root supervision wait checkpoint 100 3
  before=$(cd "$home" && find . | LC_ALL=C sort; cat "$home/data/telemetry/turns.jsonl")
  run_report "$home" >/dev/null
  run_report "$home" --json >/dev/null
  after=$(cd "$home" && find . | LC_ALL=C sort; cat "$home/data/telemetry/turns.jsonl")
  [ "$before" = "$after" ] || fail "the report must not change any file in the home"
  pass "cs-telemetry-report: reporting is strictly read-only"
}

test_aggregates_turns_and_tokens_by_role_and_purpose() {
  local home out
  home=$(make_home aggregate)
  record "$home" root supervision wait checkpoint 1000 30
  record "$home" root boss '' '' 1000 10
  record "$home" capo supervision no_action signal 1000 50
  record "$home" ship implementation '' '' 1000 10
  out=$(run_report "$home")
  assert_contains "$out" 'Turns:     100 recorded, 100 carrying token usage' \
    "the report must total every recorded turn"
  assert_line "$out" '^  root +40 +40%' "root must be 40 of 100 turns"
  assert_line "$out" '^  capo +50 +50%' "capo must be 50 of 100 turns"
  assert_line "$out" '^  supervision +80 +80%' "supervision must fold both roles"
  assert_line "$out" '^  capo / supervision +50 +50%' "the role and purpose cross-tab must appear"
  assert_line "$out" '^  wait +30 +38%' "supervision outcomes are shares of supervision, not of all turns"
  pass "cs-telemetry-report: turns and tokens aggregate by role, purpose, and their cross-tab"
}

test_opportunity_numbers_are_derived_and_labelled_as_estimates() {
  local home out json
  home=$(make_home opportunity)
  # 60 capo turns, 50 of them supervision, 40 of those ending in wait/no_action.
  record "$home" capo supervision wait checkpoint 1000 40
  record "$home" capo supervision message_worker stale 1000 10
  record "$home" capo implementation '' '' 1000 10
  record "$home" root boss '' '' 1000 40
  out=$(run_report "$home")
  assert_contains "$out" 'ESTIMATES, never guaranteed savings' \
    "the opportunity block must be labelled as an estimate"
  assert_contains "$out" 'upper bound' "the report must say these are an upper bound"
  json=$(run_report "$home" --json)
  [ "$(printf '%s' "$json" | jq -r '.opportunity.capo_share_of_frontier_turns')" = 60 ] ||
    fail "capo share of turns must be 60%:"$'\n'"$json"
  [ "$(printf '%s' "$json" | jq -r '.opportunity.capo_turns_that_are_supervision')" = 83.3 ] ||
    fail "50 of 60 capo turns are supervision:"$'\n'"$json"
  [ "$(printf '%s' "$json" | jq -r '.opportunity.supervision_ending_in_wait_or_no_action')" = 80 ] ||
    fail "40 of 50 supervision turns ended in wait or no_action:"$'\n'"$json"
  [ "$(printf '%s' "$json" | jq -r '.opportunity.all_turns_that_are_capo_supervision_wait_or_no_action')" = 40 ] ||
    fail "40 of 100 turns are capo supervision that produced no action:"$'\n'"$json"
  [ "$(printf '%s' "$json" | jq -r '.opportunity.capo_share_of_frontier_usage')" = 60 ] ||
    fail "the cheap-capo opportunity must be measured in tokens too:"$'\n'"$json"
  pass "cs-telemetry-report: the opportunity numbers are derived correctly and marked as estimates"
}

test_json_mode_carries_the_same_aggregates() {
  local home json
  home=$(make_home jsonmode)
  record "$home" root supervision wait checkpoint 500 4
  record "$home" ship implementation '' '' 1500 1
  json=$(run_report "$home" --json)
  printf '%s' "$json" | jq -e . >/dev/null || fail "--json must emit valid JSON:"$'\n'"$json"
  [ "$(printf '%s' "$json" | jq -r '.schema')" = 1 ] || fail "--json must carry the schema version"
  [ "$(printf '%s' "$json" | jq -r '.telemetry')" = 'enabled 30' ] ||
    fail "--json must report the enablement it found"
  [ "$(printf '%s' "$json" | jq -r '.turns.total')" = 5 ] || fail "--json turn total is wrong"
  [ "$(printf '%s' "$json" | jq -r '.tokens.total')" = 3500 ] || fail "--json token total is wrong"
  [ "$(printf '%s' "$json" | jq -r '.by_role.turns.root')" = 4 ] || fail "--json role tally is wrong"
  [ "$(printf '%s' "$json" | jq -r '.supervision.by_outcome.turns.wait')" = 4 ] ||
    fail "--json supervision outcomes are wrong"
  [ "$(printf '%s' "$json" | jq -r '.period.start')" = '2026-08-08T12:00:00Z' ] ||
    fail "--json must report the measured period"
  pass "cs-telemetry-report: --json carries the same aggregates for later analysis"
}

test_records_without_usage_are_counted_as_turns() {
  local home out json
  home=$(make_home nousage)
  record "$home" root supervision wait checkpoint -1 6
  record "$home" ship implementation '' '' 900 2
  out=$(run_report "$home")
  json=$(run_report "$home" --json)
  [ "$(printf '%s' "$json" | jq -r '.turns.total')" = 8 ] || fail "every turn counts, with or without usage"
  [ "$(printf '%s' "$json" | jq -r '.turns.with_usage')" = 2 ] ||
    fail "only the records carrying token usage count toward with_usage"
  assert_contains "$out" '8 recorded, 2 carrying token usage' \
    "the report must disclose how much of the period carries usage"
  pass "cs-telemetry-report: turns with no token usage still count, and the gap is disclosed"
}

test_a_damaged_line_never_fails_the_report() {
  local home out rc json
  home=$(make_home damaged)
  record "$home" root supervision wait checkpoint 100 2
  printf '{"schema":1,"timestamp":"2026-08-08T12:00:00Z","event_id":"tr\n' >> "$home/data/telemetry/turns.jsonl"
  printf 'not json at all\n' >> "$home/data/telemetry/turns.jsonl"
  record "$home" root boss '' '' 100 1
  out=$(run_report "$home" 2>&1)
  rc=$?
  expect_code 0 "$rc" "a damaged line must not fail the report"
  json=$(run_report "$home" --json)
  [ "$(printf '%s' "$json" | jq -r '.turns.total')" = 3 ] ||
    fail "the report must aggregate the intact records and skip the damaged ones:"$'\n'"$json"
  assert_contains "$out" 'Turns:     3 recorded' "the text report must agree with the JSON aggregate"
  pass "cs-telemetry-report: a partially written or corrupt line is skipped, never fatal"
}

test_usage_error_is_reported_without_a_report() {
  local home out rc
  home=$(make_home usage-error)
  out=$(run_report "$home" --nope 2>&1)
  rc=$?
  expect_code 2 "$rc" "an unknown argument must be a usage error"
  assert_contains "$out" 'unknown argument' "the usage error must name the problem"
  out=$(run_report "$home" --help 2>&1)
  rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" 'read-only report' "--help must print the script's own header"
  pass "cs-telemetry-report: usage errors and --help behave like every other cs script"
}

test_absent_file_is_a_clean_zero_exit
test_report_never_mutates_anything
test_aggregates_turns_and_tokens_by_role_and_purpose
test_opportunity_numbers_are_derived_and_labelled_as_estimates
test_json_mode_carries_the_same_aggregates
test_records_without_usage_are_counted_as_turns
test_a_damaged_line_never_fails_the_report
test_usage_error_is_reported_without_a_report
