#!/usr/bin/env bash
# tests/cs-upstream-log.test.sh - the upstream review log helper (bin/cs-upstream-log.sh).
# Drives the real script against a throwaway firstmate git fixture. Asserts:
# the last-reviewed SHA is read from the TRACKED ledger docs/upstream-review.md
# under CS_ROOT (never from the home's data/), the unreviewed range is printed,
# config/upstream resolves the checkout, and a missing ledger SHA warns and
# exits non-zero instead of guessing a baseline.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOG="$ROOT/bin/cs-upstream-log.sh"

TMP_ROOT=$(cs_test_tmproot cs-upstream-log)

# --- fixture: a fake firstmate checkout with two commits ----------------------

FM="$TMP_ROOT/firstmate"
mkdir -p "$FM"
git -C "$FM" init -q -b main
git -C "$FM" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "baseline"
BASE_SHA=$(git -C "$FM" rev-parse HEAD)
git -C "$FM" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "new upstream work"
NEW_SHA=$(git -C "$FM" rev-parse HEAD)

# --- fixture: a consigliere root with a tracked ledger and a decoy ------------

FIX="$TMP_ROOT/root"
mkdir -p "$FIX/docs" "$FIX/config" "$FIX/data"
printf 'last-reviewed: %s\n' "$BASE_SHA" > "$FIX/docs/upstream-review.md"
printf '%s\n' "$FM" > "$FIX/config/upstream"
# Decoy: a stale per-home ledger that must be ignored since the move to docs/.
printf 'last-reviewed: %s\n' "$NEW_SHA" > "$FIX/data/upstream-review.md"

run_log() {
  OUT=$(env CS_ROOT_OVERRIDE="$FIX" CS_HOME="$FIX" "$LOG" "$@" 2>&1)
  RC=$?
}

# --- the ledger is the tracked docs/ file --------------------------------------

test_reads_tracked_ledger() {
  run_log --oneline
  expect_code 0 "$RC" "upstream log against the fixture"
  assert_contains "$OUT" "upstream: 1 commits since last-reviewed $BASE_SHA" \
    "the unreviewed count must come from docs/upstream-review.md"
  assert_contains "$OUT" "new upstream work" "the unreviewed commit subject is missing"
  # The decoy data/ ledger points at NEW_SHA; using it would print 0 commits.
  assert_not_contains "$OUT" "upstream: 0 commits" \
    "the stale data/upstream-review.md decoy was read instead of the tracked ledger"
  pass "last-reviewed comes from the tracked docs/upstream-review.md, not data/"
}

# --- a missing ledger SHA warns, never guesses ---------------------------------

test_missing_ledger_warns() {
  rm "$FIX/docs/upstream-review.md"
  run_log
  expect_code 1 "$RC" "missing ledger must exit non-zero"
  assert_contains "$OUT" "no last-reviewed SHA" "missing-ledger warning missing"
  assert_contains "$OUT" "docs/upstream-review.md" \
    "the warning must name the tracked ledger path"
  printf 'last-reviewed: %s\n' "$BASE_SHA" > "$FIX/docs/upstream-review.md"
  pass "a missing ledger SHA warns with the tracked path and refuses to guess"
}

test_reads_tracked_ledger
test_missing_ledger_warns
