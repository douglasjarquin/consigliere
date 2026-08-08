#!/usr/bin/env bash
# cs-board-capacity.sh - report the live dispatch occupancy for one project.
#
# Usage: cs-board-capacity.sh <project> <lane-cap>
#
# Prints one machine-readable summary:
#   project=<name> cap=<n> occupied=<n> released=<n> free=<n> cleanup_pending=<n>
#
# This is the single owner of board-sweep lane accounting. It reads only
# state/<id>.meta records for ship tasks whose recorded project is the selected
# project's physical clone, then checks the recorded pane and recorded PR. The
# durable sweep policy comes only from bin/cs-board-watch.sh. The default
# hold-green-prs behavior is unchanged. With release-green-prs selected, one
# authenticated release-reviewed-green PR sidecar releases one slot only while
# that no-mistakes PR remains open, non-draft, review-clean, green, and at the
# exact recorded head. Missing, malformed, stale, red, or unknown data holds.
# A merged task with no endpoint is cleanup_pending, never a green-PR release.
#
# The command is read-only. It never reads backlog sections, removes a
# worktree, prunes Git registrations, force-removes anything, or changes a
# board card. Release changes scheduling arithmetic only; it does not mean
# merged, landed, closed, cleaned up, discarded, or Done.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"
# shellcheck source=bin/cs-pr-lib.sh
. "$SCRIPT_DIR/cs-pr-lib.sh"

die() { echo "cs-board-capacity: $*" >&2; exit 1; }

valid_project() {
  local project=${1-}
  local LC_ALL=C
  case "$project" in
    ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#project}" -le 48 ]
}

valid_number() {
  local number=${1-}
  case "$number" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$number" -ge 1 ]
}

usage() {
  awk 'NR == 1 {next} /^#/{sub(/^# ?/, ""); print; next} {exit}' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

PROJECT=${1:-}
CAP=${2:-}
valid_project "$PROJECT" || die "project name must be a simple name"
valid_number "$CAP" || die "lane cap must be a positive integer"
CAP=$((10#$CAP))

PROJECT_DIR="$CS_HOME/projects/$PROJECT"
[ -d "$PROJECT_DIR" ] || die "project clone is unavailable: $PROJECT_DIR"
PROJECT_DIR=$(cd -- "$PROJECT_DIR" && pwd -P)

endpoint_is_live() {
  local pane
  pane=$(cs_meta_get "$1" pane || true)
  [ -n "$pane" ] || return 1
  ! cs_herdr_pane_confirmed_gone "$pane"
}

CS_CAP_PR_STATE=
CS_CAP_PR_DRAFT=
CS_CAP_PR_HEAD=
CS_CAP_PR_CHECKS=
CS_CAP_PR_REVIEW=

gh_axi_body_token() {
  local out body count
  out=$("$@" 2>/dev/null) || return 1
  body=$(printf '%s\n' "$out" \
    | sed -n 's/^  body: "\([A-Za-z0-9_|.-]*\)"$/\1/p')
  [ -n "$body" ] || return 1
  count=$(printf '%s\n' "$body" | awk 'END {print NR}')
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$body"
}

github_pr_snapshot() {
  local path=$1 number=$2 owner repo query token extra
  command -v gh-axi >/dev/null 2>&1 || return 1
  owner=${path%%/*}
  repo=${path#*/}
  query="query { repository(owner: \"$owner\", name: \"$repo\") { pullRequest(number: $number) { state isDraft headRefOid reviewDecision commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } } }"
  token=$(gh_axi_body_token gh-axi api POST graphql \
    --field "query=$query" \
    --jq ".data.repository.pullRequest as \$pr | if \$pr == null then \"UNKNOWN\" else [\$pr.state, (\$pr.isDraft|tostring), (\$pr.headRefOid // \"NONE\"), (\$pr.commits.nodes[0].commit.statusCheckRollup.state // \"NONE\"), (\$pr.reviewDecision // \"NONE\")] | join(\"|\") end") \
    || return 1
  IFS='|' read -r CS_CAP_PR_STATE CS_CAP_PR_DRAFT CS_CAP_PR_HEAD \
    CS_CAP_PR_CHECKS CS_CAP_PR_REVIEW extra <<< "$token"
  [ -z "$extra" ] || return 1
  case "$CS_CAP_PR_STATE" in OPEN|CLOSED|MERGED) ;; *) return 1 ;; esac
  case "$CS_CAP_PR_DRAFT" in true|false) ;; *) return 1 ;; esac
  cs_pr_head_valid "$CS_CAP_PR_HEAD" || return 1
  case "$CS_CAP_PR_CHECKS" in NONE|SUCCESS|EXPECTED|ERROR|FAILURE|PENDING) ;; *) return 1 ;; esac
  case "$CS_CAP_PR_REVIEW" in NONE|APPROVED|CHANGES_REQUESTED|REVIEW_REQUIRED) ;; *) return 1 ;; esac
}

