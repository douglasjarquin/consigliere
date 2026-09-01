#!/usr/bin/env bash
# tests/cs-watch-triage.test.sh - the always-on wake triage built into
# bin/cs-watch.sh over the shared classifier (bin/cs-classify-lib.sh). The
# watcher absorbs the benign majority of wakes in bash and exits ONLY on an
# actionable wake, so consigliere's LLM re-arms once per actionable event
# instead of once per wake. These tests drive a real cs-watch.sh subprocess
# offline (fake herdr + fake cs-crew-state.sh) to assert the behavioral
# contract: provably-working no-verb wakes absorbed (no exit, no queue entry,
# suppressor advanced, beacon fresh), stopped-soldier no-verb wakes surfaced
# (queue + exit), the coalescing grace chosen by whether the first scan already
# carries a boss verb, provably-working stale panes absorbed-then-escalated past the
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
  # Absorb is proven by the .seen-* suppressor appearing (the cycle processed and
  # absorbed the signal) with the watcher still alive; poll for it instead of
  # blindly waiting a fixed window.
  if ! absorbed_alive "$pid" "$state/.seen-task_status"; then
    reap "$pid"; fail "watcher exited or never absorbed a working: signal whose soldier is provably working: $(cat "$out")"
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
  if ! absorbed_alive "$pid" "$state/.seen-task_turn-ended"; then
    reap "$pid"; fail "watcher exited or never absorbed a turn-end whose soldier is provably working: $(cat "$out")"
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
  wait_for_exit "$pid" || fail "watcher did not surface a turn-end whose soldier is not provably working"
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
  wait_for_exit "$pid" || fail "watcher did not surface a working: note whose soldier has no running pipeline and an idle pane"
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
  wait_for_exit "$pid" || fail "watcher did not exit for an actionable needs-decision signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the actionable signal reason"
  grep "$(printf '\tsignal\t')" "$state/.wake-queue" | grep -F "task.status" >/dev/null \
    || fail "actionable signal was not queued"
  [ -s "$state/.hb-surfaced-task" ] || fail "actionable signal did not record the surfaced marker"
  pass "boss-relevant signal is surfaced (queue + exit) and marked surfaced"
}

# A committed-but-unreviewed no-mistakes lane must SURFACE, not be absorbed.
# This is the enforcement half of the pre-validation review: the soldier stops
# and waits for consigliere, and the watcher has to treat that as actionable.
# Before the verb existed the soldier wrote `done:` here, which reads as a
# finished lane, so a skipped review produced no pressure at all - niceuptime-590
# idled 56m on 2026-08-02 with its wakes delivered and nobody acting.
test_needs_review_signal_surfaced() {
  local dir state fakebin out status_file pid
  dir=$(make_case needs-review-signal); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: setup\nneeds-review: flag retired; awaiting review before validation\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" || fail "watcher did not exit for an actionable needs-review signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the needs-review signal reason"
  grep "$(printf '\tsignal\t')" "$state/.wake-queue" | grep -F "task.status" >/dev/null \
    || fail "needs-review signal was not queued"
  pass "a committed-but-unreviewed lane is surfaced, never absorbed"
}

# --- the coalescing grace is chosen by what the first scan already proves ------

test_boss_verb_signal_takes_the_short_grace() {
  local dir state fakebin out status_file pid
  dir=$(make_case boss-verb-short-grace); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'needs-decision: pick A or B\n' > "$status_file"
  # A boss-relevant verb is already present, so the re-scan cannot change the
  # verdict and only the turn-end coalescing is still worth waiting for. With a
  # long no-verb grace deliberately configured, exiting inside the short window
  # proves the grace was selected by the verb and not applied unconditionally.
  watch_bg "$state" "$fakebin" "$out" CS_SIGNAL_GRACE=30 CS_SIGNAL_GRACE_ACTIONABLE=1
  pid=$!
  wait_for_exit "$pid" \
    || fail "a boss-relevant signal waited the long no-verb grace instead of the short one"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the actionable signal reason"
  pass "a signal already carrying a boss verb takes the short coalescing grace"
}

