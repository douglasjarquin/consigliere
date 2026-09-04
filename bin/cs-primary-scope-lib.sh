#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for tracked hooks that must act
# only in a genuine consigliere primary home.
# This file is sourced by hook entrypoints and has no side effects on source.

# Return 0 when $1 carries a genuine capo-home marker.
cs_root_is_capo_home() {
  local marker="$1/.cs-capo-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid capo marker force-includes a linked capo home (a capo runs its OWN
# primary consigliere session, guarded like the main primary).
# Otherwise only a plain checkout is primary, never a linked task worktree:
# soldier task worktrees are genuine linked `git worktree`s whose git-dir lives
# under the parent repo's .git/worktrees/<name> and differs from the common
# git-dir, while a main, non-worktree checkout has the two equal. Child
# worktrees never carry the gitignored marker, so this exempts them while
# guarding every real capo home.
cs_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir
  if ! cs_root_is_capo_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
    [ -z "${CS_TASK_ID:-}" ] || return 1
  fi
  cs_primary_worktree_matches "$root" || return 1
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}

cs_primary_worktree_matches() {
  local root=$1 cwd root_top
  cwd=$(pwd -P) || return 1
  if cs_root_is_capo_home "$root"; then
    root_top=$root
  else
    root_top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || return 1
  fi
  root_top=$(CDPATH='' cd -- "$root_top" && pwd -P) || return 1
  [ "$cwd" = "$root_top" ]
}
