#!/usr/bin/env bash
# Behavior (portable): the vendored Grok Bot Python suite passes and its
# canonical SQLite schema creates the projects and tasks tables.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FETCH_TEST="$ROOT/grokbot/skills/triage-eligible-fetch/test_fetch.py"
SCHEMA="$ROOT/grokbot/skills/project-management/schema.sql"
TMP_ROOT=$(cs_test_tmproot grokbot)
DB="$TMP_ROOT/factory.db"

test_vendored_python_suite() {
  if ! python3 -m unittest discover -s "$(dirname "$FETCH_TEST")" -p "$(basename "$FETCH_TEST")"; then
    fail "vendored Grok Bot Python tests failed"
  fi
  pass "vendored Grok Bot Python tests"
}

test_project_management_schema() {
  local tables
  if ! sqlite3 "$DB" <"$SCHEMA"; then
    fail "Grok Bot project-management schema did not apply"
  fi
  tables=$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;") ||
    fail "Grok Bot schema tables could not be queried"
  assert_line "$tables" '^projects$' "Grok Bot schema did not create projects"
  assert_line "$tables" '^tasks$' "Grok Bot schema did not create tasks"
  pass "Grok Bot project-management schema"
}

test_consigliere_naming() {
  local stale
  assert_present "$ROOT/grokbot/GROK_BOT_CONSIGLIERE.md" "Consigliere charter is missing"
  assert_present "$ROOT/grokbot/GROK_BOT_SOLDIER.md" "soldier charter is missing"
  assert_absent "$ROOT/grokbot/GROK_BOT_FIRSTMATE.md" "old Firstmate charter name remains"
  assert_absent "$ROOT/grokbot/GROK_BOT_CREWMATE.md" "old Crewmate charter name remains"
  stale=$(
    {
      find "$ROOT/grokbot" -type f ! -path '*/__pycache__/*' \
        -exec grep -Ein '(^|[^[:alnum:]_])(firstmate|crewmate|captain)([^[:alnum:]_]|$)' {} +
      grep -Ein '(^|[^[:alnum:]_])(firstmate|crewmate|captain)([^[:alnum:]_]|$)' "$ROOT/docs/grokbot.md"
    } || true
  )
  [ -z "$stale" ] || fail "upstream role vocabulary remains in the Grok Bot pack"$'\n'"$stale"
  pass "Consigliere role vocabulary"
}

test_cleaner_and_casino_naming() {
  local stale
  assert_present "$ROOT/grokbot/GROK_BOT_CLEANER.md" "Cleaner charter is missing"
  assert_present "$ROOT/grokbot/skills/sitdown/SKILL.md" "sitdown skill is missing"
  assert_absent "$ROOT/grokbot/skills/ahoy" "old ahoy skill dir remains"
  assert_present "$ROOT/grokbot/GROK_CASINO.md" "Grok Casino installer is missing"
  assert_absent "$ROOT/grokbot/GROK_SHIP.md" "old Grok Ship installer name remains"
  stale=$(
    find "$ROOT/grokbot" -type f ! -path '*/__pycache__/*' -exec grep -Ein 'ahoy' {} + || true
  )
  [ -z "$stale" ] || fail "stale 'ahoy' vocabulary remains in the Grok Bot pack"$'\n'"$stale"
  stale=$(grep -Ein 'ahoy' "$ROOT/docs/grokbot.md" || true)
  [ -z "$stale" ] || fail "stale 'ahoy' vocabulary remains in docs/grokbot.md"$'\n'"$stale"
  pass "Cleaner and Grok Casino naming"
}

test_vendored_python_suite
test_project_management_schema
test_consigliere_naming
test_cleaner_and_casino_naming
pass "grokbot content checks"
