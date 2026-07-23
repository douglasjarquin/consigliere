#!/usr/bin/env bash
# tests/cs-afk-daemon.test.sh - the away-mode stack: bin/cs-daemon.sh (the
# presence-gated sub-supervisor), bin/cs-composer-lib.sh (codex composer
# emptiness), bin/cs-afk-start.sh, and bin/cs-afk-return.sh. Fully offline: a
# fake herdr CLI drives agent status, ANSI pane captures, send logging, and
# native submit confirmation; a scripted cs-watch stub prints canned wake
# reasons one-shot, exactly like the real watcher's afk mode.
#
# Behavioral contract covered:
#   - a routine wake (working: note) is SELF-HANDLED: no injection, no buffer;
#   - a done: wake escalates as ONE batched away-supervisor digest, whose
#     envelope retains the bare leading U+2063, typed once into an
#     affirmatively EMPTY codex composer and confirmed natively;
#   - a pending composer (ghost text whose ANSI the transport stripped, i.e.
#     indistinguishable from typed input) DEFERS injection, and past
#     CS_MAX_DEFER_SECS the wedge alarm fires: durable marker + the notifier
#     seam (never a real notification);
#   - buffered escalations survive a daemon SIGTERM and are flushed as durable
#     catch-up evidence by cs-afk-return, which also clears state/.afk;
#   - cs-afk-start refuses outside a herdr pane, and inside one it arms
#     state/.afk, records the target pane, starts the daemon headless, and
#     verifies it came alive; cs-afk-return stops it in order.
# The composer unit test modifies PATH inside a deliberate subshell; every
# other test passes PATH per-command through env. Both are intentional.
# shellcheck disable=SC2030,SC2031
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DAEMON="$ROOT/bin/cs-daemon.sh"
AFK_START="$ROOT/bin/cs-afk-start.sh"
AFK_RETURN="$ROOT/bin/cs-afk-return.sh"

TMP_ROOT=$(cs_test_tmproot cs-afk-daemon)

# The daemon injection marker (bare U+2063), read from its single owner.
# shellcheck source=bin/cs-marker-lib.sh
. "$ROOT/bin/cs-marker-lib.sh"

# --- process hygiene: kill every daemon this file started on exit ------------
STARTED_PIDS=()
test_teardown() {
  local p
  for p in "${STARTED_PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
  done
  for p in "${STARTED_PIDS[@]:-}"; do
    [ -n "$p" ] && wait "$p" 2>/dev/null || true
  done
  cs_test_cleanup
}
trap test_teardown EXIT

# --- fixtures -----------------------------------------------------------------

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
# Offline herdr stand-in for the away-mode daemon tests. Driven by env:
#   CS_FAKE_HERDR_CAPTURE       file whose contents `pane read` prints
#   CS_FAKE_HERDR_AGENT_STATUS  agent_status returned by `agent get` (default idle)
#   CS_FAKE_HERDR_WAIT_RC       exit code of `agent wait` (default 0 = confirmed)
#   CS_FAKE_HERDR_PANE_GONE     1 = `pane get` fails (pane-gone guard)
#   CS_FAKE_HERDR_LOG           append-only log of send-text / send-keys calls
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
  "pane send-keys")
    printf 'send-keys\t%s\t%s\n' "${3:-}" "${4:-}" >> "$log"
    exit 0 ;;
  "agent get")
    printf '{"result":{"agent":{"agent":"codex","agent_status":"%s"}}}\n' \
      "${CS_FAKE_HERDR_AGENT_STATUS:-idle}"
    exit 0 ;;
  "agent wait")
    exit "${CS_FAKE_HERDR_WAIT_RC:-0}" ;;
  "status --json")
    printf '{"server":{"protocol":16,"socket":""},"client":{"protocol":16}}\n'
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/herdr"
  # Scripted one-shot cs-watch stub: prints (and consumes) the next line of
  # $CS_FAKE_WATCH_SCRIPT then exits 0, exactly like the real watcher's afk
  # one-shot mode; an exhausted script blocks like a quiet watcher.
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
  # Wedge-alarm notifier recorder: proves the active alert fired through the
  # seam without ever posting a real notification.
  cat > "$fakebin/alarm-recorder" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${CS_FAKE_ALARM_LOG:?}"
exit 0
SH
  chmod +x "$fakebin/alarm-recorder"
  printf '%s\n' "$dir"
}

