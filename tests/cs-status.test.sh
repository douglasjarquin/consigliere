#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-message-lib.sh
. "$ROOT/bin/cs-message-lib.sh"

TMP=$(cs_test_tmproot cs-status)
HOME_DIR="$TMP/home"
STATE="$HOME_DIR/state"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/data" "$STATE/inbox" "$STATE/pending"
printf '%s\n' 'task_id=root' 'kind=capo' 'home='"$HOME_DIR" > "$STATE/root.meta"
printf '%s\n' 'task_id=child' 'kind=ship' 'home='"$HOME_DIR" \
  'parent_task_id=root' 'parent_home='"$HOME_DIR" 'parent_state='"$STATE" \
  'parent_pane=unknown' 'parent_generation=root-generation' \
  'endpoint_generation=child-generation' > "$STATE/child.meta"

message_id=status-question-0000000000000001
cs_message_publish "$STATE/inbox" \
  "schema=cs-message.v1" "message_id=$message_id" "correlation_id=$message_id" \
  "sequence=1" "kind=question" "from_task_id=child" "to_task_id=root" \
  "from_home=$HOME_DIR" "from_endpoint_generation=child-generation" \
  "to_endpoint_generation=root-generation" "summary=needs answer" "artifact=" \
  "commit_sha=" "pull_request=" "created_at=1700000000" || fail "message setup"
cs_message_pending_create "$STATE" "$message_id" "$message_id" child root question 1700000000 \
  "$HOME_DIR" child-generation root-generation \
  || fail "pending setup"
printf '%s\n' 'schema=invalid' > "$STATE/inbox/malformed.msg"

output=$(CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" "$ROOT/bin/cs-status.sh") \
  || fail "status should render open state"
assert_contains "$output" 'open_messages=1' "status must count open messages"
assert_contains "$output" 'pending_obligations=1' "status must count pending obligations"
assert_contains "$output" 'malformed_messages=1' "status must surface malformed messages"
assert_contains "$output" "next=CS_HOME=$HOME_DIR bin/cs-recover.sh" "status must give the recovery action"
assert_contains "$output" "next=CS_TASK_ID=root bin/cs-inbox.sh" "status must give the inbox action"
pass "status renders bounded message obligations and exact next actions"

printf '%s\n' 'not-a-closure' > "$STATE/pending/$message_id.closed"
output=$(CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" "$ROOT/bin/cs-status.sh") \
  || fail "status should render malformed closure state"
assert_contains "$output" 'pending_obligations=1' "status must not trust a malformed closure marker"
pass "status counts malformed closure markers as unresolved obligations"

rm -f "$STATE/pending/$message_id.pending"
output=$(CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" CS_RECOVER_MAX_RECORDS=1 \
  "$ROOT/bin/cs-recover.sh" 2>&1) && fail "recovery must refuse malformed records"
assert_contains "$output" 'malformed' "recovery refusal must name the malformed record"
assert_contains "$output" 'next=inspect' "recovery refusal must give its next action"
pass "recover reports a bounded refusal and exact next action"
