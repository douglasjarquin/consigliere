#!/usr/bin/env bash
# Behavior: characterization tests for bin/cs-merge-local.sh, the sanctioned
# guarded fast-forward that lands a local-only ship task's cs/<id> branch into
# the project's default branch.
#
# Contract (from the script header + code):
#   Usage: cs-merge-local.sh <task-id>. Reads STATE from CS_STATE_OVERRIDE (or
#   CS_HOME/state) and the task's state/<id>.meta for project= and mode=.
#   Success: only for mode=local-only, only as a clean fast-forward (DEFAULT is
#   an ancestor of cs/<id>), only when the project's main checkout is ON its
#   default branch and clean. On success it prints
#   "merged cs/<id> into local <default> (<before> -> <after>) in <proj>" and
#   fast-forwards the default branch. Refusals (all before touching git, or
#   before merging): missing meta (exit 1), mode!=local-only (exit 1), branch
#   cs/<id> absent (exit 1), main checkout not on default (exit 1), dirty tree
#   (exit 1), diverged/non-fast-forward branch (exit 1, "REFUSED").
#   default_branch() prefers origin/HEAD, then a local main, then master.
#
# Hermetic: temp git repos only; the script runs no gh/herdr/network.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="$ROOT/bin/cs-merge-local.sh"
TMP=$(cs_test_tmproot cs-merge-local)
export CS_STATE_OVERRIDE="$TMP/state"
export CS_HOME="$TMP"
mkdir -p "$TMP/state"
cs_git_identity

# make_proj <id> [--diverge]: a repo whose default branch is 'main' with a
# fast-forwardable cs/<id> branch one commit ahead. With --diverge, main also
# gets its own extra commit so cs/<id> is no longer a fast-forward. Leaves the
# checkout on main, clean. Echoes the project path.
make_proj() {
  local id=$1 diverge=${2:-} proj
  proj="$TMP/proj-$id"
  cs_git_init_commit "$proj"
  git -C "$proj" branch -q -M main
  git -C "$proj" checkout -q -b "cs/$id"
  printf 'feature\n' > "$proj/feature.txt"
  git -C "$proj" add feature.txt
  git -C "$proj" commit -qm "task work"
  git -C "$proj" checkout -q main
  if [ "$diverge" = --diverge ]; then
    printf 'mainline\n' > "$proj/mainline.txt"
    git -C "$proj" add mainline.txt
    git -C "$proj" commit -qm "diverging mainline commit"
  fi
  printf '%s\n' "$proj"
}

# 1. happy path: a clean fast-forward lands cs/<id> into main.
proj=$(make_proj h1)
before=$(git -C "$proj" rev-parse main)
branch_tip=$(git -C "$proj" rev-parse "cs/h1")
cs_write_meta "$TMP/state/h1.meta" "project=$proj" "mode=local-only" "kind=ship"
out=$("$BIN" h1 2>&1) || fail "happy-path merge failed: $out"
assert_contains "$out" "merged cs/h1 into local main" "happy path names the merge"
after=$(git -C "$proj" rev-parse main)
[ "$after" = "$branch_tip" ] || fail "happy path: main was not fast-forwarded to the branch tip"
[ "$after" != "$before" ] || fail "happy path: main did not advance"
pass "cs-merge-local fast-forwards the default branch for a clean local-only task"

# 2. missing meta -> exit 1, names the missing meta, merges nothing.
set +e
out=$("$BIN" no-such-task 2>&1); rc=$?
set -e
expect_code 1 "$rc" "missing meta should exit 1"
assert_contains "$out" "no meta for task" "missing-meta refusal names the reason"
pass "cs-merge-local refuses a task with no meta"

