#!/usr/bin/env bash
# Behavior (portable): a three-level semantic message round trip stays on immediate parent edges.
set -u
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cs-recursive-message.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
STATE="$HOME_DIR/state"
FAKEBIN="$TMP/fakebin"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/data" "$STATE/inbox" "$FAKEBIN"
mkdir -p "$HOME_DIR/reports"
printf '%s\n' 'mate evidence' > "$HOME_DIR/reports/mate.txt"

# shellcheck source=bin/cs-message-lib.sh
. "$ROOT/bin/cs-message-lib.sh"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pane get")
    printf '{"result":{"pane":{"cwd":"%s"}}}\n' "${CS_FAKE_PARENT_HOME:?}"
    ;;
  "agent prompt")
    printf '%s\n' "${4:-}" >> "${CS_FAKE_PROMPTS:?}"
    printf '{"result":{"type":"agent_prompted"}}\n'
    ;;
  "agent get")
    printf '%s\n' '{"result":{"agent":{"agent":"codex"}}}'
    ;;
  *) printf '{}\n' ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

cat > "$STATE/root.meta" <<EOF
task_id=root
kind=capo
home=$HOME_DIR
endpoint_generation=root-generation
EOF
cat > "$STATE/mate.meta" <<EOF
task_id=mate
kind=capo
home=$HOME_DIR
worktree=$HOME_DIR
pane=w-mate:p1
parent_task_id=root
parent_home=$HOME_DIR
parent_state=$STATE
parent_pane=w-root:p1
parent_generation=root-generation
endpoint_generation=mate-generation
harness=codex
EOF
cat > "$STATE/worker.meta" <<EOF
task_id=worker
kind=ship
home=$HOME_DIR
worktree=$HOME_DIR
pane=w-worker:p1
parent_task_id=mate
parent_home=$HOME_DIR
parent_state=$STATE
parent_pane=w-mate:p1
parent_generation=mate-generation
endpoint_generation=worker-generation
harness=codex
EOF

run_report() {
  local task=$1 kind=$2 summary=$3
  shift 3
  env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" \
    CS_DATA_OVERRIDE="$HOME_DIR/data" CS_TASK_ID="$task" CS_HERDR_SESSION=test \
    CS_FAKE_PARENT_HOME="$HOME_DIR" CS_FAKE_PROMPTS="$TMP/prompts" \
    "$ROOT/bin/cs-report.sh" "$kind" "$summary" "$@"
}

