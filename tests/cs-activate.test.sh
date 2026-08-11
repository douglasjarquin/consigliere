#!/usr/bin/env bash
# tests/cs-activate.test.sh - bin/cs-activate.sh, per-home activation.
#
# The property under test is the one that was missing on 2026-08-01: a home whose
# wake queue has sat unattended must start its OWN agent's turn, with no parent
# involved. And the guards around that, because the thing being automated is
# typing into a pane a human may also be using.
#
# Hermetic: a fake herdr answers pane/agent queries; no real agent, no network.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTIVATE="$ROOT/bin/cs-activate.sh"
TMP_ROOT=$(cs_test_tmproot cs-activate)

# make_home <name> [pane-cwd-override]: a home with state/, config/, fakebin/.
make_home() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$dir/host" "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
# Fake herdr for activation tests. Driven by env:
#   FAKE_PANE_MISSING=1   `pane get` fails (pane recycled away / closed)
#   FAKE_PANE_CWD=<path>  cwd reported for the pane (default $CS_HOME)
#   FAKE_NO_AGENT=1       `agent get` reports no agent (dead harness)
#   FAKE_COMPOSER=<text>  pane read content (empty-composer default below)
#   FAKE_PROMPT_LOG=<f>   append every `agent prompt` payload here
#   FAKE_BUSY=<state>     agent_status (default idle)
set -u
case "${1:-} ${2:-}" in
  "pane get")
    [ "${FAKE_PANE_MISSING:-0}" = 1 ] && exit 1
    printf '{"result":{"pane":{"pane_id":"%s","cwd":"%s"}}}\n' "${3:-}" "${FAKE_PANE_CWD:-$CS_HOME}"
    exit 0 ;;
  "pane read")
    printf '%s\n' "${FAKE_COMPOSER:-$'\342\200\272 '}"
    exit 0 ;;
  "agent get")
    [ "${FAKE_NO_AGENT:-0}" = 1 ] && { printf '{"result":{"agent":{}}}\n'; exit 0; }
    printf '{"result":{"agent":{"agent":"codex","agent_status":"%s"}}}\n' "${FAKE_BUSY:-idle}"
    exit 0 ;;
  "pane process-info")
    # The composer classifier corroborates an empty verdict against this table.
    if [ "${FAKE_NO_AGENT:-0}" = 1 ]; then
      printf '{"result":{"process_info":{"shell_pid":10,"foreground_processes":[{"pid":10,"argv0":"zsh"}]}}}\n'
    else
      printf '{"result":{"process_info":{"shell_pid":10,"foreground_processes":[{"pid":20,"argv0":"codex"}]}}}\n'
    fi
    exit 0 ;;
  "agent prompt")
    [ -n "${FAKE_PROMPT_LOG:-}" ] && printf '%s\n' "${4:-}" >> "$FAKE_PROMPT_LOG"
    printf '{"result":{"type":"agent_prompted"}}\n'
    exit 0 ;;
  "agent wait") exit 0 ;;
  "status --json") printf '{"server":{"protocol":17},"client":{"protocol":17}}\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/herdr"
  printf 'w1:p1\n' > "$dir/state/.home-pane"
  printf 'stale wake\n' > "$dir/state/.wake-queue"
  # Backdate the queue past the settle window.
  touch -t 200001010000 "$dir/state/.wake-queue"
  printf '%s\n' "$dir"
}

run_activate() {  # <dir> [env...]
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" CS_HOME="$dir" \
    CS_STATE_OVERRIDE="$dir/state" CS_CONFIG_OVERRIDE="$dir/config" \
    "$@" "$ACTIVATE" "${ACT_ARGS[@]:-}" 2>&1
}

ACT_ARGS=(--status)

# 1. Default scope is always, everywhere, including the main home. Turns now END
#    rather than re-arming a checkpoint forever, so an unattended queue would
#    otherwise sit until the boss next typed - which is the failure this whole
#    change exists to remove. The boss accepted the composer race that comes with
#    it on 2026-08-11.
dir=$(make_home default-always)
out=$(run_activate "$dir")
assert_contains "$out" "due:" "the built-in default must activate with the boss present"
pass "with no config, a home activates on its own"

