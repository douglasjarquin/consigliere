#!/usr/bin/env bash
# Behavior: cs-send.sh from-consigliere marker and pending-reply integration
# for capo targets, pinned hermetically with a fake herdr (no real agent):
#   1. A kind=capo task target gets marker + corr prepended, and a durable
#      parent pending-reply record is created before delivery and marked
#      delivered after the confirmed submit.
#   2. Ship targets stay unmarked and create no records.
#   3. Explicit pane targets stay unmarked.
#   4. The --key path never marks and never creates a record.
#   5. Re-sending already-correlated text is idempotent for that open corr.
#   6. CS_PENDING_REPLY_EXISTING_CORR guards a recovery re-send.
#   7. An unconfirmed submit exits non-zero and leaves the durable
#      delivery-attempt marker for the watcher to reconcile.
#   8. The marker constant is the label plus terminal-safe U+2063.
set -u
# shellcheck source=tests/capo-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/capo-helpers.sh"
# shellcheck source=bin/cs-marker-lib.sh
. "$ROOT/bin/cs-marker-lib.sh"
# shellcheck source=bin/cs-pending-reply-lib.sh
. "$ROOT/bin/cs-pending-reply-lib.sh"

TMP=$(cs_test_tmproot cs-send-capo)
mkdir -p "$TMP"

SEND="$ROOT/bin/cs-send.sh"
FAKEBIN=$(cs_fakebin "$TMP")
cs_capo_fake_herdr "$FAKEBIN"
export PATH="$FAKEBIN:$PATH"
export CS_SEND_SETTLE=0
export FAKE_AGENT=codex FAKE_AGENT_STATUS=idle FAKE_PANE_EXISTS=1

setup_home() {  # <name> -> home with empty state/
  local home="$TMP/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

run_send() {  # <home> <log> -- <cs-send args...>
  local home=$1 log=$2; shift 2
  : > "$log"
  env CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" CS_SEND_LOG="$log" CS_SEND_SETTLE=0 \
    "$SEND" "$@" >/dev/null 2>&1
}

# 1. capo target: marker + corr + record
home=$(setup_home capo)
cs_write_meta "$home/state/domain.meta" \
  "workspace=w1" "pane=w1:p1" "kind=capo" "mode=capo" "home=$home/capo-home"
log="$TMP/send1.log"
run_send "$home" "$log" domain "audit the build" || fail "capo send should succeed"
got=$(cat "$log")
case "$got" in
  "$CS_FROMCONS_MARK"corr=[a-f0-9]*) : ;;
  *) fail "capo send: literal text should be marker+corr+text"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
esac
case "$got" in
  *"audit the build") : ;;
  *) fail "capo send lost the request body: $got" ;;
esac
corr=$(cs_pending_reply_extract_corr "$got")
[ "${#corr}" -eq 16 ] || fail "corr id should be 16 hex chars, got '$corr'"
rec=$(cs_pending_reply_path "$home/state" "$corr")
[ -f "$rec" ] || fail "marked capo send must create a parent pending-reply record"
[ "$(cs_pending_reply_get "$rec" phase)" = awaiting_report ] || fail "phase should be awaiting_report"
[ -n "$(cs_pending_reply_get "$rec" delivered_epoch)" ] || fail "delivered_epoch set after confirmed send"
[ "$(cs_pending_reply_get "$rec" task_id)" = domain ] || fail "task_id must match the capo id"
pass "cs-send: a kind=capo target gets marker + corr and a durable pending record"

# 2. ship target: unmarked, no record
home=$(setup_home ship)
cs_write_meta "$home/state/build.meta" \
  "workspace=w2" "pane=w2:p2" "kind=ship" "mode=no-mistakes" "yolo=off"
log="$TMP/send2.log"
run_send "$home" "$log" build "fix the test" || fail "ship send should succeed"
[ "$(cat "$log")" = "fix the test" ] || fail "ship send must stay unmarked: $(cat "$log")"
[ ! -d "$home/state/pending-replies" ] \
  || [ -z "$(ls "$home/state/pending-replies" 2>/dev/null)" ] \
  || fail "ship send must create no pending-reply records"
pass "cs-send: a kind=ship target is sent unmarked with no expectation"

# 3. explicit pane target: unmarked even with matching capo meta
home=$(setup_home explicit)
cs_write_meta "$home/state/domain.meta" \
  "workspace=w3" "pane=w3:p3" "kind=capo" "mode=capo" "home=$home/capo-home"
log="$TMP/send3.log"
run_send "$home" "$log" "w3:p3" "ping" || fail "explicit pane send should succeed"
[ "$(cat "$log")" = "ping" ] || fail "explicit pane send must stay unmarked: $(cat "$log")"
pass "cs-send: explicit pane targets stay unmarked"

