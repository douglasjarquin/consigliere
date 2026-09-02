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

test_vendored_python_suite
test_project_management_schema
pass "grokbot content checks"
