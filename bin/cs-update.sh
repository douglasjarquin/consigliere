#!/usr/bin/env bash
# Self-update a running consigliere and its capos to the latest origin.
#
# Mechanical half of the /update-consigliere skill. Fast-forwards the running
# consigliere repo's default branch from origin, then delegates the capo-home
# fast-forward to bin/cs-home-seed.sh --sweep (one FF implementation for capo
# homes, not two). FAST-FORWARD ONLY: never force, never create a merge
# commit, never stash; advance only when it is a clean fast-forward, otherwise
# skip and report. A tracked-files fast-forward never touches the gitignored
# operational dirs (data/, state/, config/, projects/, .no-mistakes/), so
# in-flight work is never disrupted.
#
# It does NOT re-read AGENTS.md or nudge capos itself - those are LLM actions
# the skill performs. The script's job is the safe git mechanics plus a
# parseable summary telling the caller what to do next:
#   - one status line for the main repo (updated/already current/skipped)
#   - CAPO_SYNC: lines from the capo sweep
#   - reread-consigliere: yes|no  (did the running instructions change)
#   - nudge-capos: <id>...|none   (updated live capos to nudge via cs-send)
#
# Usage: cs-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root

"$SCRIPT_DIR/cs-guard.sh" || true

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  echo "usage: cs-update.sh [--help]" >&2
  exit 0
fi
[ $# -eq 0 ] || { echo "usage: cs-update.sh [--help]" >&2; exit 1; }

# Instruction surfaces a running consigliere actually loads: a change here
# means the LLM must re-read after the fast-forward.
INSTR_PATHS='AGENTS.md bin/ skills/'

default_branch() {
  local ref
  if ref=$(git -C "$CS_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); then
    printf '%s' "${ref#origin/}"
    return 0
  fi
  for ref in main master; do
    git -C "$CS_ROOT" show-ref --verify --quiet "refs/heads/$ref" && { printf '%s' "$ref"; return 0; }
  done
  return 1
}

reread=no
if ! git -C "$CS_ROOT" remote get-url origin >/dev/null 2>&1; then
  echo "consigliere: skipped (no origin remote configured)"
else
  BRANCH=$(default_branch) || { echo "consigliere: skipped (cannot determine default branch)"; exit 0; }
  cur=$(git -C "$CS_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
  if [ "$cur" != "$BRANCH" ]; then
    echo "consigliere: skipped (checkout is on '$cur', not default branch '$BRANCH'; resolve the tangle first)"
  elif ! git -C "$CS_ROOT" fetch --quiet origin "$BRANCH"; then
    echo "consigliere: skipped (fetch failed)"
  else
    before=$(git -C "$CS_ROOT" rev-parse HEAD)
    remote=$(git -C "$CS_ROOT" rev-parse "refs/remotes/origin/$BRANCH")
    if [ "$before" = "$remote" ]; then
      echo "consigliere: already current ($(git -C "$CS_ROOT" rev-parse --short HEAD))"
    elif ! git -C "$CS_ROOT" merge-base --is-ancestor "$before" "$remote"; then
      echo "consigliere: skipped (local default branch has diverged from origin; never forced)"
    elif [ -n "$(git -C "$CS_ROOT" status --porcelain --untracked-files=no 2>/dev/null | head -1)" ]; then
      # Tracked modifications only: untracked files never block a
      # fast-forward (git itself refuses a real path collision), and a
      # running home always carries untracked operational files.
      echo "consigliere: skipped (working tree has tracked modifications; commit or clean before updating)"
    else
      git -C "$CS_ROOT" merge --ff-only --quiet "refs/remotes/origin/$BRANCH"
      after=$(git -C "$CS_ROOT" rev-parse HEAD)
      echo "consigliere: updated ($(git -C "$CS_ROOT" rev-parse --short "$before") -> $(git -C "$CS_ROOT" rev-parse --short "$after"))"
      # shellcheck disable=SC2086 # INSTR_PATHS is a deliberate word list
      if [ -n "$(git -C "$CS_ROOT" diff --name-only "$before" "$after" -- $INSTR_PATHS | head -1)" ]; then
        reread=yes
      fi
    fi
  fi
fi

# Capo homes: one FF implementation, owned by the seed sweep. Its CAPO_SYNC
# lines name each advanced home; an advanced LIVE capo should be nudged.
nudge=""
if [ -x "$SCRIPT_DIR/cs-home-seed.sh" ] && [ -f "$CONFIG_HOST/capos.md" ]; then
  sweep_out=$("$SCRIPT_DIR/cs-home-seed.sh" --sweep 2>&1) || true
  [ -z "$sweep_out" ] || printf '%s\n' "$sweep_out"
  # Must match what the sweep actually emits: "CAPO_SYNC: capo <id>: updated
  # <before>..<after>" (pinned by tests/cs-home-seed.test.sh). Matching only
  # `updated` is deliberate - a skipped home was NOT advanced, so nudging it
  # would tell a capo to re-read instructions it never received.
  nudge=$(printf '%s\n' "$sweep_out" | sed -n 's/^CAPO_SYNC: capo \([^:]*\): updated .*/\1/p' | tr '\n' ' ' | sed 's/ $//')
fi

echo "reread-consigliere: $reread"
echo "nudge-capos: ${nudge:-none}"