# 4. --key path: no marker, no record
home=$(setup_home key)
cs_write_meta "$home/state/domain.meta" \
  "workspace=w4" "pane=w4:p4" "kind=capo" "mode=capo" "home=$home/capo-home"
log="$TMP/send4.log"
run_send "$home" "$log" domain --key Escape || fail "--key send should succeed"
[ ! -s "$log" ] || fail "--key path must type no literal text"
[ ! -d "$home/state/pending-replies" ] || fail "--key path must create no pending-reply records"
pass "cs-send: the --key path carries no marker and no expectation"

# 5. re-send of already-correlated text is idempotent for the open corr
home=$(setup_home resend)
cs_write_meta "$home/state/domain.meta" \
  "workspace=w5" "pane=w5:p5" "kind=capo" "mode=capo" "home=$home/capo-home"
log="$TMP/send5.log"
run_send "$home" "$log" domain "first request" || fail "first marked send failed"
corr=$(cs_pending_reply_extract_corr "$(cat "$log")")
run_send "$home" "$log" domain "${CS_FROMCONS_MARK}corr=${corr} already routed" \
  || fail "already-correlated re-send failed"
got=$(cat "$log")
[ "$got" = "${CS_FROMCONS_MARK}corr=${corr} already routed" ] \
  || fail "re-send altered already-correlated content"$'\n'"$(printf '%s' "$got" | od -An -c)"
[ "$(find "$home/state/pending-replies" -type f ! -name '.*' | wc -l | tr -d ' ')" = 1 ] \
  || fail "an open corr re-send must not create a second expectation"
pass "cs-send: an open corr is reused exactly once, never double-prefixed"

# 6. CS_PENDING_REPLY_EXISTING_CORR guards a recovery re-send
log="$TMP/send6.log"
: > "$log"
env CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" CS_SEND_LOG="$log" CS_SEND_SETTLE=0 \
  CS_PENDING_REPLY_EXISTING_CORR="$corr" \
  "$SEND" domain "REPOST REQUIRED please" >/dev/null 2>&1 || fail "existing-corr re-send failed"
assert_contains "$(cat "$log")" "corr=$corr" "existing corr is embedded on the re-send"
[ "$(find "$home/state/pending-replies" -type f ! -name '.*' | wc -l | tr -d ' ')" = 1 ] \
  || fail "CS_PENDING_REPLY_EXISTING_CORR must not create a second expectation"
pass "cs-send: CS_PENDING_REPLY_EXISTING_CORR re-sends under the open record"

# 7. unconfirmed submit fails loudly and leaves the durable attempt marker
home=$(setup_home unconfirmed)
cs_write_meta "$home/state/domain.meta" \
  "workspace=w7" "pane=w7:p7" "kind=capo" "mode=capo" "home=$home/capo-home"
log="$TMP/send7.log"
: > "$log"
if env CS_HOME="$home" CS_STATE_OVERRIDE="$home/state" CS_SEND_LOG="$log" CS_SEND_SETTLE=0 \
  CS_SEND_RETRIES=0 FAKE_AGENT_WAIT_FAIL=1 \
  "$SEND" domain "will not confirm" >/dev/null 2>&1; then
  fail "an unconfirmed submit must exit non-zero"
fi
rec=$(find "$home/state/pending-replies" -type f ! -name '.*' | head -1)
[ -n "$rec" ] || fail "the pending record must survive an unconfirmed submit"
corr=$(cs_pending_reply_get "$rec" corr_id)
marker=$(cs_pending_reply_delivery_confirmation_path "$home/state" "$corr")
[ -f "$marker" ] || fail "the durable delivery-attempt marker must remain for the watcher"
grep -q '^attempted=' "$marker" || fail "the marker must record an attempted (unconfirmed) delivery"
[ -z "$(cs_pending_reply_get "$rec" delivered_epoch)" ] \
  || fail "an unconfirmed submit must not be promoted to delivered"
pass "cs-send: an unconfirmed submit leaves the attempt marker for reconciliation"

# 8. marker constant: label + terminal-safe U+2063; boss text never matches
separator=$(printf '\342\201\243')
[ "$CS_FROMCONS_MARK" = "[cs-from-consigliere]$separator" ] \
  || fail "marker is not the expected label + U+2063 sequence"
cs_message_from_consigliere "${CS_FROMCONS_MARK}do the work" || fail "detector should recognize a marked message"
cs_message_from_consigliere "do the work" && fail "direct boss input must remain unmarked"
cs_message_from_consigliere "[cs-from-consigliere]do the work" && fail "label without U+2063 must not match"
pass "cs-send: the marker is the label plus terminal-safe U+2063"

pass "cs-send capo marker and pending-reply integration"
