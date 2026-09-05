#!/usr/bin/env bash
# Behavior (portable): bounded recovery re-wakes durable messages once and refuses stale endpoints.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cs-recover.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
STATE="$HOME_DIR/state"
FAKEBIN="$TMP/fakebin"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/data" "$STATE/inbox" "$FAKEBIN"

# shellcheck source=bin/cs-message-lib.sh
. "$ROOT/bin/cs-message-lib.sh"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pane get")
    printf '{"result":{"pane":{"cwd":"%s"}}}\n' "${CS_FAKE_PANE_CWD:?}"
    ;;
  "agent prompt")
    printf '%s\n' "${4:-}" >> "${CS_FAKE_PROMPTS:?}"
    printf '{"result":{"type":"agent_prompted"}}\n'
    ;;
  "agent get")
    if [ "${CS_FAKE_AGENT_LIVE:-0}" = 1 ]; then
      printf '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}\n'
    else
      printf '{}\n'
    fi
    ;;
  *) printf '{}\n' ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

printf '%s\n' 'w-root:p1' > "$STATE/.home-pane"
printf '%s\n' 'root-generation' > "$STATE/.home-endpoint-generation"
cat > "$STATE/child.meta" <<EOF
task_id=child
kind=ship
home=$HOME_DIR
worktree=$HOME_DIR
pane=w-child:p1
parent_task_id=root
parent_home=$HOME_DIR
parent_state=$STATE
parent_pane=w-root:p1
parent_generation=root-generation
endpoint_generation=child-generation
harness=codex
EOF

message_id='message-recover-0000000000000001'
cs_message_publish "$STATE/inbox" \
  "schema=cs-message.v1" "message_id=$message_id" "correlation_id=$message_id" \
  "sequence=1" "kind=question" "from_task_id=child" "to_task_id=root" \
  "from_home=$HOME_DIR" "from_endpoint_generation=child-generation" \
  "to_endpoint_generation=root-generation" "summary=needs recovery" "artifact=" \
  "commit_sha=" "pull_request=" "created_at=1700000000" || fail "message setup"
cs_message_pending_create "$STATE" "$message_id" "$message_id" child root question 1700000000 \
  "$HOME_DIR" child-generation root-generation || fail "pending setup"

export PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" \
  CS_HERDR_SESSION=test CS_FAKE_PANE_CWD="$HOME_DIR" CS_FAKE_PROMPTS="$TMP/prompts" CS_FAKE_AGENT_LIVE=1
if output=$("$ROOT/bin/cs-recover.sh" 2>"$TMP/err"); then
  :
else
  fail "recover should re-wake a live durable message"
fi
printf '%s\n' "$output" | grep -F "re-woke message=$message_id" >/dev/null || fail "recover did not report the re-wake"
[ "$(grep -Fc "CONSIGLIERE_WAKE v1 message=$message_id" "$TMP/prompts")" = 1 ] || fail "recover did not deliver one bounded wake"
[ -f "$STATE/inbox/$message_id.route" ] || fail "recovery did not record the verified delivery route"
grep -F 'endpoint_generation=root-generation' "$STATE/inbox/$message_id.route" >/dev/null \
  || fail "initial recovery route recorded the wrong endpoint generation"
pass "recovery re-wakes an existing durable obligation once"

relaunch_id='message-recover-0000000000000002'
printf '%s\n' 'root-generation-2' > "$STATE/.home-endpoint-generation"
cs_message_publish "$STATE/inbox" \
  "schema=cs-message.v1" "message_id=$relaunch_id" "correlation_id=$relaunch_id" \
  "sequence=1" "kind=question" "from_task_id=child" "to_task_id=root" \
  "from_home=$HOME_DIR" "from_endpoint_generation=child-generation" \
  "to_endpoint_generation=root-generation" "summary=survives relaunch" "artifact=" \
  "commit_sha=" "pull_request=" "created_at=1700000000" || fail "relaunch message setup"
cs_message_pending_create "$STATE" "$relaunch_id" "$relaunch_id" child root question 1700000000 \
  "$HOME_DIR" child-generation root-generation \
  || fail "relaunch pending setup"
output=$("$ROOT/bin/cs-recover.sh") || fail "recover should repair a relaunched parent route"
printf '%s\n' "$output" | grep -F "re-woke message=$relaunch_id" >/dev/null \
  || fail "relaunch recovery did not re-wake the durable message"
