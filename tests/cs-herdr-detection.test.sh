#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(cs_test_tmproot cs-herdr-detection)
FAKEBIN="$TMP/fakebin"
LOG="$TMP/herdr-argv"
ORIGINAL_PATH=$PATH
HERDR_BIN=$(command -v herdr 2>/dev/null || true)
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$HERDR_ARGV_LOG"
printf 'fake-herdr-output\n'
SH
chmod +x "$FAKEBIN/herdr"
export HERDR_ARGV_LOG=$LOG
export PATH="$FAKEBIN:$PATH"

# shellcheck source=bin/cs-herdr-lib.sh
. "$ROOT/bin/cs-herdr-lib.sh"

capture="$TMP/capture with spaces.txt"
printf '%s\n' 'Esc to interrupt' > "$capture"

got=$(cs_herdr_capture_detection 'w1:p1' 40 text) || fail "detection capture helper"
assert_contains "$got" 'fake-herdr-output' "detection capture returns Herdr output"
want=$'pane\nread\nw1:p1\n--source\ndetection\n--lines\n40\n--format\ntext\n--session\ndefault'
argv=$(<"$LOG")
[ "$argv" = "$want" ] || fail "detection capture argv was '$argv', want '$want'"
pass "detection capture fixes Herdr's detection read source"

got=$(cs_herdr_agent_explain_file "$capture" codex) || fail "file explain helper"
assert_contains "$got" 'fake-herdr-output' "file explain returns Herdr output"
want=$'agent\nexplain\n--file\n'"$capture"$'\n--agent\ncodex\n--verbose\n--session\ndefault'
argv=$(<"$LOG")
[ "$argv" = "$want" ] || fail "file explain argv was '$argv', want '$want'"
pass "file explain preserves a spaced capture path and verbose rule output"

: > "$LOG"
rc=0
cs_herdr_agent_explain_file "$TMP/missing.capture" codex >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "missing capture must fail closed"
[ ! -s "$LOG" ] || fail "missing capture must not invoke Herdr"
pass "file explain rejects a missing capture before invoking Herdr"

if [ "${CS_TEST_HERDR_OFFLINE:-0}" = 1 ]; then
  [ -n "$HERDR_BIN" ] || fail "CS_TEST_HERDR_OFFLINE=1 requires herdr"
  export PATH="$ORIGINAL_PATH"
  named_capture="$TMP/named-rule.capture"
  printf '%s\n' '• Working (thinking, esc to interrupt)' > "$named_capture"
  got=$(cs_herdr_agent_explain_file "$named_capture" codex) || fail "real file explain helper"
  assert_contains "$got" 'state: working' "real explain reports the expected state"
  rule=$(printf '%s\n' "$got" | sed -n 's/^rule: //p')
  [ -n "$rule" ] && [ "$rule" != none ] || fail "real explain must name a matched rule"
  pass "real Herdr explain evaluates a saved detection capture"
fi

cs_herdr_capture() { printf '%s' "${CAPTURE:-}"; }
for raw in working blocked 'done' idle unknown; do
  CAPTURE=''
  case "$raw" in
    working) want=busy ;;
    blocked) want=blocked ;;
    "done") want='done' ;;
    idle) want=idle ;;
    unknown) want=unknown ;;
  esac
  got=$(cs_herdr_busy_state_from_raw 'w1:p1' "$raw")
  [ "$got" = "$want" ] || fail "raw '$raw' classified '$got', want '$want'"
done
CAPTURE='Esc to interrupt'
[ "$(cs_herdr_busy_state_from_raw 'w1:p1' idle)" = busy ] ||
  fail "idle plus busy signature must remain busy"
[ "$(cs_herdr_busy_state_from_raw 'w1:p1' unknown)" = busy ] ||
  fail "unknown plus busy signature must remain busy"
pass "busy-signature corroboration remains fail-closed"
