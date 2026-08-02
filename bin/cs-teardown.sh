#!/usr/bin/env bash
# Tear down a finished task: kill the recorded pane, remove the herdr-native
# task worktree, clear volatile state, and refresh the project's clone for
# PR-based ship tasks; or retire a capo home.
#
# REFUSES if the worktree holds work that has not LANDED, because cleanup
# removes the worktree and kills its processes. Work has landed when it is
# reachable from any remote-tracking branch (a fork counts as a remote), OR -
# for a normal ship task whose commits are not so reachable - when its PR is
# merged and GitHub reports a PR head that contains the current local work, or
# its content is already present in the up-to-date default branch. This
# recognizes the common squash-merge-then-delete-branch flow.
# The PR is resolved from the task's recorded pr= when present, or by looking
# up a PR whose head branch matches the worktree's branch, fetching its head
# via refs/pull/<n>/head when the branch itself was deleted. A gh lookup error
# falls back to the content check; if that is also inconclusive, teardown
# refuses rather than risk discarding unlanded work.
# Uncommitted changes are never landed.
# local-only projects additionally accept work merged into the local default
# branch as a fallback for the no-remote case.
# Scout tasks (kind=scout) carve out of that check: their worktree is declared
# scratch and the report at data/<id>/report.md is the work product. Teardown
# proceeds only once the report exists and (when bin/cs-decision-hold.sh is
# installed) the unresolved-decision completion gate passes.
# Capos (kind=capo) are retired explicitly. Normal teardown refuses while
# their home has in-flight soldier meta files, or while it still has armed
# blocking sources or owns process claims that would leak a child against a
# shared external source (bin/cs-procevent.sh retire-home is the bounded
# retirement it runs first); --force is the approved discard path. Removing the
# home never touches anything under projects/ clones.
#
# The herdr `worktree remove` runs only AFTER these proofs pass; its own
# dirty-refusal is a backstop, never the safety mechanism. A ship remove that
# still trips herdr's dirty check is a stop-and-investigate result.
# Transient / stale worktree git-lock recovery: a killed soldier process can
# leave .git lock files; cs-lock-lib.sh owns the provably-stale proof before
# any lock is cleared, and any uncertainty refuses.
#
# Usage: cs-teardown.sh <task-id> [--force]
#   --force skips ordinary-task dirty and landed-work checks, skips scout
#   report checks, and discards capo child work for kind=capo. Only use it
#   when the boss has explicitly said to discard the work.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"
# shellcheck source=bin/cs-harness-lib.sh
. "$SCRIPT_DIR/cs-harness-lib.sh"
# shellcheck source=bin/cs-lock-lib.sh
CS_LOCK_LOG_PREFIX="cs-teardown" . "$SCRIPT_DIR/cs-lock-lib.sh"

# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
CAPO_REG="$DATA/capos.md"

ID=${1:?usage: cs-teardown.sh <task-id> [--force]}
FORCE=${2:-}
case "$FORCE" in ''|--force) ;; *) echo "error: unknown flag '$FORCE'" >&2; exit 2 ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no metadata for task '$ID' at $META" >&2; exit 1; }

WT=$(cs_meta_get "$META" worktree || true)
PROJ=$(cs_meta_get "$META" project || true)
PANE=$(cs_meta_get "$META" pane || true)
WS=$(cs_meta_get "$META" workspace || true)
KIND=$(cs_meta_get "$META" kind || echo ship)
MODE=$(cs_meta_get "$META" mode || echo no-mistakes)
PR_URL=$(cs_meta_get "$META" pr || true)
HOME_PATH=$(cs_meta_get "$META" home || true)
HARNESS=$(cs_meta_get "$META" harness 2>/dev/null || true)

# Minimum age before a git lock with no live holder is considered abandoned.
STALE_LOCK_MIN_AGE=${CS_TEARDOWN_STALE_LOCK_MIN_AGE:-30}
TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED=3

default_branch() {
  local ref name
  if ref=$(git -C "$WT" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null); then
    printf '%s' "${ref#refs/remotes/origin/}"
    return 0
  fi
  for name in main master; do
    if git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1 \
       || git -C "$WT" rev-parse --quiet --verify "refs/remotes/origin/$name" >/dev/null 2>&1; then
      printf '%s' "$name"
      return 0
    fi
  done
  return 1
}