# 3. mode != local-only -> exit 1, points at cs-pr-merge.sh, does not merge.
proj=$(make_proj m1)
before=$(git -C "$proj" rev-parse main)
cs_write_meta "$TMP/state/m1.meta" "project=$proj" "mode=no-mistakes" "kind=ship"
set +e
out=$("$BIN" m1 2>&1); rc=$?
set -e
expect_code 1 "$rc" "non-local-only mode should exit 1"
assert_contains "$out" "not local-only" "wrong-mode refusal names the mode gate"
[ "$(git -C "$proj" rev-parse main)" = "$before" ] || fail "wrong mode: main must not move"
pass "cs-merge-local refuses a non-local-only task without merging"

# 4. branch cs/<id> absent -> exit 1, does not merge.
proj="$TMP/proj-nobr"
cs_git_init_commit "$proj"
git -C "$proj" branch -q -M main
before=$(git -C "$proj" rev-parse main)
cs_write_meta "$TMP/state/nobr.meta" "project=$proj" "mode=local-only" "kind=ship"
set +e
out=$("$BIN" nobr 2>&1); rc=$?
set -e
expect_code 1 "$rc" "absent branch should exit 1"
assert_contains "$out" "branch cs/nobr does not exist" "absent-branch refusal names the branch"
[ "$(git -C "$proj" rev-parse main)" = "$before" ] || fail "absent branch: main must not move"
pass "cs-merge-local refuses when the task branch does not exist"

# 5. main checkout not on the default branch -> exit 1, does not merge.
proj=$(make_proj wb1)
git -C "$proj" checkout -q "cs/wb1"   # park the checkout off the default branch
before=$(git -C "$proj" rev-parse main)
cs_write_meta "$TMP/state/wb1.meta" "project=$proj" "mode=local-only" "kind=ship"
set +e
out=$("$BIN" wb1 2>&1); rc=$?
set -e
expect_code 1 "$rc" "off-default checkout should exit 1"
assert_contains "$out" "expected default branch" "off-default refusal names the expected branch"
[ "$(git -C "$proj" rev-parse main)" = "$before" ] || fail "off-default: main must not move"
pass "cs-merge-local refuses when the main checkout is not on the default branch"

# 6. dirty working tree -> exit 1, does not merge, work preserved.
proj=$(make_proj d1)
before=$(git -C "$proj" rev-parse main)
printf 'scratch\n' > "$proj/dirty.txt"
cs_write_meta "$TMP/state/d1.meta" "project=$proj" "mode=local-only" "kind=ship"
set +e
out=$("$BIN" d1 2>&1); rc=$?
set -e
expect_code 1 "$rc" "dirty tree should exit 1"
assert_contains "$out" "dirty working tree" "dirty-tree refusal names the reason"
[ "$(git -C "$proj" rev-parse main)" = "$before" ] || fail "dirty tree: main must not move"
assert_present "$proj/dirty.txt" "dirty tree: uncommitted work preserved"
pass "cs-merge-local refuses a dirty project checkout without merging"

# 7. diverged branch (not a fast-forward) -> exit 1, REFUSED, does not merge.
proj=$(make_proj v1 --diverge)
before=$(git -C "$proj" rev-parse main)
cs_write_meta "$TMP/state/v1.meta" "project=$proj" "mode=local-only" "kind=ship"
set +e
out=$("$BIN" v1 2>&1); rc=$?
set -e
expect_code 1 "$rc" "diverged branch should exit 1"
assert_contains "$out" "REFUSED" "divergence refusal is loud"
assert_contains "$out" "not a fast-forward" "divergence refusal names the reason"
[ "$(git -C "$proj" rev-parse main)" = "$before" ] || fail "diverged: main must not move"
pass "cs-merge-local refuses a diverged (non-fast-forward) branch without merging"

# 8. no task id -> usage refusal.
set +e
out=$("$BIN" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "no-arg invocation should be non-zero"
assert_contains "$out" "usage" "no-arg invocation prints usage"
pass "cs-merge-local refuses with usage when given no task id"

pass "cs-merge-local guarded fast-forward behavior characterized"
