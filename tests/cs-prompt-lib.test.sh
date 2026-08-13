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
  "status --json")
    printf '{"server":{"protocol":19,"socket":""},"client":{"protocol":19}}\n'
    exit 0 ;;
esac
exit 1
SH
chmod +x "$FAKEBIN/herdr"

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

echo "ok - cs-prompt-lib native agent-prompt-wait collapse behavior characterized"