# --- landed-work proofs (ported from firstmate; the sacred logic) -----------

pr_number_from_branch() {
  local branch=$1 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$WT" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

ensure_commit_object() {
  local target=$1 commit=$2 n
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(pr_number_from_target "$target") || return 1
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$WT" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null
}

patch_id_for_commit() {
  local commit=$1
  git -C "$WT" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

unpushed_patches_are_in_pr_head() {
  local pr_head=$1 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$WT" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$WT" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          patch_id_for_commit "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$WT" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(patch_id_for_commit "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# Is the worktree's PR merged for local work contained in that PR? Resolves the
# PR from the recorded pr= URL first, then from the branch name, and asks
# GitHub for both the PR state and head. Returns non-zero when the PR is not
# merged, the current work is not contained in the PR head, no PR is found, or
# any gh error occurs - the caller then falls back to the content check.
pr_is_merged() {
  local branch=$1 target view state head current
  if [ -n "$PR_URL" ]; then
    target=$PR_URL
  else
    target=$(pr_number_from_branch "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$WT" && gh pr view "$target" --json state,headRefOid -q '.state + "\t" + .headRefOid' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  head=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  ensure_commit_object "$target" "$head" || return 1
  current=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || return 1
  git -C "$WT" merge-base --is-ancestor "$current" "$head" 2>/dev/null && return 0
  unpushed_patches_are_in_pr_head "$head"
}

# Is the branch's content already present in the up-to-date default branch?
# Fetches first, then 3-way merges the default branch with HEAD: when HEAD
# introduces nothing the default branch does not already contain (e.g. its
# change landed via squash) the merged tree equals the default branch's tree.
# Returns non-zero when inconclusive, so the caller refuses rather than guesses.
content_in_default() {
  local name ref default_tree merged_tree
  name=$(default_branch) || return 1
  if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    git -C "$WT" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$WT" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$WT" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$WT" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

# Has the worktree's committed work actually LANDED, though its commits are
# not reachable from any remote-tracking branch? True when a merged PR proves
# the current local work is contained in the PR head, OR the content is
# already in the default branch. False only for genuinely unlanded work.
work_is_landed() {
  local branch=$1
  pr_is_merged "$branch" && return 0
  content_in_default
}

# --- stale git-lock recovery -------------------------------------------------

worktree_git_lock_path() { # -> the worktree's index.lock path, if any exists
  local gitdir
  gitdir=$(git -C "$WT" rev-parse --git-dir 2>/dev/null) || return 1
  case "$gitdir" in
    /*) ;;
    *) gitdir="$WT/$gitdir" ;;
  esac
  [ -e "$gitdir/index.lock" ] || return 1
  printf '%s' "$gitdir/index.lock"
}

worktree_safety_blocked_by_lock() { # <what>
  local lock
  lock=$(worktree_git_lock_path) || return 1
  echo "note: git inspection for $1 blocked by lock $lock" >&2
  return 0
}

cleanup_stale_lock_for_safety_check() { # <worktree>
  local lock
  lock=$(worktree_git_lock_path) || {
    echo "REFUSED: git inspection failed but no lock file found; investigate $WT by hand." >&2
    return 1
  }
  if cs_lock_is_provably_stale "$lock" "$WT" "$STALE_LOCK_MIN_AGE"; then
    echo "note: removing provably stale git lock $lock" >&2
    rm -f "$lock"
    return 0
  fi
  echo "REFUSED: git lock $lock is not provably stale; a live process may hold it. Retry later or investigate." >&2
  return 1
}

# --- pane quiesce (freeze the soldier before the safety proof) --------------

# Close the recorded pane and wait, bounded, until no live agent remains in it,
# so the worktree cleanliness snapshot taken by validate_worktree_teardown_safety
# is against a frozen worktree the soldier is no longer writing to, and any
# index.lock the agent held has been released. A no-op when PANE is empty. Never
# fails teardown: closing an already-closed pane is harmless, and the wait is
# bounded so a --force discard never hangs on an agent that will not die.
quiesce_pane() {
  local waited=0
  [ -n "$PANE" ] || return 0
  cs_herdr_pane_close "$PANE" >/dev/null 2>&1 || true
  while cs_herdr_agent_alive "$PANE"; do
    [ "$waited" -ge 30 ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  return 0
}

# --- confirmed-gone gate (never erase the records of a surviving pane) ------

# The durable records are the only thing tying consigliere to a running soldier.
# Erase them while the pane is still alive and that soldier is stranded: no
# status, no metadata, no supervision, and nothing left pointing at it.
#
# `pane close` cannot answer this. Its status is discarded by every caller here,
# and a close that succeeded, a close that was refused, and a close that never
# reached the server all look identical from the exit code. So removal is gated
# on a positive structured proof of absence from herdr instead
# (cs_herdr_pane_presence: only a pane_not_found body counts as dead; present
# and unknown both refuse). Bounded, because close is asynchronous - herdr may
# still be tearing the pane down when it returns.
PANE_PRESENCE_STATE=""
confirm_pane_gone() { # -> 0 proven gone, 1 not proven
  local waited=0
  # No recorded pane means there is nothing that could be stranded.
  [ -n "$PANE" ] || return 0
  # Missing confirmation machinery is a refusal, not a skip. A gate that
  # disappears silently when its helper is absent is worse than no gate: it
  # reads as "proven gone" on exactly the broken installs that need it most.
  if ! command -v cs_herdr_pane_presence >/dev/null 2>&1; then
    PANE_PRESENCE_STATE="no-presence-helper"
    return 1
  fi
  while :; do
    PANE_PRESENCE_STATE=$(cs_herdr_pane_presence "$PANE")
    [ "$PANE_PRESENCE_STATE" = dead ] && return 0
    [ "$waited" -ge 30 ] && return 1
    sleep 0.1
    waited=$((waited + 1))
  done
}

# Refuse loudly and retryably. Called before anything irreversible, so the
# isolated copy, the task branch, every durable record, and the endpoint are all
# still intact for a plain rerun.
#
# Under --force the boss has given explicit discard authority and the removal
# proceeds, because refusing there would deadlock cleanup whenever herdr is
# unreachable. It is still not silent: --force authorizes discarding unlanded
# WORK, and stranding a live soldier is a different consequence than the boss
# was asked about, so it is named on the way past rather than swallowed.
require_pane_gone() { # <what-is-being-retained>
  confirm_pane_gone && return 0
  if [ "$FORCE" = "--force" ]; then
    echo "WARNING: proceeding under --force without proof that pane $PANE is gone - herdr reports '${PANE_PRESENCE_STATE:-unknown}'." >&2
    echo "WARNING: if that pane is still alive it is now orphaned: no status, no metadata, no supervision. Check it by hand." >&2
    return 0
  fi
  echo "REFUSED: cannot confirm pane $PANE is gone - herdr reports '${PANE_PRESENCE_STATE:-unknown}'." >&2
  case "$PANE_PRESENCE_STATE" in
    present) echo "That pane is still alive. Closing it was refused or has not taken effect; erasing $1 now would strand a running soldier." >&2 ;;
    *)       echo "herdr could not answer, so absence is unproven; an unreachable server is not evidence the soldier is gone." >&2 ;;
  esac
  echo "Nothing was removed. Rerun teardown once the pane is confirmed gone, or use --force after explicit discard approval." >&2
  return 1
}

# --- the fail-closed safety check -------------------------------------------

validate_worktree_teardown_safety() {
  local dirty_raw dirty unpushed_raw unpushed DEFAULT unmerged_raw unmerged branch
  [ -d "$WT" ] || return 0
  [ "$FORCE" != "--force" ] || return 0
  case "$KIND" in
    capo|scout) return 0 ;;
  esac

  if ! dirty_raw=$(git -C "$WT" status --porcelain 2>/dev/null); then
    if worktree_safety_blocked_by_lock "uncommitted changes"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for uncommitted changes." >&2
    echo "Restore the git index state, or get the boss's explicit OK to discard, then --force." >&2
    return 1
  fi
  dirty=$(printf '%s\n' "$dirty_raw" | grep -vE '^\?\? \.codex/' | head -1 || true)

  if ! unpushed_raw=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null); then
    if worktree_safety_blocked_by_lock "commits not on a remote"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for commits not on a remote." >&2
    echo "Restore the git index state, or get the boss's explicit OK to discard, then --force." >&2
    return 1
  fi
  unpushed=$(printf '%s\n' "$unpushed_raw" | head -5)

  if [ -n "$unpushed" ] && [ "$MODE" = local-only ]; then
    DEFAULT=$(default_branch) || { echo "REFUSED: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master." >&2; return 1; }
    if ! unmerged_raw=$(git -C "$WT" log --oneline HEAD --not "$DEFAULT" -- 2>/dev/null); then
      if worktree_safety_blocked_by_lock "commits not on $DEFAULT"; then
        return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
      fi
      echo "REFUSED: cannot inspect worktree $WT for commits not on $DEFAULT." >&2
      echo "Restore the git index state, or get the boss's explicit OK to discard, then --force." >&2
      return 1
    fi
    unmerged=$(printf '%s\n' "$unmerged_raw" | head -5)
    if [ -n "$dirty" ] || [ -n "$unmerged" ]; then
      echo "REFUSED: local-only worktree $WT has work not yet merged into $DEFAULT and not on any remote." >&2
      [ -n "$dirty" ] && echo "uncommitted changes present" >&2
      [ -n "$unmerged" ] && printf 'commits not yet on %s:\n%s\n' "$DEFAULT" "$unmerged" >&2
      echo "Merge the branch into local $DEFAULT first (bin/cs-merge-local.sh after the boss approves), or push to a fork/remote, or get the boss's explicit OK to discard, then --force." >&2
      return 1
    fi
  elif [ -n "$dirty" ]; then
    echo "REFUSED: worktree $WT has uncommitted changes." >&2
    echo "uncommitted changes present" >&2
    echo "Commit them (or get the boss's explicit OK to discard, then --force)." >&2
    return 1
  elif [ -n "$unpushed" ]; then
    branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
    if ! work_is_landed "$branch"; then
      echo "REFUSED: worktree $WT has work not on any remote and not landed." >&2
      printf 'unpushed commits:\n%s\n' "$unpushed" >&2
      echo "Push the branch, land its PR, or get the boss's explicit OK to discard, then --force." >&2
      return 1
    fi
  fi
}

# --- PR-poll / check artifact cleanup ----------------------------------------
# Each artifact must be an ordinary non-symlink file before removal; anything
# else is preserved and teardown refuses, because a substituted artifact is
# evidence of tampering, not garbage.

remove_task_artifacts() {
  local f
  for f in "$STATE/$ID.check.sh" "$STATE/$ID.check-trust" "$STATE/$ID.pr-poll" "$STATE/$ID.pr-poll-registration"; do
    if [ -L "$f" ]; then
      echo "REFUSED: $f is a symlink, not the ordinary file teardown created; investigate before cleanup." >&2
      return 1
    fi
    [ -e "$f" ] && rm -f "$f"
  done
  return 0
}

# --- watcher per-task/per-pane marker cleanup --------------------------------
# The watcher (bin/cs-watch.sh) derives many long-lived marker files under
# $STATE keyed by a task's id or its herdr pane. Because task ids and pane ids
# (w<N>:p<N>) are reused, a stale marker left by a prior task can make the next
# task's status look "already surfaced" (a swallowed wake) or leak into its
# stale/wedge tracking. Teardown removes exactly THIS task's derived markers, by
# exact derived name (never a glob that could match a concurrent task's marker),
# mirroring the watcher's own key derivation:
#   - .seen-<id>_status / .seen-<id>_turn-ended  (scan_signals: basename|tr '.' '_')
#   - .hb-surfaced-<id-tr>                        (_hb_surfaced_path, keyed by task id)
#   - .hash-/.count-/.stale-/.stale-since-/.wedge-escalations-<pane-tr>
#                                                 (stale/wedge poll, keyed by pane)
#   - .herdr-escalated-<pane-tr>                  (cs_transition_marker, keyed by pane)
# LOCKSTEP: if the watcher grows a new per-task/per-pane marker family, extend
# this helper in the same change. A derived marker is always an ordinary file,
# so (as remove_task_artifacts does) refuse if one is unexpectedly a symlink.
remove_watcher_markers() {
  local m id_key pane_key markers=()
  id_key=$(printf '%s' "$ID" | tr ':/.' '___')
  markers+=(
    "$STATE/.seen-$(printf '%s' "$ID.status" | tr '.' '_')"
    "$STATE/.seen-$(printf '%s' "$ID.turn-ended" | tr '.' '_')"
    "$STATE/.hb-surfaced-$id_key"
  )
  if [ -n "$PANE" ]; then
    pane_key=$(printf '%s' "$PANE" | tr ':/.' '___')
    markers+=(
      "$STATE/.hash-$pane_key"
      "$STATE/.count-$pane_key"
      "$STATE/.stale-$pane_key"
      "$STATE/.stale-since-$pane_key"
      "$STATE/.wedge-escalations-$pane_key"
      "$STATE/.herdr-escalated-$pane_key"
    )
  fi
  for m in "${markers[@]}"; do
    if [ -L "$m" ]; then
      echo "REFUSED: $m is a symlink, not the ordinary marker the watcher created; investigate before cleanup." >&2
      return 1
    fi
    [ -e "$m" ] && rm -f "$m"
  done
  return 0
}

# --- capo retirement ---------------------------------------------------------

remove_capo_registry_entry() {
  local id=$1 tmp
  [ -f "$CAPO_REG" ] || return 0
  tmp="$CAPO_REG.tmp.$$"
  grep -vE "^- $id( |$)" "$CAPO_REG" > "$tmp" || true
  mv "$tmp" "$CAPO_REG"
}

# --- main flow ---------------------------------------------------------------

if [ "$KIND" = capo ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  [ -n "$HOME_PATH" ] || { echo "error: capo $ID has no recorded home" >&2; exit 1; }
  [ -f "$HOME_PATH/.cs-capo-home" ] || {
    echo "REFUSED: '$HOME_PATH' is not a marked capo home (.cs-capo-home missing); refusing to remove an unverified directory." >&2
    exit 1
  }
  if [ "$FORCE" != "--force" ] && [ -d "$HOME_PATH/state" ]; then
    for child_meta in "$HOME_PATH/state"/*.meta; do
      [ -e "$child_meta" ] || continue
      echo "REFUSED: capo $ID still has in-flight work in $HOME_PATH/state." >&2
      echo "Found $(basename "$child_meta"). Let that home finish or explicitly discard with --force." >&2
      exit 1
    done
  fi
  # Blocking sources this home armed, and claims it owns machine-wide, must be
  # retired BEFORE the home is removed: the claim root and the external source
  # both outlive the home, so an abandoned registration leaks a blocking child
  # against a shared external source and keeps a claim no home can release.
  if [ -x "$SCRIPT_DIR/cs-procevent.sh" ]; then
    if ! CS_HOME="$HOME_PATH" CS_STATE_OVERRIDE="$HOME_PATH/state" \
        "$SCRIPT_DIR/cs-procevent.sh" retire-home >/dev/null; then
      if [ "$FORCE" != "--force" ]; then
        echo "REFUSED: capo $ID still holds armed blocking sources or owns process claims." >&2
        echo "Retire them from that home (bin/cs-procevent.sh retire-home) before cleanup, or explicitly discard with --force." >&2
        exit 1
      fi
      echo "WARNING: capo $ID's blocking sources could not all be retired; --force is removing the home anyway." >&2
    fi
  fi
  [ -n "$PANE" ] && cs_herdr_pane_close "$PANE" >/dev/null 2>&1 || true
  require_pane_gone "capo $ID's home and records" || exit 1
  [ -n "$WS" ] && cs_herdr workspace close "$WS" >/dev/null 2>&1 || true
  # The capo home is a plain detached worktree of the consigliere repo.
  git -C "$CS_ROOT" worktree remove --force "$HOME_PATH" 2>/dev/null \
    || rm -rf "$HOME_PATH"
  git -C "$CS_ROOT" worktree prune 2>/dev/null || true
  remove_capo_registry_entry "$ID"
  rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.meta"
  echo "teardown $ID complete (capo home $HOME_PATH retired)"
  exit 0
fi

if [ "$KIND" = scout ] && [ "$FORCE" != "--force" ]; then
  REPORT="$DATA/$ID/report.md"
  if [ ! -f "$REPORT" ]; then
    echo "REFUSED: scout task $ID has no report at $REPORT." >&2
    echo "The report is the work product. Have the soldier write it, or use --force after explicit discard approval." >&2
    exit 1
  fi
  if [ -x "$SCRIPT_DIR/cs-decision-hold.sh" ]; then
    if ! CS_HOME="$CS_HOME" CS_STATE_OVERRIDE="$STATE" CS_DATA_OVERRIDE="$DATA" \
        "$SCRIPT_DIR/cs-decision-hold.sh" verify "$ID" >/dev/null; then
      echo "REFUSED: scout task $ID has not passed the unresolved-decision completion gate." >&2
      echo "Inventory its report and any visual review through bin/cs-decision-hold.sh before teardown." >&2
      exit 1
    fi
  fi
fi

if [ -n "$WT" ] && [ -d "$WT" ] && [ "$FORCE" != "--force" ]; then
  # Freeze the soldier before proving its worktree is safe to discard: close the
  # pane and wait for the agent to exit so the cleanliness snapshot below sees a
  # worktree no longer being written to. The post-proof pane close at the removal
  # step stays as an idempotent backstop.
  quiesce_pane
  if validate_worktree_teardown_safety; then
    :
  else
    safety_rc=$?
    if [ "$safety_rc" -eq "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED" ]; then
      cleanup_stale_lock_for_safety_check "$WT" || exit 1
      validate_worktree_teardown_safety || exit 1
    else
      exit 1
    fi
  fi
fi

# Proofs passed (or --force with explicit discard authority). Kill the pane,
# then remove the worktree through herdr. Scout worktrees are declared scratch
# and may be dirty, so their remove is forced by design once the report gate
# above has passed; a ship remove is forced only under --force.
[ -n "$PANE" ] && cs_herdr_pane_close "$PANE" >/dev/null 2>&1 || true

# Prove the pane is gone BEFORE the first irreversible step, so a refusal leaves
# the worktree, the branch, and every durable record intact for a plain rerun.
require_pane_gone "task $ID's records" || exit 1

BRANCH=""
if [ -n "$WT" ] && [ -d "$WT" ]; then
  BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  REMOVE_FORCE=""
  if [ "$FORCE" = "--force" ] || [ "$KIND" = scout ]; then
    REMOVE_FORCE="--force"
  fi
  if [ -n "$WS" ] && cs_herdr_workspace_exists "$WS"; then
    cs_herdr_worktree_remove "$WS" $REMOVE_FORCE >/dev/null || {
      echo "error: herdr worktree remove refused for $WT after the safety proofs passed; stop and investigate (do not delete by hand)." >&2
      exit 1
    }
  else
    # Workspace already gone (e.g. server restart); remove the surviving
    # worktree through git so the repo's worktree registry stays consistent.
    git -C "$PROJ" worktree remove ${REMOVE_FORCE:+--force} "$WT" 2>/dev/null || {
      echo "error: git worktree remove refused for $WT after the safety proofs passed; stop and investigate." >&2
      exit 1
    }
  fi
fi

# Best-effort: drop the local task branch so the project does not accumulate refs.
if [ -n "$BRANCH" ] && [ "$BRANCH" != HEAD ] && [ -n "$PROJ" ] && [ -d "$PROJ" ]; then
  git -C "$PROJ" branch -D "$BRANCH" >/dev/null 2>&1 || true
fi

remove_task_artifacts || exit 1
# claude soldiers pre-trust their worktree and carry a per-soldier settings file;
# drop both so the boss's claude config and state dir do not accumulate leftovers.
if [ "$HARNESS" = claude ]; then
  [ -n "$WT" ] && cs_harness_claude_untrust_dir "$WT" || true
  rm -f "$STATE/$ID.claude-settings.json"
fi
rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.meta"
remove_watcher_markers || exit 1

if [ "$KIND" != scout ] && [ "$MODE" != local-only ] && [ -x "$SCRIPT_DIR/cs-fleet-sync.sh" ] && [ -n "$PROJ" ]; then
  "$SCRIPT_DIR/cs-fleet-sync.sh" "$PROJ" || true
fi

echo "teardown $ID complete (pane ${PANE:-<none>}, worktree ${WT:-<none>})"
echo "reminder: record completion in the backlog and re-evaluate queued work."
