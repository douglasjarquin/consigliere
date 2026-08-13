#!/usr/bin/env bash
# tests/cs-auto-decision.test.sh - bin/cs-auto-decision-lib.sh: a non-blocking,
# append-only ledger for bossless-mode auto-decisions, distinct from
# bin/cs-decision-hold.sh's blocking captain-hold machinery.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-auto-decision-lib.sh
. "$ROOT/bin/cs-auto-decision-lib.sh"

TMP=$(cs_test_tmproot cs-auto-decision)
mkdir -p "$TMP"

# 1. record then render round-trip: three categories recorded, rendered
#    output lists all three with the most severe first.
DATA="$TMP/record-render/data"
mkdir -p "$DATA"
cs_auto_decision_record task1 routine "minor fix" "did X" "matches accepted intent" \
  || fail "recording a routine entry should succeed"
cs_auto_decision_record task1 destructive "deleted stale cache" "cleared it" "cache was corrupt" \
  || fail "recording a destructive entry should succeed"
cs_auto_decision_record task1 contract-expanding "added new endpoint" "added it" "needed for feature" \
  || fail "recording a contract-expanding entry should succeed"
log=$(cs_auto_decision_log_path task1)
[ -f "$log" ] || fail "the ledger file must be created"
[ "$(wc -l < "$log" | tr -d ' ')" = 3 ] || fail "the ledger must have exactly one line per record call"
rendered=$(cs_auto_decision_render task1)
assert_contains "$rendered" "deleted stale cache" "rendered output must list the destructive entry"
assert_contains "$rendered" "added new endpoint" "rendered output must list the contract-expanding entry"
assert_contains "$rendered" "minor fix" "rendered output must list the routine entry"
destructive_pos=$(printf '%s\n' "$rendered" | grep -n "deleted stale cache" | cut -d: -f1)
routine_pos=$(printf '%s\n' "$rendered" | grep -n "minor fix" | cut -d: -f1)
[ "$destructive_pos" -lt "$routine_pos" ] || fail "the destructive entry must render before the routine one"
pass "cs_auto_decision_record and cs_auto_decision_render round-trip, most-severe first"

# 2. no blocking hold is ever created: the library source never invokes
#    tasks-axi, under any category.
[ "$(grep -c 'tasks-axi' "$ROOT/bin/cs-auto-decision-lib.sh")" = 0 ] \
  || fail "cs-auto-decision-lib.sh must never invoke tasks-axi"
pass "the auto-decision ledger never creates a tasks-axi hold"

# 3. an invalid category is refused, and nothing is written.
DATA="$TMP/invalid-category/data"
mkdir -p "$DATA"
cs_auto_decision_record task2 not-a-real-category "x" "y" "z" 2>/dev/null \
  && fail "an invalid category must be refused"
[ ! -e "$(cs_auto_decision_log_path task2)" ] \
  || fail "a refused record call must not create the ledger file"
pass "an invalid category is refused before anything is written"

# 4. the ledger file survives a simulated teardown: bin/cs-teardown.sh only
#    ever reads from data/ (e.g. report.md) and never removes it, matching
#    the existing "task-scoped notes... survive teardown" placement.
DATA="$TMP/survives-teardown/data"
mkdir -p "$DATA"
cs_auto_decision_record task3 security-sensitive "rotated a credential" "rotated it" "expired" \
  || fail "recording before the simulated teardown should succeed"
log=$(cs_auto_decision_log_path task3)
[ ! -e "$ROOT/bin/.cs-teardown-would-touch-data-marker" ] \
  || fail "unexpected leftover marker from a prior run"
grep -Fq "rm -rf.*\"\$DATA\"" "$ROOT/bin/cs-teardown.sh" 2>/dev/null \
  && fail "bin/cs-teardown.sh must never remove \$DATA wholesale"
[ -f "$log" ] || fail "the ledger file must still exist after the (simulated) teardown"
pass "the auto-decision ledger survives a simulated teardown"

pass "cs-auto-decision-lib.sh non-blocking ledger contract"