grep -F 'endpoint_generation=root-generation-2' "$STATE/inbox/$relaunch_id.route" >/dev/null \
  || fail "relaunch recovery did not update the route to the current generation"
CS_TASK_ID=root "$ROOT/bin/cs-inbox.sh" --ack "$relaunch_id" --reply accepted >/dev/null \
  || fail "the repaired route could not be acknowledged by the relaunched parent"
[ -f "$STATE/inbox/$relaunch_id.ack" ] || fail "relaunch message acknowledgement is missing"
cs_message_validate_ack "$STATE/inbox/$relaunch_id.ack" "$relaunch_id" \
  || fail "relaunch acknowledgement is malformed"
pass "recovery repairs a verified route after the parent endpoint relaunches"

export CS_FAKE_PANE_CWD="$TMP/wrong-worktree"
if "$ROOT/bin/cs-recover.sh" >"$TMP/wrong.out" 2>"$TMP/wrong.err"; then
  fail "recover accepted a wrong-home endpoint"
fi
grep -F 'another home' "$TMP/wrong.err" >/dev/null || fail "wrong-home recovery refusal lacked its reason"
[ "$(grep -Fc "CONSIGLIERE_WAKE v1 message=$message_id" "$TMP/prompts")" = 2 ] || fail "wrong-home recovery sent a wake"
pass "recovery refuses a stale or wrong-home endpoint without guessing"

bad_ack_id='message-recover-bad-0000000000000001'
cs_message_publish "$STATE/inbox" \
  "schema=cs-message.v1" "message_id=$bad_ack_id" "correlation_id=$bad_ack_id" \
  "sequence=1" "kind=question" "from_task_id=child" "to_task_id=root" \
  "from_home=$HOME_DIR" "from_endpoint_generation=child-generation" \
  "to_endpoint_generation=root-generation-2" "summary=bad acknowledgement" "artifact=" \
  "commit_sha=" "pull_request=" "created_at=1700000000" || fail "bad acknowledgement message setup"
cs_message_pending_create "$STATE" "$bad_ack_id" "$bad_ack_id" child root question 1700000000 \
  "$HOME_DIR" child-generation root-generation-2 \
  || fail "bad acknowledgement pending setup"
printf '%s\n' 'schema=cs-message.v1' 'message_id=another-message' 'acked_at=1700000000' \
  > "$STATE/inbox/$bad_ack_id.ack"
if "$ROOT/bin/cs-recover.sh" >"$TMP/bad-ack.out" 2>"$TMP/bad-ack.err"; then
  fail "recovery must refuse an acknowledgement naming another message"
fi
grep -F 'malformed acknowledgement' "$TMP/bad-ack.err" >/dev/null \
  || fail "malformed acknowledgement refusal must name the record"
pass "recovery refuses a mismatched acknowledgement instead of suppressing work"
rm -f "$STATE/inbox/$bad_ack_id.msg" "$STATE/inbox/$bad_ack_id.ack" "$STATE/pending/$bad_ack_id.pending"

mismatch_id='message-recover-generation-mismatch-000000000001'
cs_message_publish "$STATE/inbox" \
  "schema=cs-message.v1" "message_id=$mismatch_id" "correlation_id=$mismatch_id" \
  "sequence=1" "kind=question" "from_task_id=child" "to_task_id=root" \
  "from_home=$HOME_DIR" "from_endpoint_generation=child-generation" \
  "to_endpoint_generation=root-generation-2" "summary=generation mismatch" "artifact=" \
  "commit_sha=" "pull_request=" "created_at=1700000000" || fail "generation mismatch message setup"
cs_message_pending_create "$STATE" "$mismatch_id" "$mismatch_id" child root question 1700000000 \
  "$HOME_DIR" stale-child-generation root-generation-2 || fail "generation mismatch pending setup"
if "$ROOT/bin/cs-recover.sh" >"$TMP/generation-mismatch.out" 2>"$TMP/generation-mismatch.err"; then
  fail "recovery accepted a pending obligation with mismatched endpoint generation"
fi
grep -F 'does not match its inbox identity' "$TMP/generation-mismatch.err" >/dev/null \
  || fail "generation mismatch refusal lacked its identity reason"
