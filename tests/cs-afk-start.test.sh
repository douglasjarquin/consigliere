#!/usr/bin/env bash
# tests/cs-afk-start.test.sh - bin/cs-afk-start.sh: away-mode entry.
#
# cs-afk-start.sh arms state/.afk immediately (nothing left to launch, so
# nothing to separately certify) and a refresh preserves the buffer;
# cs-afk-return.sh clears state/.afk and surfaces catch-up evidence. The
# bossless-mode acknowledgment gate and ack subcommand this same file owns
# live in tests/cs-auto-decision.test.sh instead, alongside the rest of the
# bossless auto-decide contract they gate.
#
# Fully offline: cs-afk-start.sh only writes state/.afk and scans
# state/*.meta, and cs-afk-return.sh needs no fixture for an otherwise-empty
# wake-drain queue - neither script nor their cs-wake-drain.sh/cs-wake-lib.sh
# dependencies ever touch herdr or a watcher.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AFK_START="$ROOT/bin/cs-afk-start.sh"
AFK_RETURN="$ROOT/bin/cs-afk-return.sh"

TMP_ROOT=$(cs_test_tmproot cs-afk-start)

# make_case <name>: case dir with state/. Echoes the case dir.
make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

# --- afk-start arms immediately; a refresh preserves the buffer; return
#     clears the flag -------------------------------------------------------

test_afk_start_and_return_lifecycle() {
  local dir state out rc
  dir=$(make_case start-return); state="$dir/state"

  out=$(env CS_STATE_OVERRIDE="$state" "$AFK_START" 2>&1)
  rc=$?
  expect_code 0 "$rc" "cs-afk-start"
  # Nothing is launched, so arming is immediate - no separate certification step.
  assert_contains "$out" "away mode armed" "start did not report an armed away mode"
  assert_present "$state/.afk" "start did not write the durable away flag"

  # A second start while already away is a refresh, not a fresh entry.
  out=$(env CS_STATE_OVERRIDE="$state" "$AFK_START" 2>&1)
  rc=$?
  expect_code 0 "$rc" "cs-afk-start refresh"
  assert_contains "$out" "away mode refreshed" "a second start while already away must report a refresh"

  # Return clears the flag even with no daemon ever having run.
  out=$(env CS_STATE_OVERRIDE="$state" "$AFK_RETURN" 2>&1)
  rc=$?
  expect_code 0 "$rc" "cs-afk-return after a clean away session"
  assert_contains "$out" "catch-up clear" "return did not report catch-up clear"
  assert_absent "$state/.afk" "return did not clear state/.afk"
  pass "cs-afk-start arms immediately and a repeat call refreshes; cs-afk-return clears the flag"
}

test_afk_start_and_return_lifecycle

pass "cs-afk-start.sh away-mode entry contract"
