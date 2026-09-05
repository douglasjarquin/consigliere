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
# For the same outlives-the-home reason, a capo's herdr event-transport
# registration is unlinked before the home is removed
# (bin/cs-herdr-event-plugin.sh uninstall, whose header owns the mechanics);
# unlike the retirements above that step is fail-open, because it costs
# escalation latency, never supervision.
#
# The herdr `worktree remove` runs only AFTER these proofs pass; its own
# dirty-refusal is a backstop, never the safety mechanism. A ship remove that
# still trips herdr's dirty check is a stop-and-investigate result.
# Transient / stale worktree git-lock recovery: a killed soldier process can
# leave .git lock files; cs-lock-lib.sh owns the provably-stale proof before
# any lock is cleared, and any uncertainty refuses.
#
# Once the proofs pass and the pane is proven gone, two coupled pre-cleanup
# steps run BEFORE the worktree is removed, its branch deleted, or the workspace
# closed, both scoped to this exact task so they can never touch another task's
# run or processes:
#   1. Conclude a made run parked at a gate that belongs to this task's
#      exact branch AND current head (bin/cs-made-run-lib.sh owns that attribution,
#      the same contract cs-crew-state.sh uses). The run is aborted cd'd into the
#      worktree so the daemon resolves it, and the abort is CONFIRMED by
#      re-reading the run. Otherwise an orphaned run holds a fleet slot forever.
#   2. Reap processes whose cwd is under the task worktree (lsof), TERM then
#      KILL, re-verifying each candidate's identity immediately before signaling.
#      Otherwise backgrounded/disowned descendants reparented to init keep
#      pinning CPU under a worktree that no longer exists.
# Incomplete cleanup (an abort that did not stick, a process that survived KILL)
# is a fail-closed refusal naming what survived, downgraded to a named warning
# only under --force.
#
# When the task's metadata records backlog_item= (cs-spawn.sh --backlog-item),
# a successful ship/scout teardown also records that item done through
# tasks-axi (with the PR and scout report attached when known), before the
# final success line, so a finished task never lingers as in flight. A failed
# backlog write is a loud non-zero exit naming the item still shown in flight;
# with a manual backend or no compatible tasks-axi the close is skipped with a
# hand-edit reminder, and with no recorded item the old record-completion
# reminder is printed instead.
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
# shellcheck source=bin/cs-message-lib.sh
. "$SCRIPT_DIR/cs-message-lib.sh"
# shellcheck source=bin/cs-harness-lib.sh
. "$SCRIPT_DIR/cs-harness-lib.sh"
# shellcheck source=bin/cs-made-run-lib.sh
. "$SCRIPT_DIR/cs-made-run-lib.sh"
# shellcheck source=bin/cs-made-lib.sh
. "$SCRIPT_DIR/cs-made-lib.sh"
# shellcheck source=bin/cs-lock-lib.sh
CS_LOCK_LOG_PREFIX="cs-teardown" . "$SCRIPT_DIR/cs-lock-lib.sh"

# shellcheck source=bin/cs-capo-registry-lib.sh
. "$SCRIPT_DIR/cs-capo-registry-lib.sh"

# Backlog backend selection and the completion transition (backlog_item=).
# shellcheck source=bin/cs-tasks-lib.sh
. "$SCRIPT_DIR/cs-tasks-lib.sh"

# Optional turn telemetry (off unless host/telemetry.conf enables it).
# shellcheck source=bin/cs-telemetry-lib.sh
. "$SCRIPT_DIR/cs-telemetry-lib.sh"

# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
CAPO_REG="$HOST_DIR/capos.md"

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
CONTAINER=$(cs_meta_get "$META" container 2>/dev/null || echo workspace)
MODE=$(cs_meta_get "$META" mode || echo made)
PR_URL=$(cs_meta_get "$META" pr || true)
HOME_PATH=$(cs_meta_get "$META" home || true)
HARNESS=$(cs_meta_get "$META" harness 2>/dev/null || true)
BACKLOG_ITEM=$(cs_meta_get "$META" backlog_item 2>/dev/null || true)

# Minimum age before a git lock with no live holder is considered abandoned.
STALE_LOCK_MIN_AGE=${CS_TEARDOWN_STALE_LOCK_MIN_AGE:-30}
TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED=3

