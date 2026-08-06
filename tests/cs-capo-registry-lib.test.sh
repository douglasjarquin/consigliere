#!/usr/bin/env bash
# Behavior: bin/cs-capo-registry-lib.sh, the single owner of config/host/capos.md
# parsing. This suite owns the parse CONTRACT every consumer inherits:
#   - the anchored suffix parse, so a `;` or `()` inside natural-language
#     summary or scope text cannot truncate a field or steal the home;
#   - the degraded home+scope-only row a hand edit can leave behind;
#   - EOF safety, so a registry whose last line has no trailing newline still
#     yields its last capo instead of losing a live binding;
#   - literal id lookup, so a dotted id such as `a.b` can never resolve to, or
#     rewrite, an unrelated `axb` row;
#   - fail-closed refusals for a missing, unreadable, or symlinked registry and
#     for a duplicated id, none of which may read as "no capos registered";
#   - a malformed row surfaced as such rather than skipped.
# Hermetic: pure text fixtures, no herdr, no git, no network.
set -u
# shellcheck source=tests/capo-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/capo-helpers.sh"
# shellcheck source=bin/cs-capo-registry-lib.sh
. "$ROOT/bin/cs-capo-registry-lib.sh"

TMP=$(cs_test_tmproot cs-capo-registry-lib)
REG="$TMP/capos.md"

# parse_ok <line> - parse and fail the suite if the line is rejected.
parse_ok() {
  cs_capo_registry_parse_line "$1" || fail "expected a parseable registry line: $1"
}

# records_of <reg> [max_bytes] - the record stream as "status|id|home|scope"
# lines, so an assertion can name the exact field boundaries the parse chose.
records_of() {
  local status id home scope raw
  cs_capo_registry_records "$@" | while IFS=$'\t' read -r status id home scope raw; do
    printf '%s|%s|%s|%s|%s\n' "$status" "$id" "$home" "$scope" "$raw"
  done
}

# --- 1. the canonical generated row -------------------------------------------

parse_ok "$(cs_capo_registry_line alpha-capo 'Own alpha end to end.' /homes/alpha 'All alpha work.' 'alpha, beta' 2026-03-04)"
[ "$CS_CAPO_REGISTRY_ID" = alpha-capo ] || fail "id wrong: $CS_CAPO_REGISTRY_ID"
[ "$CS_CAPO_REGISTRY_SUMMARY" = 'Own alpha end to end.' ] || fail "summary wrong: $CS_CAPO_REGISTRY_SUMMARY"
[ "$CS_CAPO_REGISTRY_HOME" = /homes/alpha ] || fail "home wrong: $CS_CAPO_REGISTRY_HOME"
[ "$CS_CAPO_REGISTRY_SCOPE" = 'All alpha work.' ] || fail "scope wrong: $CS_CAPO_REGISTRY_SCOPE"
[ "$CS_CAPO_REGISTRY_PROJECTS" = 'alpha, beta' ] || fail "projects wrong: $CS_CAPO_REGISTRY_PROJECTS"
[ "$CS_CAPO_REGISTRY_ADDED" = 2026-03-04 ] || fail "added wrong: $CS_CAPO_REGISTRY_ADDED"
pass "the canonical generated row round-trips field for field"

# --- 2. punctuation inside natural-language text ------------------------------
# scope is prose: a semicolon, a parenthetical, and a closing period all live
# inside it legitimately, and the old sed truncated at the first `;` or `)`.

parse_ok '- punct - Sums it up. (home: /homes/punct; scope: owns CI; also releases (both lanes); nothing else.; projects: p; added 2026-01-01)'
[ "$CS_CAPO_REGISTRY_SCOPE" = 'owns CI; also releases (both lanes); nothing else.' ] \
  || fail "punctuated scope truncated: $CS_CAPO_REGISTRY_SCOPE"
[ "$CS_CAPO_REGISTRY_HOME" = /homes/punct ] || fail "punctuated scope stole the home: $CS_CAPO_REGISTRY_HOME"
pass "a scope containing semicolons, parentheses, and a trailing period survives intact"

# --- 3. a decoy (home: ...) inside the summary --------------------------------
# The structured suffix is the LAST parenthetical; a decoy in the prose must
# never become the routed home.

parse_ok '- decoy - fixes the (home: /wrong; scope: nope) bug (home: /homes/decoy; scope: real work; projects: p; added 2026-01-01)'
[ "$CS_CAPO_REGISTRY_HOME" = /homes/decoy ] || fail "a decoy home in the summary won: $CS_CAPO_REGISTRY_HOME"
[ "$CS_CAPO_REGISTRY_SCOPE" = 'real work' ] || fail "a decoy scope in the summary won: $CS_CAPO_REGISTRY_SCOPE"
[ "$CS_CAPO_REGISTRY_SUMMARY" = 'fixes the (home: /wrong; scope: nope) bug' ] \
  || fail "summary wrong: $CS_CAPO_REGISTRY_SUMMARY"
pass "a decoy (home: ...) inside the summary never becomes the routed home"

# --- 4. " - " inside the summary ----------------------------------------------

