#!/usr/bin/env bash
# Behavior: characterization tests for bin/cs-promote.sh, which promotes a scout
# task to a ship task in place by flipping kind= in state/<id>.meta.
#
# Contract (from the script header + code):
#   Usage: cs-promote.sh <task-id> --mode <mode> --yolo <on|off>. Reads STATE from
#   CS_STATE_OVERRIDE (or CS_HOME/state) and requires state/<id>.meta to contain
#   the exact line "kind=scout". On success it rewrites the meta dropping every
#   kind=/mode=/yolo= line and appending "kind=ship" plus the stated posture (all
#   other meta lines preserved, in order), prints "promoted <id> to ship
#   mode=<mode> yolo=<yolo> (teardown protection restored)" and a "next:" line
#   with a shell-quoted CS_HOME and a cs-send.sh invocation. Refusals: missing
#   meta (exit 1, "no meta"), meta without kind=scout (exit 1, "not a scout
#   task"); neither refusal mutates the meta.
#   The required-flag and closed-set refusals are owned by
#   tests/cs-task-delivery.test.sh, alongside the rest of the delivery contract.
#
# Hermetic: temp state dir only; no external tools.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="$ROOT/bin/cs-promote.sh"
TMP=$(cs_test_tmproot cs-promote)
export CS_STATE_OVERRIDE="$TMP/state"
export CS_HOME="$TMP"
mkdir -p "$TMP/state"

# 1. happy path: a scout task flips to ship with the stated posture, other fields
#    preserved. A real scout meta carries no mode=/yolo= at all (cs-spawn.sh
#    records none for a report deliverable), which is why promotion states both.
cs_write_meta "$TMP/state/s1.meta" \
  "project=$TMP/proj-s1" \
  "pane=w1:p1" \
  "kind=scout"
out=$("$BIN" s1 --mode local-only --yolo off 2>&1) || fail "scout promotion failed: $out"
assert_contains "$out" "promoted s1 to ship" "promotion announces the flip"
assert_contains "$out" "mode=local-only yolo=off" "promotion announces the stated posture"
assert_contains "$out" "teardown protection restored" "promotion notes restored protection"
assert_contains "$out" "cs-send.sh s1" "promotion prints the next-step cs-send.sh line"
assert_grep "kind=ship" "$TMP/state/s1.meta" "meta now records kind=ship"
assert_no_grep "kind=scout" "$TMP/state/s1.meta" "meta no longer records kind=scout"
assert_grep "project=$TMP/proj-s1" "$TMP/state/s1.meta" "unrelated meta fields are preserved"
assert_grep "pane=w1:p1" "$TMP/state/s1.meta" "the pane field is preserved"
assert_grep "mode=local-only" "$TMP/state/s1.meta" "meta records the promoted delivery mode"
assert_grep "yolo=off" "$TMP/state/s1.meta" "meta records the promoted approval posture"
pass "cs-promote flips a scout task's meta to kind=ship with an explicit posture"

# 2. missing meta -> exit 1, names the missing meta.
set +e
out=$("$BIN" ghost --mode made --yolo off 2>&1); rc=$?
set -e
expect_code 1 "$rc" "missing meta should exit 1"
assert_contains "$out" "no meta for task ghost" "missing-meta refusal names the task"
pass "cs-promote refuses a task with no meta"

# 3. a non-scout task -> exit 1, and the meta is left untouched.
cs_write_meta "$TMP/state/sh1.meta" \
  "project=$TMP/proj-sh1" \
  "kind=ship" \
  "mode=made"
before=$(cat "$TMP/state/sh1.meta")
set +e
out=$("$BIN" sh1 --mode made --yolo off 2>&1); rc=$?
set -e
expect_code 1 "$rc" "a non-scout task should exit 1"
assert_contains "$out" "not a scout task" "non-scout refusal names the reason"
[ "$(cat "$TMP/state/sh1.meta")" = "$before" ] || fail "non-scout refusal must not mutate the meta"
pass "cs-promote refuses a non-scout task and leaves its meta unchanged"

# 4. no task id -> usage refusal.
set +e
out=$("$BIN" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "no-arg invocation should be non-zero"
assert_contains "$out" "usage" "no-arg invocation prints usage"
pass "cs-promote refuses with usage when given no task id"

pass "cs-promote scout-to-ship promotion behavior characterized"
