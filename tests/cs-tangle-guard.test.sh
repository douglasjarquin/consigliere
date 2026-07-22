#!/usr/bin/env bash
# Behavior tests for the worktree-tangle guard.
#
# Consigliere is a treehouse-pooled git repo of itself: linked worktrees and
# capo homes all sit at a detached HEAD on the default branch, while the
# PRIMARY checkout (CS_ROOT) is a normal checkout on a real branch. The "tangle"
# is a soldier branching/committing in the primary instead of its own worktree,
# stranding the primary on a feature branch. These cases pin the detection
# guard: the shared lib's branch classification and the cs-guard banner - all
# hermetic over temp git repos.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/cs-tangle-lib.sh
. "$ROOT/bin/cs-tangle-lib.sh"

TMP_ROOT=$(cs_test_tmproot cs-tangle-guard)
cs_git_identity cstest cstest@example.invalid

# A fresh git repo on `main` with one commit. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" -c user.name='Consigliere Tests' -c user.email='tests@example.invalid' commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# --- shared lib: branch classification --------------------------------------

# cs_primary_tangle_branch is the whole scoping decision: a NAMED non-default
# branch is the tangle; the default branch and detached HEAD are healthy.
test_lib_classification() {
  local repo n=0 label state branch expect out
  repo=$(make_repo "$TMP_ROOT/lib-repo")
  while IFS='|' read -r label state branch expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case "$state" in
      default)  git -C "$repo" checkout -q main ;;
      feature)  git -C "$repo" checkout -q -B "$branch" ;;
      detached) git -C "$repo" checkout -q main; git -C "$repo" checkout -q --detach ;;
    esac
    out=$(cs_primary_tangle_branch "$repo" || true)
    [ "$out" = "$expect" ] || fail "$label: expected tangle='$expect', got '$out'"
  done <<'ROWS'
on the default branch is healthy|default||
on a feature branch is the tangle|feature|cs/readme-restructure-d3|cs/readme-restructure-d3
detached HEAD on default is healthy (worktrees, capo homes)|detached||
ROWS
  # A non-git directory is not a tangle and must not error.
  out=$(cs_primary_tangle_branch "$TMP_ROOT" || true)
  [ -z "$out" ] || fail "non-git dir wrongly reported a tangle: '$out'"
  pass "cs_primary_tangle_branch: feature branch alarms; default/detached/non-git stay silent"
}

# --- detection guard: cs-guard banner ----------------------------------------

run_guard() {
  # Scope the guard to a temp repo as the primary checkout; state lives under it.
  CS_ROOT_OVERRIDE="$1" CS_HOME="$1" "$ROOT/bin/cs-guard.sh" 2>&1
}

test_guard_banner() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/guard-repo")

  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed while primary was on main"

  git -C "$repo" checkout -q --detach
  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed on a detached HEAD (legitimate worktree state)"

  git -C "$repo" checkout -q -B cs/tangle-aa1
  out=$(run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "guard did not alarm on a feature branch in the primary"
  assert_contains "$out" "cs/tangle-aa1" "guard banner did not name the offending branch"
  assert_contains "$out" "checkout main" "guard banner did not print the restore remediation"
  out=$(CS_GUARD_READ_ONLY=1 run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "read-only guard did not keep the tangle alarm"
  assert_contains "$out" "read-only session must leave restore work" "read-only guard did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "read-only guard printed a state-changing restore command"
  pass "cs-guard: bordered tangle banner fires only for a feature branch and suppresses repair commands in read-only mode"
}

test_lib_classification
test_guard_banner
