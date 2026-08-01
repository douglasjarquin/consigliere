#!/usr/bin/env bash
# Behavior: cs-board-watch.sh records a durable board sweep, arms a hash-bound
# watcher poll from that record, converges the two with `sync`, and retires
# both on disarm. The generated poll reports a grown column, stays silent on a
# column consigliere itself shrank, stays silent on a clear board, and stays
# silent on every error. gh is faked; no network.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-board-watch)
export CS_HOME="$TMP/home"
mkdir -p "$CS_HOME/data" "$CS_HOME/state"
DATA="$CS_HOME/data"
STATE="$CS_HOME/state"

FAKEBIN=$(cs_fakebin "$TMP")
export ITEMS_JSON="$TMP/items.json"

# Fake gh: item-list is served from $ITEMS_JSON so a test can grow or shrink a
# column between polls. Any other subcommand is a hard error, which also proves
# the poll never edits a card.
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
  "project item-list") cat "$ITEMS_JSON" ;;
  *) echo "unexpected gh: $*" >&2; exit 3 ;;
esac
SH
chmod +x "$FAKEBIN/gh"
export CS_BOARD_GH="$FAKEBIN/gh"

# Branch on uname rather than `stat -f || stat -c`: GNU stat's -f is
# --file-system, so it succeeds with a filesystem dump instead of failing over.
file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

BIN="$ROOT/bin/cs-board-watch.sh"
POLL="$STATE/sweep-proj.check.sh"
TRUST="$STATE/sweep-proj.check-trust"
SEEN="$STATE/sweep-proj.board-seen"

# write_board <ready-count> <inbox-count>
write_board() {
  local ready=$1 inbox=$2 i n=0
  {
    printf '{"items":['
    for ((i = 0; i < ready; i += 1)); do
      [ "$n" -eq 0 ] || printf ','
      printf '{"id":"PVTI_r%d","status":"Ready","content":{"type":"Issue","number":%d,"state":"OPEN","url":"https://github.com/o/r/issues/%d","title":"ready %d"}}' "$i" "$((100 + i))" "$((100 + i))" "$i"
      n=1
    done
    for ((i = 0; i < inbox; i += 1)); do
      [ "$n" -eq 0 ] || printf ','
      printf '{"id":"PVTI_i%d","status":"Inbox","content":{"type":"Issue","number":%d,"state":"OPEN","url":"https://github.com/o/r/issues/%d","title":"inbox %d"}}' "$i" "$((200 + i))" "$((200 + i))" "$i"
      n=1
    done
    printf ']}\n'
  } > "$ITEMS_JSON"
}

write_board 2 1

# --- arming fails closed ----------------------------------------------------

out=$("$BIN" arm proj 2>&1) && fail "arm must refuse an unmapped project"
assert_contains "$out" "no board mapping" "unmapped project named"
assert_absent "$DATA/sweeps.md" "no sweep record written for an unmapped project"
assert_absent "$POLL" "no poll armed for an unmapped project"
pass "arm fails closed on an unmapped board"

printf 'proj o 7\n' > "$DATA/boards.md"

out=$("$BIN" arm 'bad name' 2>&1) && fail "arm must refuse an invalid project name"
assert_contains "$out" "invalid project name" "invalid name named"
out=$("$BIN" arm ../escape 2>&1) && fail "arm must refuse a traversing project name"
assert_contains "$out" "invalid project name" "traversing name named"
out=$("$BIN" arm proj --lanes 0 2>&1) && fail "arm must refuse a zero lane cap"
assert_contains "$out" "--lanes must be a positive integer" "bad lane cap named"
pass "arm validates project name and lane cap"

# --- arm records and binds --------------------------------------------------

out=$("$BIN" arm proj --lanes 2 --resurface 900)
assert_contains "$out" "armed: proj board sweep" "arm reports the sweep"
assert_grep "proj 2 900 " "$DATA/sweeps.md" "sweep record carries project, lanes, resurface"
assert_present "$POLL" "poll written"
assert_present "$TRUST" "poll bound to a trust record"
[ "$(file_mode "$POLL")" = 700 ] || fail "poll must be mode 0700"
out=$("$BIN" list)
assert_contains "$out" "proj lanes=2 resurface=900s" "list reports the sweep"
assert_contains "$out" "poll=armed" "list reports the poll as armed"
pass "arm records the sweep and binds its poll"

