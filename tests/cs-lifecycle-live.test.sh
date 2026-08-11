#!/usr/bin/env bash
# Behavior (LIVE, opt-in): the full phase-1 lifecycle against a real herdr lab
# and a real codex agent - cs-brief scaffold, cs-spawn isolation + launch,
# native agent detection, cs-send steer confirmation, the agent-control
# lifecycle verbs, and cs-teardown of the clean worktree. Skipped unless
# CS_TEST_CODEX_LIVE=1 (spawns a real codex).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${CS_TEST_CODEX_LIVE:-0}" != "1" ]; then
  pass "cs lifecycle live suite skipped (set CS_TEST_CODEX_LIVE=1 to run)"
  exit 0
fi

command -v codex >/dev/null 2>&1 || fail "codex binary required for live suite"

LAB=$("$ROOT/bin/cs-herdr-lab.sh" name lifecycle)
REPO="cslive-$$"
cleanup() {
  "$ROOT/bin/cs-herdr-lab.sh" teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$HOME/.herdr/worktrees/$REPO"
  cs_test_cleanup
}
trap cleanup EXIT

TMP=$(cs_test_tmproot cs-lifecycle)
export CS_HOME="$TMP/home"
export CS_DATA_OVERRIDE="$TMP/home/data"
export CS_STATE_OVERRIDE="$TMP/home/state"
mkdir -p "$TMP/home/data" "$TMP/home/state" "$TMP/home/config"
cs_git_identity
cs_git_init_commit "$TMP/$REPO"
printf -- '- %s [local-only] - live fixture (added 2026-07-22)\n' "$REPO" > "$TMP/home/config/projects.md"

"$ROOT/bin/cs-herdr-lab.sh" provision "$LAB" || fail "lab provision"
export CS_HERDR_SESSION="$LAB"

ID=live1

# brief
"$ROOT/bin/cs-brief.sh" "$ID" "$REPO" --mode local-only >/dev/null || fail "brief scaffold"
# Replace {TASK} with a deterministic no-op task.
BRIEF="$TMP/home/data/$ID/brief.md"
python3 - "$BRIEF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("{TASK}", "Do nothing else: this is a plumbing test. Do not create, edit, or commit any files. Reply with exactly LIVE_TEST_READY and stop.")
open(p, "w").write(s)
PY

# spawn
out=$("$ROOT/bin/cs-spawn.sh" "$ID" "$TMP/$REPO" --mode local-only --yolo off --effort low 2>&1) || fail "spawn failed: $out"
assert_contains "$out" "spawned $ID" "spawn reports success"
assert_contains "$out" "mode=local-only" "spawn records the explicit delivery mode"
pass "spawn creates isolated worktree and launches codex"

META="$TMP/home/state/$ID.meta"
assert_present "$META" "meta written"
PANE=$(grep '^pane=' "$META" | cut -d= -f2)
WT=$(grep '^worktree=' "$META" | cut -d= -f2)
[ -d "$WT" ] || fail "worktree missing: $WT"
[ "$(git -C "$WT" branch --show-current)" = "cs/$ID" ] || fail "task branch not checked out"
pass "meta records pane/worktree; branch cs/$ID checked out"

# duplicate spawn refuses
if "$ROOT/bin/cs-spawn.sh" "$ID" "$TMP/$REPO" --mode local-only --yolo off >/dev/null 2>&1; then
  fail "duplicate spawn for same id must refuse"
fi
pass "duplicate spawn refuses"

# native agent detection (codex boots within a bounded wait)
# shellcheck source=bin/cs-herdr-lib.sh
. "$ROOT/bin/cs-herdr-lib.sh"
found=0
for _ in $(seq 1 30); do
  if cs_herdr_agent_alive "$PANE"; then found=1; break; fi
  sleep 1
done
[ "$found" = 1 ] || fail "codex agent never detected in pane $PANE"
pass "native agent detection sees codex"

# wait for the boot turn to finish, then steer and confirm
cs_herdr_agent_wait "$PANE" idle 120000 >/dev/null || fail "codex never went idle after boot turn"
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
cs_herdr_agent_wait "$PANE" idle 180000 >/dev/null 2>&1 || true
out=$("$CTL" interrupt "$ID" 2>&1) || fail "interrupt on an idle agent must succeed: $out"
assert_contains "$out" "no turn was running" "an idle agent is idempotent success"

# Steer only into an agent that is BETWEEN turns: a steer delivered mid-turn is
# queued into the composer instead, and a queued line is exactly what the exit
# verb refuses to type onto (docs/claude.md).
cs_herdr_agent_wait "$PANE" idle 180000 >/dev/null 2>&1 || true
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
cs_herdr_agent_wait "$PANE" idle 180000 >/dev/null 2>&1 || true
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

# let the steer turn finish, then teardown the (clean) worktree
cs_herdr_agent_wait "$PANE" idle 120000 >/dev/null || true
if [ -n "$(git -C "$WT" status --porcelain)" ]; then
  # The agent was told not to touch files; if it did, this is a finding, not a
  # test failure - discard explicitly to finish the lifecycle check.
  echo "note: worktree dirtied by agent; using explicit --force discard" >&2
  out=$("$ROOT/bin/cs-teardown.sh" "$ID" --force 2>&1) || fail "forced teardown failed: $out"
else
  out=$("$ROOT/bin/cs-teardown.sh" "$ID" 2>&1) || fail "teardown failed: $out"
fi
assert_contains "$out" "teardown $ID complete" "teardown completes"
assert_absent "$META" "meta cleaned"
[ ! -d "$WT" ] || fail "worktree remains after teardown"
pass "teardown removes pane, worktree, and state"

pass "cs lifecycle live behaviors"