rm -f "$STATE/inbox/$mismatch_id.msg" "$STATE/pending/$mismatch_id.pending"
pass "recovery refuses a pending obligation with mismatched endpoint generation"

destination_mismatch_id='message-recover-destination-generation-mismatch-0001'
cs_message_publish "$STATE/inbox" \
  "schema=cs-message.v1" "message_id=$destination_mismatch_id" "correlation_id=$destination_mismatch_id" \
  "sequence=1" "kind=question" "from_task_id=child" "to_task_id=root" \
  "from_home=$HOME_DIR" "from_endpoint_generation=child-generation" \
  "to_endpoint_generation=root-generation-2" "summary=destination generation mismatch" "artifact=" \
  "commit_sha=" "pull_request=" "created_at=1700000000" || fail "destination mismatch message setup"
cs_message_pending_create "$STATE" "$destination_mismatch_id" "$destination_mismatch_id" child root question 1700000000 \
  "$HOME_DIR" child-generation root-generation || fail "destination mismatch pending setup"
if "$ROOT/bin/cs-recover.sh" >"$TMP/destination-generation-mismatch.out" 2>"$TMP/destination-generation-mismatch.err"; then
  fail "recovery accepted a pending obligation with mismatched destination endpoint generation"
fi
grep -F 'does not match its inbox identity' "$TMP/destination-generation-mismatch.err" >/dev/null \
  || fail "destination generation mismatch refusal lacked its identity reason"
rm -f "$STATE/inbox/$destination_mismatch_id.msg" "$STATE/pending/$destination_mismatch_id.pending"
pass "recovery refuses a pending obligation with mismatched destination endpoint generation"

printf '%s\n' 'done: child stopped before semantic report' > "$STATE/child.status"
export CS_FAKE_PANE_CWD="$HOME_DIR" CS_FAKE_AGENT_LIVE=1
output=$("$ROOT"/bin/cs-recover.sh) || fail "recover should request a report from a live settled child"
printf '%s\n' "$output" | grep -F 'requested-report task=child' >/dev/null \
  || fail "recover did not report the one-time child report request"
grep -F 'CONSIGLIERE_REPORT_REQUIRED v1 task=child' "$TMP/prompts" >/dev/null \
  || fail "recover did not prompt the live child for a semantic report"
prompt_count=$(grep -Fc 'CONSIGLIERE_REPORT_REQUIRED v1 task=child' "$TMP/prompts")
output=$("$ROOT"/bin/cs-recover.sh) || fail "repeated recovery should remain bounded"
[ "$(grep -Fc 'CONSIGLIERE_REPORT_REQUIRED v1 task=child' "$TMP/prompts")" = "$prompt_count" ] \
  || fail "repeated recovery prompted the settled child twice"
pass "recovery requests one missing report from a live settled child"

ordinary_child_id='message-recover-ordinary-child-0000000001'
cat > "$STATE/ordinary-child.meta" <<EOF
task_id=ordinary-child
kind=ship
pane=w-oc:p1
parent_task_id=root
parent_home=$HOME_DIR
parent_state=$STATE
parent_pane=w-root:p1
parent_generation=root-generation-2
endpoint_generation=oc-generation
harness=codex
EOF
cs_message_publish "$STATE/inbox" \
  "schema=cs-message.v1" "message_id=$ordinary_child_id" "correlation_id=$ordinary_child_id" \
  "sequence=1" "kind=failed" "from_task_id=ordinary-child" "to_task_id=root" \
  "from_home=$HOME_DIR" "from_endpoint_generation=oc-generation" \
  "to_endpoint_generation=root-generation-2" "summary=ordinary child needs recovery" "artifact=" \
  "commit_sha=" "pull_request=" "created_at=1700000000" || fail "ordinary-child message setup"
output=$("$ROOT/bin/cs-recover.sh" 2>"$TMP/ordinary-child.err") \
  || fail "recover should re-wake an ordinary (non-capo) child's durable message"
printf '%s\n' "$output" | grep -F "re-woke message=$ordinary_child_id" >/dev/null \
  || fail "recover did not re-wake the ordinary child's message"
pass "recovery re-wakes an ordinary (non-capo) child's durable message"

output=$("$ROOT/bin/cs-recover.sh" 2>"$TMP/ordinary-child-second.err") \
  || fail "a second recovery of the same unchanged ordinary-child-sourced message should still succeed"
