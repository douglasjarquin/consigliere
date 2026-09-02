#!/usr/bin/env bash
# Behavior (portable): nesting a ship/scout task as a tab inside its capo's own
# live workspace (bin/cs-herdr-nest-lib.sh, bin/cs-herdr-lib.sh's
# cs_herdr_task_create_nested / cs_herdr_nested_task_remove), instead of the
# ordinary dedicated workspace-per-task container.
#
# Stubs cs_herdr so the decision and rollback branches are exercised
# hermetically; git worktree add/remove run for real against a throwaway repo,
# since that half of the contract is plain git with no herdr involvement at
# all - the entire point of this mechanism.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "1..0 # skip jq is required"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "1..0 # skip git is required"; exit 0; }

TMP=$(cs_test_tmproot cs-herdr-nest)
mkdir -p "$TMP"

# shellcheck source=bin/cs-meta-lib.sh
. "$ROOT/bin/cs-meta-lib.sh"
# shellcheck source=bin/cs-herdr-lib.sh
. "$ROOT/bin/cs-herdr-lib.sh"
# shellcheck source=bin/cs-herdr-nest-lib.sh
. "$ROOT/bin/cs-herdr-nest-lib.sh"

# --- stub --------------------------------------------------------------
WS_EXISTS_ID=""
TAB_CREATE_RC=0
TAB_CREATE_JSON=""
CALL_LOG="$TMP/calls"
: > "$CALL_LOG"

cs_herdr() {
  case "${1:-} ${2:-}" in
    "workspace list")
      if [ -n "$WS_EXISTS_ID" ]; then
        printf '{"result":{"workspaces":[{"workspace_id":"%s"}]}}' "$WS_EXISTS_ID"
      else
        printf '{"result":{"workspaces":[]}}'
      fi
      ;;
    "tab create")
      echo "tab create $*" >> "$CALL_LOG"
      [ "$TAB_CREATE_RC" -eq 0 ] || return "$TAB_CREATE_RC"
      printf '%s' "$TAB_CREATE_JSON"
      ;;
    "pane close")
      echo "pane close $*" >> "$CALL_LOG"
      ;;
    *) return 1 ;;
  esac
}

call_count() { # <substring> -> how many logged calls contain it
  grep -c "$1" "$CALL_LOG" 2>/dev/null || true
}

# === cs_herdr_nest_target_workspace =========================================

HOME1="$TMP/root-home"
mkdir -p "$HOME1/state"
out=$(cs_herdr_nest_target_workspace "$HOME1" "root" 2>/dev/null) && rc=0 || rc=$?
[ "$rc" -eq 1 ] && [ -z "$out" ] || fail "an ordinary (non-capo) home must never nest, got rc=$rc out='$out'"
pass "a root home (no .cs-capo-home marker) never nests"

HOME2="$TMP/capo-home-no-meta"
mkdir -p "$HOME2/state"
: > "$HOME2/.cs-capo-home"
out=$(cs_herdr_nest_target_workspace "$HOME2" "capo1" 2>/dev/null) && rc=0 || rc=$?
[ "$rc" -eq 1 ] && [ -z "$out" ] || fail "a capo home with no self-meta must refuse, got rc=$rc out='$out'"
pass "a capo home missing its own state/<id>.meta refuses to nest"

HOME3="$TMP/capo-home-stale-ws"
mkdir -p "$HOME3/state"
: > "$HOME3/.cs-capo-home"
printf 'workspace=w9\n' > "$HOME3/state/capo1.meta"
WS_EXISTS_ID=""
out=$(cs_herdr_nest_target_workspace "$HOME3" "capo1" 2>/dev/null) && rc=0 || rc=$?
[ "$rc" -eq 1 ] && [ -z "$out" ] || fail "a stale (no-longer-live) recorded workspace must fail OPEN to the ordinary path, got rc=$rc out='$out'"
pass "a stale recorded capo workspace refuses (fails open) rather than nesting into a dead container"

WS_EXISTS_ID=w9
out=$(cs_herdr_nest_target_workspace "$HOME3" "capo1" 2>/dev/null) || fail "a live recorded capo workspace must resolve"
[ "$out" = w9 ] || fail "expected the capo's recorded workspace w9, got '$out'"
pass "a capo home with a live recorded workspace resolves it as the nest target"
WS_EXISTS_ID=""

# === cs_herdr_nested_worktree_path ==========================================

CS_HERDR_WORKTREES_ROOT="$TMP/wtroot"
out=$(cs_herdr_nested_worktree_path "/some/path/my-project" "task-42")
[ "$out" = "$TMP/wtroot/my-project/nested/task-42" ] || fail "unexpected nested worktree path: $out"
pass "the nested worktree path is namespaced under its own 'nested' subtree"

# === cs_herdr_task_create_nested =============================================

PROJ="$TMP/proj"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
git -C "$PROJ" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init

# target workspace does not (or no longer) exist: refuse before touching git.
WS_EXISTS_ID=""
if cs_herdr_task_create_nested "$PROJ" cs/nope nope w-missing 2>/dev/null; then
  fail "creating a nested task against a nonexistent target workspace must refuse"
