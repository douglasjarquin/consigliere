#!/usr/bin/env bash
# Behavior (LIVE, opt-in): the full phase-1 lifecycle against a real herdr lab
# and a real codex agent - cs-brief scaffold, cs-spawn isolation + launch,
# native agent detection, cs-send steer confirmation, and cs-teardown of the
# clean worktree. Skipped unless CS_TEST_CODEX_LIVE=1 (spawns a real codex).
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
