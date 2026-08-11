#!/usr/bin/env bash
# Behavior (LIVE, opt-in): cs-herdr-lib.sh drives a real isolated herdr lab -
# protocol gate, home workspace ensure, workspace-per-task worktree create,
# dirty-remove refusal, clean remove, capture, the pane cwd and key vocabulary the
# agent-control plane depends on, and worktree-open recovery.
#
# Skipped unless CS_TEST_HERDR_LIVE=1 because it provisions a real lab server.
# It never touches the default session; all calls go through the lab guard's
# session or CS_HERDR_SESSION set to the lab name.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${CS_TEST_HERDR_LIVE:-0}" != "1" ]; then
  pass "cs-herdr-lib live suite skipped (set CS_TEST_HERDR_LIVE=1 to run)"
  exit 0
fi

LAB=$("$ROOT/bin/cs-herdr-lab.sh" name libtest)
REPO="csrepo-$$"
cleanup() {
  "$ROOT/bin/cs-herdr-lab.sh" teardown "$LAB" >/dev/null 2>&1 || true
  # herdr worktree dirs outlive the lab session; sweep this run's only.
  rm -rf "$HOME/.herdr/worktrees/$REPO"
  cs_test_cleanup
}
trap cleanup EXIT

# Unique repo name per run: herdr worktrees land at
# ~/.herdr/worktrees/<repo_name>/<branch>, so a reused fixture name collides
# with leftovers from an earlier aborted run.
TMP=$(cs_test_tmproot cs-herdr-lib)
cs_git_init_commit "$TMP/$REPO"

"$ROOT/bin/cs-herdr-lab.sh" provision "$LAB" || fail "lab provision"

export CS_HERDR_SESSION="$LAB"
# shellcheck source=bin/cs-herdr-lib.sh
. "$ROOT/bin/cs-herdr-lib.sh"

cs_herdr_protocol_check || fail "protocol gate"
pass "protocol gate accepts the lab server"

ws=$(cs_herdr_home_workspace_ensure consigliere-test "$TMP/$REPO") || fail "home workspace ensure"
[ -n "$ws" ] || fail "home workspace id empty"
ws2=$(cs_herdr_home_workspace_ensure consigliere-test "$TMP/$REPO") || fail "home workspace re-ensure"
[ "$ws" = "$ws2" ] || fail "home workspace ensure is not idempotent ($ws vs $ws2)"
pass "home workspace ensure is idempotent"

# cs_herdr_task_create takes the project PATH (as bin/cs-spawn.sh passes
# $PROJ_ABS), not a workspace id: --cwd must resolve to $TMP/$REPO so the task
# branch is created in this repo and the branch-preservation assertion below is
# actually meaningful.
tuple=$(cs_herdr_task_create "$TMP/$REPO" cs/lib-test t-lib-test) || fail "task worktree create"
task_ws=$(printf '%s' "$tuple" | cut -f1)
task_pane=$(printf '%s' "$tuple" | cut -f2)
task_path=$(printf '%s' "$tuple" | cut -f3)
task_branch=$(printf '%s' "$tuple" | cut -f4)
[ "$task_branch" = "cs/lib-test" ] || fail "branch mismatch: $task_branch"
[ -d "$task_path" ] || fail "worktree path missing: $task_path"
[ "$task_ws" != "$ws" ] || fail "task workspace must be its own workspace"
git -C "$task_path" rev-parse --show-toplevel >/dev/null || fail "worktree is not a git checkout"
pass "workspace-per-task worktree create"

echo dirty > "$task_path/dirty.txt"
if cs_herdr_worktree_remove "$task_ws" >/dev/null 2>&1; then
  fail "dirty worktree remove must refuse without --force"
fi
[ -f "$task_path/dirty.txt" ] || fail "dirty file lost on refused remove"
pass "dirty-remove fails closed"

# Re-submit the probe on every attempt, not once before the loop: a freshly
# created worktree pane's shell may not be ready to accept input yet on a slow
# or headless runner, and a single early `pane run` is then silently lost while
# re-reading the buffer can never recover it. Re-running echo is idempotent.
out=""
for _ in $(seq 1 30); do
  cs_herdr_run "$task_pane" 'echo cs-capture-probe' >/dev/null || fail "pane run"
  sleep 0.3
  out=$(cs_herdr_capture "$task_pane" 20 text) || fail "capture"
  case "$out" in *cs-capture-probe*) break ;; esac
  sleep 0.5