parse_ok '- dashes - triage - then fix - then document (home: /homes/dashes; scope: s; projects: p; added 2026-01-01)'
[ "$CS_CAPO_REGISTRY_ID" = dashes ] || fail "id wrong: $CS_CAPO_REGISTRY_ID"
[ "$CS_CAPO_REGISTRY_SUMMARY" = 'triage - then fix - then document' ] \
  || fail "summary split on an inner ' - ': $CS_CAPO_REGISTRY_SUMMARY"
pass "a summary containing ' - ' stays whole and the id stays the first token"

# --- 5. a home path with spaces -----------------------------------------------

parse_ok '- spacey - s (home: /Users/boss/My Homes/spacey; scope: s; projects: p; added 2026-01-01)'
[ "$CS_CAPO_REGISTRY_HOME" = '/Users/boss/My Homes/spacey' ] || fail "spaced home wrong: [$CS_CAPO_REGISTRY_HOME]"
pass "a home path containing spaces parses whole"

# --- 6. the degraded home+scope-only row --------------------------------------
# summary, projects, and added are optional on the READ path so a hand-edited
# or older routing table keeps routing. home and scope are not: they are what
# every consumer acts on.

parse_ok '- terse (home: /homes/terse; scope: infra work)'
[ "$CS_CAPO_REGISTRY_ID" = terse ] || fail "terse id wrong: $CS_CAPO_REGISTRY_ID"
[ "$CS_CAPO_REGISTRY_HOME" = /homes/terse ] || fail "terse home wrong: $CS_CAPO_REGISTRY_HOME"
[ "$CS_CAPO_REGISTRY_SCOPE" = 'infra work' ] || fail "terse scope wrong: $CS_CAPO_REGISTRY_SCOPE"
[ -z "$CS_CAPO_REGISTRY_SUMMARY" ] || fail "terse row invented a summary: $CS_CAPO_REGISTRY_SUMMARY"
[ -z "$CS_CAPO_REGISTRY_ADDED" ] || fail "terse row invented a date: $CS_CAPO_REGISTRY_ADDED"
parse_ok '- terse2 - with a summary (home: /homes/terse2; scope: owns a; b (and c))'
[ "$CS_CAPO_REGISTRY_SCOPE" = 'owns a; b (and c)' ] || fail "terse punctuated scope wrong: $CS_CAPO_REGISTRY_SCOPE"
pass "the degraded home+scope-only row still routes, with or without a summary"

# --- 7. malformed rows are rejected, never guessed at -------------------------

for bad in \
  '- broken - a row with no structured suffix' \
  '- nohome - x (scope: y; projects: p; added 2026-01-01)' \
  '- noscope - x (home: /homes/noscope; projects: p; added 2026-01-01)' \
  '- bad;id - x (home: /homes/bad; scope: s; projects: p; added 2026-01-01)' \
  '- bad id - x (home: /homes/bad; scope: s; projects: p; added 2026-01-01)' \
  '- empty - x (home: ; scope: s)'; do
  cs_capo_registry_parse_line "$bad" && fail "expected a malformed refusal for: $bad"
  [ -z "$CS_CAPO_REGISTRY_ID" ] || fail "a rejected line left a stale id: $CS_CAPO_REGISTRY_ID"
done
pass "a row missing an id, a home, or a scope is refused, with no field left behind"

# --- 8. EOF safety: the last row survives a missing trailing newline ----------
# This is the safety hole, not a cosmetic one: a dropped last row is a live
# home binding that duplicate-home and rebind checks never see.

cs_capo_registry_write "$REG" --no-final-newline \
  "$(cs_capo_registry_line first 'First.' /homes/first 'first work' p)" \
  "$(cs_capo_registry_line last 'Last.' /homes/last 'last work' p)"
got=$(records_of "$REG")
assert_contains "$got" 'ok|last|/homes/last|last work' "the last row was dropped at EOF"
[ "$(printf '%s\n' "$got" | wc -l | tr -d ' ')" = 2 ] || fail "expected 2 records, got: $got"
[ "$(cs_capo_registry_field "$REG" last home)" = /homes/last ] || fail "lookup dropped the last row at EOF"
pass "a registry whose last line has no trailing newline still yields its last capo"

# --- 9. malformed rows are surfaced in the record stream, not skipped ---------

cs_capo_registry_write "$REG" \
  "$(cs_capo_registry_line good 'Good.' /homes/good 'good work' p)" \
  '- wrecked - no suffix at all'
got=$(records_of "$REG")
assert_contains "$got" 'ok|good|/homes/good|good work' "the healthy row must still parse"
assert_contains "$got" 'malformed|-|-|-' "a malformed row must be surfaced, not skipped"
pass "a malformed row is reported alongside the healthy rows, never silently dropped"

# --- 10. a dotted id and its near miss are different capos --------------------
# `a.b` interpolated into a regular expression also matches `axb`; matching is
# literal so a lookup cannot cross routes.

cs_capo_registry_write "$REG" \
  "$(cs_capo_registry_line a.b 'Dotted.' /homes/dotted 'dotted work' p)" \
  "$(cs_capo_registry_line axb 'Near miss.' /homes/nearmiss 'near-miss work' p)"
