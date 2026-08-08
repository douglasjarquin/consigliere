#!/usr/bin/env bash
# Behavior: THE PRIME INVARIANT of the telemetry instrumentation - enabling
# telemetry does not change a single supervision decision.
#
# Telemetry is measurement, so every instrumented path must produce byte
# identical output, the same exit status, and the same side effects whether
# telemetry is off or on. The turn-end path matters most: the turn-end signal and
# the guard's exit-2 block are load-bearing supervision mechanics, and a
# measurement bug there would cost a session rather than a statistic.
#
# Each case runs the same command twice - once with telemetry off, once with it
# on - and compares. A case that also asserts a record was written proves the
# instrumentation is live rather than accidentally inert, so an equal-output
# result can never be a false green from telemetry silently doing nothing.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-telemetry-invariants)
BLOCK_BANNER='TURN WOULD END BLIND - SUPERVISION IS OFF'
GUARD_HARNESS_RE='sleep|bash|zsh|codex|claude'
# Breadcrumbs are keyed by the session identity, which is the harness process in
# this process's ancestry. A test runs under its own shell, not under codex or
# claude, so every breadcrumb-asserting invocation must widen that walk to match
# it - otherwise the identity is unresolvable, the breadcrumb is dropped by
# design, and the assertion passes only on a machine that happens to run the
# suite from inside a harness session.
SHELL_HARNESS_RE='bash|zsh|codex|claude'

# make_home <name> <telemetry: on|off|broken> - a genuine primary-scoped home
# with one in-flight task and no live watcher, exactly the fixture
# tests/cs-turnend-guard.test.sh uses. A capo-home marker force-includes it so
# the fixture needs no real git checkout.
make_home() {
  local telemetry=$2 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/bin" "$dir/state" "$dir/host" "$dir/data"
  printf 'testcapo\n' > "$dir/.cs-capo-home"
  printf '# fixture\n' > "$dir/AGENTS.md"
  cs_write_meta "$dir/state/task.meta" "window=consigliere:cs-task" "kind=ship"
  case "$telemetry" in
    on) printf 'enabled true\n' > "$dir/host/telemetry.conf" ;;
    broken)
      printf 'enabled true\n' > "$dir/host/telemetry.conf"
      # A regular file where the storage directory must go: every write fails.
      printf 'not a directory\n' > "$dir/data/telemetry"
      ;;
  esac
  printf '%s\n' "$dir"
}

records() { cat "$1/data/telemetry/turns.jsonl" 2>/dev/null || true; }

# Breadcrumbs are keyed per session, so a test reads them by shape rather than by
# one fixed name. bin/cs-telemetry-lib.sh owns the path.
crumbs() { # <home> - every breadcrumb line this home holds, from any session
  cat "$1"/state/.telemetry-crumbs-* 2>/dev/null || true
}
crumb_files() { # <home>
  find "$1/state" -maxdepth 1 -name '.telemetry-crumbs-*' 2>/dev/null | sort
}

# run_guard <home> <stop_hook_active> - feed the Stop payload and run the guard.
# Echoes combined stdout+stderr; the caller reads $? for the exit code.
run_guard() {
  local home=$1 active=${2:-false}
  printf '{"stop_hook_active":%s,"session_id":"inv-1","hook_event_name":"Stop"}' "$active" |
    CS_ROOT_OVERRIDE="$home" \
    CS_HOME="$home" \
    CS_GUARD_GRACE=999 \
    CS_LOCK_HARNESS_RE="$GUARD_HARNESS_RE" \
    CS_TELEMETRY_DISABLE='' \
    "$ROOT/bin/cs-turnend-guard.sh" 2>&1
}

# --- the turn-end guard -------------------------------------------------------