test_no_verb_signal_keeps_the_long_grace() {
  local dir state fakebin out status_file pid
  dir=$(make_case no-verb-long-grace); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # A no-verb signal from a soldier that is NOT provably working WILL surface,
  # but only after the full grace: that window is what gives a boss-relevant
  # line time to land and turn a costly triage into a single wake. Still being
  # alive well inside the window is the assertion.
  export CS_FAKE_CREW_STATE='state: unknown · source: none · stopped turn'
  watch_bg "$state" "$fakebin" "$out" CS_SIGNAL_GRACE=30 CS_SIGNAL_GRACE_ACTIONABLE=1
  pid=$!
  wait_live "$pid" 30 || fail "a no-verb signal surfaced early; the long grace was not preserved"
  reap "$pid"
  unset CS_FAKE_CREW_STATE
  pass "a no-verb signal keeps the full grace so a late boss verb can still coalesce"
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
  wait_for_exit "$pid" || fail "watcher did not exit for a stale pane on a terminal status"
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
  if ! absorbed_alive "$pid" "$state/.last-watcher-beat"; then
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
  wait_for_exit "$pid" || fail "watcher did not exit for a terminal headless scout"
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
  if ! absorbed_alive "$pid" "$state/.stale-since-$key"; then
    reap "$pid"; fail "watcher exited or never recorded the stale timer for a terminal-looking status the run-step overrides (should absorb): $(cat "$out")"
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
  wait_for_exit "$pid" || fail "watcher did not escalate an overridden stale terminal status past the threshold"
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
  if ! absorbed_alive "$pid" "$state/.stale-since-$key"; then
    reap "$pid"; fail "watcher exited or never recorded the stale timer for a fresh provably-working non-terminal stale (should absorb): $(cat "$out")"
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
  wait_for_exit "$pid" || fail "watcher did not escalate a provably-working non-terminal stale past the threshold"
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
  if ! absorbed_alive "$pid" "$state/.stale-since-$key"; then
    reap "$pid"; fail "watcher exited or never recorded the stale timer on the priming round (should absorb): $(cat "$out")"
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
    wait_for_exit "$pid" || fail "watcher did not escalate on consecutive wedge round $n: $(cat "$out")"
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
  wait_for_exit "$pid" || fail "watcher did not surface a not-provably-working non-terminal stale at once"
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
  if ! absorbed_alive "$pid" "$state/.paused-$key"; then
    reap "$pid"; fail "watcher exited or never recorded the paused flag for a fresh declared pause (should absorb): $(cat "$out")"
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
  wait_for_exit "$pid" || fail "watcher did not re-surface a declared pause past the threshold"
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
  wait_for_exit "$pid" || fail "watcher did not surface a native blocked pane immediately"
  grep -F "stale: $pane (herdr: agent blocked - waiting on human, escalated immediately, not via wedge timer)" "$out" >/dev/null \
    || fail "blocked pane did not print the immediate escalation reason: $(cat "$out")"
  [ -e "$state/.herdr-escalated-$key" ] || fail "blocked escalation did not commit its dedupe marker"
  [ "$(count_wakes "$state" stale "$pane")" -eq 1 ] || fail "blocked escalation was not queued exactly once"

  # Re-arm with the pane still blocked: the committed marker dedupes, so the
  # watcher absorbs (no second wake) instead of flooding one wake per poll.
  : > "$out"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! absorbed_alive "$pid" "$state/.last-watcher-beat"; then
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
  if ! absorbed_alive "$pid" "$state/.herdr-escalated-$key"; then
    reap "$pid"; fail "watcher escalated a blocked pane under a declared pause, or never committed the dedupe marker (should absorb): $(cat "$out")"
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
  wait_for_exit "$pid" || fail "watcher did not surface a registered check's output"
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
  wait_for_exit "$pid" || fail "watcher did not surface the unauthenticated-check rejection"
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
  wait_for_exit "$pid" || fail "watcher did not surface the tampered-check rejection"
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
  if ! absorbed_alive "$pid" "$state/.heartbeat-streak"; then
    reap "$pid"; fail "watcher exited or never advanced the heartbeat streak for a no-change heartbeat (should absorb): $(cat "$out")"
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
  wait_for_exit "$pid" || fail "heartbeat backstop did not surface an unsurfaced boss-relevant status"
  grep -Fx "heartbeat" "$out" >/dev/null || fail "backstop did not exit with a heartbeat wake: $(cat "$out")"
  [ "$(cat "$state/.hb-surfaced-miss" 2>/dev/null || true)" = "done: PR https://example.test/pr/5" ] \
    || fail "backstop did not record the status as surfaced (would re-fire next heartbeat)"
  grep "$(printf '\theartbeat\t')" "$state/.wake-queue" >/dev/null || fail "backstop heartbeat was not queued"
  pass "heartbeat backstop fail-safe surfaces a boss-relevant status the per-wake path missed"
}

# --- a busy pane whose turn never ends is bounded -----------------------------
#
# A busy pane is otherwise unconditional, unbounded proof of liveness: the whole
# stale/wedge path is skipped while the pane looks busy, and a busy pane's hash
# keeps changing anyway (the harness renders a ticking elapsed counter), so no
# stale hash ever repeats and the timer is unreachable by construction. A hung
# foreground tool call therefore stays invisible for as long as it hangs.
# CS_BUSY_TURN_MAX_SECS bounds busy-with-no-completed-turn instead.

# The rendered footer both harnesses show during a live turn; pane_is_busy
# matches it when the native agent read is ambiguous.
BUSY_PANE_TEXT='running the test suite
esc to interrupt'

test_busy_pane_within_the_turn_bound_is_left_alone() {
  local dir state fakebin out capture_file pane key pid
  dir=$(make_case busy-within-bound); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  pane="pane-busy-ok"
  key=$(pane_key "$pane")
  printf '%s' "$BUSY_PANE_TEXT" > "$capture_file"
  cs_write_meta "$state/busyok.meta" "pane=$pane" "kind=ship"
  printf 'working: compiling\n' > "$state/busyok.status"
  printf '%s' "$(seen_sig "$state/busyok.status")" > "$state/.seen-busyok_status"
  # A turn completed moments ago: this is ordinary work, not a wedge. Prime its
  # seen-marker too, so the ordinary turn-end signal path stays out of the way
  # and this test isolates the busy-turn bound.
  : > "$state/busyok.turn-ended"
  printf '%s' "$(seen_sig "$state/busyok.turn-ended")" > "$state/.seen-busyok_turn-ended"
  export CS_FAKE_HERDR_CAPTURE="$capture_file"

  watch_bg "$state" "$fakebin" "$out" CS_BUSY_TURN_MAX_SECS=3600
  pid=$!
  absorbed_alive "$pid" "$state/.last-watcher-beat" ||
    { reap "$pid"; fail "watcher exited on an ordinary busy pane: $(cat "$out")"; }
  [ ! -e "$state/.busy-turn-since-$key" ] ||
    { reap "$pid"; fail "a busy pane within the turn bound must not start a wedge timer"; }
  [ ! -s "$state/.wake-queue" ] ||
    { reap "$pid"; fail "a busy pane within the turn bound must not enqueue a wake"; }
  reap "$pid"
  unset CS_FAKE_HERDR_CAPTURE
  pass "a busy pane whose turn completed recently is left alone"
}

