#!/usr/bin/env bash
# tests/cs-capo-decision-escalation.test.sh - end-to-end integration coverage
# for plan 009's Wave 1: the exact overnight failure that stalled a 3-lane
# casino sweep (a capo-nested decision the boss answered, resolved with no
# manual CS_HOME juggling), reproduced start to finish through the REAL
# bin/cs-watch.sh capo scan and bin/cs-send.sh --resolve-key delivery, plus
# negative-path regression coverage. Composes tests/capo-helpers.sh's
# fixtures and tests/cs-board-capacity.test.sh's lane-accounting pattern
# rather than building a parallel fixture stack.
#
# Two scenarios already have dedicated, passing coverage at the unit level
# and are not duplicated here: "a decision survives a later working: append"
# (tests/cs-watch-triage.test.sh, Task 1) and "two same-key needs-decision
# lines on one capo task never collide on the parent-facing key"
# (tests/cs-pending-reply.test.sh, Task 5).
set -u
# shellcheck source=tests/capo-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/capo-helpers.sh"
# shellcheck source=bin/cs-marker-lib.sh
. "$ROOT/bin/cs-marker-lib.sh"
# shellcheck source=bin/cs-pending-reply-lib.sh
. "$ROOT/bin/cs-pending-reply-lib.sh"

TMP=$(cs_test_tmproot cs-capo-decision-escalation)
mkdir -p "$TMP"

WATCH="$ROOT/bin/cs-watch.sh"
SEND="$ROOT/bin/cs-send.sh"
BOARD_CAPACITY="$ROOT/bin/cs-board-capacity.sh"
FAKEBIN=$(cs_fakebin "$TMP")
cs_capo_fake_herdr "$FAKEBIN"
export PATH="$FAKEBIN:$PATH"
export CS_SEND_SETTLE=0
export FAKE_AGENT=codex FAKE_AGENT_STATUS=idle FAKE_PANE_EXISTS=1

# One capo-scan pass against <parent-state-dir>, exactly as bin/cs-watch.sh's
# Layer 1b runs it every poll: scan_capo_worker_events's own read-only pass,
# THEN _capo_mark_surfaced for every row it reported - the same
# enqueue-then-mark-surfaced sequence the real caller runs after durably
# queuing the wake (Task 2's crash-safety ordering). Without this second half
# a later poll's manifest diff would never see today's open set as "old", so
# a subsequent resolve would never be detected as a close. Prints
# scan_capo_worker_events's own output.
scan_pending() {  # <parent-state-dir>
  (
    cd "$TMP" || exit 2
    # shellcheck disable=SC1090,SC1091
    PATH="$FAKEBIN:$PATH" CS_STATE_OVERRIDE="$1" . "$WATCH"
    pending=$(scan_capo_worker_events)
    printf '%s\n' "$pending"
    while IFS=$(printf '\t') read -r cid ctask _ _ _; do
      [ -n "$cid" ] || continue
      _capo_mark_surfaced "$cid" "$ctask"
    done <<EOF
$pending
EOF
  )
}

run_send() {  # <home> <state-dir> <log> -- <cs-send args...>
  local home=$1 state=$2 log=$3; shift 3
  : > "$log"
  env CS_HOME="$home" CS_STATE_OVERRIDE="$state" CS_SEND_LOG="$log" CS_SEND_SETTLE=0 "$SEND" "$@"
}

new_fixture() {  # -> "<parent-home>\t<parent-state>\t<capo-home>\t<capo-state>"
  local home capo_home
  home=$(mktemp -d "$TMP/parent.XXXXXX")
  capo_home=$(mktemp -d "$TMP/capo.XXXXXX")
  mkdir -p "$home/state" "$capo_home/state"
  : > "$capo_home/.cs-capo-home"
  cs_write_meta "$home/state/mycapo.meta" "workspace=w1" "pane=w1:p1" "kind=capo" "mode=capo" "home=$capo_home"
  printf '%s\t%s\t%s\t%s' "$home" "$home/state" "$capo_home" "$capo_home/state"
}

# === Happy path: the exact overnight failure, reproduced end to end ========

IFS=$(printf '\t') read -r home state capo_home capo_state <<EOF
$(new_fixture)
EOF

# 1. A fake capo soldier raises an open decision in its own task file, on its
#    own turn - nothing pushes this to the parent (bin/cs-watch.sh:1344-1346's
#    "reading is safer than a capo pushing").
printf 'needs-decision [key=x]: pick an approach\n' > "$capo_state/w-1.status"

# 2. The fixed Layer 1b scan (Task 1) opens a parent-side escalation record
#    (Task 3) with a minted, collision-free key (Task 5).
pending=$(scan_pending "$state")
case "$pending" in
  *"mycapo"*"w-1"*"x"*) : ;;
  *) fail "the capo scan did not report the open decision: $pending" ;;