test_guard_decisions_are_identical_with_telemetry_on() {
  local off on out_off out_on rc_off rc_on holder scenario
  for scenario in blocks afk continuation; do
    off=$(make_home "guard-$scenario-off" off)
    on=$(make_home "guard-$scenario-on" on)
    if [ "$scenario" = afk ]; then
      touch "$off/state/.afk" "$on/state/.afk"
    fi
    case "$scenario" in
      continuation)
        out_off=$(run_guard "$off" true); rc_off=$?
        out_on=$(run_guard "$on" true); rc_on=$?
        ;;
      *)
        out_off=$(run_guard "$off"); rc_off=$?
        out_on=$(run_guard "$on"); rc_on=$?
        ;;
    esac
    [ "$rc_off" = "$rc_on" ] ||
      fail "$scenario: telemetry changed the guard's exit status ($rc_off -> $rc_on)"
    [ "$out_off" = "$out_on" ] ||
      fail "$scenario: telemetry changed the guard's output"$'\n'"--- off ---"$'\n'"$out_off"$'\n'"--- on ---"$'\n'"$out_on"
    [ -n "$(records "$on")" ] ||
      fail "$scenario: telemetry was enabled but recorded nothing, so this comparison proves nothing"
    [ -z "$(records "$off")" ] || fail "$scenario: telemetry was off but something was recorded"
  done

  # The same equality where the guard steps aside for another live session.
  off=$(make_home guard-defer-off off)
  on=$(make_home guard-defer-on on)
  sleep 300 &
  holder=$!
  printf '%s\n' "$holder" > "$off/state/.lock"
  printf '%s\n' "$holder" > "$on/state/.lock"
  out_off=$(run_guard "$off"); rc_off=$?
  out_on=$(run_guard "$on"); rc_on=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc_off" = "$rc_on" ] && [ "$out_off" = "$out_on" ] ||
    fail "telemetry changed the guard's lock deference ($rc_off/$rc_on)"
  [ -n "$(records "$on")" ] || fail "a deferred turn must still be measured"
  pass "cs-telemetry: enabling telemetry changes no turn-end guard decision"
}

test_guard_still_blocks_when_telemetry_itself_is_broken() {
  local home out rc
  home=$(make_home guard-broken broken)
  out=$(run_guard "$home")
  rc=$?
  expect_code 2 "$rc" "a broken telemetry path must not stop the guard from blocking"
  assert_contains "$out" "$BLOCK_BANNER" "the block banner must still reach the agent"
  [ -z "$(records "$home")" ] || fail "a broken storage path cannot have recorded anything"
  pass "cs-telemetry: a broken telemetry path leaves the exit-2 block fully intact"
}

test_guard_measures_every_primary_turn_including_the_quiet_ones() {
  local home rec
  home=$(make_home guard-continuation on)
  # A forced continuation's own second stop is a real model turn. The scope test
  # runs ahead of the loop guard precisely so this turn is counted.
  run_guard "$home" true >/dev/null
  rec=$(records "$home")
  [ "$(printf '%s\n' "$rec" | wc -l | tr -d ' ')" = 1 ] ||
    fail "a forced continuation's stop must record exactly one turn:"$'\n'"$rec"
  [ "$(printf '%s' "$rec" | jq -r '.role')" = capo ] ||
    fail "a marked capo home must record role=capo:"$'\n'"$rec"
  [ "$(printf '%s' "$rec" | jq -r '.session_id')" = inv-1 ] ||
    fail "the session identifier must come from the Stop payload:"$'\n'"$rec"
  pass "cs-telemetry: every primary turn is measured, including forced continuations"
}

test_guard_never_consumes_another_sessions_breadcrumbs() {
  local home foreign holder out rc
  home=$(make_home guard-foreign-crumbs on)
  # The real supervisor session holds this home's lock and has a turn in flight:
  # it drained a signal wake and is holding a checkpoint, and has not ended its
  # turn yet, so its breadcrumbs are still on disk under its own session key.
  sleep 300 &
  holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"
  foreign="$home/state/.telemetry-crumbs-$holder"
  printf 'wake\tsignal\ncheckpoint\t\n' > "$foreign"
  # A SECOND session in the same home - a second window, a read-only helper, a
  # tooling session in the repo root - ends a turn. It shares the primary scope,
  # so the emitter runs, but the supervisor holds the lock so the guard defers.
  out=$(run_guard "$home"); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  expect_code 0 "$rc" "the guard must still defer to the live lock holder"
  [ -z "$out" ] || fail "a deferring guard must print nothing, got:"$'\n'"$out"
  assert_present "$foreign" "the supervisor's in-flight breadcrumbs must survive a foreign turn end"
  [ "$(cat "$foreign")" = "$(printf 'wake\tsignal\ncheckpoint\t')" ] ||
    fail "the supervisor's breadcrumbs must be untouched, got:"$'\n'"$(cat "$foreign")"
  [ "$(records "$home" | jq -r '[.purpose, (.outcome // "-"), (.wake_kind // "-")] | join(" ")')" \
    = 'unknown - -' ] ||
    fail "a foreign turn must not be credited another session's supervision:"$'\n'"$(records "$home")"
  pass "cs-telemetry: a second session in one home can neither steal nor destroy the supervisor's breadcrumbs"
}

