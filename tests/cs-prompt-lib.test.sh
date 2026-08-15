#!/usr/bin/env bash
# tests/cs-prompt-lib.test.sh - cs_prompt_guarded's post-guard submit-and-confirm
# path (bin/cs-prompt-lib.sh), specifically the native `agent prompt --wait`
# collapse in bin/cs-herdr-lib.sh's cs_herdr_agent_prompt_confirmed.
#
# The three guards ahead of the prompt attempt (pane exists, busy state,
# composer state) are covered by cs-composer-lib.sh's and cs-herdr-lib.sh's own
# tests and by tests/cs-afk-start.test.sh, tests/cs-afk-return.test.sh, and
# tests/cs-activate.test.sh's end-to-end scenarios; this file stubs them to a
# fixed pass so only the changed submit-confirm behavior is under test.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/cs-herdr-lib.sh
. "$ROOT/bin/cs-herdr-lib.sh"

# Stub the three pre-prompt guards to a fixed pass; this file is about what
# happens after them.
cs_herdr_pane_exists() { return 0; }
cs_herdr_agent_busy_state() { printf 'idle\n'; }
cs_composer_state() { printf 'empty\n'; }

# shellcheck source=bin/cs-prompt-lib.sh
. "$ROOT/bin/cs-prompt-lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-prompt-lib)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

# fake herdr's `agent prompt` reply is driven by CS_FAKE_PROMPT_MODE:
#   confirmed - success, exit 0 (the agent left its pre-submit state)
#   stalled   - agent_prompt_stalled error, exit 1
#   rejected  - agent_not_found error, exit 1
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "agent prompt")
    case "${CS_FAKE_PROMPT_MODE:-confirmed}" in
      confirmed)
        echo '{"result":{"type":"agent_prompt_confirmed"}}'
        exit 0 ;;
      stalled)
        echo '{"error":{"code":"agent_prompt_stalled","message":"no state change observed"}}' >&2
        exit 1 ;;
      rejected)
        echo '{"error":{"code":"agent_not_found","message":"agent target not found"}}' >&2
        exit 1 ;;
    esac
    ;;
  "notification show")
    printf '<%s>\n' "$@" > "${CS_FAKE_NOTIFICATION_LOG:?}"
    printf '%s\n' "$$" > "${CS_FAKE_NOTIFICATION_PID:?}"
    case "${CS_FAKE_NOTIFICATION_MODE:-success}" in
      success) exit 0 ;;
      failure) exit 17 ;;
      timeout)
        child=
        trap 'if [ -n "${child:-}" ]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi; exit 143' TERM INT
        sleep 10 & child=$!
        wait "$child"
        ;;
    esac
    ;;
  "status --json")
    printf '{"server":{"protocol":19,"socket":""},"client":{"protocol":19}}\n'
    exit 0 ;;
esac
exit 1
SH
chmod +x "$FAKEBIN/herdr"

NOTIFICATION_LOG="$TMP_ROOT/notification.log"
NOTIFICATION_PID="$TMP_ROOT/notification.pid"
WEDGE_CONFIG="$TMP_ROOT/wedge-config"
mkdir -p "$WEDGE_CONFIG"
printf 'herdr\n' > "$WEDGE_CONFIG/wedge-alarm.conf"

wedge_log() {
  printf '%s\n' "$1"
}

run_wedge_from_config() {
  local mode=$1 timeout=$2
  PATH="$FAKEBIN:$PATH" \
    CS_CONFIG_OVERRIDE="$WEDGE_CONFIG" \
    CS_WEDGE_ALARM_CHANNEL='' \
    CS_WEDGE_ALARM_EXEC='' \
    CS_FAKE_NOTIFICATION_LOG="$NOTIFICATION_LOG" \
    CS_FAKE_NOTIFICATION_PID="$NOTIFICATION_PID" \
    CS_FAKE_NOTIFICATION_MODE="$mode" \
    CS_WEDGE_ALARM_TIMEOUT_SECS="$timeout" \
    cs_wedge_alarm_notify wedge_log 'S4 wedge alarm' 'SECRET_WEDGE_SUMMARY'
}