# daemon_bg <dir> [VAR=val ...]: start the daemon against <dir>'s state with
# the offline defaults; caller reads $! for the pid. Records the pid for the
# EXIT teardown.
daemon_bg() {
  local dir=$1 state fakebin
  shift
  state="$dir/state"; fakebin="$dir/fakebin"
  env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
    CS_WATCH_BIN="$fakebin/cs-watch-stub" CS_FAKE_WATCH_SCRIPT="$dir/watch-script" \
    CS_SUPERVISOR_PANE=w1:p1 CS_FAKE_HERDR_LOG="$dir/herdr.log" \
    CS_WEDGE_ALARM_EXEC=discard CS_HOUSEKEEPING_TICK=1 \
    CS_ESCALATE_BATCH_SECS=0 CS_HEARTBEAT_SCAN_SECS=999999 \
    "$@" "$DAEMON" > "$dir/daemon.out" 2>&1 &
  STARTED_PIDS+=("$!")
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# wait_for <ticks> <cmd...>: poll every 0.1s until <cmd...> succeeds.
wait_for() {
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_death() {
  local pid=$1 limit=${2:-100} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

file_has() { grep -F -- "$1" "$2" >/dev/null 2>&1; }

# --- composer lib unit coverage (sourced, pure) --------------------------------

test_composer_classifier() {
  local dir state cap verdict
  dir=$(make_case composer-unit); state="$dir/state"; cap="$dir/cap.txt"
  (
    cd "$dir" || exit 1
    export PATH="$dir/fakebin:$PATH" CS_FAKE_HERDR_CAPTURE="$cap"
    # shellcheck source=bin/cs-herdr-lib.sh
    . "$ROOT/bin/cs-herdr-lib.sh"
    # shellcheck source=bin/cs-composer-lib.sh
    . "$ROOT/bin/cs-composer-lib.sh"
    # Empty codex composer: bare › prompt with a DIM (SGR 2) ghost suggestion.
    printf 'transcript above\n\342\200\272 \033[2mTry "fix the failing test"\033[0m\n' > "$cap"
    verdict=$(cs_composer_state w1:p1)
    [ "$verdict" = empty ] || { echo "ghost-only codex composer read '$verdict', want empty" >&2; exit 1; }
    # Real typed input after the prompt is pending.
    printf '\342\200\272 land the PR now\n' > "$cap"
    verdict=$(cs_composer_state w1:p1)
    [ "$verdict" = pending ] || { echo "typed input read '$verdict', want pending" >&2; exit 1; }
    # ANSI stripped by the transport: ghost text arrives as plain bytes and
    # must classify pending (the documented fail-toward-defer direction).
    printf '\342\200\272 \033[2m\033[0m\n' > "$cap"; :
    printf '\342\200\272 Try "fix the failing test"\n' > "$cap"
    verdict=$(cs_composer_state w1:p1)
    [ "$verdict" = pending ] || { echo "ANSI-stripped ghost read '$verdict', want pending (defer)" >&2; exit 1; }
    # A bare dead-shell prompt is never a composer: unknown.
    printf '$ \n' > "$cap"
    verdict=$(cs_composer_state w1:p1)
    [ "$verdict" = unknown ] || { echo "bare shell prompt read '$verdict', want unknown" >&2; exit 1; }
    # A bordered box with only its own shell glyph is an empty agent composer.
    printf '\342\224\202 > \342\224\202\n' > "$cap"
    verdict=$(cs_composer_state w1:p1)
    [ "$verdict" = empty ] || { echo "bordered empty composer read '$verdict', want empty" >&2; exit 1; }
    # Unreadable/blank pane: unknown.
    : > "$cap"
    verdict=$(cs_composer_state w1:p1)
    [ "$verdict" = unknown ] || { echo "blank pane read '$verdict', want unknown" >&2; exit 1; }
  ) || fail "composer classifier verdicts wrong"
  pass "codex composer classifier: ghost-empty, typed-pending, stripped-transport-pending, dead-shell-unknown, bordered-empty"
}

# --- 1. a routine wake is self-handled: no model turn, no injection ------------

test_routine_wake_self_handled() {
  local dir state pid
  dir=$(make_case routine-self); state="$dir/state"
  printf 'working: compiling step 2\n' > "$state/task.status"
  date '+%s' > "$state/.afk"
  printf 'signal: %s\n' "$state/task.status" > "$dir/watch-script"
  printf 'transcript\n\342\200\272\n' > "$dir/capture.txt"
  daemon_bg "$dir" CS_FAKE_HERDR_CAPTURE="$dir/capture.txt"
  pid=$!
  wait_for 100 file_has "self-handle: signal:" "$state/.subsuper-daemon.log" \
    || { reap "$pid"; fail "daemon did not self-handle the routine working: signal: $(cat "$state/.subsuper-daemon.log" 2>/dev/null)"; }
  [ ! -s "$state/.subsuper-escalations" ] || { reap "$pid"; fail "a routine wake was buffered for escalation"; }
  [ ! -s "$dir/herdr.log" ] || { reap "$pid"; fail "a routine wake caused an injection: $(cat "$dir/herdr.log")"; }
  reap "$pid"
  pass "a routine working: wake is self-handled in bash (no injection, no escalation buffer)"
}

# --- 2. a done: wake escalates as ONE marked digest into an empty composer -----

test_done_wake_escalates_one_marked_digest() {
  local dir state pid sent
  dir=$(make_case done-escalate); state="$dir/state"
  printf 'working: setup\ndone: PR https://example.test/pr/7 checks green\n' > "$state/task.status"
  date '+%s' > "$state/.afk"
  printf 'signal: %s\n' "$state/task.status" > "$dir/watch-script"
  # An affirmatively empty codex composer: bare › prompt plus DIM ghost text
  # that the ANSI-aware classifier must strip (the 2026-07-08 incident shape).
  printf 'transcript above\n\342\200\272 \033[2mTry "explain this codebase"\033[0m\n' > "$dir/capture.txt"
  daemon_bg "$dir" CS_FAKE_HERDR_CAPTURE="$dir/capture.txt"
  pid=$!
  wait_for 150 file_has "send-text" "$dir/herdr.log" \
    || { reap "$pid"; fail "daemon never injected the done: escalation: $(cat "$state/.subsuper-daemon.log" 2>/dev/null)"; }
  # Give the submit-confirm path a moment to finish, then freeze the log view.
  wait_for 100 test ! -s "$state/.subsuper-escalations" \
    || { reap "$pid"; fail "escalation buffer was not cleared after a confirmed submit"; }
  reap "$pid"
  [ "$(grep -c "^send-text" "$dir/herdr.log")" -eq 1 ] \
    || fail "expected exactly ONE typed digest, got: $(cat "$dir/herdr.log")"
  sent=$(grep "^send-text" "$dir/herdr.log" | cut -f3)
  case "$sent" in
    "$CS_INJECT_MARK"*) : ;;
    *) fail "digest is not prefixed with CS_INJECT_MARK (bare U+2063): $sent" ;;
  esac
  [ "$(cs_operational_input_kind "$sent")" = away-supervisor ] \
    || fail "digest does not carry the away-supervisor kind"
  sent=$(cs_operational_input_body "$sent")
  assert_contains "$sent" "1 event(s)" "digest is not the single batched away-mode digest"
  assert_contains "$sent" "done: PR https://example.test/pr/7" "digest lost the boss-relevant done: content"
  case "$sent" in
    *$'\n'*) fail "digest contains an embedded newline (must be single-line)" ;;
  esac
  file_has "send-keys" "$dir/herdr.log" || fail "digest was never submitted with Enter"
  pass "a done: wake escalates as ONE typed away-supervisor digest into an empty composer, natively confirmed"
}

