#!/usr/bin/env bash
# tests/cs-watch-triage.test.sh - the always-on wake triage built into
# bin/cs-watch.sh over the shared classifier (bin/cs-classify-lib.sh). The
# watcher absorbs the benign majority of wakes in bash and exits ONLY on an
# actionable wake, so consigliere's LLM re-arms once per actionable event
# instead of once per wake. These tests drive a real cs-watch.sh subprocess
# offline (fake herdr + fake cs-crew-state.sh) to assert the behavioral
# contract: provably-working no-verb wakes absorbed (no exit, no queue entry,
# suppressor advanced, beacon fresh), stopped-soldier no-verb wakes surfaced
# (queue + exit), provably-working stale panes absorbed-then-escalated past the
# threshold with the demand-deep-inspection marker at the consecutive-wedge
# threshold, declared pauses absorbed on the long bounded cadence, native
# blocked panes surfaced immediately, the heartbeat backstop fail-safe, check
# authentication (hash-validated snapshots run, unauthenticated checks rejected
# WITHOUT execution), afk one-shot coherence, and the watcher singleton lock.
set -u

# shellcheck source=tests/cs-watch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/cs-watch-helpers.sh"

WATCH="$ROOT/bin/cs-watch.sh"

TMP_ROOT=$(cs_test_tmproot cs-watch-triage)

# --- benign wakes are absorbed ONLY when the soldier is provably working ------

test_provably_working_signal_absorbed() {
  local dir state fakebin out status_file pid
  dir=$(make_case provably-working-signal); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # The soldier's pipeline is in an actively-running step: positive evidence it
  # is still working, so a no-verb working: signal is absorbed (the original
  # low-churn case during a long validation).
  export CS_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a working: signal whose soldier is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working signal printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working signal enqueued a durable wake record"
  [ -s "$state/.seen-task_status" ] || fail "provably-working signal did not advance its .seen-* suppressor"
  [ -e "$state/.last-watcher-beat" ] || fail "watcher beacon was not touched while absorbing"
  reap "$pid"
  unset CS_FAKE_CREW_STATE
  pass "a no-verb signal whose soldier is provably working is absorbed (no exit, no queue, suppressor advanced, beacon present)"
}

test_turn_ended_provably_working_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case turn-ended-working); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  : > "$state/task.turn-ended"
  # A busy pane is the second form of positive evidence (covers a queued
  # continuation right after the turn-end).
  export CS_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a turn-end whose soldier is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working turn-end printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working turn-end enqueued a durable wake record"
  reap "$pid"
  unset CS_FAKE_CREW_STATE
  pass "a bare turn-end whose soldier is provably working (busy pane) is absorbed"
}

# --- a no-verb signal whose soldier is NOT provably working SURFACES ----------
# This is the swallowed-finish guard: a soldier that finished (or stopped and
# waits) reports its final turn-end with no boss-relevant status and no running
# pipeline, so the wake must surface instead of being absorbed.

test_turn_ended_not_working_surfaced() {
  local dir state fakebin out pid
  dir=$(make_case turn-ended-stopped); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  : > "$state/task.turn-ended"
  # No running pipeline, no busy pane: the soldier has stopped (e.g. it finished
  # via an interactive menu and wrote no done: status). Default unknown verdict.
  export CS_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 60 || fail "watcher did not surface a turn-end whose soldier is not provably working"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null || fail "watcher did not print the surfaced turn-end signal"
  grep "$(printf '\tsignal\t')" "$state/.wake-queue" | grep -F "task.turn-ended" >/dev/null \
    || fail "surfaced turn-end was not queued"
  unset CS_FAKE_CREW_STATE
  pass "a bare turn-end whose soldier is not provably working is surfaced (the swallowed-finish guard)"
}

test_working_note_not_working_surfaced() {
  local dir state fakebin out status_file pid
  dir=$(make_case working-note-stopped); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # A soldier with no run whose pane went idle: cs-crew-state falls back to the
  # stale working: status-log line. That is NOT positive evidence, so the wake
  # must surface - these soldiers must never be left hanging.
  export CS_FAKE_CREW_STATE='state: working · source: status-log · working: compiling step 2'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 60 || fail "watcher did not surface a working: note whose soldier has no running pipeline and an idle pane"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the surfaced working: signal"
  grep "$(printf '\tsignal\t')" "$state/.wake-queue" | grep -F "task.status" >/dev/null \
    || fail "surfaced working: note was not queued"
  [ -s "$state/.seen-task_status" ] || fail "surfaced working: note did not advance its .seen-* suppressor"
  unset CS_FAKE_CREW_STATE
  pass "a no-verb working: note whose soldier is idle with no running pipeline is surfaced"
}

# --- actionable wakes are surfaced (queue + exit) -----------------------------

