#!/usr/bin/env bash
# Behavior: parent-owned capo pending-reply guards (bin/cs-pending-reply-lib.sh).
#
# Reproduces the missed-report experience: a marked request is delivered, the
# capo turn completes, and no correlated parent report arrives. The parent
# must notice without scraping conversation, send exactly one recovery repost
# once the grace has elapsed (the overdue gate), and escalate once - durably -
# if that recovery turn is also missed.
set -u
# shellcheck source=tests/capo-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/capo-helpers.sh"
# shellcheck source=bin/cs-marker-lib.sh
. "$ROOT/bin/cs-marker-lib.sh"
# shellcheck source=bin/cs-pending-reply-lib.sh
. "$ROOT/bin/cs-pending-reply-lib.sh"

TMP=$(cs_test_tmproot cs-pending-reply)
mkdir -p "$TMP"

export CS_PENDING_REPLY_GRACE_SECS=0

setup_parent() {  # <name> -> home
  local home="$TMP/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

phase_of() {  # <state> <corr>
  cs_pending_reply_get "$(cs_pending_reply_path "$1" "$2")" phase
}

# 1. normal correlated reply resolves once (idempotent), via=status
home=$(setup_parent resolve-once); state="$home/state"
export CS_PENDING_REPLY_NOW=1000
corr=$(cs_pending_reply_create "$home" "$state" capo1 "audit the ledger")
cs_pending_reply_mark_delivered "$state" "$corr"
cs_pending_reply_try_resolve "$state" "$corr" && fail "missing status must not resolve"
printf 'done [corr=%s]: ledger clean\n' "$corr" > "$state/capo1.status"
cs_pending_reply_try_resolve "$state" "$corr" || fail "correlated status should resolve"
[ "$(phase_of "$state" "$corr")" = resolved ] || fail "phase should be resolved"
cs_pending_reply_try_resolve "$state" "$corr" || fail "second resolve must stay successful"
rec=$(cs_pending_reply_path "$state" "$corr")
[ "$(cs_pending_reply_get "$rec" resolved_via)" = status ] || fail "resolved_via should be status"
pass "normal correlated reply resolves once (idempotent)"

# 2. transport success is never reply success
home=$(setup_parent transport); state="$home/state"
export CS_PENDING_REPLY_NOW=2000
corr=$(cs_pending_reply_create "$home" "$state" capo1 "ping")
cs_pending_reply_mark_delivered "$state" "$corr" || fail "mark delivered failed"
[ "$(phase_of "$state" "$corr")" = awaiting_report ] || fail "delivery must leave awaiting_report"
cs_pending_reply_try_resolve "$state" "$corr" && fail "delivery alone must not resolve"
pass "transport success cannot masquerade as reply success"

# 3. completed turn with no report triggers exactly one recovery
home=$(setup_parent one-recovery); state="$home/state"
hook_log="$TMP/recovery-hook.log"; : > "$hook_log"
# Invoked indirectly through CS_PENDING_REPLY_SEND_HOOK.
# shellcheck disable=SC2329
recovery_hook() { printf '%s\t%s\n' "$1" "$2" >> "$hook_log"; }
export CS_PENDING_REPLY_SEND_HOOK='recovery_hook'
export CS_PENDING_REPLY_NOW=3000
corr=$(cs_pending_reply_create "$home" "$state" capo1 "status of phase 7")
cs_pending_reply_mark_delivered "$state" "$corr"
cs_pending_reply_observe_busy "$state" "$corr" busy
cs_pending_reply_observe_busy "$state" "$corr" idle
cs_pending_reply_send_recovery "$state" "$corr" || fail "recovery should send after completed turn + grace"
[ "$(phase_of "$state" "$corr")" = recovery_sent ] || fail "phase should be recovery_sent"
cs_pending_reply_send_recovery "$state" "$corr" 2>/dev/null && fail "second recovery must refuse"
[ "$(wc -l < "$hook_log" | tr -d ' ')" = 1 ] || fail "expected exactly one recovery send"
assert_contains "$(cat "$hook_log")" "corr=$corr" "recovery message carries the original corr"
assert_contains "$(cat "$hook_log")" "REPOST REQUIRED" "recovery message asks for a repost"
pass "completed turn with no report triggers exactly one recovery"

# 4. recovery reply resolves the original expectation
printf 'done [corr=%s]: phase 7 is done (reposted)\n' "$corr" > "$state/capo1.status"
cs_pending_reply_try_resolve "$state" "$corr" || fail "recovery reply should resolve original"
[ "$(phase_of "$state" "$corr")" = resolved ] || fail "expected resolved after recovery reply"
pass "recovery reply resolves the original expectation"

# 5. overdue gate: recovery refuses before grace elapses, fires after
home=$(setup_parent overdue); state="$home/state"
export CS_PENDING_REPLY_GRACE_SECS=100
export CS_PENDING_REPLY_NOW=1000
corr=$(cs_pending_reply_create "$home" "$state" capo1 "slow domain question")
cs_pending_reply_mark_delivered "$state" "$corr"
cs_pending_reply_mark_turn_completed "$state" "$corr" request
export CS_PENDING_REPLY_NOW=1050
cs_pending_reply_send_recovery "$state" "$corr" 2>/dev/null && fail "recovery must wait out the grace"
[ "$(phase_of "$state" "$corr")" = awaiting_report ] || fail "pre-grace record stays awaiting_report"
export CS_PENDING_REPLY_NOW=1101
cs_pending_reply_send_recovery "$state" "$corr" || fail "recovery should fire once overdue"
[ "$(phase_of "$state" "$corr")" = recovery_sent ] || fail "overdue recovery should be recorded"
export CS_PENDING_REPLY_GRACE_SECS=0
pass "recovery honors the grace window (overdue gating)"

# 6. second missed turn escalates once and remains durable
home=$(setup_parent escalate); state="$home/state"
export CS_PENDING_REPLY_NOW=4000
corr=$(cs_pending_reply_create "$home" "$state" capo1 "why is phase 7 stuck")
cs_pending_reply_mark_delivered "$state" "$corr"
cs_pending_reply_mark_turn_completed "$state" "$corr" request
cs_pending_reply_send_recovery "$state" "$corr" || fail "recovery send failed"
cs_pending_reply_mark_turn_completed "$state" "$corr" recovery
cs_pending_reply_maybe_escalate "$state" "$corr" || fail "escalation should fire"
[ "$(phase_of "$state" "$corr")" = escalated ] || fail "phase should be escalated"
status_line=$(tail -1 "$state/capo1.status")
# The escalation opens a keyed decision under this library's per-request key, so
# one request's escalation neither masks nor is masked by an unrelated decision
# on the same task, and only its own close can clear it.
case "$status_line" in
  "blocked [key=pending-reply-$corr]: pending-reply-missed: "*"pending-reply-id=$corr"*) : ;;
  *) fail "parent status should carry one keyed blocked missed-report line: $status_line" ;;