done
assert_contains "$out" "cs-capture-probe" "pane run output visible in capture"
pass "pane run + capture round-trip"

# The two endpoint facts the agent-control plane depends on, pinned against the
# REAL binary (docs/herdr.md records the measurements).
pane_cwd=$(cs_herdr_pane_cwd "$task_pane") || fail "herdr reported no cwd for pane $task_pane"
want_cwd=$(cd "$task_path" && pwd -P) || fail "cannot resolve $task_path"
[ "$pane_cwd" = "$want_cwd" ] ||
  fail "pane cwd should be the worktree: got '$pane_cwd', want '$want_cwd'"
pass "cs_herdr_pane_cwd reports the pane's own working directory"

# herdr's key vocabulary is narrow, which is WHY a lifecycle command can never be
# typed into a composer holding unsent text: there is no clear key to reach for.
key_err=$(cs_herdr_send_keys "$task_pane" C-u 2>&1 >/dev/null || true)
case "$key_err" in
  *invalid_key*|*"unsupported key"*) : ;;
  *) fail "herdr $(herdr --version 2>/dev/null) now accepts C-u ('$key_err'); re-verify docs/herdr.md and docs/agent-control.md before relying on the refusal" ;;
esac
cs_herdr_send_keys "$task_pane" esc >/dev/null || fail "herdr must accept its canonical esc key name"
pass "send-keys accepts esc and refuses an unsupported key"

# The submit-confirmation flag, pinned against the REAL binary at the pinned
# version. `agent wait` renamed this flag between 0.7.4 (--status) and 0.7.5
# (--until); consigliere shipped --status, herdr updated the fleet to 0.7.5, and
# every steer silently stopped confirming while CI stayed green on the old pin.
# CI now pins 0.7.5 so this lane exercises the contract the fleet runs.
#
# Assert on the MESSAGE, never the exit code: this pane has no agent, so any
# spelling exits non-zero, and only "unknown option" distinguishes a bad flag
# from a normal no-agent result. An earlier version conflated the two and failed
# for the wrong reason.
wait_err=$(cs_herdr_agent_wait "$task_pane" idle 500 2>&1 >/dev/null || true)
case "$wait_err" in
  *"unknown option"*)
    fail "cs_herdr_agent_wait passed a flag this herdr ($(herdr --version 2>/dev/null)) rejects: $wait_err"
    ;;
esac
pass "cs_herdr_agent_wait uses a flag the pinned herdr accepts"

# And the OLD spelling must now be rejected, which is what proves the pin and
# the code agree. If this ever passes, herdr changed again - re-verify before
# touching cs_herdr_agent_wait.
if herdr agent wait "$task_pane" --status idle --timeout 200 2>&1 | grep -q -- "unknown option"; then
  pass "the pre-0.7.5 spelling --status is rejected, so code and pin agree"
else
  fail "this herdr still accepts 'agent wait --status'; the pin may have moved backwards - re-verify docs/herdr.md"
fi

rm "$task_path/dirty.txt"
cs_herdr_worktree_remove "$task_ws" >/dev/null || fail "clean worktree remove"
[ ! -d "$task_path" ] || fail "worktree dir remains after clean remove"
git -C "$TMP/$REPO" show-ref --verify --quiet refs/heads/cs/lib-test || fail "branch must survive clean remove"
pass "clean remove deletes worktree, preserves branch"

tuple=$(cs_herdr_task_create "$TMP/$REPO" cs/lib-recover t-lib-recover) || fail "second task create"
task_ws=$(printf '%s' "$tuple" | cut -f1)
task_path=$(printf '%s' "$tuple" | cut -f3)
echo keep > "$task_path/keep.txt"
cs_herdr workspace close "$task_ws" >/dev/null || fail "workspace close"
[ -f "$task_path/keep.txt" ] || fail "worktree must survive workspace close"
tuple=$(cs_herdr_worktree_open "$task_path" t-lib-recovered) || fail "worktree open recovery"
task_ws=$(printf '%s' "$tuple" | cut -f1)
[ -n "$task_ws" ] || fail "recovered workspace id empty"
rm "$task_path/keep.txt"
cs_herdr_worktree_remove "$task_ws" >/dev/null || fail "cleanup remove after recovery"
pass "worktree survives workspace close and reopens by path"

pass "cs-herdr-lib live behaviors"