# --- 3. pending composer defers; max-defer fires the wedge alarm ---------------

test_pending_composer_defers_and_wedge_alarm_fires() {
  local dir state pid
  dir=$(make_case pending-defer); state="$dir/state"
  printf 'done: PR https://example.test/pr/9\n' > "$state/task.status"
  date '+%s' > "$state/.afk"
  printf 'signal: %s\n' "$state/task.status" > "$dir/watch-script"
  # Ghost text whose ANSI styling the transport stripped: indistinguishable
  # from typed input, so the classifier must read pending and the daemon must
  # DEFER (the documented failure direction), then alarm past max-defer.
  printf 'transcript above\n\342\200\272 Try "explain this codebase"\n' > "$dir/capture.txt"
  daemon_bg "$dir" CS_FAKE_HERDR_CAPTURE="$dir/capture.txt" \
    CS_MAX_DEFER_SECS=2 \
    CS_WEDGE_ALARM_EXEC="$dir/fakebin/alarm-recorder" \
    CS_WEDGE_ALARM_CHANNEL=osascript \
    CS_FAKE_ALARM_LOG="$dir/alarm.log"
  pid=$!
  wait_for 100 test -s "$state/.subsuper-escalations" \
    || { reap "$pid"; fail "the done: wake was never buffered: $(cat "$state/.subsuper-daemon.log" 2>/dev/null)"; }
  wait_for 300 test -e "$state/.subsuper-inject-wedged" \
    || { reap "$pid"; fail "max-defer never raised the wedge marker: $(cat "$state/.subsuper-daemon.log" 2>/dev/null)"; }
  wait_for 100 test -s "$dir/alarm.log" \
    || { reap "$pid"; fail "the wedge alarm never fired through the notifier seam"; }
  reap "$pid"
  if grep -q "^send-text" "$dir/herdr.log" 2>/dev/null; then
    fail "daemon injected into a pending composer: $(cat "$dir/herdr.log")"
  fi
  [ -s "$state/.subsuper-escalations" ] || fail "the deferred escalation buffer was lost"
  assert_grep "osascript" "$dir/alarm.log" "alarm recorder did not receive the configured channel"
  assert_grep "WEDGED" "$dir/alarm.log" "alarm summary does not say WEDGED"
  assert_grep "Buffered items" "$state/.subsuper-inject-wedged" "wedge marker lost the buffered evidence"
  assert_grep "done: PR https://example.test/pr/9" "$state/.subsuper-inject-wedged" "wedge marker lost the digest content"
  file_has "inject deferred" "$state/.subsuper-daemon.log" || fail "daemon log does not show the deferral"
  pass "a pending (ANSI-stripped ghost) composer defers injection; past CS_MAX_DEFER_SECS the wedge marker and seam-recorded alarm fire"
}

