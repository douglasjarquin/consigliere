#!/usr/bin/env bash
# Behavior (portable): bounded recovery re-wakes durable messages once and refuses stale endpoints.
set -u
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
cs_message_pending_create "$STATE" "$message_id" "$message_id" child root question 1700000000 || fail "pending setup"

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
  || fail "relaunch pending setup"
output=$("$ROOT/bin/cs-recover.sh") || fail "recover should repair a relaunched parent route"
printf '%s\n' "$output" | grep -F "re-woke message=$relaunch_id" >/dev/null \
  || fail "relaunch recovery did not re-wake the durable message"
grep -F 'endpoint_generation=root-generation-2' "$STATE/inbox/$relaunch_id.route" >/dev/null \
  || fail "relaunch recovery did not update the route to the current generation"
CS_TASK_ID=root "$ROOT/bin/cs-inbox.sh" --ack "$relaunch_id" --reply accepted >/dev/null \
  || fail "the repaired route could not be acknowledged by the relaunched parent"
[ -f "$STATE/inbox/$relaunch_id.ack" ] || fail "relaunch message acknowledgement is missing"
pass "recovery repairs a verified route after the parent endpoint relaunches"

export CS_FAKE_PANE_CWD="$TMP/wrong-worktree"
if "$ROOT/bin/cs-recover.sh" >"$TMP/wrong.out" 2>"$TMP/wrong.err"; then
  fail "recover accepted a wrong-home endpoint"
fi
grep -F 'another home' "$TMP/wrong.err" >/dev/null || fail "wrong-home recovery refusal lacked its reason"
[ "$(grep -Fc "CONSIGLIERE_WAKE v1 message=$message_id" "$TMP/prompts")" = 2 ] || fail "wrong-home recovery sent a wake"
pass "recovery refuses a stale or wrong-home endpoint without guessing"

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

pass "bounded durable-message recovery contract"
