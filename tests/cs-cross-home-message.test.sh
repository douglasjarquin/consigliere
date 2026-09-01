#!/usr/bin/env bash
# Behavior (portable): cross-home messages use the recorded parent and sender Herdr sessions.
set -u
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cs-cross-home-message.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
CHILD_HOME="$TMP/child"
PARENT_HOME="$TMP/parent"
CHILD_STATE="$CHILD_HOME/state"
PARENT_STATE="$PARENT_HOME/state"
FAKEBIN="$TMP/fakebin"
LOG="$TMP/herdr.log"
mkdir -p "$CHILD_HOME/config" "$CHILD_HOME/data" "$CHILD_STATE" "$PARENT_HOME/config" \
  "$PARENT_HOME/data" "$PARENT_STATE/inbox" "$FAKEBIN"
printf '%s\n' parent-generation > "$PARENT_STATE/.home-endpoint-generation"
printf '%s\n' w-parent:p1 > "$PARENT_STATE/.home-pane"

cat > "$CHILD_STATE/child.meta" <<EOF
task_id=child
kind=ship
home=$CHILD_HOME
worktree=$CHILD_HOME
pane=w-child:p1
parent_task_id=root
parent_home=$PARENT_HOME
parent_state=$PARENT_STATE
parent_pane=w-parent:p1
parent_generation=parent-generation
parent_herdr_session=parent-session
endpoint_generation=child-generation
herdr_session=child-session
harness=codex
EOF

cat > "$FAKEBIN/herdr" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$LOG"
case "\${1:-} \${2:-}" in
  "pane get")
    case " \$* " in
      *"--session parent-session"*) cwd="$PARENT_HOME" ;;
      *"--session child-session"*) cwd="$CHILD_HOME" ;;
      *) exit 1 ;;
    esac
    printf '{"result":{"pane":{"cwd":"%s"}}}\\n' "\$cwd"
    ;;
  "agent get") printf '%s\\n' '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}' ;;
  "agent prompt") printf '%s\\n' '{"result":{"type":"agent_prompted"}}' ;;
  *) printf '%s\\n' '{}' ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

report=$(PATH="$FAKEBIN:$PATH" CS_HOME="$CHILD_HOME" CS_STATE_OVERRIDE="$CHILD_STATE" \
  CS_DATA_OVERRIDE="$CHILD_HOME/data" CS_TASK_ID=child CS_HERDR_SESSION=child-session \
  "$ROOT/bin/cs-report.sh" question "parent needs a decision") || fail "cross-home report"
message_id=$(printf '%s\n' "$report" | sed -n 's/^reported message=\([^ ]*\).*/\1/p')
[ -n "$message_id" ] || fail "cross-home report did not return its message id"
[ -f "$PARENT_STATE/inbox/$message_id.msg" ] || fail "cross-home report did not publish to the parent home"
grep -F -- '--session parent-session' "$LOG" >/dev/null || fail "report did not use the recorded parent Herdr session"
if grep -F -- '--session child-session' "$LOG" >/dev/null; then
  fail "report used the child session while waking the parent"
fi
pass "cross-home report wakes the recorded parent session"

recovered=$(PATH="$FAKEBIN:$PATH" CS_HOME="$CHILD_HOME" CS_STATE_OVERRIDE="$CHILD_STATE" \
  CS_DATA_OVERRIDE="$CHILD_HOME/data" CS_TASK_ID=child CS_HERDR_SESSION=child-session \
  "$ROOT/bin/cs-recover.sh") || fail "cross-home recovery"
printf '%s\n' "$recovered" | grep -F "re-woke message=$message_id task=root" >/dev/null \
  || fail "cross-home recovery did not re-wake the parent message"
pass "cross-home recovery selects the recorded parent session"

PATH="$FAKEBIN:$PATH" CS_HOME="$PARENT_HOME" CS_STATE_OVERRIDE="$PARENT_STATE" CS_TASK_ID=root \
  CS_HERDR_SESSION=parent-session "$ROOT/bin/cs-inbox.sh" --ack "$message_id" --reply "accepted" \
  >/dev/null || fail "cross-home reply"
[ -f "$CHILD_STATE/pending/$message_id.reply" ] || fail "cross-home reply was not written to the sender home"
[ -f "$CHILD_STATE/pending/$message_id.closed" ] || fail "cross-home reply did not close the sender obligation"
grep -F -- '--session child-session' "$LOG" >/dev/null || fail "reply did not use the recorded sender Herdr session"
pass "cross-home reply returns through the recorded sender session"

printf 'all cross-home message tests passed\n'