fi
[ -d "$TMP/wtroot/proj/nested/nope" ] && fail "no worktree may be left behind when the target workspace check fails"
pass "a nonexistent target workspace refuses before any git worktree is created"

# success path.
WS_EXISTS_ID=w1
TAB_CREATE_RC=0
TAB_CREATE_JSON='{"result":{"tab":{"tab_id":"w1:t7"},"root_pane":{"pane_id":"w1:p7"}}}'
: > "$CALL_LOG"
tuple=$(cs_herdr_task_create_nested "$PROJ" cs/ok task-ok w1 "") || fail "a live target workspace with a successful tab create must succeed"
ws=$(printf '%s' "$tuple" | cut -f1)
pane=$(printf '%s' "$tuple" | cut -f2)
wt=$(printf '%s' "$tuple" | cut -f3)
branch=$(printf '%s' "$tuple" | cut -f4)
[ "$ws" = w1 ] || fail "the tuple's workspace must be the TARGET workspace, not a newly created one; got '$ws'"
[ "$pane" = "w1:p7" ] || fail "expected pane w1:p7, got '$pane'"
[ "$wt" = "$TMP/wtroot/proj/nested/task-ok" ] || fail "unexpected worktree path '$wt'"
[ "$branch" = cs/ok ] || fail "expected branch cs/ok, got '$branch'"
[ -d "$wt" ] || fail "the worktree directory must actually exist on disk"
git -C "$PROJ" worktree list | grep -Fq "$wt" || fail "git must record the new worktree"
[ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = cs/ok ] || fail "the worktree must be checked out on the new branch"
[ "$(call_count "tab create")" -eq 1 ] || fail "exactly one tab create call was expected"
pass "a successful nested create returns the target workspace, new pane, and a real git worktree on the new branch"

# tab create failure rolls the git worktree back.
WS_EXISTS_ID=w1
TAB_CREATE_RC=1
TAB_CREATE_JSON=''
if cs_herdr_task_create_nested "$PROJ" cs/rollback task-rollback w1 "" 2>/dev/null; then
  fail "a failed tab create must not report success"
fi
[ -d "$TMP/wtroot/proj/nested/task-rollback" ] && fail "a failed tab create must roll the git worktree back, not leave it behind"
git -C "$PROJ" worktree list | grep -q "task-rollback" && fail "git's own worktree registry must not retain the rolled-back worktree"
pass "a failed tab create rolls the git worktree back instead of leaving an orphaned checkout"
TAB_CREATE_RC=0

# a pre-existing path at the computed location refuses rather than colliding.
mkdir -p "$TMP/wtroot/proj/nested/collide"
TAB_CREATE_JSON='{"result":{"tab":{"tab_id":"w1:t8"},"root_pane":{"pane_id":"w1:p8"}}}'
if cs_herdr_task_create_nested "$PROJ" cs/collide collide w1 "" 2>/dev/null; then
  fail "a pre-existing path at the target worktree location must refuse, never be clobbered"
fi
pass "a pre-existing worktree path at the computed location is refused, not overwritten"

# === cs_herdr_nested_task_remove =============================================

: > "$CALL_LOG"
tuple=$(cs_herdr_task_create_nested "$PROJ" cs/remove-clean remove-clean w1 "") || fail "setup: create for the clean-removal case"
wt=$(printf '%s' "$tuple" | cut -f3)
cs_herdr_nested_task_remove "$PROJ" "$wt" "w1:p7" || fail "removing a clean nested worktree must succeed"
[ -d "$wt" ] && fail "the worktree directory must be gone after a clean removal"
[ "$(call_count "pane close")" -eq 1 ] || fail "a successful removal must close exactly the task's own pane"
pass "removing a clean nested worktree deletes the checkout and closes its own pane, nothing else"

: > "$CALL_LOG"
tuple=$(cs_herdr_task_create_nested "$PROJ" cs/remove-dirty remove-dirty w1 "") || fail "setup: create for the dirty-removal case"
wt=$(printf '%s' "$tuple" | cut -f3)
echo dirty > "$wt/uncommitted.txt"
if cs_herdr_nested_task_remove "$PROJ" "$wt" "w1:p9" 2>/dev/null; then
  fail "removing a DIRTY nested worktree without --force must refuse"
fi
[ -d "$wt" ] || fail "a refused removal must leave the worktree intact for inspection"
[ "$(call_count "pane close")" -eq 0 ] || fail "a refused (dirty) removal must never close the pane out from under surviving work"
pass "a dirty nested worktree refuses removal without --force, leaving the pane untouched"

cs_herdr_nested_task_remove "$PROJ" "$wt" "w1:p9" --force || fail "removing a dirty nested worktree WITH --force must succeed"
[ -d "$wt" ] && fail "the worktree directory must be gone after a forced removal"
[ "$(call_count "pane close")" -eq 1 ] || fail "a forced removal must still close the task's own pane"
pass "--force removes a dirty nested worktree and then closes its pane"

pass "nested-tab task lifecycle contract"
