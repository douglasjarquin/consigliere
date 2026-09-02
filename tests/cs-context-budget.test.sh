#!/usr/bin/env bash
# tests/cs-context-budget.test.sh - issue #151 phase 4: bin/cs-context-budget.sh
# is the CI gate that fails a PR when the kernel or a startup fixture regresses
# past its hard ceiling. This suite proves both directions: the tool passes
# clean against the real repo's current state (the actual gate future PRs
# run), and it correctly detects and names a real regression rather than
# silently passing one.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="$ROOT/bin/cs-context-budget.sh"

# --- 1. clean against the real repo: this IS the CI gate --------------------
out=$(bash "$BIN" 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "cs-context-budget.sh must exit 0 against the current repo state (a real, unaddressed budget regression):"$'\n'"$out"
assert_not_contains "$out" "REGRESSIONS" "a clean run must print no REGRESSIONS section"
pass "cs-context-budget.sh passes clean against the repo's current AGENTS.md and startup fixtures"

# --- 2. the pathological (200-task) startup fixture proves the phase-3 task
#        cap actually keeps a large fleet's digest under the hard ceiling ---
assert_contains "$out" "pathological:" "the pathological fixture is measured and reported"
pathological_bytes=$(printf '%s\n' "$out" | sed -n 's/^ *pathological: \([0-9]*\) bytes.*/\1/p')
[ -n "$pathological_bytes" ] || fail "could not parse the pathological fixture's byte count from the report"
[ "$pathological_bytes" -le 20480 ] || fail "the 200-task pathological fixture is $pathological_bytes bytes, over the 20480-byte hard ceiling - the phase-3 task cap is not holding"
pass "the 200-task pathological startup fixture stays under the 20 KB hard ceiling ($pathological_bytes bytes)"

# --- 3. an artificially low kernel ceiling is caught and named exactly ------
out=$(CS_CONTEXT_BUDGET_KERNEL_MAX=100 bash "$BIN" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "a kernel over its (artificially lowered) ceiling must fail, not pass"
assert_contains "$out" "REGRESSIONS" "the failing run names a REGRESSIONS section"
assert_contains "$out" "AGENTS.md kernel is" "the regression names the kernel specifically"
assert_contains "$out" "over the 100-byte hard ceiling" "the regression names the exact ceiling that was breached"
pass "an artificially lowered kernel ceiling is caught and named exactly, not silently passed"

# --- 4. an artificially low startup ceiling is caught the same way ---------
out=$(CS_CONTEXT_BUDGET_STARTUP_MAX=10 bash "$BIN" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "a startup fixture over its (artificially lowered) ceiling must fail, not pass"
regression_count=$(printf '%s\n' "$out" | grep -c "over the 10-byte hard ceiling")
[ "$regression_count" -eq 3 ] || fail "expected all 3 startup fixtures (empty, five, pathological) to breach a 10-byte ceiling, got $regression_count regressions named"
pass "an artificially lowered startup ceiling is caught for every fixture, not silently passed"

# --- 5. --json emits valid, parseable JSON with the same regression -------
out=$(CS_CONTEXT_BUDGET_KERNEL_MAX=100 bash "$BIN" --json 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "--json must still exit nonzero on a real regression"
command -v python3 >/dev/null 2>&1 && {
  printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' \
    || fail "--json output is not valid JSON:"$'\n'"$out"
}
assert_contains "$out" '"schema": "cs-context-budget.v1"' "the JSON output carries its schema"
assert_contains "$out" 'AGENTS.md kernel is' "the JSON regressions array names the same breach as the human output"
pass "--json emits valid JSON carrying the same regression the human output reports"

# --- 6. every pack in --list is measured, none silently skipped ------------
list_count=$(bash "$ROOT/bin/cs-context-pack.sh" --list | grep -c .)
row_count=$(printf '%s\n' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["packs"]))' 2>/dev/null)
[ -n "$row_count" ] || row_count=$(bash "$BIN" --json 2>&1 | grep -o '"role"' | wc -l | tr -d '[:space:]')
[ "$row_count" -eq "$list_count" ] || fail "expected all $list_count listed combinations measured, got $row_count pack rows"
pass "every role/workflow/harness combination cs-context-pack.sh lists is measured, none skipped"

pass "cs-context-budget.sh"
