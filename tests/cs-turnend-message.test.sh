#!/usr/bin/env bash
# Behavior: a settled child without semantic result evidence gets one recovery message.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/cs-message-lib.sh
. "$ROOT/bin/cs-message-lib.sh"

TMP=$(cs_test_tmproot cs-turnend-message)
HOME_DIR="$TMP/home"
STATE="$HOME_DIR/state"
PARENT_STATE="$TMP/state"
FAKEBIN="$TMP/fakebin"
mkdir -p "$HOME_DIR/bin" "$HOME_DIR/config" "$HOME_DIR/data" "$STATE" \
  "$PARENT_STATE/inbox" "$FAKEBIN"
printf '# fixture\n' > "$HOME_DIR/AGENTS.md"
printf 'capo\n' > "$HOME_DIR/.cs-capo-home"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pane get")
    printf '%s\n' '{"result":{"pane":{"cwd":"'"$CS_FAKE_PARENT_HOME"'"}}}'
    ;;
  "agent prompt")
    printf '%s\n' "${4:-}" >> "$CS_FAKE_PROMPTS"
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

cs_write_meta "$STATE/root.meta" \
  task_id=root kind=capo home="$TMP" worktree="$TMP" pane=w1:p1 \
  endpoint_generation=root-generation
cs_write_meta "$STATE/child.meta" \
  task_id=child kind=ship home="$HOME_DIR" worktree="$HOME_DIR" pane=w2:p2 \
  endpoint_generation=child-generation parent_task_id=root \
  parent_home="$TMP" parent_state="$PARENT_STATE" parent_pane=w1:p1 \
  parent_generation=root-generation
printf '%s\n' 'done: terminal buffer only' > "$STATE/child.status"
touch "$STATE/.last-monitor-beat"
printf '%s\n' 'w1:p1' > "$STATE/.home-pane"

export PATH="$FAKEBIN:$PATH"
export CS_HOME="$HOME_DIR" CS_ROOT_OVERRIDE="$HOME_DIR"
export CS_STATE_OVERRIDE="$STATE" CS_DATA_OVERRIDE="$HOME_DIR/data"
export CS_TASK_ID=child CS_FAKE_PARENT_HOME="$TMP" CS_FAKE_PROMPTS="$TMP/prompts"
export CS_HERDR_SESSION=test CS_MONITOR_BIN="$HOME_DIR/no-such-monitor"
export HERDR_PANE_ID=w1:p1 CS_GUARD_GRACE=999
recovery_id=$(cs_message_recovery_id child child-generation) || fail "recovery id derivation"

set +e
output=$(printf '%s\n' '{"stop_hook_active":false}' | "$ROOT/bin/cs-turnend-guard.sh" 2>&1)
rc=$?
set -e
expect_code 0 "$rc" "settled-child backstop must not block the turn end"
message="$PARENT_STATE/inbox/$recovery_id.msg"
assert_present "$message" "settled child must publish one recovery message"
assert_line "$(cat "$message")" '^kind=failed$' "recovery message must be classified as failed"
assert_line "$(cat "$message")" '^summary=settled child has no semantic result; inspect its durable work$' \
  "recovery reason must be bounded and actionable"
assert_present "$STATE/.message-recovery-$recovery_id" "recovery marker must make the backstop idempotent"
assert_line "$(cat "$TMP/prompts")" "CONSIGLIERE_WAKE v1 message=$recovery_id" \
  "recovery must wake the immediate parent"

set +e
printf '%s\n' '{"stop_hook_active":false}' | "$ROOT/bin/cs-turnend-guard.sh" >/dev/null 2>&1
second_rc=$?
set -e
expect_code 0 "$second_rc" "a repeated turn end must remain permitted"
[ "$(wc -l < "$TMP/prompts" | tr -d ' ')" = 1 ] || fail "recovery backstop must not prompt twice"
[ "$(find "$PARENT_STATE/inbox" -name '*.msg' -type f | wc -l | tr -d ' ')" = 1 ] || \
  fail "recovery backstop must not create a second message"
pass "cs-turnend-guard: recovers a settled child without semantic reporting exactly once"
