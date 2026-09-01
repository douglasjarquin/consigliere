#!/usr/bin/env bash
set -u
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MESSAGE_LIB="$ROOT/bin/cs-message-lib.sh"
REPORT="$ROOT/bin/cs-report.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cs-message.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
STATE="$HOME_DIR/state"
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
mkdir -p "$HOME_DIR/data/child" "$HOME_DIR/reports" "$STATE" "$HOME_DIR/config" "$STATE/inbox"
printf '%s\n' 'verified result' > "$HOME_DIR/reports/result.md"

if [ ! -f "$MESSAGE_LIB" ] || [ ! -x "$REPORT" ]; then
  fail "the durable message library and report command must exist"
fi

# shellcheck source=bin/cs-message-lib.sh
. "$MESSAGE_LIB"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "agent prompt")
    printf '%s\n' "${4:-}" >> "$CS_FAKE_MESSAGE_PROMPTS"
    printf '%s\n' '{"result":{"type":"agent_prompted"}}'
    ;;
  "pane get")
    printf '%s\n' '{"result":{"pane":{"cwd":"'"$CS_FAKE_MESSAGE_PARENT_HOME"'"}}}'
    ;;
  "agent get")
    printf '%s\n' '{"result":{"agent":{"agent":"codex"}}}'
    ;;
  *) printf '%s\n' '{}';;
esac
SH
chmod +x "$FAKEBIN/herdr"

write_meta() {
  local task=$1
  cat > "$STATE/$task.meta" <<EOF
task_id=$task
kind=ship
home=$HOME_DIR
pane=w-child:p1
parent_task_id=parent
parent_home=$HOME_DIR
parent_state=$STATE
parent_pane=w1:p1
parent_generation=parent-generation-1
endpoint_generation=child-generation-1
harness=codex
EOF
}
write_meta child

export PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE"
export CS_DATA_OVERRIDE="$HOME_DIR/data" CS_TASK_ID=child
export CS_FAKE_MESSAGE_PROMPTS="$TMP/prompts"
export CS_FAKE_MESSAGE_PARENT_HOME="$HOME_DIR"
export CS_HERDR_SESSION=test

valid_message=(
  "schema=cs-message.v1"
  "message_id=message-0000000000000001"
  "correlation_id=correlation-0000000000000001"
  "sequence=1"
  "kind=result"
  "from_task_id=child"
  "to_task_id=parent"
  "from_home=$HOME_DIR"
  "from_endpoint_generation=child-generation-1"
  "to_endpoint_generation=parent-generation-1"
  "summary=verified result"
  "artifact=reports/result.md"
  "commit_sha=0123456789abcdef0123456789abcdef01234567"
  "pull_request="
  "created_at=1700000000"
)

cs_message_publish "$STATE/inbox" "${valid_message[@]}" || fail "valid message should publish"
record="$STATE/inbox/message-0000000000000001.msg"
[ -f "$record" ] || fail "valid message record missing"
cs_message_validate_file "$record" || fail "published message should validate"
[ ! -e "$STATE/inbox/.message-0000000000000001.msg.tmp" ] || fail "staging file must not remain"
pass "valid message is atomically published and validates"

if env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" \
  CS_DATA_OVERRIDE="$HOME_DIR/data" CS_TASK_ID=child CS_HERDR_SESSION=test \
  CS_FAKE_MESSAGE_PROMPTS="$CS_FAKE_MESSAGE_PROMPTS" \
  "$REPORT" result "missing evidence" --message-id message-no-evidence >/dev/null 2>&1; then
  fail "a result without artifact, commit, or pull request evidence must be refused"
fi
[ ! -e "$STATE/inbox/message-no-evidence.msg" ] || fail "evidence-free result was published"
pass "evidence-free result reports are refused before publication"

cs_message_publish "$STATE/inbox" "${valid_message[@]}" || fail "duplicate publication should be idempotent"
[ "$(find "$STATE/inbox" -name '*.msg' -type f | wc -l | tr -d ' ')" = 1 ] || fail "duplicate publication created another record"
pass "duplicate message publication is idempotent"

conflict=("${valid_message[@]}")
conflict[10]='summary=conflicting result'
if cs_message_publish "$STATE/inbox" "${conflict[@]}" >/dev/null 2>&1; then
  fail "conflicting duplicate must be refused"
fi
[ "$(grep -Fc 'summary=verified result' "$record")" = 1 ] || fail "conflicting duplicate changed the record"
pass "conflicting duplicate is refused without mutation"

oversized=("${valid_message[@]}")
oversized[10]="summary=$(printf 'x%.0s' $(seq 1 2000))"
if cs_message_publish "$STATE/inbox" "${oversized[@]}" >/dev/null 2>&1; then
  fail "oversized message must be refused"
fi
pass "oversized message is refused"

printf '%s\n' 'schema=invalid' > "$STATE/inbox/malformed.msg"
if cs_message_validate_file "$STATE/inbox/malformed.msg" >/dev/null 2>&1; then
  fail "malformed message must be refused"