# --- 4. buffered escalations survive a daemon kill; return flushes them --------

test_buffer_survives_kill_and_return_flushes() {
  local dir state fakebin pid out rc
  dir=$(make_case kill-and-return); state="$dir/state"; fakebin="$dir/fakebin"
  printf 'done: PR https://example.test/pr/11\n' > "$state/task.status"
  date '+%s' > "$state/.afk"
  printf 'signal: %s\n' "$state/task.status" > "$dir/watch-script"
  # Pending composer: every flush (including the shutdown flush) must defer,
  # so the buffer durably survives the daemon's death.
  printf '\342\200\272 half-typed boss text\n' > "$dir/capture.txt"
  daemon_bg "$dir" CS_FAKE_HERDR_CAPTURE="$dir/capture.txt"
  pid=$!
  wait_for 100 test -s "$state/.subsuper-escalations" \
    || { reap "$pid"; fail "the done: wake was never buffered before the kill"; }
  kill -TERM "$pid" 2>/dev/null || true
  wait_for_death "$pid" || { reap "$pid"; fail "daemon did not shut down on SIGTERM"; }
  wait "$pid" 2>/dev/null || true
  [ -s "$state/.subsuper-escalations" ] \
    || fail "buffered escalation did not survive the daemon kill (shutdown flush must defer on a pending composer)"

  out=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
    CS_FAKE_HERDR_CAPTURE="$dir/capture.txt" "$AFK_RETURN" 2>&1)
  rc=$?
  expect_code 0 "$rc" "cs-afk-return with no open blockers"
  assert_contains "$out" "catch-up escalation:" "return did not flush the buffered escalation as evidence"
  assert_contains "$out" "done: PR https://example.test/pr/11" "return catch-up lost the escalation content"
  assert_contains "$out" "catch-up clear" "return did not report the gate clear"
  assert_absent "$state/.afk" "return did not clear state/.afk"
  assert_absent "$state/.subsuper-escalations" "return did not clear the delivery artifacts after surfacing them"
  assert_absent "$state/.afk-return-catchup" "return left its gate behind after a clean catch-up"
  pass "buffered escalations survive a daemon kill and are flushed by cs-afk-return, which clears .afk and prints catch-up"
}

# --- 4b. an open blocked: decision keeps the return gate closed ----------------

test_return_gate_blocks_on_open_blocker() {
  local dir state fakebin out rc
  dir=$(make_case return-blocked); state="$dir/state"; fakebin="$dir/fakebin"
  date '+%s' > "$state/.afk"
  cs_write_meta "$state/stuck.meta" "pane=w4:p4" "kind=ship"
  printf 'blocked [key=creds]: need the deploy token\n' > "$state/stuck.status"
  out=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" "$AFK_RETURN" 2>&1)
  rc=$?
  expect_code 3 "$rc" "cs-afk-return with a live open blocker"
  assert_contains "$out" "consigliere-actionable blocker: stuck [key=creds]" "gate did not name the open blocker"
  assert_present "$state/.afk-return-catchup" "the fail-closed gate file is missing"
  out=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" "$AFK_RETURN" guard 2>&1)
  rc=$?
  expect_code 3 "$rc" "guard while catch-up is pending"
  # Remediate: close the keyed decision, then check clears the gate.
  printf 'resolved [key=creds]: token installed\n' >> "$state/stuck.status"
  out=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" "$AFK_RETURN" check 2>&1)
  rc=$?
  expect_code 0 "$rc" "cs-afk-return check after the blocker resolved"
  assert_absent "$state/.afk-return-catchup" "check did not clear the gate after resolution"
  pass "the return catch-up gate fails closed on an open blocked: decision and clears only after resolved [key=...]"
}

