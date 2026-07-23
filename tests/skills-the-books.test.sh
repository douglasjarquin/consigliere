#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_the_books_discovery_contract() {
  local skill rundown readme body_hash
  skill="$ROOT/skills/the-books/SKILL.md"
  rundown="$ROOT/skills/rundown/SKILL.md"
  readme="$ROOT/README.md"

  assert_present "$skill" "the-books skill is missing"
  assert_absent "$ROOT/skills/bearings" "legacy bearings skill directory remains"
  assert_grep 'name: the-books' "$skill" "the-books metadata name is wrong"
  assert_grep '# The Books' "$skill" "the-books heading is wrong"
  assert_grep '/the-books' "$skill" "the-books invocation is missing"
  assert_grep 'bearings report' "$skill" "bearings alias phrase is missing"
  assert_grep 'morning brief' "$skill" "morning brief discovery phrase is missing"
  assert_grep 'status report' "$skill" "status report discovery phrase is missing"
  assert_grep 'catch-up' "$skill" "catch-up discovery phrase is missing"

  body_hash=$(tail -n +8 "$skill" | shasum -a 256 | awk '{print $1}')
  [ "$body_hash" = 'aceb0eda5680bbc428800d89644c20af455d40b673280a2afa8b3f51bb4800a1' ] \
    || fail "the-books procedure changed during the rename"

  assert_present "$rundown" "rundown fallback skill is missing"
  assert_grep 'name: rundown' "$rundown" "rundown metadata name is wrong"
  assert_grep 'fall back to /the-books' "$rundown" "rundown does not name the-books as its fallback"
  assert_grep 'use `/the-books`' "$rundown" "rundown does not direct the boss to the-books"
  assert_grep 'the-books' "$readme" "README skill inventory omits the-books"
  assert_no_grep 'bearings' "$readme" "README skill inventory still names bearings"
  pass "the-books: discovery aliases, unchanged brief, and rundown fallback"
}

test_the_books_discovery_contract