# 2. afk-only is still selectable, and then the boss being present means silence.
dir=$(make_home explicit-afk)
printf 'afk-only\n' > "$dir/host/activation.conf"
out=$(run_activate "$dir")
assert_contains "$out" "afk-only and the boss is present" "afk-only must still gate on presence"
pass "an explicit afk-only home stays quiet while the boss is present"

# 3. Same home, boss away -> due.
: > "$dir/state/.afk"
out=$(run_activate "$dir")
assert_contains "$out" "due:" "afk-only home must activate once the boss is away"
pass "afk-only activates while away"

# 4. off means off.
dir=$(make_home offhome)
printf 'off\n' > "$dir/host/activation.conf"
: > "$dir/state/.afk"
out=$(run_activate "$dir")
assert_contains "$out" "off:" "host/activation.conf=off must disable activation"
pass "off disables activation entirely"

# 5. An unusable config value refuses rather than guessing a scope.
dir=$(make_home badcfg)
printf 'sometimes\n' > "$dir/host/activation.conf"
out=$(run_activate "$dir")
assert_contains "$out" "refuse:" "an unknown scope must refuse, not default to on"
pass "an unrecognized host/activation.conf refuses"

# 6. An empty queue is the healthy end state.
dir=$(make_home emptyq)
printf 'always\n' > "$dir/host/activation.conf"
: > "$dir/state/.wake-queue"
out=$(run_activate "$dir")
assert_contains "$out" "queue empty" "an empty queue must not activate"
pass "an empty queue never activates"

# 6b. Standing open decisions must never drive activation. The wake drain prints
#     fleet-wide open decisions on every drain, including an empty one, so a home
#     with an unanswered decision has something to say on every single drain -
#     but nothing enqueued. Activation triggers on the QUEUE alone, or that
#     never-empty print would become a self-feeding turn loop.
dir=$(make_home open-decision)
printf 'always\n' > "$dir/host/activation.conf"
: > "$dir/state/.wake-queue"
cs_write_meta "$dir/state/task.meta" "window=consigliere:cs-task" "kind=ship"
printf 'working: on it\nneeds-decision: pick A or B [key=pick-one]\n' > "$dir/state/task.status"
out=$(run_activate "$dir")
assert_contains "$out" "queue empty" "a standing open decision must not activate on its own"
pass "standing open decisions never activate a home"

# 7. A queue still receiving wakes settles first: one burst, one turn.
dir=$(make_home settling)
printf 'always\n' > "$dir/host/activation.conf"
printf 'fresh\n' > "$dir/state/.wake-queue"   # mtime = now
out=$(run_activate "$dir")
assert_contains "$out" "still settling" "a fresh queue must wait out the quiet window"
pass "a still-arriving queue waits for quiet"

# 7b. The quiet window is where the asymmetry lives now that every home is
#     always-on. Nobody types into a capo pane, so 60s of quiet is enough there;
#     the main home waits 180s, because every second of quiet is a second the
#     check-then-act composer race is not entered. A queue that settled 120s ago
#     separates the two.
backdate_queue() {  # <dir> <seconds>
  local back
  back=$(( $(date +%s) - $2 ))
  if [ "$(uname)" = Darwin ]; then
    touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$1/state/.wake-queue"
  else
    touch -m -d "@$back" "$1/state/.wake-queue"
  fi
}

dir=$(make_home main-quiet)
backdate_queue "$dir" 120
out=$(run_activate "$dir")
assert_contains "$out" "still settling" "the main home must wait out the longer window"
assert_contains "$out" "180s" "the main home default must be 180s"
pass "the main home waits a longer quiet window before prompting its own pane"

dir=$(make_home capo-quiet)
printf 'thecapo\n' > "$dir/.cs-capo-home"
backdate_queue "$dir" 120
out=$(run_activate "$dir")
assert_contains "$out" "due:" "a capo home must pick the same queue up at 60s"
pass "a capo home uses the shorter quiet window"

