#!/usr/bin/env bash
# tests/cs-afk-start.test.sh - bin/cs-afk-start.sh: away-mode entry.
#
# cs-afk-start.sh arms state/.afk immediately (nothing left to launch, so
# nothing to separately certify) and a refresh preserves the buffer;
# cs-afk-return.sh clears state/.afk and surfaces catch-up evidence. The
# bossless-mode acknowledgment gate and ack subcommand this same file owns
# live in tests/cs-auto-decision.test.sh instead, alongside the rest of the
# bossless auto-decide contract they gate.
#
# Fully offline: a fake herdr CLI drives agent status, ANSI pane captures,
# send logging, and native submit confirmation; a scripted cs-watch stub
# prints canned wake reasons one-shot.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AFK_START="$ROOT/bin/cs-afk-start.sh"
AFK_RETURN="$ROOT/bin/cs-afk-return.sh"

TMP_ROOT=$(cs_test_tmproot cs-afk-start)

# make_case <name>: case dir with state/ and fakebin/ containing the fake
# herdr (agent status + ANSI captures + send log + native wait) and the
# scripted cs-watch stub. Echoes the case dir.
make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
# Offline herdr stand-in. Driven by env:
#   CS_FAKE_HERDR_CAPTURE       file whose contents `pane read` prints
#   CS_FAKE_HERDR_AGENT_STATUS  agent_status returned by `agent get` (default idle)
#   CS_FAKE_HERDR_WAIT_RC       exit code of `agent wait` (default 0 = confirmed)
#   CS_FAKE_HERDR_PANE_GONE     1 = `pane get` fails (pane-gone guard)
#   CS_FAKE_HERDR_LOG           append-only log of agent-prompt / send-text / send-keys calls
set -u
log="${CS_FAKE_HERDR_LOG:-/dev/null}"
case "${1:-} ${2:-}" in
  "pane get")
    [ "${CS_FAKE_HERDR_PANE_GONE:-0}" = 1 ] && exit 1
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}"
    exit 0 ;;
  "pane read")
    if [ -n "${CS_FAKE_HERDR_CAPTURE:-}" ]; then
      cat "$CS_FAKE_HERDR_CAPTURE" 2>/dev/null
    fi
    exit 0 ;;
  "pane send-text")
    printf 'send-text\t%s\t%s\n' "${3:-}" "${4:-}" >> "$log"
    exit 0 ;;
  "agent prompt")
    printf 'agent-prompt\t%s\t%s\n' "${3:-}" "${4:-}" >> "$log"
    exit 0 ;;
  "pane send-keys")
    printf 'send-keys\t%s\t%s\n' "${3:-}" "${4:-}" >> "$log"
    exit 0 ;;
  "agent get")
    printf '{"result":{"agent":{"agent":"codex","agent_status":"%s"}}}\n' \
      "${CS_FAKE_HERDR_AGENT_STATUS:-idle}"
    exit 0 ;;
  "pane process-info")
    if [ "${CS_FAKE_HERDR_AGENT_PROC:-claude}" = none ]; then
      printf '{"result":{"process_info":{"shell_pid":100,"foreground_processes":[{"pid":100,"argv0":"zsh"}]}}}\n'
    else
      printf '{"result":{"process_info":{"shell_pid":100,"foreground_processes":[{"pid":200,"argv0":"%s"}]}}}\n' \
        "${CS_FAKE_HERDR_AGENT_PROC:-claude}"
    fi
    exit 0 ;;
  "agent wait")
    for a in "$@"; do
      case "$a" in
        --status|--status=*) echo "unknown option: --status" >&2; exit 2 ;;
      esac
    done
    exit "${CS_FAKE_HERDR_WAIT_RC:-0}" ;;
  "status --json")
    printf '{"server":{"protocol":16,"socket":""},"client":{"protocol":16}}\n'
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/herdr"
  # Scripted one-shot cs-watch stub: prints (and consumes) the next line of
  # $CS_FAKE_WATCH_SCRIPT then exits 0; an exhausted script blocks like a
  # quiet watcher.
  cat > "$fakebin/cs-watch-stub" <<'SH'
#!/usr/bin/env bash
set -u
script="${CS_FAKE_WATCH_SCRIPT:?}"
line=""
if [ -s "$script" ]; then
  line=$(head -n 1 "$script")
  tail -n +2 "$script" > "$script.tmp" 2>/dev/null || : > "$script.tmp"
  mv "$script.tmp" "$script"
fi
if [ -n "$line" ]; then
  printf '%s\n' "$line"
  exit 0
fi
sleep "${CS_FAKE_WATCH_IDLE_SLEEP:-300}"
exit 0
SH
  chmod +x "$fakebin/cs-watch-stub"
  printf '%s\n' "$dir"
}

# --- afk-start arms immediately; a refresh preserves the buffer; return
#     clears the flag -------------------------------------------------------

test_afk_start_and_return_lifecycle() {
  local dir state fakebin out rc
  dir=$(make_case start-return); state="$dir/state"; fakebin="$dir/fakebin"
  : > "$dir/watch-script"   # quiet watcher: the stub blocks
  out=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
    CS_WATCH_BIN="$fakebin/cs-watch-stub" CS_FAKE_WATCH_SCRIPT="$dir/watch-script" \
    CS_FAKE_HERDR_LOG="$dir/herdr.log" CS_WEDGE_ALARM_EXEC=discard \
    "$AFK_START" 2>&1)
  rc=$?
  expect_code 0 "$rc" "cs-afk-start"
  # Nothing is launched, so arming is immediate - no separate certification step.
  assert_contains "$out" "away mode armed" "start did not report an armed away mode"
  assert_present "$state/.afk" "start did not write the durable away flag"

  # A second start while already away is a refresh, not a fresh entry.
  out=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
    CS_WATCH_BIN="$fakebin/cs-watch-stub" CS_FAKE_WATCH_SCRIPT="$dir/watch-script" \
    "$AFK_START" 2>&1)
  rc=$?
  expect_code 0 "$rc" "cs-afk-start refresh"
  assert_contains "$out" "away mode refreshed" "a second start while already away must report a refresh"

  # Return clears the flag even with no daemon ever having run.
  out=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
    CS_FAKE_HERDR_CAPTURE="$dir/capture.txt" "$AFK_RETURN" 2>&1)
  rc=$?
  expect_code 0 "$rc" "cs-afk-return after a clean away session"
  assert_contains "$out" "catch-up clear" "return did not report catch-up clear"
  assert_absent "$state/.afk" "return did not clear state/.afk"
  pass "cs-afk-start arms immediately and a repeat call refreshes; cs-afk-return clears the flag"
}

test_afk_start_and_return_lifecycle

pass "cs-afk-start.sh away-mode entry contract"
