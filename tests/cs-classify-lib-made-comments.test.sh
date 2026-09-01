#!/usr/bin/env bash
# Behavior: bin/cs-classify-lib.sh's busy-state classification comments used to
# describe crew_absorb_class's reuse of bin/cs-crew-state.sh in terms of the
# old no-mistakes-based mechanism ("may make a bounded no-mistakes call", "an
# actively-running no-mistakes step (running/fixing/ci)", "A no-mistakes
# soldier appends...", "no-mistakes install"). Task 28
# (plans/made-rewrite.md) replaced busy-detection's log-scraping with a
# made-based mechanism, so those comments are now stale documentation: this is
# a pure doc-consistency check, not a behavior test, since the task explicitly
# forbids re-deriving the classification logic itself.
#
# This is a simple grep-based doc-consistency check (mirrors
# tests/cs-brief-made-skill-string.test.sh's approach for an analogous
# no-mistakes -> made string migration in a different file): once the five
# sites cited by Task 34 (originally lines 15, 43, 91, 391, 399) are updated,
# NO reference to "no-mistakes" should remain anywhere in this file.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FILE="$ROOT/bin/cs-classify-lib.sh"

[ -f "$FILE" ] || fail "bin/cs-classify-lib.sh must exist"

if grep -n "no-mistakes" "$FILE" >/dev/null 2>&1; then
  fail "bin/cs-classify-lib.sh still references no-mistakes: $(grep -n "no-mistakes" "$FILE")"
fi
pass "bin/cs-classify-lib.sh has no stale no-mistakes references"

# The replacement wording must actually describe the made-based mechanism, not
# just drop the string: crew_absorb_class's docstring should still explain
# that reading cs-crew-state.sh's authoritative state is not a pure read,
# because it may shell out to `made`.
assert_grep() {
  local pattern=$1 file=$2 label=$3
  grep -qF "$pattern" "$file" || fail "$label"
}
assert_grep "made" "$FILE" "crew_absorb_class docstring names made as the tool cs-crew-state.sh calls"
assert_grep "bounded made call" "$FILE" "the two 'NOT a pure read' notes describe a bounded made call"

pass "bin/cs-classify-lib.sh's busy-detection comments name made, not no-mistakes"