run_guarded() {
  PATH="$FAKEBIN:$PATH" CS_FAKE_PROMPT_MODE="$1" cs_prompt_guarded p1 'digest text' cat 2>&1
}

out=$(run_guarded confirmed); rc=$?
[ "$rc" -eq 0 ] || fail "confirmed prompt should return 0, got $rc ($out)"
pass "a confirmed prompt (herdr success) returns 0 with no log line"

out=$(run_guarded stalled); rc=$?
[ "$rc" -eq 1 ] || fail "stalled prompt should return 1, got $rc"
case "$out" in
  *"prompt unconfirmed"*) : ;;
  *) fail "stalled prompt (agent_prompt_stalled) should log 'prompt unconfirmed', got: $out" ;;
esac
pass "agent_prompt_stalled is read as unconfirmed, not a hard rejection"

out=$(run_guarded rejected); rc=$?
[ "$rc" -eq 1 ] || fail "rejected prompt should return 1, got $rc"
case "$out" in
  *"prompt failed"*) : ;;
  *) fail "rejected prompt (agent_not_found) should log 'prompt failed', got: $out" ;;
esac
pass "agent_not_found is read as a hard rejection, not a stall"

rm -f "$NOTIFICATION_LOG" "$NOTIFICATION_PID"
out=$(run_wedge_from_config success 10); rc=$?
expect_code 0 "$rc" "a successful Herdr notification must not fail the wedge seam"
expected=$'<notification>\n<show>\n<S4 wedge alarm>\n<--body>\n<SECRET_WEDGE_SUMMARY>\n<--sound>\n<request>'
actual=$(cat "$NOTIFICATION_LOG")
[ "$actual" = "$expected" ] ||
  fail "the configured Herdr channel must receive the exact notification argument vector"
pass "the S4 config route invokes Herdr notification show with the exact request sound"

rm -f "$NOTIFICATION_LOG" "$NOTIFICATION_PID"
out=$(run_wedge_from_config failure 10); rc=$?
expect_code 0 "$rc" "a failed Herdr notification must remain best-effort"
assert_contains "$out" "wedge alarm: herdr notification failed" \
  "a failed Herdr notification must be logged"
assert_not_contains "$out" "SECRET_WEDGE_SUMMARY" \
  "a failed Herdr notification log must redact the summary"
pass "a Herdr notification failure is best-effort and redacted"

rm -f "$NOTIFICATION_LOG" "$NOTIFICATION_PID"
timeout_out="$TMP_ROOT/timeout.log"
run_wedge_from_config timeout 1 > "$timeout_out" 2>&1 &
call_pid=$!
waited=0
while kill -0 "$call_pid" 2>/dev/null; do
  if [ "$waited" -ge 60 ]; then
    fake_pid=$(cat "$NOTIFICATION_PID" 2>/dev/null || printf '')
    [ -n "$fake_pid" ] && kill -TERM "$fake_pid" 2>/dev/null || true
    kill -KILL "$call_pid" 2>/dev/null || true
    wait "$call_pid" 2>/dev/null || true
    fail "a bounded Herdr notification call must finish within six seconds"
  fi
  sleep 0.1
  waited=$((waited + 1))
done
rc=0
wait "$call_pid" || rc=$?
expect_code 0 "$rc" "a timed-out Herdr notification must remain best-effort"
timeout_out=$(cat "$timeout_out")
assert_contains "$timeout_out" "herdr notifier timed out" \
  "a timed-out Herdr notification must log the bounded failure"
assert_not_contains "$timeout_out" "SECRET_WEDGE_SUMMARY" \
  "a timed-out Herdr notification log must redact the summary"
fake_pid=$(cat "$NOTIFICATION_PID")
if kill -0 "$fake_pid" 2>/dev/null; then
  fail "the timed-out Herdr notifier process must be terminated"
fi
pass "a timed-out Herdr notification is bounded, best-effort, and cleaned up"

echo "ok - cs-prompt-lib native agent-prompt-wait collapse behavior characterized"