printf '%s\n' "$output" | grep -F "already-delivered message=$ordinary_child_id" >/dev/null \
  || fail "second recovery did not report the ordinary-child-sourced message as already delivered"
[ "$(grep -Fc "CONSIGLIERE_WAKE v1 message=$ordinary_child_id" "$TMP/prompts")" = 1 ] \
  || fail "second recovery re-sent a wake for an unchanged, already-delivered ordinary-child-sourced message"
pass "recovery delivers an ordinary (non-capo) child's message to root at most once per unchanged endpoint generation"

cat > "$STATE/forged-child.meta" <<EOF
task_id=forged-child
kind=ship
pane=w-oc:p1
parent_task_id=root
parent_home=$HOME_DIR
parent_state=$STATE
parent_pane=w-root:p1
parent_generation=root-generation-2
endpoint_generation=fc-generation
harness=codex
home=$TMP/not-the-real-home
EOF
forged_id='message-recover-forged-child-0000000001'
cs_message_publish "$STATE/inbox" \
  "schema=cs-message.v1" "message_id=$forged_id" "correlation_id=$forged_id" \
  "sequence=1" "kind=failed" "from_task_id=forged-child" "to_task_id=root" \
  "from_home=$HOME_DIR" "from_endpoint_generation=fc-generation" \
  "to_endpoint_generation=root-generation-2" "summary=forged sender home" "artifact=" \
  "commit_sha=" "pull_request=" "created_at=1700000000" || fail "forged-child message setup"
if "$ROOT/bin/cs-recover.sh" >"$TMP/forged-child.out" 2>"$TMP/forged-child.err"; then
  fail "recovery accepted a message whose explicit sender home does not match its claimed origin"
fi
grep -F 'invalid sender lineage or generation' "$TMP/forged-child.err" >/dev/null \
  || fail "forged sender-home refusal lacked its lineage reason"
rm -f "$STATE/inbox/$forged_id.msg" "$STATE/forged-child.meta"
pass "recovery still refuses an explicit sender home that does not match its claimed origin"

already_reported_id='message-recover-already-reported-0000000001'
cat > "$STATE/already-reported-child.meta" <<EOF
task_id=already-reported-child
kind=ship
pane=w-arc:p1
parent_task_id=root
parent_home=$HOME_DIR
parent_state=$STATE
parent_pane=w-root:p1
parent_generation=root-generation-2
endpoint_generation=arc-generation
harness=codex
EOF
printf '%s\n' 'done: finished' > "$STATE/already-reported-child.status"
cs_message_publish "$STATE/inbox" \
  "schema=cs-message.v1" "message_id=$already_reported_id" "correlation_id=$already_reported_id" \
  "sequence=1" "kind=result" "from_task_id=already-reported-child" "to_task_id=root" \
  "from_home=$HOME_DIR" "from_endpoint_generation=arc-generation" \
  "to_endpoint_generation=root-generation-2" "summary=already reported normally" "artifact=" \
  "commit_sha=" "pull_request=" "created_at=1700000000" || fail "already-reported-child message setup"
cs_message_ack "$STATE/inbox" "$already_reported_id" || fail "already-reported-child ack setup"
recovery_marker=$(cs_message_recovery_id already-reported-child arc-generation) \
  || fail "could not derive the already-reported-child recovery id"
output=$("$ROOT/bin/cs-recover.sh") || fail "recover should not fail reconciling an already-reported child"
printf '%s\n' "$output" | grep -F 'requested-report task=already-reported-child' >/dev/null \
  && fail "recover re-escalated a child that already reported normally"
[ -e "$STATE/.report-requested-$recovery_marker" ] \
  && fail "recover marked a report as requested for a child that already reported normally"
pass "recovery does not re-escalate an ordinary child that already reported normally"

storm_id='message-recover-storm-0000000000000001'
cs_message_publish "$STATE/inbox" \
  "schema=cs-message.v1" "message_id=$storm_id" "correlation_id=$storm_id" \
  "sequence=1" "kind=question" "from_task_id=child" "to_task_id=root" \
  "from_home=$HOME_DIR" "from_endpoint_generation=child-generation" \
  "to_endpoint_generation=root-generation-2" "summary=must not flood root" "artifact=" \
  "commit_sha=" "pull_request=" "created_at=1700000000" || fail "storm message setup"