# --- 5. afk-start refuses outside a herdr pane ---------------------------------

test_afk_start_refuses_outside_herdr_pane() {
  local dir state fakebin out rc
  dir=$(make_case start-refuse); state="$dir/state"; fakebin="$dir/fakebin"
  out=$(env -u HERDR_PANE_ID PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
    "$AFK_START" 2>&1)
  rc=$?
  expect_code 1 "$rc" "cs-afk-start outside a herdr pane"
  assert_contains "$out" "HERDR_PANE_ID" "refusal does not name the missing herdr pane env"
  assert_absent "$state/.afk" "a refused start still armed away mode"
  assert_absent "$state/.subsuper-target" "a refused start still recorded a target pane"
  pass "cs-afk-start refuses outside a herdr pane and arms nothing"
}

# --- 6. afk-start arms + verifies the daemon; return stops it in order ---------

test_afk_start_and_return_lifecycle() {
  local dir state fakebin out rc pid
  dir=$(make_case start-return); state="$dir/state"; fakebin="$dir/fakebin"
  : > "$dir/watch-script"   # quiet watcher: the stub blocks
  out=$(env HERDR_PANE_ID=w9:p9 PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
    CS_WATCH_BIN="$fakebin/cs-watch-stub" CS_FAKE_WATCH_SCRIPT="$dir/watch-script" \
    CS_FAKE_HERDR_LOG="$dir/herdr.log" CS_WEDGE_ALARM_EXEC=discard \
    "$AFK_START" 2>&1)
  rc=$?
  expect_code 0 "$rc" "cs-afk-start inside a herdr pane"
  assert_contains "$out" "away mode armed" "start did not confirm the daemon came alive"
  assert_present "$state/.afk" "start did not write the durable away flag"
  [ "$(cat "$state/.subsuper-target" 2>/dev/null)" = "w9:p9" ] \
    || fail "start did not record the supervisor pane id in .subsuper-target"
  pid=$(cat "$state/.subsuper-daemon.pid" 2>/dev/null || true)
  [ -n "$pid" ] || fail "start did not record the daemon pid"
  kill -0 "$pid" 2>/dev/null || fail "daemon is not alive after a verified start"
  STARTED_PIDS+=("$pid")

  # A second start while the daemon lives is a refresh, not a restart.
  out=$(env HERDR_PANE_ID=w9:p9 PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
    CS_WATCH_BIN="$fakebin/cs-watch-stub" CS_FAKE_WATCH_SCRIPT="$dir/watch-script" \
    "$AFK_START" 2>&1)
  rc=$?
  expect_code 0 "$rc" "cs-afk-start refresh"
  assert_contains "$out" "daemon already running" "refresh did not detect the live daemon"
  [ "$(cat "$state/.subsuper-daemon.pid" 2>/dev/null)" = "$pid" ] \
    || fail "refresh restarted the daemon instead of preserving it"

  # Ordered return: daemon stopped first, then .afk cleared.
  out=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
    CS_FAKE_HERDR_LOG="$dir/herdr.log" "$AFK_RETURN" 2>&1)
  rc=$?
  expect_code 0 "$rc" "cs-afk-return after a clean away session"
  assert_contains "$out" "catch-up clear" "return did not report catch-up clear"
  wait_for_death "$pid" 50 || fail "return did not stop the daemon"
  assert_absent "$state/.afk" "return did not clear state/.afk"
  pass "cs-afk-start arms and verifies the headless daemon (refresh preserved); cs-afk-return stops it and clears .afk in order"
}

test_composer_classifier
test_routine_wake_self_handled
test_done_wake_escalates_one_marked_digest
test_pending_composer_defers_and_wedge_alarm_fires
test_buffer_survives_kill_and_return_flushes
test_return_gate_blocks_on_open_blocker
test_afk_start_refuses_outside_herdr_pane
test_afk_start_and_return_lifecycle