test_actionable_signal_surfaced() {
  local dir state fakebin out status_file pid
  dir=$(make_case actionable-signal); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 60 || fail "watcher did not exit for an actionable needs-decision signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the actionable signal reason"
  grep "$(printf '\tsignal\t')" "$state/.wake-queue" | grep -F "task.status" >/dev/null \
    || fail "actionable signal was not queued"
  [ -s "$state/.hb-surfaced-task" ] || fail "actionable signal did not record the surfaced marker"
  pass "boss-relevant signal is surfaced (queue + exit) and marked surfaced"
}

test_terminal_stale_surfaced() {
  local dir state fakebin out capture_file pane sig pid
  dir=$(make_case terminal-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  pane="pane-done-1"
  printf 'finished, awaiting review' > "$capture_file"
  cs_write_meta "$state/done.meta" "pane=$pane" "kind=ship"
  printf 'done: PR https://example.test/pr/3\n' > "$state/done.status"
  sig=$(seen_sig "$state/done.status"); printf '%s' "$sig" > "$state/.seen-done_status"
  prime_stale "$state" "$pane" "finished, awaiting review" >/dev/null
  export CS_FAKE_HERDR_CAPTURE="$capture_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 60 || fail "watcher did not exit for a stale pane on a terminal status"
  grep -Fx "stale: $pane" "$out" >/dev/null || fail "watcher did not print the terminal stale wake: $(cat "$out")"
  [ "$(count_wakes "$state" stale "$pane")" -ge 1 ] || fail "terminal stale was not queued"
  unset CS_FAKE_HERDR_CAPTURE
  pass "a stale pane sitting on a terminal status is surfaced (queue + exit)"
}

# --- a live headless scout (codex exec / claude -p) is NOT stale-triaged -------
# It presents no interactive composer/busy banner, so the stale heuristics would
# raise a spurious "went quiet" wake while it legitimately works. The watcher
# skips its stale triage until the run writes a terminal done:/failed:.
# (docs/headless-scouts.md; bin/cs-watch.sh pane_is_headless)

test_live_headless_scout_stale_absorbed() {
  local dir state fakebin out capture_file pane pid
  dir=$(make_case headless-live); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  pane="pane-headless-1"
  printf 'exec: investigating (no TUI)\n' > "$capture_file"
  cs_write_meta "$state/hs.meta" "pane=$pane" "kind=scout" "headless=1"
  # A live headless run writes NO status file until it exits with done:/failed:
  # (cs-spawn does not pre-create it), so the signal scan sees nothing and only
  # the stale-pane path fires.
  rm -f "$state/hs.status"
  prime_stale "$state" "$pane" "exec: investigating (no TUI)" >/dev/null
  export CS_FAKE_HERDR_CAPTURE="$capture_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited (spurious wake) for a live headless scout: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "live headless scout raised a stale wake reason: $(cat "$out")"
  [ "$(count_wakes "$state" stale "$pane")" -eq 0 ] || fail "live headless scout enqueued a stale wake"
  reap "$pid"
  unset CS_FAKE_HERDR_CAPTURE
  pass "a live (non-terminal) headless scout is not stale-triaged (no spurious wake)"
}

# --- a headless scout that has finished IS surfaced (the guard only skips the
# live, non-terminal window; completion still surfaces) ------------------------

test_terminal_headless_scout_surfaced() {
  local dir state fakebin out capture_file pane sig pid
  dir=$(make_case headless-terminal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  pane="pane-headless-done-1"
  printf 'done: headless scout finished; read the report\n' > "$capture_file"
  cs_write_meta "$state/hd.meta" "pane=$pane" "kind=scout" "headless=1"
  printf 'done: headless scout finished; read the report\n' > "$state/hd.status"
  sig=$(seen_sig "$state/hd.status"); printf '%s' "$sig" > "$state/.seen-hd_status"
  prime_stale "$state" "$pane" "done: headless scout finished; read the report" >/dev/null
  export CS_FAKE_HERDR_CAPTURE="$capture_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 60 || fail "watcher did not exit for a terminal headless scout"
  grep -Fx "stale: $pane" "$out" >/dev/null || fail "terminal headless scout not surfaced: $(cat "$out")"
  unset CS_FAKE_HERDR_CAPTURE
  pass "a finished (terminal) headless scout is still surfaced"
}

# --- stale pane, STALE terminal status overridden by an active run: absorbed --
# A soldier's own status log gets no new entry once consigliere hands it to a
# no-mistakes validation (the sparse status-reporting contract), so the log
# keeps showing its pre-validation "done:" line as the LAST line for the run's
# entire duration. crew_is_provably_working must get a chance to override a
# boss-relevant-but-stale status line, exactly as it does for a plain
# non-terminal one - then wedge-escalate if the run genuinely freezes.

test_stale_terminal_status_overridden_by_active_run() {
  local dir state fakebin out capture_file pane key pane_hash sig pid
  dir=$(make_case terminal-stale-overridden); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  pane="pane-validating-1"
  key=$(pane_key "$pane")
  printf 'no-mistakes axi run: validating...' > "$capture_file"
  cs_write_meta "$state/validating.meta" "pane=$pane" "kind=ship"
  # The soldier reported done BEFORE consigliere triggered validation; this
  # line never gets superseded while the pipeline itself runs.
  printf 'done: implementation complete, ready to validate\n' > "$state/validating.status"
  sig=$(seen_sig "$state/validating.status"); printf '%s' "$sig" > "$state/.seen-validating_status"
  pane_hash=$(prime_stale "$state" "$pane" "no-mistakes axi run: validating...")
  export CS_FAKE_HERDR_CAPTURE="$capture_file"
  export CS_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: a high escalation threshold means the first sighting is absorbed,
  # not surfaced, despite the boss-relevant "done:" status-log line.
  watch_bg "$state" "$fakebin" "$out" CS_STALE_ESCALATE_SECS=999
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a stale terminal-looking status the run-step overrides (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the overridden stale terminal status printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "the overridden stale terminal status enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  [ ! -e "$state/.hb-surfaced-validating" ] || fail "an absorbed wake must not mark the status line as surfaced"
  reap "$pid"

  # Phase B: backdate the idle timer past the threshold; the run genuinely
  # wedges and the next poll escalates exactly like the non-terminal case.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  watch_bg "$state" "$fakebin" "$out" CS_STALE_ESCALATE_SECS=240
  pid=$!
  wait_for_exit "$pid" 60 || fail "watcher did not escalate an overridden stale terminal status past the threshold"
  grep -F "stale: $pane" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  unset CS_FAKE_CREW_STATE CS_FAKE_HERDR_CAPTURE
  pass "a stale terminal-looking status is overridden and absorbed while a run is actively working, then wedge-escalated"
}

# --- non-terminal stale, soldier provably working: absorbed, then escalated ---

test_nonterminal_stale_provably_working_absorbed_then_escalated() {
  local dir state fakebin out capture_file pane key pane_hash sig pid
  dir=$(make_case nonterminal-stale-working); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  pane="pane-quiet-1"
  key=$(pane_key "$pane")
  printf 'idle building output' > "$capture_file"
  cs_write_meta "$state/quiet.meta" "pane=$pane" "kind=ship"
  printf 'working: still compiling\n' > "$state/quiet.status"
  sig=$(seen_sig "$state/quiet.status"); printf '%s' "$sig" > "$state/.seen-quiet_status"
  pane_hash=$(prime_stale "$state" "$pane" "idle building output")
  export CS_FAKE_HERDR_CAPTURE="$capture_file"
  # The soldier's pipeline is actively running: a static pane is normal (CI wait).
  export CS_FAKE_CREW_STATE='state: working · source: run-step · ci running'

  # Phase A: a high escalation threshold means the first sighting is absorbed.
  watch_bg "$state" "$fakebin" "$out" CS_STALE_ESCALATE_SECS=999
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a fresh provably-working non-terminal stale (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh provably-working stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh provably-working stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  reap "$pid"

  # Phase B: backdate the idle timer past the threshold; the next run escalates.
  # (The subsequent-sight timer path does not re-read the soldier state.)
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  watch_bg "$state" "$fakebin" "$out" CS_STALE_ESCALATE_SECS=240
  pid=$!
  wait_for_exit "$pid" 60 || fail "watcher did not escalate a provably-working non-terminal stale past the threshold"
  grep -F "stale: $pane" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer was not cleared after escalation"
  [ "$(count_wakes "$state" stale "$pane")" -ge 1 ] || fail "wedge escalation was not queued"
  unset CS_FAKE_CREW_STATE CS_FAKE_HERDR_CAPTURE
  pass "provably-working non-terminal stale is absorbed on first sight, then wedge-escalated past the threshold"
}

# --- consecutive wedge escalations on the same pane demand deep inspection ----

test_wedge_escalation_marks_demand_deep_inspection_after_threshold() {
  local dir state fakebin out capture_file pane key sig pid n
  dir=$(make_case wedge-escalation); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  pane="pane-wedged-1"
  key=$(pane_key "$pane")
  printf 'idle building output' > "$capture_file"
  cs_write_meta "$state/wedged.meta" "pane=$pane" "kind=ship"
  printf 'working: still monitoring ci\n' > "$state/wedged.status"
  sig=$(seen_sig "$state/wedged.status"); printf '%s' "$sig" > "$state/.seen-wedged_status"
  prime_stale "$state" "$pane" "idle building output" >/dev/null
  export CS_FAKE_HERDR_CAPTURE="$capture_file"
  export CS_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Priming round: first sighting of this stale hash classifies and absorbs it
  # (establishing .stale-$key and starting the wedge timer).
  watch_bg "$state" "$fakebin" "$out" CS_STALE_ESCALATE_SECS=999
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited on the priming round (should absorb): $(cat "$out")"
  fi
  reap "$pid"

  n=1
  while [ "$n" -le 3 ]; do
    # Backdate the wedge timer past the threshold before each round (the
    # subsequent-sight timer path does not re-read the soldier state).
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    watch_bg "$state" "$fakebin" "$out" CS_STALE_ESCALATE_SECS=240
    pid=$!
    wait_for_exit "$pid" 60 || fail "watcher did not escalate on consecutive wedge round $n: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "escalation counter did not persist across consecutive rounds"
  unset CS_FAKE_CREW_STATE CS_FAKE_HERDR_CAPTURE
  pass "consecutive wedge escalations on the same pane accumulate and demand deep inspection at the threshold"
}

# --- non-terminal stale, soldier NOT provably working: surfaced immediately ---

test_nonterminal_stale_not_working_surfaced() {
  local dir state fakebin out capture_file pane key pane_hash sig pid
  dir=$(make_case nonterminal-stale-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  pane="pane-stopped-1"
  key=$(pane_key "$pane")
  printf 'idle prompt, finished' > "$capture_file"
  cs_write_meta "$state/stopped.meta" "pane=$pane" "kind=ship"
  printf 'working: implementing\n' > "$state/stopped.status"
  sig=$(seen_sig "$state/stopped.status"); printf '%s' "$sig" > "$state/.seen-stopped_status"
  pane_hash=$(prime_stale "$state" "$pane" "idle prompt, finished")
  export CS_FAKE_HERDR_CAPTURE="$capture_file"
  # No running pipeline; the pane is idle. NOT provably working.
  export CS_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  # Even with a high wedge threshold, a not-provably-working stale surfaces at once.
  watch_bg "$state" "$fakebin" "$out" CS_STALE_ESCALATE_SECS=999
  pid=$!
  wait_for_exit "$pid" 60 || fail "watcher did not surface a not-provably-working non-terminal stale at once"
  grep -Fx "stale: $pane" "$out" >/dev/null || fail "watcher did not print the immediate stale wake: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "an immediate stopped-soldier stale was mislabeled a wedge"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced on surface"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer should not be set when surfacing immediately"
  [ "$(count_wakes "$state" stale "$pane")" -ge 1 ] || fail "immediate stale wake was not queued"
  unset CS_FAKE_CREW_STATE CS_FAKE_HERDR_CAPTURE
  pass "a not-provably-working non-terminal stale is surfaced immediately (never left to wait out the timer)"
}

# --- non-terminal stale, soldier DECLARED a pause: absorbed, re-surfaced on a
#     long cadence, never wedge-escalated -------------------------------------

test_nonterminal_stale_paused_absorbed_then_resurfaced() {
  local dir state fakebin out capture_file pane key pane_hash sig pid statusf
  dir=$(make_case nonterminal-stale-paused); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  pane="pane-held-1"
  key=$(pane_key "$pane")
  printf 'idle, holding for upstream' > "$capture_file"
  cs_write_meta "$state/held.meta" "pane=$pane" "kind=ship"
  statusf="$state/held.status"
  # A DECLARED pause (not boss-relevant), .seen-* primed so the signal scan does
  # not pre-empt the stale path.
  printf 'paused: holding for the upstream tool release\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  pane_hash=$(prime_stale "$state" "$pane" "idle, holding for upstream")
  export CS_FAKE_HERDR_CAPTURE="$capture_file"
  # The agent has confidently exited (a held pane after the agent stops); a
  # live agent at a declared gate would surface once instead.
  export CS_FAKE_HERDR_AGENT=""
  # crew_absorb_class reads the declared pause from cs-crew-state.sh.
  export CS_FAKE_CREW_STATE='state: paused · source: status-log · holding for the upstream tool release'

  # Phase A: a fresh pause (status file just written) under a high re-surface
  # threshold is absorbed - no wake, no wedge timer.
  watch_bg "$state" "$fakebin" "$out" CS_PAUSE_RESURFACE_SECS=999
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a fresh declared pause (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh paused stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh paused stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on paused absorb"
  [ -e "$state/.paused-$key" ] || fail "paused flag not recorded on absorb"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused absorb must not start the wedge timer"
  reap "$pid"

  # Phase B: age the pause past the (now normal) threshold by backdating its
  # status file, re-prime .seen-* to the new signature so the signal scan stays
  # quiet, and confirm it re-surfaces as a paused recheck - never a wedge.
  backdate "$statusf" 500
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  : > "$out"
  printf 'idle, holding for upstream (token 2)' > "$capture_file"
  watch_bg "$state" "$fakebin" "$out" CS_PAUSE_RESURFACE_SECS=240
  pid=$!
  wait_for_exit "$pid" 60 || fail "watcher did not re-surface a declared pause past the threshold"
  grep -F "stale: $pane" "$out" >/dev/null || fail "re-surface did not print a stale wake"
  grep -F "awaiting external" "$out" >/dev/null || fail "re-surface was not labeled a paused/awaiting-external recheck"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause was mislabeled a possible wedge"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the paused re-surface throttle marker was not recorded"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused re-surface must not use the wedge timer"
  [ "$(count_wakes "$state" stale "$pane")" -ge 1 ] || fail "paused re-surface was not queued"
  unset CS_FAKE_CREW_STATE CS_FAKE_HERDR_CAPTURE CS_FAKE_HERDR_AGENT
  pass "a declared pause is absorbed on first sight, then re-surfaced as a recheck past the threshold, never wedge-escalated"
}

# --- native blocked panes surface immediately, deduped, pause-exempted --------

test_blocked_pane_surfaces_immediately() {
  local dir state fakebin out capture_file pane key sig pid
  dir=$(make_case blocked-immediate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  pane="pane-blocked-1"
  key=$(pane_key "$pane")
  printf 'Allow codex to run rm -rf? [y/n]' > "$capture_file"
  cs_write_meta "$state/blocked.meta" "pane=$pane" "kind=ship"
  printf 'working: implementing\n' > "$state/blocked.status"
  sig=$(seen_sig "$state/blocked.status"); printf '%s' "$sig" > "$state/.seen-blocked_status"
  export CS_FAKE_HERDR_CAPTURE="$capture_file"
  export CS_FAKE_HERDR_AGENT_STATUS=blocked

  # First poll, fresh hash, no stale priming needed: the native blocked reading
  # must surface at once, never wait for two identical hashes or a wedge timer.
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 60 || fail "watcher did not surface a native blocked pane immediately"
  grep -F "stale: $pane (herdr: agent blocked - waiting on human, escalated immediately, not via wedge timer)" "$out" >/dev/null \
    || fail "blocked pane did not print the immediate escalation reason: $(cat "$out")"
  [ -e "$state/.herdr-escalated-$key" ] || fail "blocked escalation did not commit its dedupe marker"
  [ "$(count_wakes "$state" stale "$pane")" -eq 1 ] || fail "blocked escalation was not queued exactly once"

  # Re-arm with the pane still blocked: the committed marker dedupes, so the
  # watcher absorbs (no second wake) instead of flooding one wake per poll.
  : > "$out"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 25; then
    reap "$pid"; fail "re-armed watcher re-escalated an already-surfaced blocked pane: $(cat "$out")"
  fi
  reap "$pid"
  [ "$(count_wakes "$state" stale "$pane")" -eq 1 ] || fail "an already-surfaced blocked pane was re-queued"
  unset CS_FAKE_HERDR_CAPTURE CS_FAKE_HERDR_AGENT_STATUS
  pass "a native blocked pane is surfaced immediately with the push reason, deduped across re-arms"
}

test_blocked_pane_declared_pause_absorbed() {
  local dir state fakebin out capture_file pane key sig pid
  dir=$(make_case blocked-paused); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  pane="pane-blocked-paused-1"
  key=$(pane_key "$pane")
  printf 'waiting at a known external gate' > "$capture_file"
  cs_write_meta "$state/blocked-paused.meta" "pane=$pane" "kind=ship"
  printf 'paused: waiting on the upstream release gate\n' > "$state/blocked-paused.status"
  sig=$(seen_sig "$state/blocked-paused.status"); printf '%s' "$sig" > "$state/.seen-blocked-paused_status"
  export CS_FAKE_HERDR_CAPTURE="$capture_file"
  export CS_FAKE_HERDR_AGENT_STATUS=blocked
  export CS_FAKE_CREW_STATE='state: paused · source: status-log · waiting on the upstream release gate'

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 25; then
    reap "$pid"; fail "watcher escalated a blocked pane under a declared pause (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a pause-exempted blocked pane printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "a pause-exempted blocked pane enqueued a wake"
  [ -e "$state/.herdr-escalated-$key" ] || fail "the pause-exempted blocked pane did not commit its dedupe marker"
  reap "$pid"
  unset CS_FAKE_HERDR_CAPTURE CS_FAKE_HERDR_AGENT_STATUS CS_FAKE_CREW_STATE
  pass "a blocked pane under a declared pause is absorbed (marker committed) instead of escalated"
}

# --- authenticated custom checks: run from validated snapshots only -----------

test_registered_check_runs_from_snapshot() {
  local dir state fakebin out pid check hash
  dir=$(make_case check-registered); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  check="$state/good.check.sh"
  cat > "$check" <<'SH'
#!/usr/bin/env bash
echo "merge landed"
SH
  chmod 0700 "$check"
  hash=$(shasum -a 256 "$check" | awk '{print $1}')
  printf 'cs-custom-check-v1\n%s\n' "$hash" > "$state/good.check-trust"
  chmod 0600 "$state/good.check-trust"
  watch_bg "$state" "$fakebin" "$out" CS_CHECK_INTERVAL=1
  pid=$!
  wait_for_exit "$pid" 80 || fail "watcher did not surface a registered check's output"
  grep -F "check: $check: merge landed" "$out" >/dev/null || fail "registered check output not printed: $(cat "$out")"
  grep "$(printf '\tcheck\t')" "$state/.wake-queue" | grep -F "merge landed" >/dev/null \
    || fail "registered check wake was not queued"
  [ -e "$state/.last-check" ] || fail "check cadence marker was not advanced"
  pass "a hash-registered custom check runs from its validated snapshot and surfaces its output"
}

test_unauthenticated_check_rejected_without_execution() {
  local dir state fakebin out pid check canary
  dir=$(make_case check-unauthenticated); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  check="$state/evil.check.sh"
  canary="$dir/canary"
  cat > "$check" <<SH
#!/usr/bin/env bash
touch "$canary"
echo "pwned"
SH
  chmod 0700 "$check"
  # No .check-trust binding: the watcher must refuse WITHOUT executing.
  watch_bg "$state" "$fakebin" "$out" CS_CHECK_INTERVAL=1
  pid=$!
  wait_for_exit "$pid" 80 || fail "watcher did not surface the unauthenticated-check rejection"
  grep -F "check: rejected unauthenticated state checks: $check" "$out" >/dev/null \
    || fail "rejection reason not printed: $(cat "$out")"
  [ ! -e "$canary" ] || fail "an unauthenticated check WAS EXECUTED (canary present)"
  grep "$(printf '\tcheck\t')" "$state/.wake-queue" | grep -F "unauthenticated" >/dev/null \
    || fail "rejection wake was not queued"
  pass "an unauthenticated state check is rejected and surfaced without ever being executed"
}

test_tampered_registered_check_rejected() {
  local dir state fakebin out pid check hash canary
  dir=$(make_case check-tampered); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  check="$state/tamper.check.sh"
  canary="$dir/canary"
  printf '#!/usr/bin/env bash\necho ok\n' > "$check"
  chmod 0700 "$check"
  hash=$(shasum -a 256 "$check" | awk '{print $1}')
  printf 'cs-custom-check-v1\n%s\n' "$hash" > "$state/tamper.check-trust"
  chmod 0600 "$state/tamper.check-trust"
  # Tamper AFTER registration: the bytes no longer match the trust hash.
  cat > "$check" <<SH
#!/usr/bin/env bash
touch "$canary"
echo "tampered"
SH
  chmod 0700 "$check"
  watch_bg "$state" "$fakebin" "$out" CS_CHECK_INTERVAL=1
  pid=$!
  wait_for_exit "$pid" 80 || fail "watcher did not surface the tampered-check rejection"
  grep -F "check: rejected unauthenticated state checks: $check" "$out" >/dev/null \
    || fail "tampered check was not rejected: $(cat "$out")"
  [ ! -e "$canary" ] || fail "a tampered registered check WAS EXECUTED (canary present)"
  pass "a registered check whose bytes no longer match its trust binding is rejected without execution"
}

# --- heartbeat: no-change absorbed, backstop surfaces a missed status ---------

test_heartbeat_no_change_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case heartbeat-absorb); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  # A truly quiet fleet (no panes, no statuses) with a fast heartbeat cadence.
  watch_bg "$state" "$fakebin" "$out" CS_HEARTBEAT=1
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a no-change heartbeat (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "no-change heartbeat printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "no-change heartbeat enqueued a durable wake record"
  [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] || fail "heartbeat backoff streak did not advance while absorbing"
  reap "$pid"
  pass "a heartbeat with no boss-relevant change is absorbed and backs off the cadence"
}

test_heartbeat_backstop_surfaces_unsurfaced_status() {
  local dir state fakebin out sig pid
  dir=$(make_case heartbeat-backstop); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  # A boss-relevant status whose .seen-* signature ALREADY matches (so the
  # per-poll signal scan stays quiet) but which was never surfaced (no
  # .hb-surfaced-* marker). This stands in for a per-wake-path miss; the
  # heartbeat fleet-scan backstop must catch it and wake consigliere.
  printf 'done: PR https://example.test/pr/5\n' > "$state/miss.status"
  sig=$(seen_sig "$state/miss.status"); printf '%s' "$sig" > "$state/.seen-miss_status"
  watch_bg "$state" "$fakebin" "$out" CS_HEARTBEAT=1
  pid=$!
  wait_for_exit "$pid" 60 || fail "heartbeat backstop did not surface an unsurfaced boss-relevant status"
  grep -Fx "heartbeat" "$out" >/dev/null || fail "backstop did not exit with a heartbeat wake: $(cat "$out")"
  [ "$(cat "$state/.hb-surfaced-miss" 2>/dev/null || true)" = "done: PR https://example.test/pr/5" ] \
    || fail "backstop did not record the status as surfaced (would re-fire next heartbeat)"
  grep "$(printf '\theartbeat\t')" "$state/.wake-queue" >/dev/null || fail "backstop heartbeat was not queued"
  pass "heartbeat backstop fail-safe surfaces a boss-relevant status the per-wake path missed"
}

# --- beacon stays fresh while absorbing ---------------------------------------

test_beacon_stays_fresh_while_absorbing() {
  local dir state fakebin out status_file pid m1 m2 now
  dir=$(make_case beacon-fresh); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: a\n' > "$status_file"
  # Provably working so the working: notes are absorbed (the path that must keep
  # the beacon fresh).
  export CS_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_live "$pid" 15 || { reap "$pid"; fail "watcher exited while absorbing the first benign signal"; }
  m1=$(file_mtime "$state/.last-watcher-beat")
  # A second benign signal keeps it absorbing; the beacon must keep advancing.
  printf 'working: b\n' >> "$status_file"
  wait_live "$pid" 20 || { reap "$pid"; fail "watcher exited while absorbing a second benign signal"; }
  m2=$(file_mtime "$state/.last-watcher-beat")
  now=$(date +%s)
  if [ -z "$m1" ] || [ -z "$m2" ]; then
    reap "$pid"
    fail "watcher beacon missing while absorbing"
  fi
  [ "$m2" -ge "$m1" ] || { reap "$pid"; fail "beacon mtime regressed while absorbing"; }
  [ "$(( now - m2 ))" -lt 10 ] || { reap "$pid"; fail "beacon went stale while absorbing (age $(( now - m2 ))s)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "absorbing benign signals enqueued a wake"; }
  reap "$pid"
  unset CS_FAKE_CREW_STATE
  pass "the liveness beacon stays fresh while the watcher absorbs benign wakes (guards never false-alarm)"
}

# --- afk coherence: the daemon owns triage; the watcher does not double-triage -

test_afk_present_reverts_watcher_to_one_shot() {
  local dir state fakebin out status_file pid
  dir=$(make_case afk-coherence); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: routine note\n' > "$status_file"
  date '+%s' > "$state/.afk"   # away mode: the daemon owns triage
  # Set a PROVABLY-WORKING verdict: if afk failed to bypass the provably-working
  # check, this no-verb signal would be absorbed (not surfaced). The test
  # asserting a surface therefore also proves afk reverts to one-shot and skips
  # the costly read.
  export CS_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 60 || fail "with .afk present the watcher did not exit one-shot for a benign signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "afk-mode watcher did not surface the signal for the daemon"
  grep "$(printf '\tsignal\t')" "$state/.wake-queue" | grep -F "task.status" >/dev/null \
    || fail "afk-mode benign signal was not queued for the daemon to classify"
  unset CS_FAKE_CREW_STATE
  pass "with .afk present the watcher reverts to one-shot so the daemon owns triage (no double-triage)"
}

# --- event splice: bounded native wait over a canned stream -------------------
# cs_watch_wait_transition is exercised offline by substituting the raw-socket
# reader (CS_HERDR_EVENT_READER) with a script replaying projected lines, the
# same seam firstmate's suite uses. Sourcing cs-watch.sh loads the functions
# and returns before the lock/loop.

test_event_splice_blocked_edge_and_dedupe_clear() {
  local dir state fakebin reader rec rc marker
  dir=$(make_case event-splice); state="$dir/state"; fakebin="$dir/fakebin"
  reader="$fakebin/fake-reader"

  # Reader 1: subscribes, then streams a blocked edge for pane-ev-1.
  cat > "$reader" <<'SH'
#!/usr/bin/env bash
# args: <socket> <timeout> <pane...>
echo "@subscribed"
printf 'pane-ev-1\tws-1\tblocked\tcodex\n'
sleep 5
exit 0
SH
  chmod +x "$reader"
  export CS_FAKE_HERDR_SOCKET="$dir/fake.sock"
  export CS_FAKE_HERDR_AGENT_STATUS=working   # level reconcile sees no blocked pane
  rec=$(
    cd "$dir" || exit 2
    # shellcheck disable=SC1090,SC1091
    PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" . "$WATCH"
    CS_HERDR_EVENT_READER="$reader" PATH="$fakebin:$PATH" cs_watch_wait_transition 5 "$state" pane-ev-1
  ); rc=$?
  expect_code 0 "$rc" "blocked stream edge did not return an actionable record"
  [ "$(printf '%s' "$rec" | cut -f1)" = pane-ev-1 ] || fail "record pane_id wrong: $rec"
  [ "$(printf '%s' "$rec" | cut -f4)" = blocked ] || fail "record to_status wrong: $rec"

  # Reader 2: a working edge only, then a clean full-budget end (exit 0). The
  # pre-seeded escalation marker must be CLEARED (so a later blocked edge
  # re-escalates) and the wait must report a clean timeout (rc 1).
  cat > "$reader" <<'SH'
#!/usr/bin/env bash
echo "@subscribed"
printf 'pane-ev-1\tws-1\tworking\tcodex\n'
sleep 0.3
exit 0
SH
  chmod +x "$reader"
  export CS_FAKE_HERDR_AGENT_STATUS=working
  marker="$state/.herdr-escalated-pane-ev-1"
  : > "$marker"
  rec=$(
    cd "$dir" || exit 2
    # shellcheck disable=SC1090,SC1091
    PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" . "$WATCH"
    CS_HERDR_EVENT_READER="$reader" PATH="$fakebin:$PATH" cs_watch_wait_transition 5 "$state" pane-ev-1
  ); rc=$?
  expect_code 1 "$rc" "clean full-budget wait did not return 1"
  [ ! -e "$marker" ] || fail "a working edge did not clear the escalation dedupe marker"

  # Reader 3: fails to subscribe (exit 2, no @subscribed). The event path must
  # report unusable (rc 2) so the caller sleeps and counts toward disable.
  cat > "$reader" <<'SH'
#!/usr/bin/env bash
exit 2
SH
  chmod +x "$reader"
  rec=$(
    cd "$dir" || exit 2
    # shellcheck disable=SC1090,SC1091
    PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" . "$WATCH"
    CS_HERDR_EVENT_READER="$reader" PATH="$fakebin:$PATH" cs_watch_wait_transition 5 "$state" pane-ev-1
  ); rc=$?
  expect_code 2 "$rc" "a failed subscribe did not report the event path unusable"
  unset CS_FAKE_HERDR_SOCKET CS_FAKE_HERDR_AGENT_STATUS
  pass "the event splice returns blocked edges, clears the dedupe marker on working, and fails closed on subscribe failure"
}

test_event_splice_level_reconcile_catches_already_blocked() {
  local dir state fakebin reader rec rc
  dir=$(make_case event-splice-level); state="$dir/state"; fakebin="$dir/fakebin"
  reader="$fakebin/fake-reader"
  # The stream stays silent; the pane is ALREADY blocked when the wait starts
  # (a gap edge). The level reconcile right after @subscribed must return it.
  cat > "$reader" <<'SH'
#!/usr/bin/env bash
echo "@subscribed"
sleep 5
exit 0
SH
  chmod +x "$reader"
  export CS_FAKE_HERDR_SOCKET="$dir/fake.sock"
  export CS_FAKE_HERDR_AGENT_STATUS=blocked
  rec=$(
    cd "$dir" || exit 2
    # shellcheck disable=SC1090,SC1091
    PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" . "$WATCH"
    CS_HERDR_EVENT_READER="$reader" PATH="$fakebin:$PATH" cs_watch_wait_transition 5 "$state" pane-lvl-1
  ); rc=$?
  expect_code 0 "$rc" "an already-blocked pane was not caught by the level reconcile"
  [ "$(printf '%s' "$rec" | cut -f1)" = pane-lvl-1 ] || fail "level record pane_id wrong: $rec"
  [ "$(printf '%s' "$rec" | cut -f4)" = blocked ] || fail "level record to_status wrong: $rec"
  unset CS_FAKE_HERDR_SOCKET CS_FAKE_HERDR_AGENT_STATUS
  pass "the level reconcile catches a pane already blocked when the subscription (re)connects"
}

# --- watcher singleton lock ---------------------------------------------------

test_duplicate_watcher_noops_through_singleton_lock() {
  local dir state fakebin out out2 pid i
  dir=$(make_case singleton-lock); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  # Quiet fleet: the first watcher blocks absorbing nothing.
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -e "$state/.watch.lock" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/.watch.lock" ] || { reap "$pid"; fail "first watcher never acquired the singleton lock"; }
  out2=$(env PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" \
    CS_CREW_STATE_BIN="$fakebin/cs-crew-state.sh" CS_HERDR_EVENTS_FORCE=0 \
    CS_POLL=1 CS_SIGNAL_GRACE=1 CS_CHECK_INTERVAL=999999 CS_HEARTBEAT=999999 "$WATCH") \
    || { reap "$pid"; fail "duplicate watcher invocation exited non-zero"; }
  case "$out2" in
    "watcher: already running"*) : ;;
    *) reap "$pid"; fail "duplicate watcher did not no-op through the singleton lock: $out2" ;;
  esac
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "the original watcher died when a duplicate ran"; }
  reap "$pid"
  pass "a duplicate watcher invocation no-ops through the singleton lock"
}

test_provably_working_signal_absorbed
test_turn_ended_provably_working_absorbed
test_turn_ended_not_working_surfaced
test_working_note_not_working_surfaced
test_actionable_signal_surfaced
test_terminal_stale_surfaced
test_live_headless_scout_stale_absorbed
test_terminal_headless_scout_surfaced
test_stale_terminal_status_overridden_by_active_run
test_nonterminal_stale_provably_working_absorbed_then_escalated
test_wedge_escalation_marks_demand_deep_inspection_after_threshold
test_nonterminal_stale_not_working_surfaced
test_nonterminal_stale_paused_absorbed_then_resurfaced
test_blocked_pane_surfaces_immediately
test_blocked_pane_declared_pause_absorbed
test_registered_check_runs_from_snapshot
test_unauthenticated_check_rejected_without_execution
test_tampered_registered_check_rejected
test_heartbeat_no_change_absorbed
test_heartbeat_backstop_surfaces_unsurfaced_status
test_beacon_stays_fresh_while_absorbing
test_afk_present_reverts_watcher_to_one_shot
test_event_splice_blocked_edge_and_dedupe_clear
test_event_splice_level_reconcile_catches_already_blocked
test_duplicate_watcher_noops_through_singleton_lock