esac
cs_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null || true
[ "$(phase_of "$state" "$corr")" = escalated ] || fail "phase must stay escalated"
[ "$(grep -Fc "pending-reply-id=$corr" "$state/capo1.status")" = 1 ] \
  || fail "missed recovery should publish exactly one escalation"
rec=$(cs_pending_reply_path "$state" "$corr")
[ -f "$rec" ] || fail "escalated record must remain on disk"
printf 'working: unrelated churn\n' >> "$state/capo1.status"
cs_pending_reply_try_resolve "$state" "$corr" && fail "unrelated status must not resolve"
[ "$(phase_of "$state" "$corr")" = escalated ] || fail "must remain escalated after unrelated status"
pass "second missed turn escalates once and remains durable"

# 7. unrelated events and stale correlation ids cannot resolve
home=$(setup_parent stale-corr); state="$home/state"
export CS_PENDING_REPLY_NOW=5000
corr=$(cs_pending_reply_create "$home" "$state" capo1 "need answer")
cs_pending_reply_mark_delivered "$state" "$corr"
other=$(cs_pending_reply_new_id)
printf 'done [corr=%s]: wrong token\n' "$other" > "$state/capo1.status"
cs_pending_reply_try_resolve "$state" "$corr" && fail "stale/wrong corr must not resolve"
printf 'done: finished without corr\n' >> "$state/capo1.status"
cs_pending_reply_try_resolve "$state" "$corr" && fail "status without corr must not resolve"
[ "$(phase_of "$state" "$corr")" = awaiting_report ] || fail "phase must stay awaiting_report"
pass "unrelated events and stale correlation ids cannot resolve"

