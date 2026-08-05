#!/usr/bin/env bash
# cs-board-capacity.sh - report the live dispatch occupancy for one project.
#
# Usage: cs-board-capacity.sh <project> <lane-cap>
#
# Prints one machine-readable summary:
#   project=<name> cap=<n> occupied=<n> free=<n> cleanup_pending=<n>
#
# This is the single owner of board-sweep lane accounting. It reads only
# state/<id>.meta records for ship tasks whose recorded project is the selected
# project's physical clone, then checks the recorded pane and recorded PR.
# A task occupies a lane unless its endpoint is proven absent AND its recorded
# GitHub PR is verified merged. A merged task with unresolved cleanup is
# reported in cleanup_pending and remains untouched.
#
# The command is read-only. It never reads backlog sections, removes a
# worktree, prunes Git registrations, force-removes anything, or changes a
# board card. Any uncertain endpoint or PR result keeps the task occupied.
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

PROJECT_DIR="$CS_HOME/projects/$PROJECT"
[ -d "$PROJECT_DIR" ] || die "project clone is unavailable: $PROJECT_DIR"
PROJECT_DIR=$(cd -- "$PROJECT_DIR" && pwd -P)

endpoint_is_live() {
  local pane
  pane=$(cs_meta_get "$1" pane || true)
  [ -n "$pane" ] || return 1
  ! cs_herdr_pane_confirmed_gone "$pane"
}

merged_pr_is_verified() {
  local meta=$1
  cs_pr_metadata_identity_parse "$meta" || return 1
  [ "$CS_PR_META_PROVIDER" = github ] || return 1
  command -v gh-axi >/dev/null 2>&1 || return 1
  [ -n "$(gh-axi api "/repos/$CS_PR_META_PATH/pulls/$CS_PR_META_NUMBER" \
    --jq '.merged_at // empty' 2>/dev/null || true)" ]
}

occupied=0
cleanup_pending=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  task_project=$(cs_meta_get "$meta" project || true)
  [ "$task_project" = "$PROJECT_DIR" ] || continue
  kind=$(cs_meta_get "$meta" kind || echo ship)
  [ "$kind" = ship ] || continue

  if endpoint_is_live "$meta"; then
    occupied=$((occupied + 1))
  elif merged_pr_is_verified "$meta"; then
    cleanup_pending=$((cleanup_pending + 1))
  else
    occupied=$((occupied + 1))
  fi
done

free=$((CAP - occupied))
[ "$free" -ge 0 ] || free=0
printf 'project=%s cap=%s occupied=%s free=%s cleanup_pending=%s\n' \
  "$PROJECT" "$CAP" "$occupied" "$free" "$cleanup_pending"