esac
rec=$(cs_pending_reply_capo_escalation_find "$state" mycapo w-1 x) \
  || fail "the capo scan must have opened a parent-side escalation record"
assert_contains "$(status_open_decisions "$state/mycapo.status")" "mycapo-w-1" \
  "the minted parent-facing key must be open in the parent's own ledger"

# 3. cs-send.sh --resolve-key against that parent-facing key, with NO CS_HOME
#    override by the caller (Task 4), delivers the answer to the capo; the
#    parent's own record stays open - closing is Task 3's job, gated on the
#    capo's own resolution, never on this delivery.
run_send "$home" "$state" "$TMP/deliver.log" mycapo --resolve-key mycapo-w-1 "use option B" >/dev/null \
  || fail "the boss's answer, routed with no CS_HOME override, should deliver"
got=$(cat "$TMP/deliver.log")
assert_contains "$got" "use option B" "the delivered text must carry the boss's own answer"
[ "$(cs_pending_reply_get "$rec" phase)" = escalated ] \
  || fail "the parent's own record must remain open immediately after delivery"
[ "$(grep -Fc 'resolved [key=mycapo-w-1]' "$state/mycapo.status")" = 0 ] \
  || fail "delivery alone must never close the parent's own escalation record"

# 4. Standing in for the capo's own next agent turn (the fixture cannot run a
#    live agent): it resolves ITS OWN decision locally, in its OWN home,
#    using the answer text this delivery carried.
mkdir -p "$capo_home/projects/proj"
proj_dir=$(cd "$capo_home/projects/proj" && pwd -P)
cs_write_meta "$capo_state/w-1.meta" "workspace=cw1" "pane=cw1:p1" "kind=ship" "project=$proj_dir"
run_send "$capo_home" "$capo_state" "$TMP/capo-resolve.log" w-1 --resolve-key x "$got" >/dev/null \
  || fail "the capo's own local resolve should succeed"
assert_contains "$(cat "$capo_state/w-1.status")" "resolved [key=x]: relayed-from-parent via cs-send:" \
  "the capo's own task file must show its own key resolved, distinguishably relayed (Task 7)"

# 5. A subsequent capo-scan run (Task 3's closing half) observes that and
#    closes the parent's own record - the capo's soldier is now unblocked.
scan_pending "$state" >/dev/null
[ "$(cs_pending_reply_get "$rec" phase)" = resolved ] \
  || fail "the next capo scan must close the parent's own record once the capo resolves"
case "$(status_open_decisions "$state/mycapo.status")" in
  *mycapo-w-1*) fail "the parent's ledger must show no open decision for the closed key" ;;
esac

# 6. Lane mechanics: answering the decision unblocks the soldier, but does
#    NOT itself free the lane - it frees only later, through the existing
#    teardown/merge-verified path (a dead pane ALONE still counts occupied,
#    fail-safe against a crashed or wedged soldier; only a verified merged
#    PR moves it out of occupied, bin/cs-board-capacity.sh's own contract).
cap=$(env CS_HOME="$capo_home" CS_STATE_OVERRIDE="$capo_state" "$BOARD_CAPACITY" proj 3)
case "$cap" in
  *"occupied=1"*) : ;;
  *) fail "the lane must still read occupied immediately after the decision closes: $cap" ;;
esac
pr_head=4444444444444444444444444444444444444444
cat > "$FAKEBIN/gh-axi" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"pullRequest(number: 404)"*)
    printf '%s\n' 'api_response:' '  body: MERGED|false|$pr_head|SUCCESS|NONE' '  truncated: false'
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/gh-axi"
cs_write_meta "$capo_state/w-1.meta" "workspace=cw1" "pane=" "kind=ship" "project=$proj_dir" \
  "pr=https://github.com/o/r/pull/404" "pr_head=$pr_head"
cap=$(env CS_HOME="$capo_home" CS_STATE_OVERRIDE="$capo_state" "$BOARD_CAPACITY" proj 3)
case "$cap" in
  *"cleanup_pending=1"*) : ;;
  *) fail "the lane must free via the merge-verified path, never from decision-close alone: $cap" ;;
esac
pass "the exact overnight failure resolves end to end, and the lane frees later, not on decision-close"

# === Negative paths ==========================================================

# 7. A wrong key refuses and closes nothing on either side.
IFS=$(printf '\t') read -r home state capo_home capo_state <<EOF
$(new_fixture)
EOF
printf 'needs-decision [key=y]: pick an approach\n' > "$capo_state/w-2.status"
scan_pending "$state" >/dev/null
rec=$(cs_pending_reply_capo_escalation_find "$state" mycapo w-2 y) \
  || fail "fixture setup: the escalation record should have opened"
if run_send "$home" "$state" "$TMP/wrongkey.log" mycapo --resolve-key mycapo-wrong "use option Z" >/dev/null 2>&1; then
  fail "a wrong parent-facing key must be refused, not delivered"
