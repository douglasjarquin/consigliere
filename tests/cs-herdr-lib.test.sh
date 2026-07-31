#!/usr/bin/env bash
# Behavior (portable): workspace-label resolution in cs-herdr-lib.sh.
#
# Herdr enforces NO workspace-label uniqueness, so a label is a hint and never
# an identity. Resolving a home by taking the FIRST label match silently binds
# it to whichever duplicate comes back first, with no signal that a choice was
# made at all - the supervisor then drives a workspace the boss is not watching.
# These tests pin the refusal instead.
#
# The live herdr lane (tests/cs-herdr-lib-live.test.sh) covers the real server;
# this suite stubs cs_herdr so the ambiguity branches are exercised hermetically.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "1..0 # skip jq is required"; exit 0; }

TMP=$(cs_test_tmproot cs-herdr-lib)
mkdir -p "$TMP"

# shellcheck source=bin/cs-herdr-lib.sh
. "$ROOT/bin/cs-herdr-lib.sh"

# --- stub -------------------------------------------------------------------
# Only `workspace list` and `workspace create` are reachable from the functions
# under test. The create tally lives in a FILE, not a variable: the functions
# under test are called through command substitution, so a counter incremented
# in the stub's subshell would never reach the assertions. Distinguishing
# "refused" from "quietly made a third workspace" is the whole point here.
WS_JSON=''
CREATED_LOG="$TMP/created"
: > "$CREATED_LOG"

cs_herdr() {
  case "${1:-} ${2:-}" in
    "workspace list") printf '%s' "$WS_JSON" ;;
    "workspace create")
      echo create >> "$CREATED_LOG"
      printf '{"result":{"workspace":{"workspace_id":"w-created"}}}'
      ;;
    *) return 1 ;;
  esac
}

creates() {  # -> how many workspace creates the stub has served
  # grep -c prints 0 AND exits 1 on an empty log, so capture first, default after.
  local n
  n=$(grep -c . "$CREATED_LOG" 2>/dev/null) || n=0
  printf '%s' "$n"
}

reset_creates() { : > "$CREATED_LOG"; }

workspaces_json() {  # <label:id>... -> herdr workspace list payload
  local entries='' pair label id
  for pair in "$@"; do
    label=${pair%%:*}
    id=${pair##*:}
    [ -z "$entries" ] || entries="$entries,"
    entries="$entries{\"label\":\"$label\",\"workspace_id\":\"$id\"}"
  done
  printf '{"result":{"workspaces":[%s]}}' "$entries"
}

# --- exactly one match ------------------------------------------------------
WS_JSON=$(workspaces_json consigliere:w1 capo-alpha:w2 capo-beta:w3)
got=$(cs_herdr_workspace_find capo-alpha) || fail "a single label match must resolve"
[ "$got" = w2 ] || fail "expected w2 for capo-alpha, got '$got'"
pass "a unique workspace label resolves to its workspace"

# --- no match ---------------------------------------------------------------
rc=0
out=$(cs_herdr_workspace_find capo-missing 2>/dev/null) || rc=$?
[ "$rc" -eq 1 ] || fail "an absent label must return rc=1, got $rc"
[ -z "$out" ] || fail "an absent label must print nothing, got '$out'"
pass "an absent workspace label reports not-found"

# --- duplicate labels refuse ------------------------------------------------
WS_JSON=$(workspaces_json capo-alpha:w7 consigliere:w1 capo-alpha:w9)
rc=0
out=$(cs_herdr_workspace_find capo-alpha 2>/dev/null) || rc=$?
[ "$rc" -eq 2 ] || fail "a duplicated label must return rc=2 (ambiguous), got $rc"
[ -z "$out" ] || fail "an ambiguous label must print no workspace id, got '$out'"
# The diagnostic has to name the label and both candidates, or the boss has
# nothing to act on.
err=$({ cs_herdr_workspace_find capo-alpha >/dev/null; } 2>&1) || true
assert_contains "$err" 'capo-alpha' "ambiguity diagnostic names the label"
assert_contains "$err" 'w7' "ambiguity diagnostic names the first candidate"
assert_contains "$err" 'w9' "ambiguity diagnostic names the second candidate"
pass "duplicate workspace labels refuse instead of picking the first match"

# --- ensure: adopts a unique match without creating -------------------------
WS_JSON=$(workspaces_json capo-alpha:w2)
reset_creates
got=$(cs_herdr_home_workspace_ensure capo-alpha /tmp) || fail "ensure must adopt a unique match"
[ "$got" = w2 ] || fail "ensure returned '$got', expected the existing w2"
[ "$(creates)" -eq 0 ] || fail "ensure must not create when a unique home workspace exists"
pass "home workspace ensure adopts the one existing match"

# --- ensure: creates when absent --------------------------------------------
WS_JSON=$(workspaces_json consigliere:w1)
reset_creates
got=$(cs_herdr_home_workspace_ensure capo-alpha /tmp) || fail "ensure must create when absent"
[ "$got" = w-created ] || fail "ensure returned '$got', expected the created workspace"
[ "$(creates)" -eq 1 ] || fail "ensure must create exactly once when absent, saw $(creates)"
pass "home workspace ensure creates the home when it does not exist"

# --- ensure: ambiguity is a hard stop, never a third workspace --------------
WS_JSON=$(workspaces_json capo-alpha:w7 capo-alpha:w9)
reset_creates
rc=0
got=$(cs_herdr_home_workspace_ensure capo-alpha /tmp 2>/dev/null) || rc=$?
[ "$rc" -ne 0 ] || fail "ensure must fail on an ambiguous home label"
[ -z "$got" ] || fail "ensure must print no workspace id when ambiguous, got '$got'"
[ "$(creates)" -eq 0 ] ||
  fail "ensure must NOT create a third workspace when the label is already ambiguous"
pass "an ambiguous home label stops rather than deepening the ambiguity"

pass "cs-herdr-lib workspace label resolution"