test_guard_is_exempt_in_a_soldier_worktree() {
  local home
  home=$(make_home guard-soldier on)
  # A child task worktree carries no capo marker and is not a plain checkout, so
  # the guard exempts it - and telemetry must respect exactly the same scope
  # rather than recording a soldier's turn twice.
  rm -f "$home/.cs-capo-home"
  run_guard "$home" >/dev/null
  [ -z "$(records "$home")" ] ||
    fail "telemetry must honour the guard's primary scope and record nothing outside it"
  pass "cs-telemetry: the turn-end emitter honours the guard's existing primary scope"
}

# --- the wake drain -----------------------------------------------------------

drain() { # <home>
  CS_HOME="$1" CS_ROOT_OVERRIDE="$ROOT" CS_STATE_OVERRIDE="$1/state" \
    CS_LOCK_HARNESS_RE="$SHELL_HARNESS_RE" \
    CS_TELEMETRY_DISABLE='' "$ROOT/bin/cs-wake-drain.sh" 2>&1
}

seed_queue() { # <home>
  local now
  now=$(date +%s)
  {
    printf '%s\t1\tsignal\ttask.status\tsignal: task.status\n' "$now"
    printf '%s\t2\tstale\tw1:p1\tstale: w1:p1\n' "$now"
  } > "$1/state/.wake-queue"
}

test_wake_drain_output_is_unchanged_by_telemetry() {
  local off on out_off out_on rc_off rc_on
  off=$(make_home drain-off off)
  on=$(make_home drain-on on)
  seed_queue "$off"
  seed_queue "$on"
  out_off=$(drain "$off"); rc_off=$?
  out_on=$(drain "$on"); rc_on=$?
  [ "$rc_off" = "$rc_on" ] || fail "telemetry changed the drain's exit status ($rc_off -> $rc_on)"
  [ "$out_off" = "$out_on" ] ||
    fail "telemetry changed the drain's output"$'\n'"--- off ---"$'\n'"$out_off"$'\n'"--- on ---"$'\n'"$out_on"
  assert_contains "$out_on" 'signal: task.status' "the drain must still print the wakes it consumed"
  [ ! -s "$on/state/.wake-queue" ] || fail "the drain must still empty the queue"
  # The breadcrumbs the drain recorded are what let the turn-end emitter name the
  # provenance of this supervision turn.
  assert_contains "$(crumbs "$on")" 'wake	signal' "the drained signal wake must be recorded"
  assert_contains "$(crumbs "$on")" 'wake	stale' "the drained stale wake must be recorded"
  [ -z "$(crumb_files "$off")" ] || fail "telemetry off must record no breadcrumbs"
  pass "cs-telemetry: the wake drain's output, exit status, and queue handling are unchanged"
}

# --- the bounded checkpoint ---------------------------------------------------

checkpoint() { # <home>
  # A fresh monitor beacon makes the checkpoint treat this home as already
  # watched, so it goes straight to the queue wait and returns the queued rows.
  touch "$1/state/.last-monitor-beat"
  CS_HOME="$1" CS_ROOT_OVERRIDE="$ROOT" CS_STATE_OVERRIDE="$1/state" \
    CS_LOCK_HARNESS_RE="$SHELL_HARNESS_RE" \
    CS_TELEMETRY_DISABLE='' "$ROOT/bin/cs-watch-checkpoint.sh" --seconds 3 2>&1
}