fi
[ ! -s "$TMP/wrongkey.log" ] || fail "a refused wrong-key send must deliver nothing"
[ "$(cs_pending_reply_get "$rec" phase)" = escalated ] \
  || fail "a refused wrong-key send must leave the parent's own record open"
[ "$(grep -Fc 'resolved' "$capo_state/w-2.status")" = 0 ] \
  || fail "a refused wrong-key send must leave the capo's own file untouched"
pass "a wrong parent-facing key refuses and closes nothing on either side"

# 8. A failed delivery closes neither ledger.
IFS=$(printf '\t') read -r home state capo_home capo_state <<EOF
$(new_fixture)
EOF
printf 'needs-decision [key=z]: pick an approach\n' > "$capo_state/w-3.status"
scan_pending "$state" >/dev/null
rec=$(cs_pending_reply_capo_escalation_find "$state" mycapo w-3 z) \
  || fail "fixture setup: the escalation record should have opened"
if env CS_HOME="$home" CS_STATE_OVERRIDE="$state" CS_SEND_LOG="$TMP/faildeliver.log" CS_SEND_SETTLE=0 \
  CS_SEND_RETRIES=0 FAKE_AGENT_WAIT_FAIL=1 \
  "$SEND" mycapo --resolve-key mycapo-w-3 "use option Q" >/dev/null 2>&1; then
  fail "an unconfirmed submit must exit non-zero"
fi
[ "$(cs_pending_reply_get "$rec" phase)" = escalated ] \
  || fail "a failed delivery must leave the parent's own record open"
[ "$(grep -Fc 'resolved' "$capo_state/w-3.status")" = 0 ] \
  || fail "a failed delivery must leave the capo's own file untouched"
pass "a failed delivery closes neither the parent's nor the capo's ledger"

# 9. Two concurrently-open decisions in different fake lanes cannot
#    cross-resolve each other.
IFS=$(printf '\t') read -r home_a state_a _ capo_state_a <<EOF
$(new_fixture)
EOF
cs_write_meta "$state_a/othercapo.meta" "workspace=w9" "pane=w9:p9" "kind=capo" "mode=capo" "home=$TMP/othercapo-home"
mkdir -p "$TMP/othercapo-home/state"
: > "$TMP/othercapo-home/.cs-capo-home"
printf 'needs-decision [key=a]: lane A question\n' > "$capo_state_a/w-a.status"
printf 'needs-decision [key=b]: lane B question\n' > "$TMP/othercapo-home/state/w-b.status"
scan_pending "$state_a" >/dev/null
cs_pending_reply_capo_escalation_find "$state_a" mycapo w-a a >/dev/null \
  || fail "fixture setup: lane A's escalation record should have opened"
rec_b=$(cs_pending_reply_capo_escalation_find "$state_a" othercapo w-b b) \
  || fail "fixture setup: lane B's escalation record should have opened"
run_send "$home_a" "$state_a" "$TMP/lanea.log" mycapo --resolve-key mycapo-w-a "answer for A" >/dev/null \
  || fail "lane A's own resolve-key should deliver"
[ "$(cs_pending_reply_get "$rec_b" phase)" = escalated ] \
  || fail "answering lane A must never touch lane B's own record"
[ "$(grep -Fc 'resolved' "$TMP/othercapo-home/state/w-b.status")" = 0 ] \
  || fail "answering lane A must never write into lane B's own capo file"
pass "two concurrently-open decisions in different lanes cannot cross-resolve each other"

# 10. Resolving an already-closed key refuses.
IFS=$(printf '\t') read -r home state capo_home capo_state <<EOF
$(new_fixture)
EOF
printf 'needs-decision [key=x]: pick an approach\n' > "$capo_state/w-1.status"
scan_pending "$state" >/dev/null
run_send "$home" "$state" "$TMP/first.log" mycapo --resolve-key mycapo-w-1 "first answer" >/dev/null \
  || fail "the first resolve-key send should deliver"
cs_write_meta "$capo_state/w-1.meta" "workspace=cw1" "pane=cw1:p1" "kind=ship"
run_send "$capo_home" "$capo_state" "$TMP/capofirst.log" w-1 --resolve-key x "first answer" >/dev/null \
  || fail "the capo's own first local resolve should succeed"
scan_pending "$state" >/dev/null
if run_send "$home" "$state" "$TMP/second.log" mycapo --resolve-key mycapo-w-1 "second answer" >/dev/null 2>&1; then
  fail "resolving an already-closed key must refuse, not deliver a second time"
fi
[ ! -s "$TMP/second.log" ] || fail "a refused already-closed resolve must deliver nothing"
pass "resolving an already-closed parent-facing key refuses"

pass "cs-capo-decision-escalation end-to-end and negative-path coverage"
