#!/usr/bin/env bash
# Behavior (LIVE, opt-in): the full phase-1 lifecycle against a real herdr lab
# and a real CLAUDE agent - cs-brief scaffold, cs-spawn isolation + launch,
# native agent detection, cs-send steer confirmation (/skill syntax path is
# exercised separately), the agent-control lifecycle verbs, and cs-teardown of
# the clean worktree. Skipped unless
# CS_TEST_CLAUDE_LIVE=1 (spawns a real claude).
#
# This is the claude twin of cs-lifecycle-live.test.sh. It is the authoritative
# check that (a) the claude --settings turn-end hook touches state/<id>.turn-ended,
# and (b) herdr's native agent detection reports a claude agent's busy/idle status
# (the watcher depends on it). If herdr does not auto-detect claude agents, run
# `herdr integration install claude` first, or record the gap.
set -u
# The root harness for this suite is claude; set BEFORE sourcing lib.sh so its
# default codex pin does not win.
export CS_HARNESS_OVERRIDE=claude
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${CS_TEST_CLAUDE_LIVE:-0}" != "1" ]; then
  pass "cs claude lifecycle live suite skipped (set CS_TEST_CLAUDE_LIVE=1 to run)"
  exit 0
fi

command -v claude >/dev/null 2>&1 || fail "claude binary required for live suite"

LAB=$("$ROOT/bin/cs-herdr-lab.sh" name claudelife)
REPO="csclaudelive-$$"
cleanup() {
  "$ROOT/bin/cs-herdr-lab.sh" teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$HOME/.herdr/worktrees/$REPO"
  cs_test_cleanup
}
trap cleanup EXIT

TMP=$(cs_test_tmproot cs-claude-lifecycle)
export CS_HOME="$TMP/home"
export CS_DATA_OVERRIDE="$TMP/home/data"
export CS_STATE_OVERRIDE="$TMP/home/state"
mkdir -p "$TMP/home/data" "$TMP/home/state" "$TMP/home/config"
cs_git_identity
cs_git_init_commit "$TMP/$REPO"
printf -- '- %s [local-only] - live fixture\n' "$REPO" > "$TMP/home/config/projects.md"

"$ROOT/bin/cs-herdr-lab.sh" provision "$LAB" || fail "lab provision"
export CS_HERDR_SESSION="$LAB"

ID=claudelive1

"$ROOT/bin/cs-brief.sh" "$ID" "$REPO" --mode local-only >/dev/null || fail "brief scaffold"
BRIEF="$TMP/home/data/$ID/brief.md"
python3 - "$BRIEF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("{TASK}", "Do nothing else: this is a plumbing test. Do not create, edit, or commit any files. Reply with exactly LIVE_TEST_READY and stop.")
open(p, "w").write(s)
PY

out=$("$ROOT/bin/cs-spawn.sh" "$ID" "$TMP/$REPO" --mode local-only --yolo off --effort low 2>&1) || fail "spawn failed: $out"
assert_contains "$out" "spawned $ID" "spawn reports success"
pass "spawn creates isolated worktree and launches claude"

META="$TMP/home/state/$ID.meta"
assert_present "$META" "meta written"
[ "$(grep '^harness=' "$META" | cut -d= -f2)" = claude ] || fail "meta harness must be claude"
PANE=$(grep '^pane=' "$META" | cut -d= -f2)
WT=$(grep '^worktree=' "$META" | cut -d= -f2)
[ -d "$WT" ] || fail "worktree missing: $WT"
assert_present "$TMP/home/state/$ID.claude-settings.json" "claude settings file written"
pass "meta records harness=claude; settings file present"

# native agent detection (claude boots within a bounded wait)
# shellcheck source=bin/cs-herdr-lib.sh
. "$ROOT/bin/cs-herdr-lib.sh"
found=0
for _ in $(seq 1 40); do
  if cs_herdr_agent_alive "$PANE"; then found=1; break; fi
  sleep 1
done
[ "$found" = 1 ] || fail "claude agent never detected in pane $PANE (does herdr auto-detect claude? see docs/claude.md)"
pass "native agent detection sees a claude agent"

# turn-end signal: the --settings Stop hook must touch the turn-end file
found=0
for _ in $(seq 1 60); do
  [ -f "$TMP/home/state/$ID.turn-ended" ] && { found=1; break; }
  sleep 1
done
[ "$found" = 1 ] || fail "claude Stop hook never touched state/$ID.turn-ended"
pass "claude turn-end Stop hook touches the turn-end signal"