fi
pass "malformed message is refused"

if env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" \
  CS_DATA_OVERRIDE="$HOME_DIR/data" CS_TASK_ID=child CS_HERDR_SESSION=test \
  CS_FAKE_MESSAGE_PROMPTS="$CS_FAKE_MESSAGE_PROMPTS" \
  "$REPORT" result "verified result" --artifact reports/result.md \
  --commit 0123456789abcdef0123456789abcdef01234567 >/dev/null; then
  :
else
  fail "cs-report should publish and wake the exact parent"
fi
report_record=$(find "$STATE/inbox" -name '*.msg' -type f | sort | tail -1)
cs_message_validate_file "$report_record" || fail "cs-report record should validate"
grep -F 'to_task_id=parent' "$report_record" >/dev/null || fail "report must target the immediate parent"
grep -F 'CONSIGLIERE_WAKE v1 message=' "$TMP/prompts" >/dev/null || fail "report must ring the parent with a bounded wake reference"
pass "cs-report publishes a verified parent message before its doorbell"

question_report=$(env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" \
  CS_DATA_OVERRIDE="$HOME_DIR/data" CS_TASK_ID=child CS_HERDR_SESSION=test \
  CS_FAKE_MESSAGE_PROMPTS="$CS_FAKE_MESSAGE_PROMPTS" \
  "$REPORT" question "choose the local option") || fail "question report should publish"
question_id=$(printf '%s\n' "$question_report" | sed -n 's/^reported message=\([^ ]*\).*/\1/p')
[ -n "$question_id" ] || fail "question report did not return a message id"
[ -f "$STATE/pending/$question_id.pending" ] || fail "question report did not create a pending obligation before delivery"
pass "response-required reports create a durable pending obligation"

retry_id=message-retry-0000000000000001
env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" \
  CS_DATA_OVERRIDE="$HOME_DIR/data" CS_TASK_ID=child CS_HERDR_SESSION=test \
  CS_FAKE_MESSAGE_PROMPTS="$CS_FAKE_MESSAGE_PROMPTS" \
  "$REPORT" result "retryable result" --artifact reports/result.md --message-id "$retry_id" >/dev/null || fail "first explicit-id report"
env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" \
  CS_DATA_OVERRIDE="$HOME_DIR/data" CS_TASK_ID=child CS_HERDR_SESSION=test \
  CS_FAKE_MESSAGE_PROMPTS="$CS_FAKE_MESSAGE_PROMPTS" \
  "$REPORT" result "retryable result" --artifact reports/result.md --message-id "$retry_id" >/dev/null || fail "same-id report retry"
[ "$(find "$STATE/inbox" -name "$retry_id.msg" -type f | wc -l | tr -d ' ')" = 1 ] || fail "same-id retry created more than one message record"
[ "$(grep -Fc "CONSIGLIERE_WAKE v1 message=$retry_id" "$CS_FAKE_MESSAGE_PROMPTS")" = 2 ] || fail "same-id retry did not re-ring the same message"
if env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" \
  CS_DATA_OVERRIDE="$HOME_DIR/data" CS_TASK_ID=child CS_HERDR_SESSION=test \
  CS_FAKE_MESSAGE_PROMPTS="$CS_FAKE_MESSAGE_PROMPTS" \
  "$REPORT" result "changed retry semantics" --message-id "$retry_id" >/dev/null 2>&1; then
  fail "same-id retry with changed semantics must be refused"
fi
grep -F 'summary=retryable result' "$STATE/inbox/$retry_id.msg" >/dev/null || fail "conflicting retry mutated the durable message"
pass "same-id report retry preserves one logical message and repeats only the doorbell"

export CS_FAKE_MESSAGE_PARENT_HOME="$TMP/missing-parent"
if env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" \
  CS_DATA_OVERRIDE="$HOME_DIR/data" CS_TASK_ID=child CS_HERDR_SESSION=test \
  CS_FAKE_MESSAGE_PROMPTS="$CS_FAKE_MESSAGE_PROMPTS" \
  "$REPORT" blocked "parent unavailable" >/dev/null 2>&1; then
  fail "an unavailable parent must not receive a wake"
fi
[ "$(find "$STATE/inbox" -name '*.msg' -type f | wc -l | tr -d ' ')" = 6 ] || fail "unavailable parent report was not retained"
pass "report remains durable when the parent endpoint is unavailable"
export CS_FAKE_MESSAGE_PARENT_HOME="$HOME_DIR"

cs_message_ack "$STATE/inbox" "message-0000000000000001" || fail "message acknowledgement should publish"
[ -f "$STATE/inbox/message-0000000000000001.ack" ] || fail "message acknowledgement missing"
cs_message_ack "$STATE/inbox" "message-0000000000000001" || fail "duplicate acknowledgement should be idempotent"
pass "message acknowledgement is separate and idempotent"

pass "generic parent/child message contract"