# --- the generated poll -----------------------------------------------------

out=$(bash "$POLL")
assert_contains "$out" "2 ready, 1 inbox on the proj board (lane cap 2)" "first poll reports depth"
assert_present "$SEEN" "poll records what it reported"
pass "poll reports a non-empty board on its first run"

out=$(bash "$POLL")
[ -z "$out" ] || fail "unchanged counts inside the resurface window must be silent, got: $out"
pass "poll is silent while nothing changed"

# Consigliere dispatching two lanes shrinks Ready; that must not wake anyone.
write_board 0 1
out=$(bash "$POLL")
[ -z "$out" ] || fail "a shrinking column must be silent, got: $out"
pass "poll is silent on a column consigliere shrank"

# A boss promotion into Ready grows the column and must report immediately.
write_board 3 1
out=$(bash "$POLL")
assert_contains "$out" "3 ready, 1 inbox" "grown Ready column reported"
pass "poll reports a grown column immediately"

# A new Inbox idea alone also reports.
write_board 3 4
out=$(bash "$POLL")
assert_contains "$out" "3 ready, 4 inbox" "grown Inbox column reported"
pass "poll reports a grown Inbox column"

# Still-full board, nothing changed, resurface interval elapsed -> report again
# so a sweep cannot go quiet while work sits.
printf '3\n4\n1\n' > "$SEEN"
out=$(bash "$POLL")
assert_contains "$out" "3 ready, 4 inbox" "stale still-full board resurfaced"
pass "poll resurfaces a still-full board after the interval"

# A cleared board is the healthy end state: silent forever.
write_board 0 0
out=$(bash "$POLL")
[ -z "$out" ] || fail "a clear board must be silent, got: $out"
pass "poll is silent on a clear board"

# A failed board read must never read as an empty column, and never as a wake.
write_board 5 5
rm -f "$SEEN"
out=$(CS_BOARD_GH="$TMP/nope" bash "$POLL" 2>/dev/null)
[ -z "$out" ] || fail "a failed board read must be silent, got: $out"
assert_absent "$SEEN" "a failed read records nothing"
pass "poll is silent when the board cannot be read"

# --- drift and convergence --------------------------------------------------

printf '\n# tampered\n' >> "$POLL"
out=$("$BIN" list)
assert_contains "$out" "poll=NOT ARMED" "hand-edited poll is no longer trusted"
pass "editing the poll disarms it instead of changing what runs"

out=$("$BIN" sync)
assert_contains "$out" "re-armed the proj board sweep poll" "sync re-arms a broken poll"
assert_no_grep "tampered" "$POLL" "sync regenerated the poll from the record"
out=$("$BIN" list)
assert_contains "$out" "poll=armed" "poll trusted again after sync"
pass "sync re-arms a sweep whose poll drifted"

# A poll whose record is gone would keep waking the fleet for an ended sweep.
printf '# Active board sweeps.\n' > "$DATA/sweeps.md"
out=$("$BIN" list)
assert_contains "$out" "ORPHAN poll with no record" "orphan poll reported"
out=$("$BIN" sync)
assert_contains "$out" "retired the proj board sweep poll" "sync retires an orphan poll"
assert_absent "$POLL" "orphan poll removed"
assert_absent "$TRUST" "orphan trust record removed"
pass "sync retires a poll whose record is gone"

out=$("$BIN" sync)
[ -z "$out" ] || fail "a converged sync must be silent, got: $out"
pass "sync is silent once records and polls agree"

# --- disarm -----------------------------------------------------------------

"$BIN" arm proj >/dev/null
assert_present "$POLL" "re-armed for the disarm case"
out=$("$BIN" disarm proj)
assert_contains "$out" "disarmed: proj board sweep" "disarm reports the sweep"
assert_absent "$POLL" "disarm removes the poll"
assert_absent "$TRUST" "disarm removes the trust record"
assert_absent "$SEEN" "disarm removes the poll's memory"
assert_no_grep "proj " "$DATA/sweeps.md" "disarm drops the record"
out=$("$BIN" disarm proj)
assert_contains "$out" "no active sweep for proj" "disarm is idempotent"
out=$("$BIN" list)
assert_contains "$out" "(no active board sweeps)" "list reports an empty sweep set"
pass "disarm retires the record and every poll artifact"