cs_message_pending_create "$STATE" "$storm_id" "$storm_id" child root question 1700000000 \
  "$HOME_DIR" child-generation root-generation-2 || fail "storm pending setup"
output=$("$ROOT/bin/cs-recover.sh") || fail "first recovery of the storm message should succeed"
printf '%s\n' "$output" | grep -F "re-woke message=$storm_id" >/dev/null \
  || fail "first recovery did not deliver the storm message"
[ "$(grep -Fc "CONSIGLIERE_WAKE v1 message=$storm_id" "$TMP/prompts")" = 1 ] \
  || fail "first recovery did not send exactly one wake"
output=$("$ROOT/bin/cs-recover.sh") || fail "second recovery with nothing changed should still succeed"
printf '%s\n' "$output" | grep -F "already-delivered message=$storm_id" >/dev/null \
  || fail "second recovery did not report the message as already delivered"
[ "$(grep -Fc "CONSIGLIERE_WAKE v1 message=$storm_id" "$TMP/prompts")" = 1 ] \
  || fail "second recovery re-sent a wake for an unchanged, already-delivered message (the redelivery storm regression)"
[ ! -f "$STATE/inbox/$storm_id.ack" ] \
  || fail "the message must remain durably unacked - the fix nudges root once, it never acks on root's behalf"
pass "recovery delivers a root-directed message at most once per unchanged endpoint generation, never a redelivery storm"

cat > "$STATE/mid-child.meta" <<EOF
task_id=mid-child
kind=ship
pane=w-mid:p1
worktree=$HOME_DIR
parent_task_id=root
parent_home=$HOME_DIR
parent_state=$STATE
parent_pane=w-root:p1
parent_generation=root-generation-2
endpoint_generation=mid-generation
harness=codex
EOF
cat > "$STATE/grandchild.meta" <<EOF
task_id=grandchild
kind=ship
home=$HOME_DIR
worktree=$HOME_DIR
pane=w-gc:p1
parent_task_id=mid-child
parent_home=$HOME_DIR
parent_state=$STATE
parent_pane=w-mid:p1
parent_generation=mid-generation
endpoint_generation=gc-generation
harness=codex
EOF
child_recipient_id='message-recover-child-recipient-0000000001'
cs_message_publish "$STATE/inbox" \
  "schema=cs-message.v1" "message_id=$child_recipient_id" "correlation_id=$child_recipient_id" \
  "sequence=1" "kind=question" "from_task_id=grandchild" "to_task_id=mid-child" \
  "from_home=$HOME_DIR" "from_endpoint_generation=gc-generation" \
  "to_endpoint_generation=mid-generation" "summary=child-to-child delivery must not storm" "artifact=" \
  "commit_sha=" "pull_request=" "created_at=1700000000" || fail "child-recipient message setup"
cs_message_pending_create "$STATE" "$child_recipient_id" "$child_recipient_id" grandchild mid-child question 1700000000 \
  "$HOME_DIR" gc-generation mid-generation || fail "child-recipient pending setup"
output=$("$ROOT/bin/cs-recover.sh") || fail "first recovery of the child-recipient message should succeed"
printf '%s\n' "$output" | grep -F "re-woke message=$child_recipient_id" >/dev/null \
  || fail "first recovery did not deliver the child-recipient message"
[ "$(grep -Fc "CONSIGLIERE_WAKE v1 message=$child_recipient_id" "$TMP/prompts")" = 1 ] \
  || fail "first recovery of the child-recipient message did not send exactly one wake"
output=$("$ROOT/bin/cs-recover.sh") || fail "second recovery of the unchanged child-recipient message should still succeed"
printf '%s\n' "$output" | grep -F "already-delivered message=$child_recipient_id" >/dev/null \
  || fail "second recovery did not report the child-recipient message as already delivered"
[ "$(grep -Fc "CONSIGLIERE_WAKE v1 message=$child_recipient_id" "$TMP/prompts")" = 1 ] \
  || fail "second recovery re-sent a wake for an unchanged, already-delivered child-recipient message (wake_message must be as bounded as wake_root_message)"
pass "recovery delivers a non-root (child) recipient's message at most once per unchanged endpoint generation"

pass "bounded durable-message recovery contract"
