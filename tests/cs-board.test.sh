#!/usr/bin/env bash
# Behavior: cs-board.sh resolves board config, lists open Ready and Inbox
# issues, moves a card to In Progress or Backlog (never to Ready or Done),
# reads status, and fails closed on missing config/options. gh is faked;
# no network.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-board)
export CS_DATA_OVERRIDE="$TMP/data"
mkdir -p "$TMP/data"

FAKEBIN=$(cs_fakebin "$TMP")
# Fake gh: canned project view / field-list / item-list, and an item-edit that
# records its args so the test can prove only In Progress is ever set.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
sub="$1 $2"
case "$sub" in
  "project view")
    echo '{"id":"PVT_board1","number":7,"title":"Board"}' ;;
  "project field-list")
    cat <<'JSON'
{"fields":[
  {"id":"PVTSSF_status","name":"Status","options":[
    {"id":"opt_inbox","name":"Inbox"},
    {"id":"opt_backlog","name":"Backlog"},
    {"id":"opt_ready","name":"Ready"},
    {"id":"opt_wip","name":"In Progress"},
    {"id":"opt_done","name":"Done"}]}
]}
JSON
    ;;
  "project item-list")
    cat <<'JSON'
{"items":[
  {"id":"PVTI_a","status":"Ready","content":{"type":"Issue","number":11,"state":"OPEN","url":"https://github.com/o/r/issues/11","title":"first ready"}},
  {"id":"PVTI_b","status":"In Progress","content":{"type":"Issue","number":12,"state":"OPEN","url":"https://github.com/o/r/issues/12","title":"already started"}},
  {"id":"PVTI_c","status":"Ready","content":{"type":"Issue","number":13,"state":"CLOSED","url":"https://github.com/o/r/issues/13","title":"ready but closed"}},
  {"id":"PVTI_d","status":"Ready","content":{"type":"DraftIssue","number":0,"title":"draft note"}},
  {"id":"PVTI_e","status":"Ready","content":{"type":"Issue","number":14,"state":"OPEN","url":"https://github.com/o/r/issues/14","title":"second ready"}},
  {"id":"PVTI_f","status":"Inbox","content":{"type":"Issue","number":15,"state":"OPEN","url":"https://github.com/o/r/issues/15","title":"raw idea"}},
  {"id":"PVTI_g","status":"Inbox","content":{"type":"DraftIssue","number":0,"title":"inbox draft"}},
  {"id":"PVTI_h","status":"Inbox","content":{"type":"Issue","number":16,"state":"CLOSED","url":"https://github.com/o/r/issues/16","title":"inbox but closed"}}
]}
JSON
    ;;
  "project item-edit")
    echo "$*" >> "$EDIT_LOG"
    echo '{"id":"edited"}' ;;
  *) echo "unexpected gh: $*" >&2; exit 3 ;;
esac
SH
chmod +x "$FAKEBIN/gh"
export CS_BOARD_GH="$FAKEBIN/gh"
export EDIT_LOG="$TMP/edit.log"
: > "$EDIT_LOG"

BIN="$ROOT/bin/cs-board.sh"

# missing mapping fails closed
out=$("$BIN" ready proj 2>&1) && fail "missing mapping must fail"
assert_contains "$out" "no board mapping" "missing mapping named"
pass "missing board mapping fails closed"

# markdown comments and blank lines are ignored; mapping keyed by project name
cat > "$TMP/data/boards.md" <<'EOF'
# Board mappings for the contracts skill
# <project> <owner> <number> [labels...]

proj o 7
EOF

# ready: only OPEN Issues in Ready, drafts and non-Ready and closed excluded
out=$("$BIN" ready proj)
assert_contains "$out" "PVTI_a	11	https://github.com/o/r/issues/11	first ready" "first ready listed"
assert_contains "$out" "PVTI_e	14	" "second ready listed"
assert_not_contains "$out" "PVTI_b" "in-progress excluded"
assert_not_contains "$out" "PVTI_c" "closed excluded"
assert_not_contains "$out" "PVTI_d" "draft excluded"
[ "$(printf '%s\n' "$out" | grep -c .)" = 2 ] || fail "exactly two ready issues"
pass "ready lists only open Ready issues"

# inbox: only OPEN Issues in Inbox, drafts and closed excluded
out=$("$BIN" inbox proj)
assert_contains "$out" "PVTI_f	15	https://github.com/o/r/issues/15	raw idea" "inbox issue listed"
assert_not_contains "$out" "PVTI_g" "inbox draft excluded"
assert_not_contains "$out" "PVTI_h" "closed inbox issue excluded"
assert_not_contains "$out" "PVTI_a" "ready issue not in inbox listing"
[ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] || fail "exactly one inbox issue"
pass "inbox lists only open Inbox issues"

# start: moves to In Progress, and ONLY to the In Progress option id
out=$("$BIN" start proj PVTI_a)
assert_contains "$out" "In Progress" "start reports the move"
assert_grep 'single-select-option-id opt_wip' "$EDIT_LOG" "edit used the In Progress option"
assert_no_grep 'opt_done' "$EDIT_LOG" "Done option is never set"
pass "start moves card only to In Progress"

# specced: moves to Backlog, and never to Ready or Done (the human gate)
out=$("$BIN" specced proj PVTI_f)
assert_contains "$out" "Backlog" "specced reports the move"
assert_grep 'single-select-option-id opt_backlog' "$EDIT_LOG" "edit used the Backlog option"
assert_no_grep 'opt_ready' "$EDIT_LOG" "Ready option is never set"
assert_no_grep 'opt_done' "$EDIT_LOG" "Done option is still never set"
pass "specced moves card only to Backlog"

edits_before=$(wc -l < "$EDIT_LOG")
out=$("$BIN" specced proj PVTI_a 2>&1) && fail "specced must reject a non-Inbox card"
assert_contains "$out" "must be in 'Inbox'" "specced names the required source column"
[ "$(wc -l < "$EDIT_LOG")" = "$edits_before" ] || fail "non-Inbox card must not be edited"
pass "specced rejects non-Inbox cards"

# status: read-only current value
out=$("$BIN" status proj PVTI_b)
[ "$out" = "In Progress" ] || fail "status read wrong value: '$out'"
pass "status reads current card value"

# check: reports options and the built-in-only Done reminder
out=$("$BIN" check proj)
assert_contains "$out" "Done=ok" "check confirms Done option"
assert_contains "$out" "Inbox=ok" "check confirms Inbox option"
assert_contains "$out" "Backlog=ok" "check confirms Backlog option"
assert_contains "$out" "built-in" "check reminds about the workflow"
assert_contains "$out" "human approval gate" "check states the Backlog->Ready gate"
pass "check reports board sanity + workflow reminder"

# custom labels via underscores
printf 'todoproj o 9 Todo In_Progress Status\n' > "$TMP/data/boards.md"
out=$("$BIN" ready todoproj 2>&1)
# fixture items are labeled "Ready", not "Todo", so a Todo board finds none
[ -z "$out" ] || fail "custom ready label should match nothing in this fixture, got: $out"
pass "custom label config is honored"

printf 'badproj o 7 Ready In_Progress Status Inbox Ready\n' > "$TMP/data/boards.md"
edits_before=$(wc -l < "$EDIT_LOG")
out=$("$BIN" specced badproj PVTI_f 2>&1) && fail "Ready alias must fail closed"
assert_contains "$out" "aliases the protected 'Ready' option" "Ready alias is rejected"
[ "$(wc -l < "$EDIT_LOG")" = "$edits_before" ] || fail "Ready alias must not edit a card"
pass "specced rejects a Ready alias"

pass "cs-board behaviors"