test_checkpoint_behavior_is_unchanged_by_telemetry() {
  local off on out_off out_on rc_off rc_on
  off=$(make_home checkpoint-off off)
  on=$(make_home checkpoint-on on)
  seed_queue "$off"
  seed_queue "$on"
  out_off=$(checkpoint "$off"); rc_off=$?
  out_on=$(checkpoint "$on"); rc_on=$?
  [ "$rc_off" = "$rc_on" ] || fail "telemetry changed the checkpoint's exit status ($rc_off -> $rc_on)"
  [ "$out_off" = "$out_on" ] ||
    fail "telemetry changed the checkpoint's output"$'\n'"--- off ---"$'\n'"$out_off"$'\n'"--- on ---"$'\n'"$out_on"
  [ -s "$on/state/.wake-queue" ] || fail "the checkpoint must still leave the queue for the drain"
  assert_contains "$(crumbs "$on")" 'checkpoint' "a checkpoint turn must record its breadcrumb"
  [ -z "$(crumb_files "$off")" ] || fail "telemetry off must record no breadcrumbs"
  pass "cs-telemetry: the bounded checkpoint's output, exit status, and queue handling are unchanged"
}

# --- the worker turn-end wiring -----------------------------------------------

launch() { # <harness> [telemetry-cmd]
  CS_HARNESS_OVERRIDE="$1" bash -c "
set -eu
. '$ROOT/bin/cs-harness-lib.sh'
cs_harness_soldier_launch '$1' default default \"'/op'\" \"'/brief'\" \"'/turnend'\" \"'/settings'\" '${2:-}'"
}

test_launch_wiring_is_byte_identical_with_telemetry_off() {
  local codex claude settings
  codex=$(launch codex)
  claude=$(launch claude)
  # The exact strings an uninstrumented consigliere produced, so a regression in
  # the optional telemetry argument cannot silently reshape a launch line.
  [ "$codex" = "codex --dangerously-bypass-approvals-and-sandbox -c \"notify=[\\\"bash\\\",\\\"-c\\\",\\\"touch '/turnend'\\\"]\" \"\$('/op' encode launch-brief < '/brief')\"" ] ||
    fail "the codex launch line changed with telemetry off:"$'\n'"$codex"
  [ "$claude" = "claude --dangerously-skip-permissions --settings '/settings' \"\$('/op' encode launch-brief < '/brief')\"" ] ||
    fail "the claude launch line changed with telemetry off:"$'\n'"$claude"
  settings=$(bash -c ". '$ROOT/bin/cs-harness-lib.sh'; cs_harness_claude_settings_json /s/t.turn-ended")
  [ "$settings" = '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch /s/t.turn-ended"}]}]}}' ] ||
    fail "the claude soldier settings file changed with telemetry off:"$'\n'"$settings"
  pass "cs-telemetry: with telemetry off every soldier launch artefact is byte identical"
}

test_worker_turn_end_signal_survives_a_failing_telemetry_command() {
  local dir tele notify line settings first
  dir="$TMP_ROOT/worker-signal"
  mkdir -p "$dir"
  # A telemetry command that cannot possibly work. The turn-end touch must still
  # land: it is what supervision watches for, and it runs first, joined by `;`
  # rather than `&&` so nothing about telemetry can gate it.
  tele='/nonexistent/telemetry --worker --task t'
  notify="touch '$dir/turn-ended'; $tele"
  line=$(CS_HARNESS_OVERRIDE=codex bash -c "
set -eu
. '$ROOT/bin/cs-harness-lib.sh'
cs_harness_soldier_launch codex default default \"'/op'\" \"'/brief'\" \"'$dir/turn-ended'\" \"''\" '$tele'")
  assert_contains "$line" "$notify" \
    "the codex notify command must touch first and only then run telemetry"
  # Run exactly what codex would run in the pane.
  bash -c "$notify" >/dev/null 2>&1 || true
  assert_present "$dir/turn-ended" \
    "the turn-end signal must be written even when the telemetry command cannot run"

  settings=$(bash -c ". '$ROOT/bin/cs-harness-lib.sh'; cs_harness_claude_settings_json '$dir/claude-turn-ended' '$tele --stdin'")
  printf '%s' "$settings" | jq -e . >/dev/null ||
    fail "an instrumented claude settings file must stay valid JSON:"$'\n'"$settings"
  first=$(printf '%s' "$settings" | jq -r '.hooks.Stop[0].hooks[0].command')
  [ "$first" = "touch $dir/claude-turn-ended" ] ||
    fail "the touch must remain the FIRST, separate claude Stop hook command, got: $first"
  [ "$(printf '%s' "$settings" | jq -r '.hooks.Stop[0].hooks | length')" = 2 ] ||
    fail "telemetry must be a second hook command, never folded into the touch"
  bash -c "$first" >/dev/null 2>&1 || true
  assert_present "$dir/claude-turn-ended" "the claude turn-end touch must still be a standalone command"
  pass "cs-telemetry: the worker turn-end signal cannot be delayed, gated, or lost by telemetry"
}