# Wait for the boot turn through the CORROBORATED state policy rather than a raw
# `agent wait --until idle`: a finished claude turn can report native `done`, which
# docs/herdr.md maps to `done` and not to `idle`, so the strict wait times out on a
# perfectly healthy agent (observed 2026-08-11, claude 2.1.227). The busy state is
# what every consigliere caller actually acts on.
wait_not_busy() { # <pane> <secs>
  local waited=0
  while [ "$waited" -lt "$2" ]; do
    case "$(cs_herdr_agent_busy_state "$1")" in
      busy) ;;
      *) return 0 ;;
    esac
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}
wait_not_busy "$PANE" 180 || fail "claude never finished its boot turn"
out=$("$ROOT/bin/cs-send.sh" "$ID" "Reply with exactly LIVE_STEER_OK and stop." 2>&1) || fail "steer failed: $out"
case "$out" in *submitted*|*queued*) : ;; *) fail "steer not confirmed: $out" ;; esac
pass "steer submit confirmed"

# --- agent lifecycle control plane ------------------------------------------
# What a stubbed herdr cannot prove: that this harness's own interrupt key and
# exit command actually stop a REAL agent, and that a relaunch adopting this pane
# brings one back in place. bin/cs-control.sh owns the verbs.
CTL="$ROOT/bin/cs-control.sh"

# The steer above is still running its turn; the idempotent case needs an agent
# that is genuinely between turns.
wait_not_busy "$PANE" 180 || true
out=$("$CTL" interrupt "$ID" 2>&1) || fail "interrupt on an idle agent must succeed: $out"
assert_contains "$out" "no turn was running" "an idle agent is idempotent success"

# Steer only into an agent that is BETWEEN turns: a steer delivered mid-turn is
# queued into the composer instead, and a queued line is exactly what the exit
# verb refuses to type onto (docs/claude.md).
wait_not_busy "$PANE" 180 || true
out=$("$ROOT/bin/cs-send.sh" "$ID" "Count slowly from 1 to 60, one number per line, then stop." 2>&1) ||
  fail "steer for the interrupt case failed: $out"
cs_herdr_agent_wait "$PANE" working 60000 >/dev/null 2>&1 || true
# Assert the report matches reality rather than a fixed outcome: whether a
# harness cancels within the window is timing, but a claimed stop must never be
# a lie, and that is the property worth pinning live.
irc=0
out=$("$CTL" interrupt "$ID" 2>&1) || irc=$?
case "$out" in
  *"turn stopped, agent still running"*)
    expect_code 0 "$irc" "a reported stop must succeed"
    case "$(cs_herdr_agent_busy_state "$PANE")" in
      busy) fail "interrupt claimed the turn stopped while the agent is still working: $out" ;;
    esac
    cs_herdr_agent_alive "$PANE" || fail "interrupt claimed the agent is still running, and it is not: $out"
    pass "cs-control interrupt cancelled a real turn and left the agent running"
    ;;
  *"NOT confirmed"*)
    expect_code 1 "$irc" "an unconfirmed interrupt must exit non-zero"
    pass "cs-control interrupt reported an unconfirmed cancel instead of claiming one"
    ;;
  *) fail "unexpected interrupt report: $out" ;;
esac

# Relaunch a SETTLED agent: its stop step would otherwise inherit whatever the
# cancel above did or did not do, which is not what this case is testing.
wait_not_busy "$PANE" 180 || true
before_pid=$(cs_herdr_pane_agent_process "$PANE" | cut -f1)
out=$("$CTL" relaunch "$ID" --note 'LIVE_RELAUNCH_NOTE: continue from here' 2>&1) ||
  fail "relaunch must succeed: $out"
assert_contains "$out" "agent replaced via" "relaunch reports which launch path it took"
after_pid=$(cs_herdr_pane_agent_process "$PANE" | cut -f1)
[ -n "$after_pid" ] && [ "$after_pid" != "$before_pid" ] ||
  fail "relaunch must leave a DIFFERENT agent process on $PANE (before ${before_pid:-none}, after ${after_pid:-none})"
[ "$(sed -n 's/^phase=//p' "$TMP/home/state/$ID.control-relaunch" | tail -1)" = 'done' ] ||
  fail "the relaunch journal must end at done"
assert_grep 'LIVE_RELAUNCH_NOTE' "$TMP/home/data/$ID/brief.md" "the progress note reaches the instructions"
[ -d "$WT" ] || fail "relaunch must never touch the worktree"
pass "cs-control relaunch replaces the agent in place, proven by process identity"

wait_not_busy "$PANE" 120 || true
if [ -n "$(git -C "$WT" status --porcelain)" ]; then
  echo "note: worktree dirtied by agent; using explicit --force discard" >&2
  out=$("$ROOT/bin/cs-teardown.sh" "$ID" --force 2>&1) || fail "forced teardown failed: $out"
else
  out=$("$ROOT/bin/cs-teardown.sh" "$ID" 2>&1) || fail "teardown failed: $out"
fi
assert_contains "$out" "teardown $ID complete" "teardown completes"
assert_absent "$META" "meta cleaned"
[ ! -d "$WT" ] || fail "worktree remains after teardown"
pass "teardown removes pane, worktree, and state"

pass "cs claude lifecycle live behaviors"
