#!/usr/bin/env bash
# tests/cs-line-cap-lib.test.sh - the shared per-line cap both agent-facing
# digests use (bin/cs-line-cap-lib.sh).
#
# The session-start status tails and the wake digest's OPEN DECISIONS section
# call this library directly, so its <max> is a contract rather than a hint: an
# emitted line may never exceed it. These cases pin that contract at its edges,
# where the marker itself no longer fits inside the requested bound, because a
# cap that quietly returns twelve characters for a five-character bound would
# break the caller that trusted the number it passed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/cs-line-cap-lib.sh
. "$ROOT/bin/cs-line-cap-lib.sh"

LONG=$(awk 'BEGIN { while (i++ < 400) printf "x" }')

# cap <line> <max>: the capped result, so each case reads as one assertion.
cap() {
  cs_cap_line_var "$1" "$2"
  printf '%s' "$CS_LINE_CAP_LINE"
}

test_line_under_the_cap_is_untouched() {
  local got
  got=$(cap 'working: short enough' 220)
  [ "$got" = 'working: short enough' ] || fail "a line under the cap was altered: $got"
  pass "a line under the cap is returned unchanged"
}

test_long_line_is_cut_to_the_cap_with_its_marker() {
  local got
  got=$(cap "$LONG" 220)
  [ "${#got}" -eq 220 ] || fail "a cut line ran ${#got} characters against a 220-character cap"
  case "$got" in
    *' [truncated]') : ;;
    *) fail "a cut line lost the shared truncation marker: $got" ;;
  esac
  pass "an over-long line is cut to exactly the cap and marked"
}

# The reason this file exists: with a cap smaller than ' [truncated]' there is
# no room for content plus a disclosure, and the old behavior emitted the whole
# marker anyway - twelve characters for a caller that asked for fewer.
test_cap_below_the_marker_still_binds() {
  local max got want
  for max in 1 5 11 12; do
    got=$(cap "$LONG" "$max")
    [ "${#got}" -le "$max" ] \
      || fail "a cap of $max emitted ${#got} characters: '$got'"
    want=${CS_LINE_CAP_SUFFIX:0:$max}
    [ "$got" = "$want" ] \
      || fail "a cap of $max emitted '$got' instead of the marker cut to fit ('$want')"
  done
  pass "a cap smaller than the truncation marker still binds the emitted line"
}

test_zero_and_negative_caps_emit_nothing() {
  local max got
  for max in 0 -1; do
    got=$(cap "$LONG" "$max")
    [ -z "$got" ] || fail "a cap of $max emitted '$got' instead of nothing"
  done
  pass "a zero or negative cap emits nothing rather than a marker"
}

test_cap_line_prints_the_same_cut() {
  local got
  got=$(cs_cap_line "$LONG" 30)
  [ "${#got}" -eq 30 ] || fail "the printing form emitted ${#got} characters against a 30-character cap"
  cs_cap_line_var "$LONG" 30
  [ "$got" = "$CS_LINE_CAP_LINE" ] \
    || fail "the printing and assigning forms disagree: '$got' vs '$CS_LINE_CAP_LINE'"
  pass "cs_cap_line prints exactly what cs_cap_line_var assigns"
}

test_line_under_the_cap_is_untouched
test_long_line_is_cut_to_the_cap_with_its_marker
test_cap_below_the_marker_still_binds
test_zero_and_negative_caps_emit_nothing
test_cap_line_prints_the_same_cut