[ "$(cs_capo_registry_field "$REG" a.b home)" = /homes/dotted ] || fail "dotted id resolved to the wrong home"
[ "$(cs_capo_registry_field "$REG" axb home)" = /homes/nearmiss ] || fail "near-miss id resolved to the wrong home"
cs_capo_registry_line_is_id "$(cs_capo_registry_line axb 'Near miss.' /homes/nearmiss 'near-miss work' p)" a.b \
  && fail "the dotted id matched the near-miss row"
cs_capo_registry_line_is_id "$(cs_capo_registry_line a.b 'Dotted.' /homes/dotted 'dotted work' p)" a.b \
  || fail "the dotted id did not match its own row"
pass "a dotted id matches only its own row, never a regex near miss"

# --- 11. an unknown or invalid id refuses with a reason ----------------------

cs_capo_registry_field "$REG" nosuch home && fail "an unregistered id must refuse"
assert_contains "$CS_CAPO_REGISTRY_ERROR" "is not registered" "the missing-entry reason is named"
cs_capo_registry_field "$REG" 'a b' home && fail "an id outside the charset must refuse"
assert_contains "$CS_CAPO_REGISTRY_ERROR" "capo id must be" "the invalid-id reason is named"
cs_capo_registry_valid_id 'x;y' && fail "a delimiter in an id must be refused"
pass "an unregistered or out-of-charset id refuses with a named reason"

# --- 12. duplicate ids refuse instead of resolving to the last row -----------

cs_capo_registry_write "$REG" \
  "$(cs_capo_registry_line dup 'One.' /homes/one 'work' p)" \
  "$(cs_capo_registry_line dup 'Two.' /homes/two 'work' p)"
cs_capo_registry_field "$REG" dup home && fail "a duplicated id must refuse, not pick a row"
assert_contains "$CS_CAPO_REGISTRY_ERROR" "has 2 entries" "the duplicate reason names the count"
pass "a duplicated id refuses instead of silently resolving to the last row"

# --- 13. missing, symlinked, and unreadable registries all fail closed -------

cs_capo_registry_exists "$TMP/absent.md" && fail "an absent registry must not report as existing"
cs_capo_registry_records "$TMP/absent.md" && fail "an absent registry must refuse"
assert_contains "$CS_CAPO_REGISTRY_ERROR" "no capo registry at" "the absent reason is named"

cs_capo_registry_write "$TMP/target.md" "$(cs_capo_registry_line linked 'L.' /homes/linked 'work' p)"
ln -s "$TMP/target.md" "$TMP/linked.md"
cs_capo_registry_exists "$TMP/linked.md" || fail "a symlinked registry must still count as present"
cs_capo_registry_records "$TMP/linked.md" && fail "a symlinked registry must refuse, never be followed"
assert_contains "$CS_CAPO_REGISTRY_ERROR" "symlink" "the symlink reason is named"
cs_capo_registry_field "$TMP/linked.md" linked home && fail "a symlinked registry must refuse lookups too"

if [ "$(id -u)" = 0 ]; then
  pass "unreadable-registry check skipped: running as root, where the mode bits do not apply"
else
  cp "$TMP/target.md" "$TMP/noread.md"
  chmod 000 "$TMP/noread.md"
  cs_capo_registry_exists "$TMP/noread.md" || fail "an unreadable registry must still count as present"
  cs_capo_registry_records "$TMP/noread.md" && fail "an unreadable registry must refuse, not report zero capos"
  assert_contains "$CS_CAPO_REGISTRY_ERROR" "unreadable" "the unreadable reason is named"
  chmod 644 "$TMP/noread.md"
  pass "an unreadable registry refuses rather than reading as an empty fleet"
fi
pass "a missing or symlinked registry refuses with a named reason"

# --- 14. an empty registry is a success with no records ----------------------

: > "$REG"
got=$(cs_capo_registry_records "$REG") || fail "an empty registry must succeed"
[ -z "$got" ] || fail "an empty registry must yield no records, got: $got"
pass "an existing but empty registry succeeds with no records"

# --- 15. a byte-bounded read drops its cut tail, not a real EOF row ----------
# cs-fleet-view.sh bounds the registry read. A line the bound sliced in half is
# a cut tail; an unterminated line in a file that ended on its own is a record.

cs_capo_registry_write "$REG" \
  "$(cs_capo_registry_line one 'One.' /homes/one 'work one' p)" \
  "$(cs_capo_registry_line two 'Two.' /homes/two 'work two' p)"
bytes=$(wc -c < "$REG" | tr -d ' ')
got=$(records_of "$REG" $((bytes - 20)))
assert_contains "$got" 'ok|one|/homes/one|work one' "the complete row before the bound must survive"
assert_not_contains "$got" 'malformed' "a byte-bound cut tail must not be reported as a malformed row"
got=$(records_of "$REG" "$bytes")
assert_contains "$got" 'ok|two|/homes/two|work two' "a bound at or past EOF must keep every row"
pass "a byte-bounded read drops only the tail the bound cut"

pass "cs-capo-registry-lib parse, lookup, and fail-closed contract"