# 8. Cooldown is also the recursion guard: the turn this starts drains the queue
#    and may append more wakes.
dir=$(make_home cooldown)
printf 'always\n' > "$dir/host/activation.conf"
: > "$dir/state/.last-activation"
out=$(run_activate "$dir")
assert_contains "$out" "cooldown" "a recent activation must suppress the next"
pass "cooldown suppresses back-to-back activation"

# --- target validation: the C-D1 hazard -------------------------------------

# 9. A recycled pane id must never be prompted. Supervision text landing in a
#    soldier's pane mid-implementation would be acted on.
dir=$(make_home recycled)
printf 'always\n' > "$dir/host/activation.conf"
out=$(run_activate "$dir" FAKE_PANE_CWD=/somewhere/else)
assert_contains "$out" "belongs to another home" "a pane rooted elsewhere must not be prompted"
assert_present "$dir/state/.activation-stalled" "a blocked home must leave a durable marker"
pass "a recycled pane id is refused, not prompted"

# 10. A vanished pane blocks and marks, rather than rotting silently.
dir=$(make_home gonepane)
printf 'always\n' > "$dir/host/activation.conf"
out=$(run_activate "$dir" FAKE_PANE_MISSING=1)
assert_contains "$out" "no longer exists" "a missing pane must be reported"
assert_present "$dir/state/.activation-stalled" "a missing pane must leave a durable marker"
pass "a vanished target pane is surfaced, not ignored"

# 11. A dead agent is the failure this whole feature exists to prevent
#     recurring, and with the parent out of the loop nobody else is watching.
dir=$(make_home deadagent)
printf 'always\n' > "$dir/host/activation.conf"
out=$(run_activate "$dir" FAKE_NO_AGENT=1)
assert_contains "$out" "needs recovery" "a dead agent must be surfaced for recovery"
assert_present "$dir/state/.activation-stalled" "a dead agent must leave a durable marker"
pass "a home whose agent died is surfaced, not left to rot"

# --- actually prompting ------------------------------------------------------

ACT_ARGS=()

# 12. The real thing: a due home prompts its own pane, with the operational
#     marker intact, and stamps the cooldown.
dir=$(make_home prompts)
printf 'always\n' > "$dir/host/activation.conf"
log="$dir/prompt.log"
run_activate "$dir" FAKE_PROMPT_LOG="$log" >/dev/null
assert_present "$log" "a due home must actually prompt"
assert_grep "drain" "$log" "the prompt must tell the agent to drain its queue"
assert_present "$dir/state/.last-activation" "activation must stamp its cooldown"
pass "a due home prompts its own agent and stamps the cooldown"

# 13. The prompt must carry the away-supervisor envelope, not read as the boss.
#     An unmarked prompt would classify as boss input and, in the main home,
#     would exit away mode.
marker=$(printf '\342\201\243')
assert_grep "$marker" "$log" "the activation prompt must carry the operational-input marker"
pass "the activation prompt is marked machine input, not boss input"

# 14. It must never prompt a pane whose composer holds text: agent prompt
#     concatenates onto it (measured on both harnesses) and submits the merge.
dir=$(make_home busycomposer)
printf 'always\n' > "$dir/host/activation.conf"
log2="$dir/prompt.log"
run_activate "$dir" FAKE_PROMPT_LOG="$log2" FAKE_COMPOSER="$(printf '\342\200\272 half typed line')" >/dev/null
assert_absent "$log2" "a non-empty composer must block the prompt, never concatenate onto it"
pass "a half-typed composer is never prompted over"

# 15. Nor a mid-turn agent.
dir=$(make_home busyagent)
printf 'always\n' > "$dir/host/activation.conf"
log3="$dir/prompt.log"
run_activate "$dir" FAKE_PROMPT_LOG="$log3" FAKE_BUSY=working >/dev/null
assert_absent "$log3" "a working agent must not be prompted"
pass "a mid-turn agent is not interrupted"

pass "cs-activate per-home activation contract"
