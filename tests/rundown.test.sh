#!/usr/bin/env bash
# Regression coverage for the user-invocable, session-only rundown skill.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/skills/rundown/SKILL.md"
README="$ROOT/README.md"

test_user_invocation_and_inventory() {
  assert_grep 'name: rundown' "$SKILL" "rundown skill name is missing"
  assert_grep 'user-invocable: true' "$SKILL" "rundown is not user-invocable"
  assert_grep '/rundown' "$SKILL" "rundown trigger is missing"
  assert_grep 'rundown' "$README" "README does not inventory rundown"
  pass "rundown is invocable and listed in the skills inventory"
}

test_session_only_recap_boundary() {
  assert_grep 'conversation history already visible' "$SKILL" "rundown does not limit itself to visible history"
  assert_grep 'most recent real boss-authored message' "$SKILL" "rundown lacks the boss-message boundary"
  # shellcheck disable=SC2016  # literal grep patterns; backticks are content, not expansion
  assert_grep 'current `/rundown` message is outside the recap interval' "$SKILL" "current invocation is included in the recap interval"
  # shellcheck disable=SC2016
  assert_grep 'previous `/rundown` is a real boss message' "$SKILL" "previous rundown is not a recap boundary"
  assert_grep 'nothing happened after the previous boss message' "$SKILL" "empty recap behavior is missing"
  pass "rundown uses the previous real boss message as its session boundary"
}

test_operational_input_and_side_effect_boundaries() {
  local term
  for term in System developer tool monitoring 'turn-end guard' 'away-mode daemon' \
    'launch instruction' 'session-start nudge' from-consigliere; do
    assert_grep "$term" "$SKILL" "rundown does not exclude operational input: $term"
  done
  for term in 'run shell commands' 'gather fleet or task status' 'use GitHub or browser clients' \
    'call tools' 'read or write files' 'create a report' 'persist anything'; do
    assert_grep "$term" "$SKILL" "rundown side-effect boundary is missing: $term"
  done
  pass "rundown excludes operational input and all fresh-state side effects"
}

test_first_message_fallback() {
  assert_grep 'If no prior real boss message exists' "$SKILL" "rundown lacks the first-message fallback"
  assert_grep '../the-books/SKILL.md' "$SKILL" "rundown does not point to the-books"
  # shellcheck disable=SC2016  # literal grep pattern; backticks are content, not expansion
  assert_grep 'Fall back to `the-books` only when this is genuinely the first real boss message' \
    "$SKILL" "rundown fallback is not limited to the first real boss message"
  pass "rundown delegates only a first-message request to the-books"
}

test_user_invocation_and_inventory
test_session_only_recap_boundary
test_operational_input_and_side_effect_boundaries
test_first_message_fallback

pass "rundown skill contract"
