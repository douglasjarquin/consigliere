#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/cs-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/cs-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
# Consigliere merges GitHub pull requests only: a valid GitLab merge request
# URL is recognized exactly and refused loudly, never silently misparsed.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# The merge command's exit status is never trusted as the outcome. After
# gh-axi returns success, GitHub's live state is read back through gh and the
# merge is reported only when GitHub itself says the PR is merged. A PR that
# sits in the merge queue is reported as queued, not merged, and exits 3. A PR
# that is still open or closed-unmerged, and an outcome read that fails or is
# unavailable, are loud failures (exit 1): pr= is already recorded and the
# merge poll armed, so a merge that landed despite the failed read still
# surfaces through that poll.
# A verified merge leaves a durable record, not just agent memory: a
# "done: PR <url> merged" event is appended to state/<id>.status (the ordinary
# wake-event convention of bin/cs-classify-lib.sh) and merged=1 plus
# merged_at=<GitHub mergedAt> are appended to state/<id>.meta
# (docs/configuration.md owns the schema).
# Usage: cs-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
# Exit: 0 verified merged, 1 failure or unverified outcome, 2 invalid request,
# 3 queued in the merge queue and not merged yet.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root

# shellcheck source=bin/cs-pr-lib.sh
. "$SCRIPT_DIR/cs-pr-lib.sh"
# Optional turn telemetry (off unless host/telemetry.conf enables it).
# shellcheck source=bin/cs-telemetry-lib.sh
. "$SCRIPT_DIR/cs-telemetry-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! cs_pr_task_id_valid "$ID" || ! cs_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
# bin/cs-pr-lib.sh parses GitLab merge request URLs, so a valid one lands here
# with an exact identity; refuse it by name rather than as a malformed URL.
if [ "$CS_PR_PROVIDER" != github ]; then
  echo "error: GitLab merge requests are not supported; consigliere merges GitHub pull requests only" >&2
  exit 2
fi
URL=$CS_PR_URL
PR_OWNER=$CS_PR_OWNER
PR_REPO=$CS_PR_REPO
PR_NUMBER=$CS_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/cs-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"

# The merge command's success is not the outcome; only GitHub's own live state
# is. pr= is already recorded and the merge poll armed above, so every refusal
# below still leaves a landed merge discoverable through that poll.
if ! command -v gh >/dev/null 2>&1; then
  echo "error: merge command succeeded but the outcome is unverified: gh is unavailable to read the PR state" >&2
  exit 1
fi
OUTCOME=$(gh pr view "$URL" --json state,mergedAt,isInMergeQueue \
  -q '[.state, (.isInMergeQueue | tostring), (.mergedAt // "")] | join(" ")' 2>/dev/null) || OUTCOME=
PR_STATE=
IN_QUEUE=
MERGED_AT=
read -r PR_STATE IN_QUEUE MERGED_AT <<EOF
$OUTCOME
EOF
if [ -z "$PR_STATE" ]; then
  echo "error: merge command succeeded but the outcome is unverified: the GitHub PR state read failed" >&2
  exit 1
fi
if [ "$PR_STATE" != MERGED ]; then
  if [ "$IN_QUEUE" = true ]; then
    printf 'queued: PR %s is in the merge queue and not merged yet; the armed merge poll reports when it lands\n' "$URL"
    exit 3
  fi
  echo "error: merge command succeeded but GitHub reports the PR as $PR_STATE, not merged" >&2
  exit 1
fi

# Durable record of the verified merge: a status wake event plus meta fields,
# so a landed merge never lives only in agent memory.
printf 'done: PR %s merged\n' "$URL" >> "$STATE/$ID.status"
grep -q '^merged=' "$META" \
  || printf 'merged=1\nmerged_at=%s\n' "$MERGED_AT" >> "$META"
printf 'merged: PR %s\n' "$URL"
# TELEMETRY, measurement only, and only on a merge GitHub confirmed: this
# script runs under `set -e`, so an unverified merge never reaches this line.
cs_telemetry_crumb merge pr || true