# Bounded timeout (seconds) for the pre-teardown made run query.
NM_TIMEOUT=${CS_TEARDOWN_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
NM_READ_ATTEMPTS=3
NM_READ_RETRY=0.3
# lsof is the verified mechanism for the leaked-process sweep; resolved once.
LSOF_BIN=$(command -v lsof || true)
CS_REAP_SURVIVORS=""

message_state_has_open_records() {
  local state=$1 target=$2 file id ack
  for file in "$state"/pending/*.pending; do
    [ -f "$file" ] || continue
    id=$(cs_message_pending_field "$file" message_id 2>/dev/null || true)
    [ -n "$id" ] || return 1
    cs_message_pending_close_validate_file "$state/pending/$id.closed" "$id" || return 1
  done
  for file in "$state"/inbox/*.msg; do
    [ -f "$file" ] || continue
    cs_message_validate_file "$file" || return 1
    [ "$(cs_message_field "$file" to_task_id)" = "$target" ] || continue
    ack="${file%.msg}.ack"
    if [ -e "$ack" ]; then
      cs_message_validate_ack "$ack" "$(cs_message_field "$file" message_id)" || return 1
    else
      return 1
    fi
  done
  return 0
}

reconcile_messages_before_teardown() {
  local parent_state recovery_out recovery_rc=0 has_records=0
  if [ -d "$STATE/pending" ] || [ -d "$STATE/inbox" ]; then
    has_records=1
  fi
  parent_state=$(cs_meta_get "$META" parent_state 2>/dev/null || true)
  if [ -n "$parent_state" ] && [ "$parent_state" != "$STATE" ] && {
    [ -d "$parent_state/inbox" ] || [ -d "$parent_state/pending" ];
  }; then
    has_records=1
  fi
  [ "$has_records" -eq 1 ] || return 0
  recovery_out=$(CS_HOME="${HOME_PATH:-$CS_HOME}" CS_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/cs-recover.sh" 2>&1) || recovery_rc=$?
  [ -n "$recovery_out" ] && printf '%s\n' "$recovery_out" >&2
  [ "$recovery_rc" -eq 0 ] || return 1
  message_state_has_open_records "$STATE" "$ID" || return 1
  if [ -n "$parent_state" ] && [ "$parent_state" != "$STATE" ]; then
    message_state_has_open_records "$parent_state" "$ID" || return 1
  fi
  return 0
}

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

# --- conclude a parked run + reap leaked processes --------------------------
# Two coupled pre-cleanup steps, both scoped to THIS task's exact identity so
# they can never touch another task's run or processes. They run after the pane
# is proven gone and before the worktree is removed, its branch deleted, or the
# herdr workspace is closed. Both are idempotent: a retried teardown after a
# partial first attempt finds nothing left parked and no surviving process.

# Conclude a made run that is still slot-holding (queued/running/
# awaiting_review) for this task's exact branch AND current head. Teardown can
# otherwise remove a task whose pipeline run is still in flight, leaving an
# orphaned run holding a fleet slot indefinitely. Attribution is
# bin/cs-made-run-lib.sh's contract, the same owner cs-crew-state.sh uses: a
# run on another branch, or on this branch at a rewritten or diverged head, is
# never touched. awaiting_merge and every terminal state (succeeded/failed/
# canceled/superseded) are treated as ALREADY CONCLUDED - no cancel is issued:
# made run cancel against awaiting_merge hangs ~5s then errors (docs/made.md),
# since that run's work-goroutine has already finished, and a landed task's run
# may legitimately still show awaiting_merge at teardown time since the daemon
# cannot observe the eventual GitHub merge itself. The cancel is confirmed by
# re-resolving the run rather than assumed. Returns non-zero only when a
# slot-holding run is still slot-holding after the cancel, or when made never
# answers at all.
conclude_nm_run() {
  local branch current_branch row out attempt readable=0
  CS_MADE_CONCLUDE_FAILURE=""
  [ "$MODE" = made ] || return 0
  branch=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 0
  [ -n "$branch" ] || return 0

  row=""
  for ((attempt = 1; attempt <= NM_READ_ATTEMPTS; attempt++)); do
    if row=$(cs_made_resolve_run "$WT" "$NM_TIMEOUT" "$branch"); then
      readable=1
      break
    fi
    # cs_made_resolve_run returns 1 both when made answered (well-formed JSON)
    # but no run matched this branch, and when the raw call itself failed - a
    # direct reachability probe of the same listing tells the two apart.
    if out=$(cs_made_run_read "$WT" "$NM_TIMEOUT" run list --json --active) \
       && printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
      readable=1
      break
    fi
    row=""
    [ "$attempt" -lt "$NM_READ_ATTEMPTS" ] && sleep "$NM_READ_RETRY"
  done
  if [ "$readable" -eq 0 ]; then
    CS_MADE_CONCLUDE_FAILURE="could not verify that no orphaned made run remains for this task because the daemon did not answer; retry once it responds"
    return 1
  fi
  # No run ever existed for this branch (a task that never pushed, or one
  # whose run already fell out of made's history) - nothing to conclude.
  [ -n "$row" ] || return 0

  local state run_id
  state=$(printf '%s' "$row" | jq -r '.state // empty')
  run_id=$(printf '%s' "$row" | jq -r '.run_id // empty')
  case "$state" in
    queued|running|awaiting_review) ;;
    *) return 0 ;;  # awaiting_merge, succeeded, failed, canceled, superseded: already concluded
  esac

  current_branch=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null) || {
    CS_MADE_CONCLUDE_FAILURE="task identity changed under teardown, so it cannot safely conclude this made run; retry"
    return 1
  }
  if [ "$current_branch" != "$branch" ]; then
    CS_MADE_CONCLUDE_FAILURE="task identity changed under teardown, so it cannot safely conclude this made run; retry"
    return 1
  fi

  echo "note: concluding this task's made run ($state) before cleanup." >&2
  cs_made_run_cancel "$run_id" >/dev/null 2>&1 || true
  local confirmation_readable=0 still_holding=0 confirm_state=""
  for ((attempt = 1; attempt <= NM_READ_ATTEMPTS; attempt++)); do
    if row=$(cs_made_resolve_run "$WT" "$NM_TIMEOUT" "$branch"); then
      confirmation_readable=1
      confirm_state=$(printf '%s' "$row" | jq -r '.state // empty')
      case "$confirm_state" in
        queued|running|awaiting_review) still_holding=1 ;;
        *) still_holding=0 ;;
      esac
      [ "$still_holding" -eq 0 ] && break
    elif out=$(cs_made_run_read "$WT" "$NM_TIMEOUT" run list --json --active) \
         && printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
      confirmation_readable=1
      still_holding=0
      break
    fi
    [ "$attempt" -lt "$NM_READ_ATTEMPTS" ] && sleep "$NM_READ_RETRY"
  done
  if [ "$confirmation_readable" -eq 0 ]; then
    CS_MADE_CONCLUDE_FAILURE="cancel was issued, but teardown could not confirm that this task's made run stopped; retry after the daemon responds"
  elif [ "$still_holding" -eq 1 ]; then
    CS_MADE_CONCLUDE_FAILURE="this task's made run is still ${confirm_state:-active} after a cancel attempt"
  else
    return 0
  fi
  return 1
}

proc_cwd() {
  "$LSOF_BIN" -a -d cwd -p "$1" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
}

proc_cwd_under_roots() {
  local pid=$1 cwd root
  shift
  cwd=$(proc_cwd "$pid") || return 1
  [ -n "$cwd" ] || return 1
  for root in "$@"; do
    case "$cwd/" in
      "$root"/*) return 0 ;;
    esac
  done
  return 1
}

reap_pid_is_teardown_ancestry() {
  local candidate=$1 current=$$ next
  while :; do
    [ "$candidate" = "$current" ] && return 0
    [ "$current" = 1 ] && return 1
    next=$(ps -o ppid= -p "$current" 2>/dev/null | tr -d '[:space:]')
    case "$next" in
      ''|*[!0-9]*) return 1 ;;
    esac
    current=$next
  done
}

reap_leaked_processes() { # <root...>
  local root resolved pid roots=() pids=() uniq survivors=()
  CS_REAP_SURVIVORS=""
  for root in "$@"; do
    [ -d "$root" ] || continue
    resolved=$(cd "$root" 2>/dev/null && pwd -P) || continue
    roots+=("$resolved")
  done
  [ "${#roots[@]}" -gt 0 ] || return 0
  for root in "${roots[@]}"; do
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      pids+=("$pid")
    done < <("$LSOF_BIN" -a -d cwd +D "$root" -t 2>/dev/null || true)
  done
  [ "${#pids[@]}" -gt 0 ] || return 0
  uniq=$(printf '%s\n' "${pids[@]}" | sort -un)
  for pid in $uniq; do
    reap_pid_is_teardown_ancestry "$pid" && continue
    proc_cwd_under_roots "$pid" "${roots[@]}" || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 0.5
  for pid in $uniq; do
    reap_pid_is_teardown_ancestry "$pid" && continue
    proc_cwd_under_roots "$pid" "${roots[@]}" || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  sleep 0.2
  for pid in $uniq; do
    reap_pid_is_teardown_ancestry "$pid" && continue
    if kill -0 "$pid" 2>/dev/null && proc_cwd_under_roots "$pid" "${roots[@]}"; then
      survivors+=("$pid")
    fi
  done
  [ "${#survivors[@]}" -eq 0 ] || { CS_REAP_SURVIVORS="${survivors[*]}"; return 1; }
  return 0
}

# Run both pre-cleanup steps for a ship or scout task worktree. Incomplete
# cleanup (a parked run that would not conclude, or a process that survived KILL)
# is a fail-closed refusal naming what survived - never a silent warning - except
# under --force, where the boss's explicit discard authority downgrades the
# refusal to a named warning, matching every other proof in this script.
conclude_and_reap() {
  # A scout never drives a made run of its own; only conclude for ships.
  if [ "$KIND" = ship ] && ! conclude_nm_run; then
    if [ "$FORCE" = "--force" ]; then
      echo "WARNING: ${CS_MADE_CONCLUDE_FAILURE:-made run conclusion was not confirmed}; --force is proceeding. Check it by hand." >&2
    else
      echo "REFUSED: ${CS_MADE_CONCLUDE_FAILURE:-made run conclusion was not confirmed}." >&2
      echo "Nothing was removed. Retry once the daemon responds, or get the boss's explicit OK to discard, then --force." >&2
      return 1
    fi
  fi
  if [ -z "$LSOF_BIN" ]; then
    if [ "$FORCE" = "--force" ]; then
      echo "WARNING: lsof is unavailable; --force is proceeding without reaping any leaked task processes under $WT. Check for them by hand." >&2
    else
      echo "REFUSED: lsof is unavailable, so leaked task processes under $WT cannot be found and reaped." >&2
      echo "Install lsof, or get the boss's explicit OK to discard, then --force." >&2
      return 1
    fi
  elif ! reap_leaked_processes "$WT"; then
    if [ "$FORCE" = "--force" ]; then
      echo "WARNING: task processes survived under $WT (pids: ${CS_REAP_SURVIVORS:-?}); --force is proceeding anyway. Check them by hand." >&2
    else
      echo "REFUSED: task processes rooted under $WT survived TERM and KILL (pids: ${CS_REAP_SURVIVORS:-?})." >&2
      echo "They would be orphaned by cleanup. Investigate, or get the boss's explicit OK to discard, then --force." >&2
      return 1
    fi
  fi
  return 0
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
  # LOCKSTEP: the control plane's relaunch journal and its superseded copy
  # (bin/cs-control-lib.sh) are keyed by task id, so a leftover journal would
  # make the next task reusing this id refuse its first relaunch.
  for f in "$STATE/$ID.check.sh" "$STATE/$ID.check-trust" "$STATE/$ID.plan-progress" "$STATE/$ID.pr-poll" "$STATE/$ID.pr-poll-registration" \
    "$STATE/$ID.control-relaunch" "$STATE/$ID.control-relaunch.abandoned"; do
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
    "$STATE/.decision-cursor-$ID"
  )
  # A drain killed mid-write leaves the cursor's own staging temp files behind
  # (.decision-cursor-<id>.read.XXXXXX / .tmp.XXXXXX from cs-classify-lib.sh's
  # mktemp), and nothing else ever reclaims them. Match ONLY those two suffixed
  # families - never a bare .decision-cursor-$ID* glob, which would also eat the
  # live cursor of another task whose id merely starts with this id.
  for m in "$STATE/.decision-cursor-$ID".read.* "$STATE/.decision-cursor-$ID".tmp.*; do
    if [ -e "$m" ] || [ -L "$m" ]; then
      markers+=("$m")
    fi
  done
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

# Drop exactly this capo's rows. The id is matched LITERALLY through
# bin/cs-capo-registry-lib.sh: a capo id may contain `.`, so the old
# `grep -vE "^- $id( |$)"` treated it as a wildcard and retiring `a.b` deleted
# an unrelated `axb` route. The rewrite is EOF-safe too, so a registry whose
# last line has no trailing newline keeps that entry instead of losing it.
remove_capo_registry_entry() {
  local id=$1 tmp line
  cs_capo_registry_valid_id "$id" || {
    echo "REFUSED: '$id' is not a valid capo id; the routing table was left unchanged." >&2
    return 1
  }
  cs_capo_registry_exists "$CAPO_REG" || return 0
  if ! cs_capo_registry_available "$CAPO_REG"; then
    echo "warning: ${CS_CAPO_REGISTRY_ERROR}; the routing table was left unchanged." >&2
    return 0
  fi
  tmp="$CAPO_REG.tmp.$$"
  : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    if cs_capo_registry_line_is_id "$line" "$id"; then
      continue
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$CAPO_REG"
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
  # Same reason, same ordering: herdr's plugin registry is GLOBAL to the user, so
  # this home's event-transport registration outlives the home too, and its id is
  # derived from the home path - once the directory is gone the id can no longer
  # be computed and the entry is unreachable forever, leaving herdr dispatching
  # every pane's status edge to a deleted hook. Unlike the retirements above this
  # is fail-open on purpose: the registration costs escalation latency, never
  # supervision, so a herdr hiccup must not block a retirement whose own safety
  # proofs have already passed.
  if [ -x "$SCRIPT_DIR/cs-herdr-event-plugin.sh" ]; then
    CS_HOME="$HOME_PATH" CS_STATE_OVERRIDE="$HOME_PATH/state" \
      CS_HOST_OVERRIDE="$HOME_PATH/host" CS_DATA_OVERRIDE="$HOME_PATH/data" \
      CS_CONFIG_OVERRIDE="$HOME_PATH/config" \
      "$SCRIPT_DIR/cs-herdr-event-plugin.sh" uninstall >/dev/null 2>&1 || true
  fi
  [ -n "$PANE" ] && cs_herdr_pane_close "$PANE" >/dev/null 2>&1 || true
  require_pane_gone "capo $ID's home and records" || exit 1
  [ -n "$WS" ] && cs_herdr workspace close "$WS" >/dev/null 2>&1 || true
  # The capo home is a plain detached worktree of the consigliere repo.
  git -C "$CS_ROOT" worktree remove --force "$HOME_PATH" 2>/dev/null \
    || rm -rf "$HOME_PATH"
  git -C "$CS_ROOT" worktree prune 2>/dev/null || true
  remove_capo_registry_entry "$ID"
  # The .read.*/.tmp.* globs reclaim cursor staging temp files a killed drain
  # left behind; they stay narrowly suffixed so another task whose id starts
  # with this id keeps its own live cursor.
  rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.meta" \
    "$STATE/.decision-cursor-$ID" \
    "$STATE/.decision-cursor-$ID".read.* "$STATE/.decision-cursor-$ID".tmp.*
  # TELEMETRY, measurement only, on a teardown that actually completed.
  cs_telemetry_crumb teardown capo || true
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

if [ "$FORCE" != "--force" ] && ! reconcile_messages_before_teardown; then
  echo "REFUSED: message reconciliation for task $ID is unresolved or malformed; records and worktree were preserved." >&2
  exit 1
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

# Conclude this task's parked made run and reap any leaked task processes
# BEFORE the worktree is removed, its branch deleted, or the workspace closed, so
# a torn-down task can never strand an orphaned run holding a fleet slot or leave
# descendants pinning CPU under a worktree that no longer exists.
if [ -n "$WT" ] && [ -d "$WT" ]; then
  conclude_and_reap || exit 1
fi

BRANCH=""
if [ -n "$WT" ] && [ -d "$WT" ]; then
  BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  REMOVE_FORCE=""
  if [ "$FORCE" = "--force" ] || [ "$KIND" = scout ]; then
    REMOVE_FORCE="--force"
  fi
  if [ "$CONTAINER" = tab ]; then
    # WS here is the capo's own persistent home workspace, not a worktree-bound
    # one: cs_herdr_worktree_remove would tear down that whole home. Only the
    # task's own tab (its root pane) and its plain-git worktree are this
    # task's to remove.
    cs_herdr_nested_task_remove "$PROJ" "$WT" "$PANE" $REMOVE_FORCE >/dev/null || {
      echo "error: nested task removal refused for $WT after the safety proofs passed; stop and investigate (do not delete by hand)." >&2
      exit 1
    }
  elif [ -n "$WS" ] && cs_herdr_workspace_exists "$WS"; then
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
# Both harnesses pre-trust their worktree at spawn, so both give the trust entry
# back here; claude additionally carries a per-soldier settings file. Without this
# the boss's harness config accumulates one dead entry per torn-down worktree.
if [ "$HARNESS" = claude ]; then
  [ -n "$WT" ] && cs_harness_claude_untrust_dir "$WT" || true
  rm -f "$STATE/$ID.claude-settings.json"
elif [ "$HARNESS" = codex ]; then
  [ -n "$WT" ] && cs_harness_codex_untrust_dir "$WT" || true
elif [ "$HARNESS" = grok ]; then
  cs_grok_turnend_disarm "$STATE" "$ID" "$WT"
fi
rm -f "$STATE/$ID.status" "$STATE/$ID.turn-ended" "$STATE/$ID.meta"
remove_watcher_markers || exit 1

if [ "$KIND" != scout ] && [ "$MODE" != local-only ] && [ -x "$SCRIPT_DIR/cs-fleet-sync.sh" ] && [ -n "$PROJ" ]; then
  "$SCRIPT_DIR/cs-fleet-sync.sh" "$PROJ" || true
fi

# The completion backlog transition, folded into the same cleanup that removed
# the task's physical record, before the success line below: a torn-down task
# must never keep showing as in flight. A write failure is a loud non-zero
# exit - the cleanup itself already happened and is not undone, but the result
# is not clean until the item is closed by hand.
BACKLOG_LINE="reminder: record completion in the backlog and re-evaluate queued work."
if [ -n "$BACKLOG_ITEM" ]; then
  DONE_ARGS=()
  [ -n "$PR_URL" ] && DONE_ARGS+=(--pr "$PR_URL")
  [ "$KIND" = scout ] && [ -f "$DATA/$ID/report.md" ] && DONE_ARGS+=(--report "$DATA/$ID/report.md")
  backlog_rc=0
  cs_tasks_backlog_transition "$CONFIG" "done" "$BACKLOG_ITEM" ${DONE_ARGS[@]+"${DONE_ARGS[@]}"} || backlog_rc=$?
  case "$backlog_rc" in
    0) BACKLOG_LINE="backlog item '$BACKLOG_ITEM' recorded done; re-evaluate queued work." ;;
    2) BACKLOG_LINE="reminder: record completion of backlog item '$BACKLOG_ITEM' by hand and re-evaluate queued work." ;;
    *)
      echo "error: cleanup for '$ID' finished, but backlog item '$BACKLOG_ITEM' could not be recorded done and still shows as in flight; close it by hand, then re-evaluate queued work." >&2
      exit 1
      ;;
  esac
fi

# TELEMETRY, measurement only, on a teardown that actually completed. A refusal
# never reaches this line, so a task cleaned up under protest is never counted as
# a supervision turn that closed the loop.
cs_telemetry_crumb teardown "$KIND" || true
echo "teardown $ID complete (pane ${PANE:-<none>}, worktree ${WT:-<none>})"
echo "$BACKLOG_LINE"