test_busy_pane_past_the_turn_bound_wedge_escalates() {
  local dir state fakebin out capture_file pane key pid
  dir=$(make_case busy-past-bound); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  pane="pane-busy-hung"
  key=$(pane_key "$pane")
  printf '%s' "$BUSY_PANE_TEXT" > "$capture_file"
  cs_write_meta "$state/hung.meta" "pane=$pane" "kind=ship"
  printf 'working: running the suite\n' > "$state/hung.status"
  printf '%s' "$(seen_sig "$state/hung.status")" > "$state/.seen-hung_status"
  # The pane has looked busy for two hours without ever completing a turn - the
  # signature of a hung foreground tool call behind a live-looking footer.
  : > "$state/hung.turn-ended"
  backdate "$state/hung.turn-ended" 7200
  printf '%s' "$(seen_sig "$state/hung.turn-ended")" > "$state/.seen-hung_turn-ended"
  export CS_FAKE_HERDR_CAPTURE="$capture_file"

  # Phase A: past the bound, so the wedge timer starts - but absorbed for now.
  watch_bg "$state" "$fakebin" "$out" CS_BUSY_TURN_MAX_SECS=3600 CS_STALE_ESCALATE_SECS=999
  pid=$!
  if ! absorbed_alive "$pid" "$state/.busy-turn-since-$key"; then
    reap "$pid"; fail "a busy pane past the turn bound did not start a wedge timer: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] ||
    { reap "$pid"; fail "the busy-turn bound surfaced before its wedge threshold elapsed"; }
  reap "$pid"

  # Phase B: the wedge timer itself elapses; now it must escalate.
  echo $(( $(date +%s) - 500 )) > "$state/.busy-turn-since-$key"
  : > "$out"
  watch_bg "$state" "$fakebin" "$out" CS_BUSY_TURN_MAX_SECS=3600 CS_STALE_ESCALATE_SECS=240
  pid=$!
  wait_for_exit "$pid" ||
    fail "watcher did not escalate a busy pane hung past the turn bound"
  grep -F "stale: $pane" "$out" >/dev/null ||
    fail "the busy-turn escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null ||
    fail "the busy-turn escalation did not flag a possible wedge"
  [ "$(count_wakes "$state" stale "$pane")" -ge 1 ] ||
    fail "the busy-turn escalation was not queued durably"
  unset CS_FAKE_HERDR_CAPTURE
  pass "a busy pane with no completed turn past the bound wedge-escalates for inspection"
}