# 8. restart/compaction preserves the expectation and exact parent destination
home=$(setup_parent restart); state="$home/state"
export CS_PENDING_REPLY_NOW=6000
corr=$(cs_pending_reply_create "$home" "$state" capo1 "survive restart")
cs_pending_reply_mark_delivered "$state" "$corr"
rec=$(cs_pending_reply_path "$state" "$corr")
parent_status=$(cs_pending_reply_get "$rec" parent_status)
# shellcheck source=bin/cs-pending-reply-lib.sh
. "$ROOT/bin/cs-pending-reply-lib.sh"
[ -f "$rec" ] || fail "record must survive restart"
[ "$(cs_pending_reply_get "$rec" parent_status)" = "$parent_status" ] || fail "parent_status stable"
[ "$(phase_of "$state" "$corr")" = awaiting_report ] || fail "phase preserved"
case "$parent_status" in
  /*.status) : ;;
  *) fail "parent_status should be an absolute status path, got $parent_status" ;;
esac
pass "restart preserves expectation and exact parent destination"

# 9. wrong-home reports are detected but never silently acknowledge
home=$(setup_parent wrong-home); state="$home/state"
capo_home="$TMP/capo-home-$RANDOM"
mkdir -p "$capo_home/state"
export CS_PENDING_REPLY_NOW=7000
corr=$(cs_pending_reply_create "$home" "$state" capo1 "report to parent")
cs_pending_reply_mark_delivered "$state" "$corr"
printf 'done [corr=%s]: stranded in self-home\n' "$corr" > "$capo_home/state/capo1.status"
cs_pending_reply_detect_wrong_home "$state" "$corr" "$capo_home" || fail "wrong-home detect should succeed"
rec=$(cs_pending_reply_path "$state" "$corr")
[ "$(cs_pending_reply_get "$rec" wrong_home_hits)" = 1 ] || fail "first sighting counts once"
cs_pending_reply_detect_wrong_home "$state" "$corr" "$capo_home" || fail "repeat detect should succeed"
[ "$(cs_pending_reply_get "$rec" wrong_home_hits)" = 1 ] || fail "unchanged history stays one hit"
printf 'done [corr=%s]: second stranded report\n' "$corr" >> "$capo_home/state/capo1.status"
cs_pending_reply_detect_wrong_home "$state" "$corr" "$capo_home" || fail "new sighting detect should succeed"
[ "$(cs_pending_reply_get "$rec" wrong_home_hits)" = 2 ] || fail "distinct reports each count once"
[ "$(phase_of "$state" "$corr")" = awaiting_report ] || fail "wrong-home must not acknowledge"
cs_pending_reply_try_resolve "$state" "$corr" && fail "wrong-home status must not resolve"
pass "wrong-home reports are detected but do not silently acknowledge"

# 10. failed transport discards undelivered expectation only
home=$(setup_parent discard); state="$home/state"
export CS_PENDING_REPLY_NOW=8000
corr=$(cs_pending_reply_create "$home" "$state" capo1 "never lands")
cs_pending_reply_discard_undelivered "$state" "$corr" || fail "discard undelivered failed"
[ ! -f "$(cs_pending_reply_path "$state" "$corr")" ] || fail "undelivered record should be removed"
corr=$(cs_pending_reply_create "$home" "$state" capo1 "landed")
cs_pending_reply_mark_delivered "$state" "$corr"
cs_pending_reply_discard_undelivered "$state" "$corr" 2>/dev/null && fail "delivered record must not be discarded"
[ -f "$(cs_pending_reply_path "$state" "$corr")" ] || fail "delivered record must remain"
pass "failed transport discards undelivered expectation only"

# 11. delivery-attempt marker reconciles: confirmed commits, orphaned attempt
#     escalates as delivery-unknown, and a late report resolves it
home=$(setup_parent delivery-marker); state="$home/state"
export CS_PENDING_REPLY_NOW=9000
export CS_PENDING_REPLY_GRACE_SECS=100
corr=$(cs_pending_reply_create "$home" "$state" capo1 "attempted delivery")
export CS_PENDING_REPLY_GRACE_SECS=0
cs_pending_reply_prepare_delivery "$state" "$corr" || fail "prepare delivery failed"
marker=$(cs_pending_reply_delivery_confirmation_path "$state" "$corr")
[ -f "$marker" ] || fail "attempt marker should persist"
cs_pending_reply_tick_one "$state" "$corr" unknown || fail "tick over attempt failed"
[ "$(phase_of "$state" "$corr")" = awaiting_report ] || fail "attempt within grace stays pending"
export CS_PENDING_REPLY_NOW=9010
rec=$(cs_pending_reply_path "$state" "$corr")
cs_pending_reply_set "$rec" grace_secs 5 || fail "grace fixture failed"
cs_pending_reply_tick_one "$state" "$corr" unknown || fail "overdue attempt tick failed"
[ "$(phase_of "$state" "$corr")" = escalated ] || fail "orphaned attempt should escalate delivery-unknown"
grep -Fq "pending-reply-delivery-unknown:" "$state/capo1.status" \
  || fail "delivery uncertainty should use its distinct escalation"
printf 'done [corr=%s]: late report proves delivery\n' "$corr" >> "$state/capo1.status"
cs_pending_reply_tick "$state" || fail "tick over late report failed"
[ "$(phase_of "$state" "$corr")" = resolved ] || fail "late report should resolve delivery-unknown"
pass "delivery-attempt marker reconciles durably"

# 12. tick end-to-end: miss -> one recovery -> escalate -> durable forever
home=$(setup_parent tick-e2e); state="$home/state"
capo_home="$home/capo"; mkdir -p "$capo_home/state"
hook_log="$TMP/tick-hook.log"; : > "$hook_log"
# Invoked indirectly through CS_PENDING_REPLY_SEND_HOOK.
# shellcheck disable=SC2329
recovery_hook() { printf 'recovered\n' >> "$hook_log"; }
export CS_PENDING_REPLY_SEND_HOOK='recovery_hook'
export CS_PENDING_REPLY_NOW=10000
corr=$(cs_pending_reply_create "$home" "$state" capo1 "e2e miss")
cs_pending_reply_mark_delivered "$state" "$corr"
cs_write_meta "$state/capo1.meta" "workspace=w1" "pane=w1:p1" "kind=capo" "home=$capo_home"
cs_pending_reply_tick_one "$state" "$corr" busy "$capo_home"
cs_pending_reply_tick_one "$state" "$corr" idle "$capo_home"
[ "$(phase_of "$state" "$corr")" = recovery_sent ] || fail "tick should send recovery after idle+grace"
[ -s "$hook_log" ] || fail "recovery should have been sent via tick"
cs_pending_reply_tick_one "$state" "$corr" busy "$capo_home"
cs_pending_reply_tick_one "$state" "$corr" idle "$capo_home"
[ "$(phase_of "$state" "$corr")" = escalated ] || fail "tick should escalate after second miss"
export CS_PENDING_REPLY_NOW=999999
cs_pending_reply_tick_one "$state" "$corr" idle "$capo_home"
[ -f "$(cs_pending_reply_path "$state" "$corr")" ] \
  || fail "expiration must never silently erase an unresolved reply"
[ "$(phase_of "$state" "$corr")" = escalated ] || fail "must stay escalated"
pass "tick end-to-end: miss -> one recovery -> escalate -> durable"

# 13. the watcher tick reads busy state through the herdr layer, not chat:
#     document-pointer resolve plus endpoint-observation override
home=$(setup_parent doc-pointer); state="$home/state"
export CS_PENDING_REPLY_NOW=11000
corr=$(cs_pending_reply_create "$home" "$state" capo1 "deep audit")
cs_pending_reply_mark_delivered "$state" "$corr"
printf 'done [corr=%s]: see data/capo1/report.md\n' "$corr" > "$state/capo1.status"
cs_write_meta "$state/capo1.meta" "workspace=w1" "pane=w1:p1" "kind=capo" "home=$home/capo"
# Stub the endpoint read (no real herdr in this suite); the correlated report
# must resolve regardless of what the endpoint observation says.
cs_pending_reply_endpoint_observation() { printf 'unknown'; }
cs_pending_reply_tick "$state" || fail "tick failed"
[ "$(phase_of "$state" "$corr")" = resolved ] || fail "document pointer should resolve via tick"
[ "$(cs_pending_reply_get "$(cs_pending_reply_path "$state" "$corr")" resolved_via)" = document ] \
  || fail "resolved_via should be document"
# shellcheck source=bin/cs-pending-reply-lib.sh
. "$ROOT/bin/cs-pending-reply-lib.sh"
pass "status-pointed document resolves through the watcher tick"

# 14. an escalation OPENS a durable keyed decision, and resolving the record
#     closes it. Reproduces the settled-request-keeps-escalating experience: the
#     capo answers, the record resolves, and without the close the escalation
#     stays in every later open-decisions fold forever.
home=$(setup_parent escalation-close); state="$home/state"
export CS_PENDING_REPLY_NOW=12000
corr=$(cs_pending_reply_create "$home" "$state" capo1 "why is the lane idle")
cs_pending_reply_mark_delivered "$state" "$corr"
cs_pending_reply_mark_turn_completed "$state" "$corr" request
cs_pending_reply_send_recovery "$state" "$corr" >/dev/null 2>&1 || true
cs_pending_reply_mark_turn_completed "$state" "$corr" recovery
cs_pending_reply_maybe_escalate "$state" "$corr" || fail "escalation should fire"
escalation_key="pending-reply-$corr"
assert_contains "$(status_open_decisions "$state/capo1.status")" "$escalation_key" \
  "the escalation must open a keyed decision in the fold"
printf 'done [corr=%s]: the lane was waiting on CI\n' "$corr" >> "$state/capo1.status"
cs_pending_reply_try_resolve "$state" "$corr" || fail "the correlated report should resolve"
assert_not_contains "$(status_open_decisions "$state/capo1.status")" "$escalation_key" \
  "a resolved escalation must leave the open-decisions fold"
rec=$(cs_pending_reply_path "$state" "$corr")
[ -n "$(cs_pending_reply_get "$rec" escalation_closed_epoch)" ] \
  || fail "the record must remember that its escalation was closed"
closes=$(grep -Fc "resolved [key=$escalation_key]" "$state/capo1.status")
cs_pending_reply_close_escalation "$state" "$corr" || fail "a repeat close should stay successful"
cs_pending_reply_tick "$state" || fail "tick over a closed escalation should succeed"
[ "$(grep -Fc "resolved [key=$escalation_key]" "$state/capo1.status")" = "$closes" ] \
  || fail "the escalation close must never double-close"
pass "a resolved pending-reply escalation closes its keyed decision exactly once"

# 15. the close never clears an unrelated decision that later took the same key:
#     an escalation whose own note is no longer what holds the key is left alone.
home=$(setup_parent escalation-takeover); state="$home/state"
export CS_PENDING_REPLY_NOW=13000
corr=$(cs_pending_reply_create "$home" "$state" capo1 "audit the ledger")
cs_pending_reply_mark_delivered "$state" "$corr"
cs_pending_reply_mark_turn_completed "$state" "$corr" request
cs_pending_reply_send_recovery "$state" "$corr" >/dev/null 2>&1 || true
cs_pending_reply_mark_turn_completed "$state" "$corr" recovery
cs_pending_reply_maybe_escalate "$state" "$corr" || fail "escalation should fire"
escalation_key="pending-reply-$corr"
# The library's own escalation is closed, then an unrelated writer takes the key
# over with a note this library never wrote.
{
  printf 'resolved [key=%s]: closed by hand\n' "$escalation_key"
  printf 'needs-decision [key=%s]: unrelated decision on the same key\n' "$escalation_key"
  printf 'done [corr=%s]: ledger clean\n' "$corr"
} >> "$state/capo1.status"
cs_pending_reply_try_resolve "$state" "$corr" || fail "the correlated report should resolve"
assert_contains "$(status_open_decisions "$state/capo1.status")" \
  "unrelated decision on the same key" \
  "the close must not clear an unrelated decision that took the key over"
pass "the escalation close never clears an unrelated decision holding the same key"

# 16. a NUL-bearing record is refused before any field is parsed. bash's read
#     drops NUL bytes and bash generations disagree on the result (3.2 truncates
#     at the NUL, 5.x splices the surrounding bytes), so a NUL-bearing
#     parent_home could resolve to a home the record's bytes never name
#     contiguously - and which home a recovery send wrote to would depend on the
#     interpreter. The whole record must fail closed instead.
home=$(setup_parent nul-record); state="$home/state"
wrong_home="$TMP/spliced-home-$RANDOM"
mkdir -p "$wrong_home/state"
export CS_PENDING_REPLY_NOW=14000
corr=$(cs_pending_reply_create "$home" "$state" capo1 "needs an answer")
cs_pending_reply_mark_delivered "$state" "$corr"
cs_pending_reply_mark_turn_completed "$state" "$corr" request
rec=$(cs_pending_reply_path "$state" "$corr")
[ -n "$(cs_pending_reply_get "$rec" parent_home)" ] || fail "the clean record must read back"
cs_pending_reply_record_intact "$rec" || fail "the clean record must be intact"
# Splice a NUL mid-path into the recorded parent_home: the surrounding bytes name
# the wrong home only once an interpreter drops the NUL and joins them.
spliced_head=${wrong_home%/*}
spliced_tail=${wrong_home##*/}
{
  LC_ALL=C tr -d '\0' < "$rec" | grep -v '^parent_home='
  printf 'parent_home=%s/' "$spliced_head"
  printf '\000'
  printf '%s\n' "$spliced_tail"
} > "$rec.spliced"
mv -f "$rec.spliced" "$rec"
cs_pending_reply_record_intact "$rec" && fail "a NUL-bearing record must not be intact"
[ -z "$(cs_pending_reply_get "$rec" parent_home)" ] \
  || fail "a NUL-bearing record must yield no parent_home"
[ -z "$(cs_pending_reply_get "$rec" phase)" ] \
  || fail "a NUL-bearing record must yield no field at all"
cs_pending_reply_set "$rec" phase resolved && fail "a NUL-bearing record must refuse a rewrite"
unset CS_PENDING_REPLY_SEND_HOOK
cs_pending_reply_send_recovery "$state" "$corr" 2>/dev/null \
  && fail "a NUL-bearing record must never drive a recovery send"
cs_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null \
  && fail "a NUL-bearing record must never escalate"
cs_pending_reply_try_resolve "$state" "$corr" 2>/dev/null \
  && fail "a NUL-bearing record must never resolve"
cs_pending_reply_tick "$state" || fail "the tick must survive a corrupt record"
[ ! -e "$wrong_home/state/capo1.status" ] \
  || fail "a NUL-bearing record must never write into the spliced-together home"
pass "a NUL-bearing pending-reply record is refused before field parsing"

pass "cs-pending-reply lifecycle guards"
