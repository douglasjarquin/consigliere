#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cs-runtime-contract.XXXXXX")
CHECKOUT="$TMP_ROOT/checkout"
WORKTREE_CREATED=0

cleanup() {
  if [ "$WORKTREE_CREATED" -eq 1 ]; then
    git -C "$ROOT" worktree remove --force "$CHECKOUT" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

git -C "$ROOT" worktree add --detach --quiet "$CHECKOUT" HEAD
WORKTREE_CREATED=1

[ -f "$CHECKOUT/AGENTS.md" ] || fail "fresh worktree is missing the Consigliere instruction contract"
[ -L "$CHECKOUT/CLAUDE.md" ] || fail "fresh worktree is missing CLAUDE.md -> AGENTS.md"
[ "$(readlink "$CHECKOUT/CLAUDE.md")" = "AGENTS.md" ] || fail "CLAUDE.md must point to AGENTS.md"
[ -d "$CHECKOUT/skills" ] || fail "fresh worktree is missing local skills"
[ -L "$CHECKOUT/.agents/skills" ] || fail "fresh worktree is missing Codex skill discovery"
[ -L "$CHECKOUT/.claude/skills" ] || fail "fresh worktree is missing Claude skill discovery"
[ -f "$CHECKOUT/.agents/skills/consigliere-coding-guidelines/SKILL.md" ] || fail "Codex cannot discover Consigliere skills"
[ -f "$CHECKOUT/.claude/skills/consigliere-coding-guidelines/SKILL.md" ] || fail "Claude cannot discover Consigliere skills"
[ -x "$CHECKOUT/bin/cs-doctor.sh" ] || fail "fresh worktree is missing the documented doctor command"

PATH="/opt/homebrew/bin:$PATH" "$CHECKOUT/bin/cs-doctor.sh" --help >/dev/null \
  || fail "doctor command must execute in a fresh worktree"

pass "fresh worktree exposes the Consigliere runtime contract"