test_completed_turn_resets_the_busy_bound() {
  local dir state fakebin out capture_file pane key pid
  dir=$(make_case busy-turn-reset); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  pane="pane-busy-resumed"
  key=$(pane_key "$pane")
  printf '%s' "$BUSY_PANE_TEXT" > "$capture_file"
  cs_write_meta "$state/resumed.meta" "pane=$pane" "kind=ship"
  printf 'working: back at it\n' > "$state/resumed.status"
  printf '%s' "$(seen_sig "$state/resumed.status")" > "$state/.seen-resumed_status"
  # A wedge timer is already running from an earlier hung stretch...
  echo $(( $(date +%s) - 500 )) > "$state/.busy-turn-since-$key"
  # ...but a turn has since COMPLETED, so the pane is demonstrably taking turns.
  : > "$state/resumed.turn-ended"
  printf '%s' "$(seen_sig "$state/resumed.turn-ended")" > "$state/.seen-resumed_turn-ended"
  export CS_FAKE_HERDR_CAPTURE="$capture_file"

  # A threshold this low would escalate instantly if the timer were still live.
  watch_bg "$state" "$fakebin" "$out" CS_BUSY_TURN_MAX_SECS=3600 CS_STALE_ESCALATE_SECS=1
  pid=$!
  # Wait on the condition itself: the beacon is written before the stale loop
  # reaches this pane, so beacon-then-check would race the first cycle.
  wait_until "$CS_WATCH_TEST_TICKS" test ! -e "$state/.busy-turn-since-$key" ||
    { reap "$pid"; fail "a completed turn must clear the busy-turn wedge timer"; }
  kill -0 "$pid" 2>/dev/null ||
    { fail "watcher exited after a completed turn should have cleared the bound: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] ||
    { reap "$pid"; fail "a completed turn must not leave the busy-turn escalation armed"; }
  reap "$pid"
  unset CS_FAKE_HERDR_CAPTURE
  pass "a completed turn resets the busy-turn bound"
}

# --- beacon stays fresh while absorbing ---------------------------------------

test_beacon_stays_fresh_while_absorbing() {
  local dir state fakebin out status_file pid m1 m2
  dir=$(make_case beacon-fresh); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: a\n' > "$status_file"
  # Provably working so the working: notes are absorbed (the path that must keep
  # the beacon fresh).
  export CS_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  absorbed_alive "$pid" "$state/.last-watcher-beat" || { reap "$pid"; fail "watcher exited while absorbing the first benign signal"; }
  m1=$(file_mtime "$state/.last-watcher-beat")
  [ -n "$m1" ] || { reap "$pid"; fail "watcher beacon missing while absorbing"; }
  # A second benign signal keeps it absorbing; the beacon must keep ADVANCING.
  #
  # Wait for the advance rather than checking the beacon's absolute age. The age
  # form (`date +%s` here minus an mtime stamped over there) had a hard 10s cliff
  # that any clock advance while the watcher was descheduled would fail, and it
  # proved less: `.last-watcher-beat` already exists from the first cycle, so an
  # absorbed_alive on it returned instantly without ever showing a second cycle
  # ran. wait_mtime_after shows exactly that.
  printf 'working: b\n' >> "$status_file"
  wait_mtime_after "$state/.last-watcher-beat" "$m1" \
    || { reap "$pid"; fail "the watcher stopped advancing its liveness beacon while absorbing a second benign signal"; }
  is_live_non_zombie "$pid" || { reap "$pid"; fail "watcher exited while absorbing a second benign signal"; }
  m2=$(file_mtime "$state/.last-watcher-beat")
  [ -n "$m2" ] || { reap "$pid"; fail "watcher beacon missing while absorbing"; }
  [ "$m2" -gt "$m1" ] || { reap "$pid"; fail "beacon did not advance while absorbing ($m1 -> $m2)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "absorbing benign signals enqueued a wake"; }
  reap "$pid"
  unset CS_FAKE_CREW_STATE
  pass "the liveness beacon stays fresh while the watcher absorbs benign wakes (guards never false-alarm)"
}

# --- event splice: bounded wait over the plugin event spool -------------------
# cs_watch_wait_transition drains <state>/.herdr-events, the durable spool
# herdr's server-side plugin hook appends to (bin/cs-herdr-event-lib.sh). A test
# writes spool records directly, which is exactly what the hook does. Sourcing
# cs-watch.sh loads the functions and returns before the lock/loop.

spool_append() {  # <state> <kind> <pane> <workspace> <field3> <field4>
  local state=$1; shift
  local pane=$2 workspace=$3 agent=$5 home meta
  home=${state%/state}
  meta="$state/$pane.meta"
  if [ ! -e "$meta" ] && [ "$pane" != pane-other-1 ]; then
    cat > "$meta" <<EOF
task_id=$pane
kind=ship
home=$home
worktree=$home
workspace=$workspace
pane=$pane
harness=$agent
parent_task_id=root
parent_home=$home
parent_state=$state
parent_pane=unknown
parent_generation=event-parent-generation
endpoint_generation=event-generation
herdr_session=default
EOF
  fi
  # shellcheck source=bin/cs-herdr-event-lib.sh
  . "$ROOT/bin/cs-herdr-event-lib.sh"
  cs_event_append "$(cs_event_spool_path "$state")" \
    "$(cs_event_record_with_generation "$@" event-generation)"
}

test_event_splice_blocked_edge_and_dedupe_clear() {
  local dir state fakebin rec rc marker
  dir=$(make_case event-splice); state="$dir/state"; fakebin="$dir/fakebin"
  export CS_FAKE_HERDR_AGENT_STATUS=working   # level reconcile sees no blocked pane

  spool_append "$state" status pane-ev-1 ws-1 blocked codex
  rec=$(
    cd "$dir" || exit 2
    # shellcheck disable=SC1090,SC1091
    PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" . "$WATCH"
    PATH="$fakebin:$PATH" cs_watch_wait_transition 1 "$state" pane-ev-1
  ); rc=$?
  expect_code 0 "$rc" "a spooled blocked edge did not return an actionable record"
  [ "$(printf '%s' "$rec" | cut -f1)" = pane-ev-1 ] || fail "record pane_id wrong: $rec"
  [ "$(printf '%s' "$rec" | cut -f4)" = blocked ] || fail "record to_status wrong: $rec"

  # A working edge only: the pre-seeded escalation marker must be CLEARED (so a
  # later blocked edge re-escalates) and the wait must report a clean timeout.
  export CS_FAKE_HERDR_AGENT_STATUS=idle
  marker="$state/.herdr-escalated-pane-ev-1"
  : > "$marker"
  spool_append "$state" status pane-ev-1 ws-1 working codex
  rec=$(
    cd "$dir" || exit 2
    # shellcheck disable=SC1090,SC1091
    PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" . "$WATCH"
    PATH="$fakebin:$PATH" cs_watch_wait_transition 1 "$state" pane-ev-1
  ); rc=$?
  expect_code 1 "$rc" "clean full-budget wait did not return 1"
  [ ! -e "$marker" ] || fail "a working edge did not clear the escalation dedupe marker"
  unset CS_FAKE_HERDR_AGENT_STATUS
  pass "the event splice returns spooled blocked edges and clears the dedupe marker on working"
}

# Records for one pane inside a single drained batch are in time order, so a
# `working` edge behind a `blocked` edge means the pane is no longer waiting on
# the human. Escalating the superseded `blocked` would wake the boss for nothing
# AND arm that pane's dedupe marker with no `working` edge left to clear it,
# which would then suppress the pane's next genuine block on the fast path.
test_event_splice_supersedes_a_blocked_edge_within_one_batch() {
  local dir state fakebin rec rc marker
  dir=$(make_case event-supersede); state="$dir/state"; fakebin="$dir/fakebin"
  export CS_FAKE_HERDR_AGENT_STATUS=working   # level reconcile sees no blocked pane

  spool_append "$state" status pane-sup-1 ws-1 blocked codex
  spool_append "$state" status pane-sup-1 ws-1 working codex
  rec=$(
    cd "$dir" || exit 2
    # shellcheck disable=SC1090,SC1091
    PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" . "$WATCH"
    PATH="$fakebin:$PATH" cs_watch_wait_transition 1 "$state" pane-sup-1
  ); rc=$?
  expect_code 1 "$rc" "a blocked edge superseded by a working edge in the same batch was escalated"
  [ -z "$rec" ] || fail "a superseded blocked edge produced a record: $rec"
  marker="$state/.herdr-escalated-pane-sup-1"
  [ ! -e "$marker" ] || fail "a superseded escalation left the dedupe marker armed"

  # The pane is genuinely blocked again on a later batch: the fast path must
  # still escalate it, which is exactly what an armed marker would have blocked.
  spool_append "$state" status pane-sup-1 ws-1 blocked codex
  rec=$(
    cd "$dir" || exit 2
    # shellcheck disable=SC1090,SC1091
    PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" . "$WATCH"
    PATH="$fakebin:$PATH" cs_watch_wait_transition 1 "$state" pane-sup-1
  ); rc=$?
  expect_code 0 "$rc" "the next genuine block after a superseded edge was not escalated"
  [ "$(printf '%s' "$rec" | cut -f1)" = pane-sup-1 ] || fail "re-block record pane_id wrong: $rec"

  # A hold for a DIFFERENT pane is untouched by the supersede.
  dir=$(make_case event-supersede-other); state="$dir/state"; fakebin="$dir/fakebin"
  spool_append "$state" status pane-sup-1 ws-1 blocked codex
  spool_append "$state" status pane-sup-1 ws-1 working codex
  spool_append "$state" status pane-sup-2 ws-1 blocked claude
  rec=$(
    cd "$dir" || exit 2
    # shellcheck disable=SC1090,SC1091
    PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" . "$WATCH"
    PATH="$fakebin:$PATH" cs_watch_wait_transition 1 "$state" pane-sup-1 pane-sup-2
  ); rc=$?
  expect_code 0 "$rc" "a second pane's blocked edge in the same batch was lost"
  [ "$(printf '%s' "$rec" | cut -f1)" = pane-sup-2 ] || fail "expected the other pane's record, got: $rec"
  [ ! -e "$state/.herdr-escalated-pane-sup-1" ] \
    || fail "the superseded pane's marker was armed while another pane escalated"

  # The same batch with the superseded pane's records BRACKETING the other
  # pane's block: the second pane's escalation was already held when the
  # supersede arrived, so a per-batch (rather than per-pane) hold would drop a
  # genuine block and cost a full poll cycle to recover it.
  dir=$(make_case event-supersede-bracket); state="$dir/state"; fakebin="$dir/fakebin"
  spool_append "$state" status pane-sup-1 ws-1 blocked codex
  spool_append "$state" status pane-sup-2 ws-1 blocked claude
  spool_append "$state" status pane-sup-1 ws-1 working codex
  rec=$(
    cd "$dir" || exit 2
    # shellcheck disable=SC1090,SC1091
    PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" . "$WATCH"
    PATH="$fakebin:$PATH" cs_watch_wait_transition 1 "$state" pane-sup-1 pane-sup-2
  ); rc=$?
  expect_code 0 "$rc" "a blocked edge bracketed by a superseded pane's edges was lost"
  [ "$(printf '%s' "$rec" | cut -f1)" = pane-sup-2 ] || fail "expected the bracketed pane's record, got: $rec"
  [ "$(printf '%s' "$rec" | cut -f4)" = blocked ] || fail "bracketed record to_status wrong: $rec"
  [ ! -e "$state/.herdr-escalated-pane-sup-1" ] \
    || fail "the superseded pane's marker was armed in the bracketed order"
  # The caller commits the escalated pane's marker, not the wait.
  [ ! -e "$state/.herdr-escalated-pane-sup-2" ] \
    || fail "the wait committed the escalated pane's dedupe marker itself"
  unset CS_FAKE_HERDR_AGENT_STATUS
  pass "a working edge behind a blocked edge in one batch cancels that pane's escalation"
}

test_event_splice_without_the_plugin_falls_back_to_polling() {
  local dir state fakebin rec rc
  dir=$(make_case event-nopluging); state="$dir/state"; fakebin="$dir/fakebin"
  export CS_FAKE_HERDR_AGENT_STATUS=working
  # No spool: this machine has no event plugin installed. The wait must report
  # the transport unusable so the caller sleeps its own budget - supervision
  # continues on the poll loop, which is the permanent fail-closed backstop.
  rec=$(
    cd "$dir" || exit 2
    # shellcheck disable=SC1090,SC1091
    PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" . "$WATCH"
    PATH="$fakebin:$PATH" cs_watch_wait_transition 1 "$state" pane-ev-1
  ); rc=$?
  expect_code 2 "$rc" "an absent event spool must report the transport unusable"
  [ -z "$rec" ] || fail "an absent transport produced a record: $rec"
  unset CS_FAKE_HERDR_AGENT_STATUS
  pass "a machine without the event plugin falls back to the poll loop instead of failing"
}

test_event_splice_drains_edges_that_fired_with_no_watcher_running() {
  local dir state fakebin rec rc
  dir=$(make_case event-durable); state="$dir/state"; fakebin="$dir/fakebin"
  export CS_FAKE_HERDR_AGENT_STATUS=working   # the pane is NO LONGER blocked now
  # THE gain over the in-watcher subscriber: the hook runs in herdr's process, so
  # a soldier that blocked while the watcher was down still has its edge waiting
  # in the spool. A level read at start would miss it (the pane has moved on);
  # the spool cannot.
  spool_append "$state" status pane-gap-1 ws-1 blocked claude
  rec=$(
    cd "$dir" || exit 2
    # shellcheck disable=SC1090,SC1091
    PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" . "$WATCH"
    PATH="$fakebin:$PATH" cs_watch_wait_transition 1 "$state" pane-gap-1
  ); rc=$?
  expect_code 0 "$rc" "an edge spooled while no watcher ran was not delivered"
  [ "$(printf '%s' "$rec" | cut -f1)" = pane-gap-1 ] || fail "gap record pane_id wrong: $rec"
  unset CS_FAKE_HERDR_AGENT_STATUS
  pass "edges that fired while no watcher was running are still delivered on the next wait"
}

test_event_splice_level_reconcile_catches_already_blocked() {
  local dir state fakebin rec rc
  dir=$(make_case event-splice-level); state="$dir/state"; fakebin="$dir/fakebin"
  # The spool stays empty; the pane is ALREADY blocked when the wait starts (an
  # edge lost while the plugin was absent). The level reconcile must return it.
  spool_append "$state" status pane-other-1 ws-1 working codex
  spool_append "$state" status pane-lvl-1 ws-1 working codex
  export CS_FAKE_HERDR_AGENT_STATUS=blocked
  export CS_FAKE_HERDR_PANE_CWD="$dir"
  rec=$(
    cd "$dir" || exit 2
    # shellcheck disable=SC1090,SC1091
    PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" . "$WATCH"
    PATH="$fakebin:$PATH" cs_watch_wait_transition 1 "$state" pane-lvl-1
  ); rc=$?
  expect_code 0 "$rc" "an already-blocked pane was not caught by the level reconcile"
  [ "$(printf '%s' "$rec" | cut -f1)" = pane-lvl-1 ] || fail "level record pane_id wrong: $rec"
  [ "$(printf '%s' "$rec" | cut -f4)" = blocked ] || fail "level record to_status wrong: $rec"
  unset CS_FAKE_HERDR_AGENT_STATUS
  unset CS_FAKE_HERDR_PANE_CWD
  pass "the level reconcile catches a pane already blocked when the wait starts"
}

test_event_splice_ignores_foreign_panes_and_unknown_kinds() {
  local dir state fakebin rec rc
  dir=$(make_case event-kinds); state="$dir/state"; fakebin="$dir/fakebin"
  export CS_FAKE_HERDR_AGENT_STATUS=working

  # The spool carries EVERY pane on the machine (one herdr server, one plugin
  # hook per home), so an edge for a pane this home does not supervise - another
  # home's soldier, the boss's own pane - must be consumed and ignored.
  spool_append "$state" status pane-foreign-1 ws-9 blocked claude
  # An unknown kind is IGNORED, never misread as a status edge, which is what
  # lets the hook add a kind before this side knows about it.
  spool_append "$state" brand-new-kind pane-ev-9 ws-1 blocked codex
  rec=$(
    cd "$dir" || exit 2
    # shellcheck disable=SC1090,SC1091
    PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" . "$WATCH"
    PATH="$fakebin:$PATH" cs_watch_wait_transition 1 "$state" pane-ev-9
  ); rc=$?
  expect_code 1 "$rc" "a foreign pane or unknown kind must leave a clean bounded wait"
  [ -z "$rec" ] || fail "a foreign pane or unknown kind produced a record: $rec"
  unset CS_FAKE_HERDR_AGENT_STATUS
  pass "the splice ignores panes this home does not supervise and kinds it does not know"
}

test_snapshot_answers_panes_and_absence_falls_back() {
  local dir state fakebin out pid
  dir=$(make_case snapshot-path); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  # The discriminator: the snapshot says working while a per-pane `agent get`
  # would say idle. A busy read can therefore only have come from the snapshot.
  printf 'working: long tool call\n' > "$state/snap.status"
  cs_write_meta "$state/snap.meta" "pane=pane-snap" "kind=ship"
  export CS_FAKE_HERDR_AGENT_STATUS=idle
  export CS_FAKE_HERDR_SNAPSHOT_PANE=pane-snap
  export CS_FAKE_HERDR_SNAPSHOT_STATUS=working
  export CS_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  # A pane the snapshot reports as working is provably working, so a no-verb
  # signal is absorbed: the watcher keeps running and advances its suppressor.
  wait_until "$CS_WATCH_TEST_TICKS" test -e "$state/.seen-snap_status" \
    || { kill "$pid" 2>/dev/null; cat "$out"; fail "the snapshot-sourced status never drove a cycle"; }
  wait_live "$pid" 10 || { cat "$out"; fail "a snapshot-working pane must not surface a wake"; }
  kill "$pid" 2>/dev/null || true
  pass "the per-cycle snapshot answers pane status without a per-pane query"

  # A pane ABSENT from the snapshot must fall back to asking directly, never be
  # read as a negative: it may simply have been created after the snapshot.
  dir=$(make_case snapshot-absent); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  printf 'needs-decision: pick one\n' > "$state/other.status"
  cs_write_meta "$state/other.meta" "pane=pane-other" "kind=ship"
  export CS_FAKE_HERDR_SNAPSHOT_PANE=pane-not-this-one
  export CS_FAKE_HERDR_SNAPSHOT_STATUS=working
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_until "$CS_WATCH_TEST_TICKS" grep -q '^signal:' "$out" \
    || { kill "$pid" 2>/dev/null; cat "$out"; fail "a pane absent from the snapshot must still be evaluated directly"; }
  kill "$pid" 2>/dev/null || true
  unset CS_FAKE_HERDR_SNAPSHOT_PANE CS_FAKE_HERDR_SNAPSHOT_STATUS
  pass "a pane absent from the snapshot falls back to a direct query"
}

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

# --- capo-side worker events are read directly, not waited on ----------------

test_capo_worker_event_surfaced_without_the_capo_taking_a_turn() {
  local dir state fakebin out capo pid
  dir=$(make_case capo-worker-event); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  # A capo home this parent owns, with a worker parked on a boss-relevant event.
  # Nothing in that home is polling - its agent is mid-turn - so the parent has
  # to find this itself instead of waiting to be told.
  capo="$dir/capo-home"
  mkdir -p "$capo/state"
  : > "$capo/.cs-capo-home"
  printf 'blocked: pipeline is reverting an approved decision\n' > "$capo/state/w-546.status"
  cs_write_meta "$state/mycapo.meta" "kind=capo" "home=$capo"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_until "$CS_WATCH_TEST_TICKS" grep -q '^capo:' "$out" \
    || { kill "$pid" 2>/dev/null; cat "$out"; fail "capo-side worker event was never surfaced"; }
  grep -F 'mycapo/w-546' "$out" >/dev/null || { cat "$out"; fail "the wake must name the capo and its worker"; }
  grep -F 'reverting an approved decision' "$out" >/dev/null || fail "the wake must carry the worker's own line"
  grep "$(printf '\tcapo\t')" "$state/.wake-queue" | grep -F 'mycapo/w-546' >/dev/null \
    || { cat "$state/.wake-queue"; fail "capo wake must be durably queued"; }
  [ -s "$state/.capo-surfaced-mycapo__w-546" ] || fail "the surfaced marker must be written"
  kill "$pid" 2>/dev/null || true
  pass "a boss-relevant capo worker event surfaces without the capo taking a turn"
}

test_capo_worker_event_deduped_and_scoped() {
  local dir state fakebin out capo pid
  dir=$(make_case capo-worker-dedupe); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  capo="$dir/capo-home"
  mkdir -p "$capo/state"
  : > "$capo/.cs-capo-home"
  printf 'blocked: still the same block\n' > "$capo/state/w-1.status"
  # Already surfaced: a standing block must not re-wake every poll.
  printf 'default\tblocked\tstill the same block' > "$state/.capo-surfaced-mycapo__w-1"
  # A working: line is not boss-relevant, and a directory without the capo-home
  # marker is not a capo home at all - neither may produce a wake.
  printf 'working: mid-run\n' > "$capo/state/w-2.status"
  cs_write_meta "$state/mycapo.meta" "kind=capo" "home=$capo"
  mkdir -p "$dir/not-a-capo/state"
  printf 'blocked: must never be read\n' > "$dir/not-a-capo/state/w-9.status"
  cs_write_meta "$state/bogus.meta" "kind=capo" "home=$dir/not-a-capo"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_live "$pid" 25 || { cat "$out"; fail "an already-surfaced capo block must not wake the watcher"; }
  kill "$pid" 2>/dev/null || true
  ! grep -q '^capo:' "$out" || { cat "$out"; fail "surfaced, non-boss-relevant, and unmarked-home cases must all stay quiet"; }
  ! grep -q 'must never be read' "$out" || fail "a home without the capo-home marker must never be read"
  pass "capo worker events dedupe on the surfaced line and skip unmarked homes"
}

test_capo_worker_decision_survives_a_later_working_append() {
  local dir state fakebin out capo pid
  dir=$(make_case capo-worker-fold-survives); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  capo="$dir/capo-home"
  mkdir -p "$capo/state"
  : > "$capo/.cs-capo-home"
  printf 'needs-decision [key=fix-a]: pick an approach\nworking: continuing\n' > "$capo/state/w-1.status"
  cs_write_meta "$state/mycapo.meta" "kind=capo" "home=$capo"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_until "$CS_WATCH_TEST_TICKS" grep -q '^capo:' "$out" \
    || { kill "$pid" 2>/dev/null; cat "$out"; fail "a decision masked by a later working: append was never surfaced"; }
  grep -F 'pick an approach' "$out" >/dev/null || { cat "$out"; fail "the wake must still carry the open decision's own text"; }
  kill "$pid" 2>/dev/null || true
  pass "a capo decision survives a later working: append (the exact overnight bug class)"
}

test_capo_worker_resolved_decision_does_not_resurface() {
  local dir state fakebin out capo pid
  dir=$(make_case capo-worker-fold-resolved-quiet); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  capo="$dir/capo-home"
  mkdir -p "$capo/state"
  : > "$capo/.cs-capo-home"
  printf 'needs-decision [key=fix-a]: pick an approach\nresolved [key=fix-a]: answered via cs-send: use option B\n' \
    > "$capo/state/w-1.status"
  cs_write_meta "$state/mycapo.meta" "kind=capo" "home=$capo"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_live "$pid" 25 || { cat "$out"; fail "a resolved decision must not resurface as a capo wake"; }
  kill "$pid" 2>/dev/null || true
  ! grep -q '^capo:' "$out" || { cat "$out"; fail "a resolved decision must not resurface"; }
  pass "a resolved capo decision does not resurface"
}

test_capo_worker_identical_wording_different_tasks_both_surface() {
  local dir state fakebin out capo pid
  dir=$(make_case capo-worker-identical-wording); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  capo="$dir/capo-home"
  mkdir -p "$capo/state"
  : > "$capo/.cs-capo-home"
  printf 'needs-decision [key=review]: needs boss input\n' > "$capo/state/w-10.status"
  printf 'needs-decision [key=review]: needs boss input\n' > "$capo/state/w-20.status"
  cs_write_meta "$state/mycapo.meta" "kind=capo" "home=$capo"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_until "$CS_WATCH_TEST_TICKS" grep -q '^capo:' "$out" \
    || { kill "$pid" 2>/dev/null; cat "$out"; fail "identical-wording decisions on different tasks were never surfaced"; }
  grep -F 'mycapo/w-10' "$out" >/dev/null || { cat "$out"; fail "the first task's identically-worded decision did not surface"; }
  grep -F 'mycapo/w-20' "$out" >/dev/null || { cat "$out"; fail "the second task's identically-worded decision did not surface"; }
  [ -s "$state/.capo-surfaced-mycapo__w-10" ] || fail "the first task's own marker must be written"
  [ -s "$state/.capo-surfaced-mycapo__w-20" ] || fail "the second task's own marker must be written"
  kill "$pid" 2>/dev/null || true
  pass "identically-worded decisions on different tasks each get their own marker and both surface"
}

test_capo_worker_reopen_after_resolve_resurfaces() {
  local dir state fakebin out capo pid reopen_pending
  dir=$(make_case capo-worker-reopen); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  capo="$dir/capo-home"
  mkdir -p "$capo/state"
  : > "$capo/.cs-capo-home"
  printf 'needs-decision [key=x]: pick approach\n' > "$capo/state/w-1.status"
  cs_write_meta "$state/mycapo.meta" "kind=capo" "home=$capo"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_until "$CS_WATCH_TEST_TICKS" grep -q '^capo:' "$out" \
    || { kill "$pid" 2>/dev/null; cat "$out"; fail "the first open decision under key x was never surfaced"; }
  reap "$pid"

  # A scan while it sits resolved (the resurfacing regression's actual proof
  # point): if this pass leaves a stale manifest behind, the reopen below
  # would wrongly collide with it even though the wording is byte-identical.
  # Called directly rather than through a live watcher: the escalation
  # record Task 3 opened for the first surfacing also becomes visible to the
  # watcher's own ordinary per-task signal scan on its very next pass - an
  # accepted, separate wake channel for the same underlying event, out of
  # scope for this dedupe-identity regression (a direct call exercises only
  # the fold this test is about).
  printf 'resolved [key=x]: answered via cs-send: use option A\n' >> "$capo/state/w-1.status"
  (
    cd "$dir" || exit 2
    # shellcheck disable=SC1090,SC1091
    PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" . "$WATCH"
    scan_capo_worker_events >/dev/null
  )

  printf 'needs-decision [key=x]: pick approach\n' >> "$capo/state/w-1.status"
  # Called directly for the same reason as the middle scan above: what this
  # regression is actually about is scan_capo_worker_events's own dedupe
  # decision, not which of possibly several independently-valid wake reasons
  # a live watcher exits on first.
  reopen_pending=$(
    cd "$dir" || exit 2
    # shellcheck disable=SC1090,SC1091
    PATH="$fakebin:$PATH" CS_STATE_OVERRIDE="$state" . "$WATCH"
    scan_capo_worker_events
  )
  case "$reopen_pending" in
    *"mycapo"*"w-1"*"x"*) ;;
    *) fail "a decision reopened under the same key with IDENTICAL wording did not resurface: $reopen_pending" ;;
  esac
  pass "a decision reopened under the same key and wording after a resolve is treated as a new surfacing event"
}


