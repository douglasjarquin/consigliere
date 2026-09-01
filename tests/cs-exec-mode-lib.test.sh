#!/usr/bin/env bash
# Behavior (portable): cs-exec-mode-lib.sh - the closed ultrawork|plan-first
# set and its stated default.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-exec-mode-lib.sh
. "$ROOT/bin/cs-exec-mode-lib.sh"

[ "$CS_EXEC_MODE_DEFAULT" = ultrawork ] || fail "the default must be ultrawork"

cs_exec_mode_valid ultrawork || fail "ultrawork must be valid"
cs_exec_mode_valid plan-first || fail "plan-first must be valid"
cs_exec_mode_valid bogus && fail "an unknown value must be invalid" || true
cs_exec_mode_valid "" && fail "an empty value must be invalid" || true
pass "cs_exec_mode_valid accepts only ultrawork and plan-first"

pass "cs-exec-mode-lib behavior"
