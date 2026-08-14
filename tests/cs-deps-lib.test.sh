#!/usr/bin/env bash
# Behavior (portable): cs-deps-lib.sh's dependency inventory correctly names
# `made` (not the pre-migration `no-mistakes`) among the optional tools, with
# a purpose string and install hint that both name `made` and point at made's
# own repo (https://github.com/douglasjarquin/made), never the old
# kunchenguid/no-mistakes upstream.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-deps-lib.sh
. "$ROOT/bin/cs-deps-lib.sh"

# --- optional tool list: made, not no-mistakes ------------------------------

optional=$(cs_deps_tools optional)
assert_line "$optional" '^made$' "cs_deps_tools optional must list 'made'"
assert_no_line "$optional" '^no-mistakes$' "cs_deps_tools optional must not list the pre-migration 'no-mistakes' name"
pass "cs_deps_tools optional reports made, not no-mistakes"

# --- purpose: names made, not no-mistakes -----------------------------------

purpose=$(cs_deps_purpose made) || fail "cs_deps_purpose made must succeed"
assert_contains "$purpose" made "cs_deps_purpose made must mention made"
assert_not_contains "$purpose" no-mistakes "cs_deps_purpose made must not mention no-mistakes"
pass "cs_deps_purpose made describes made, not no-mistakes"

# --- install hint: made's own repo URL --------------------------------------

hint=$(cs_deps_hint made) || fail "cs_deps_hint made must succeed"
assert_contains "$hint" "https://github.com/douglasjarquin/made" \
  "cs_deps_hint made must point at made's own repo"
assert_not_contains "$hint" kunchenguid "cs_deps_hint made must not point at the old kunchenguid/no-mistakes repo"
pass "cs_deps_hint made installs from made's own repo"

pass "cs-deps-lib reports made (not no-mistakes) as the optional delivery-pipeline dependency"