test_provably_working_signal_absorbed
test_turn_ended_provably_working_absorbed
test_turn_ended_not_working_surfaced
test_working_note_not_working_surfaced
test_actionable_signal_surfaced
test_needs_review_signal_surfaced
test_boss_verb_signal_takes_the_short_grace
test_no_verb_signal_keeps_the_long_grace
test_terminal_stale_surfaced
test_live_headless_scout_stale_absorbed
test_terminal_headless_scout_surfaced
test_stale_terminal_status_overridden_by_active_run
test_nonterminal_stale_provably_working_absorbed_then_escalated
test_wedge_escalation_marks_demand_deep_inspection_after_threshold
test_nonterminal_stale_not_working_surfaced
test_nonterminal_stale_paused_absorbed_then_resurfaced
test_busy_pane_within_the_turn_bound_is_left_alone
test_busy_pane_past_the_turn_bound_wedge_escalates
test_completed_turn_resets_the_busy_bound
test_blocked_pane_surfaces_immediately
test_blocked_pane_declared_pause_absorbed
test_registered_check_runs_from_snapshot
test_unauthenticated_check_rejected_without_execution
test_tampered_registered_check_rejected
test_heartbeat_no_change_absorbed
test_heartbeat_backstop_surfaces_unsurfaced_status
test_beacon_stays_fresh_while_absorbing
test_event_splice_blocked_edge_and_dedupe_clear
test_event_splice_supersedes_a_blocked_edge_within_one_batch
test_event_splice_without_the_plugin_falls_back_to_polling
test_event_splice_drains_edges_that_fired_with_no_watcher_running
test_event_splice_level_reconcile_catches_already_blocked
test_duplicate_watcher_noops_through_singleton_lock
test_capo_worker_event_surfaced_without_the_capo_taking_a_turn
test_capo_worker_event_deduped_and_scoped
test_capo_worker_decision_survives_a_later_working_append
test_capo_worker_resolved_decision_does_not_resurface
test_capo_worker_identical_wording_different_tasks_both_surface
test_capo_worker_reopen_after_resolve_resurfaces
test_event_splice_ignores_foreign_panes_and_unknown_kinds
test_snapshot_answers_panes_and_absence_falls_back