test_worker_emitter_terminates_on_every_argument_shape() {
  local emit=$ROOT/bin/cs-telemetry-emit.sh rc args
  # The worker emitter runs INSIDE a soldier's turn-end wiring, where a hang is
  # strictly worse than an error: codex's notify program and claude's Stop hook
  # never return, so the pane never ends its turn. Every argument shape must
  # therefore terminate, including a trailing option whose value is missing.
  for args in '--worker --task' '--task' '--worker --task t --stdin' \
              '--worker --stdin --task' '--stdin' '--worker'; do
    # shellcheck disable=SC2086 # each case is a deliberate argument vector
    ( exec 3>&2 2>/dev/null; CS_TELEMETRY_DISABLE=1 "$emit" $args </dev/null >/dev/null 2>&3 ) &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
      sleep 0.1
      waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fail "cs-telemetry-emit.sh hung on arguments: $args"
    fi
    wait "$pid"; rc=$?
    expect_code 0 "$rc" "cs-telemetry-emit.sh must exit 0 on arguments: $args"
  done
  pass "cs-telemetry: the worker emitter always terminates, so it can never wedge a turn-end hook"
}

test_launch_wiring_refuses_an_unsafe_telemetry_command() {
  local home safe cmd
  # The command is embedded inside a JSON string in both harnesses' wiring, so a
  # home path that would force a backslash into it must yield NO telemetry rather
  # than a malformed turn-end hook.
  home="$TMP_ROOT/it's-a-home"
  mkdir -p "$home/host" "$home/state" "$home/data"
  printf 'enabled true\n' > "$home/host/telemetry.conf"
  cmd=$(CS_HOME="$home" CS_TELEMETRY_DISABLE='' bash -c "
set -eu
. '$ROOT/bin/cs-telemetry-lib.sh'
cs_telemetry_worker_hook_command task '$ROOT/bin' stdin")
  [ -z "$cmd" ] || fail "a command needing a backslash must be refused, got: $cmd"

  # The same home without the quote does produce a command, so the refusal above
  # is the quoting guard rather than telemetry simply being off.
  safe="$TMP_ROOT/plain-home"
  mkdir -p "$safe/host" "$safe/state" "$safe/data"
  printf 'enabled true\n' > "$safe/host/telemetry.conf"
  cmd=$(CS_HOME="$safe" CS_TELEMETRY_DISABLE='' bash -c "
set -eu
. '$ROOT/bin/cs-telemetry-lib.sh'
cs_telemetry_worker_hook_command task '$ROOT/bin' stdin")
  assert_contains "$cmd" 'cs-telemetry-emit.sh' "an ordinary home must still get a worker hook command"
  assert_contains "$cmd" '--stdin' "the claude form must read the Stop payload from stdin"
  pass "cs-telemetry: an unsafe worker hook command is refused rather than emitted malformed"
}

test_guard_decisions_are_identical_with_telemetry_on
test_guard_still_blocks_when_telemetry_itself_is_broken
test_guard_measures_every_primary_turn_including_the_quiet_ones
test_guard_never_consumes_another_sessions_breadcrumbs
test_guard_is_exempt_in_a_soldier_worktree
test_wake_drain_output_is_unchanged_by_telemetry
test_checkpoint_behavior_is_unchanged_by_telemetry
test_launch_wiring_is_byte_identical_with_telemetry_off
test_worker_turn_end_signal_survives_a_failing_telemetry_command
test_worker_emitter_terminates_on_every_argument_shape
test_launch_wiring_refuses_an_unsafe_telemetry_command