merged_pr_is_verified() {
  local meta=$1
  cs_pr_metadata_identity_parse "$meta" || return 1
  [ "$CS_PR_META_PROVIDER" = github ] || return 1
  github_pr_snapshot "$CS_PR_META_PATH" "$CS_PR_META_NUMBER" || return 1
  [ "$CS_CAP_PR_STATE" = MERGED ]
}

scheduling_release_is_verified() {
  local meta=$1 id=$2 mode
  mode=$(cs_meta_get "$meta" mode || true)
  [ "$mode" = no-mistakes ] || return 1
  cs_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/cs-pr-poll.sh" || return 1
  [ "$CS_PR_DATA_PROVIDER" = github ] || return 1
  [ "$CS_PR_DATA_CAPACITY" = release-reviewed-green ] || return 1
  cs_pr_head_valid "$CS_PR_DATA_HEAD" || return 1
  github_pr_snapshot "$CS_PR_DATA_PATH" "$CS_PR_DATA_NUMBER" || return 1
  [ "$CS_CAP_PR_STATE" = OPEN ] || return 1
  [ "$CS_CAP_PR_DRAFT" = false ] || return 1
  [ "$CS_CAP_PR_HEAD" = "$CS_PR_DATA_HEAD" ] || return 1
  case "$CS_CAP_PR_CHECKS" in SUCCESS|NONE) ;; *) return 1 ;; esac
  case "$CS_CAP_PR_REVIEW" in NONE|APPROVED) ;; *) return 1 ;; esac
}

GREEN_PR_POLICY=$("$SCRIPT_DIR/cs-board-watch.sh" policy "$PROJECT" 2>/dev/null || true)
RELEASE_GREEN_PRS=0
[ "$GREEN_PR_POLICY" != release-green-prs ] || RELEASE_GREEN_PRS=1

occupied=0
released=0
cleanup_pending=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  task_project=$(cs_meta_get "$meta" project || true)
  [ "$task_project" = "$PROJECT_DIR" ] || continue
  kind=$(cs_meta_get "$meta" kind || echo ship)
  [ "$kind" = ship ] || continue
  id=$(basename "$meta" .meta)

  if [ "$RELEASE_GREEN_PRS" -eq 1 ] && scheduling_release_is_verified "$meta" "$id"; then
    released=$((released + 1))
  elif endpoint_is_live "$meta"; then
    occupied=$((occupied + 1))
  elif merged_pr_is_verified "$meta"; then
    cleanup_pending=$((cleanup_pending + 1))
  else
    occupied=$((occupied + 1))
  fi
done

free=$((CAP - occupied))
[ "$free" -ge 0 ] || free=0
printf 'project=%s cap=%s occupied=%s released=%s free=%s cleanup_pending=%s\n' \
  "$PROJECT" "$CAP" "$occupied" "$released" "$free" "$cleanup_pending"