worker_report=$(run_report worker question "worker needs a local choice") || fail "worker report"
worker_id=$(printf '%s\n' "$worker_report" | sed -n 's/^reported message=\([^ ]*\).*/\1/p')
[ -n "$worker_id" ] || fail "worker report did not return a message id"
mate_view=$(env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" \
  CS_TASK_ID=mate "$ROOT/bin/cs-inbox.sh") || fail "mate inbox drain"
printf '%s\n' "$mate_view" | grep -F "message=$worker_id" >/dev/null || fail "mate did not receive the worker message"
printf '%s\n' "$mate_view" | grep -F 'from=worker' >/dev/null || fail "mate did not identify the worker sender"
if printf '%s\n' "$mate_view" | grep -F 'from=root' >/dev/null; then
  fail "mate inbox included an unrelated parent message"
fi
escalated=$(env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" \
  CS_TASK_ID=mate CS_FAKE_PARENT_HOME="$HOME_DIR" CS_FAKE_PROMPTS="$TMP/prompts" \
  "$ROOT/bin/cs-inbox.sh" --escalate "$worker_id" --summary "root decision required: choose the local option") \
  || fail "mate escalation"
transfer_id=$(printf '%s\n' "$escalated" | sed -n 's/^escalated message=[^ ]* transfer=\([^ ]*\).*/\1/p')
[ -n "$transfer_id" ] || fail "mate escalation did not return its transfer id"
[ -f "$STATE/inbox/$worker_id.ack" ] || fail "mate escalation did not acknowledge the child message"
[ -f "$STATE/pending/$worker_id.closed" ] || fail "mate escalation did not close the child obligation"
grep -F "CONSIGLIERE_WAKE v1 message=$transfer_id" "$TMP/prompts" >/dev/null || fail "escalation wake was not delivered to the root"
prompt_count=$(wc -l < "$TMP/prompts" | tr -d ' ')
repeat_escalation=$(env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" \
  CS_TASK_ID=mate CS_FAKE_PARENT_HOME="$HOME_DIR" CS_FAKE_PROMPTS="$TMP/prompts" \
  "$ROOT/bin/cs-inbox.sh" --escalate "$worker_id" --summary "root decision required: choose the local option") \
  || fail "duplicate mate escalation"
printf '%s\n' "$repeat_escalation" | grep -F "already escalated message=$worker_id transfer=$transfer_id" >/dev/null \
  || fail "duplicate escalation did not identify the existing transfer"
[ "$(wc -l < "$TMP/prompts" | tr -d ' ')" = "$prompt_count" ] || fail "duplicate escalation re-woke the root"
pass "the immediate parent transfers one compressed decision without forwarding the worker transcript"

env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" \
  CS_TASK_ID=root CS_FAKE_PARENT_HOME="$HOME_DIR" CS_FAKE_PROMPTS="$TMP/prompts" \
  "$ROOT/bin/cs-inbox.sh" --ack "$transfer_id" --reply "root approves the local option" >/dev/null \
  || fail "root answer"
[ -f "$STATE/inbox/$transfer_id.ack" ] || fail "root answer acknowledgement missing"
[ -f "$STATE/pending/$transfer_id.closed" ] || fail "root answer did not close mate obligation"
[ -f "$STATE/pending/$transfer_id.reply" ] || fail "root answer must have a durable reply record"
[ -f "$STATE/pending/$transfer_id.reply-delivered" ] || fail "root answer must have confirmed delivery state"
grep -F "CONSIGLIERE_REPLY v1 message=$transfer_id" "$TMP/prompts" >/dev/null || fail "root answer was not delivered to mate"

{
  printf '%s\n' 'previous_endpoint_generation=worker-generation'
  printf '%s\n' 'previous_endpoint_generation_at='"$(date +%s)"
  printf '%s\n' 'endpoint_generation=worker-generation-2'
} >> "$STATE/worker.meta"
env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" \
  CS_TASK_ID=mate CS_FAKE_PARENT_HOME="$HOME_DIR" CS_FAKE_PROMPTS="$TMP/prompts" \
  "$ROOT/bin/cs-inbox.sh" --ack "$worker_id" --reply "root approves the local option" >/dev/null \
  || fail "mate answer"
[ -f "$STATE/inbox/$worker_id.ack" ] || fail "mate answer acknowledgement missing"
[ -f "$STATE/pending/$worker_id.closed" ] || fail "mate answer did not close worker obligation"
grep -F "CONSIGLIERE_REPLY v1 message=$worker_id" "$TMP/prompts" >/dev/null || fail "mate answer was not delivered to worker"
worker_reply_count=$(grep -Fc "CONSIGLIERE_REPLY v1 message=$worker_id" "$TMP/prompts")
rm -f "$STATE/inbox/$worker_id.ack"
env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" \
  CS_TASK_ID=mate CS_FAKE_PARENT_HOME="$HOME_DIR" CS_FAKE_PROMPTS="$TMP/prompts" \
  "$ROOT/bin/cs-inbox.sh" --ack "$worker_id" --reply "root approves the local option" >/dev/null \
  || fail "retry after a lost acknowledgement"
[ "$(grep -Fc "CONSIGLIERE_REPLY v1 message=$worker_id" "$TMP/prompts")" = "$worker_reply_count" ] \
  || fail "retry after a lost acknowledgement duplicated the logical answer"
pass "the three-level answer returns through each independent edge"

mate_report=$(run_report mate result "mate resolved the worker choice" --artifact reports/mate.txt --correlation "$worker_id") || fail "mate result report"
mate_id=$(printf '%s\n' "$mate_report" | sed -n 's/^reported message=\([^ ]*\).*/\1/p')
[ -n "$mate_id" ] || fail "mate report did not return a message id"
root_view=$(env PATH="$FAKEBIN:$PATH" CS_HOME="$HOME_DIR" CS_STATE_OVERRIDE="$STATE" \
  CS_TASK_ID=root "$ROOT/bin/cs-inbox.sh") || fail "root inbox drain"
printf '%s\n' "$root_view" | grep -F "message=$mate_id" >/dev/null || fail "root did not receive the mate result"
printf '%s\n' "$root_view" | grep -F 'from=mate' >/dev/null || fail "root result was not attributed to the immediate parent"
printf '%s\n' "$root_view" | grep -F "summary=mate resolved the worker choice" >/dev/null || fail "root result summary was not preserved"
if printf '%s\n' "$root_view" | grep -F 'from=worker' >/dev/null; then
  fail "root received a raw grandchild message"
fi
grep -F "CONSIGLIERE_WAKE v1 message=$worker_id" "$TMP/prompts" >/dev/null || fail "worker wake was not delivered"
grep -F "CONSIGLIERE_WAKE v1 message=$mate_id" "$TMP/prompts" >/dev/null || fail "mate wake was not delivered"
pass "the root receives one compressed parent result and no raw grandchild traffic"

pass "three-level recursive message round trip"
