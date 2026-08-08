#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and GitHub's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The poll's authenticated sidecar records hold by default. For a board issue
# in no-mistakes mode, an armed sweep's release-green-prs policy changes that
# token to release-reviewed-green at the exact recorded head. Capacity remains
# a live decision by bin/cs-board-capacity.sh; this script does not merge,
# close, clean up, discard, or move the task's board card.
# The watcher check source is byte-for-byte bin/cs-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# Consigliere watches GitHub pull requests only. bin/cs-pr-lib.sh also parses
# GitLab merge request URLs, so a valid one is recognized exactly and refused
# loudly here rather than armed or silently misparsed.
# Usage: cs-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root

# shellcheck source=bin/cs-pr-lib.sh
. "$SCRIPT_DIR/cs-pr-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! cs_pr_task_id_valid "$ID" || ! cs_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
if [ "$CS_PR_PROVIDER" != github ]; then
  echo "error: GitLab merge requests are not supported; consigliere watches GitHub pull requests only" >&2
  exit 2
fi
URL=$CS_PR_URL
PROVIDER=$CS_PR_PROVIDER
HOST=$CS_PR_HOST
PROJECT_PATH=$CS_PR_PATH
NUMBER=$CS_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(cs_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$CS_ROOT/bin/cs-guard.sh" || true

# pr_head is recorded only when gh can supply it; the consumer
# (bin/cs-teardown.sh) already treats it as optional and reads the head from
# the forge at teardown time, falling back to its content check.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
TASK_PROJECT=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
TASK_MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
TASK_ISSUE=$(grep '^issue=' "$META" | tail -1 | cut -d= -f2- || true)
GREEN_PR_POLICY=$(
  "$SCRIPT_DIR/cs-board-watch.sh" policy-path "$TASK_PROJECT" 2>/dev/null || true
)
PR_HEAD=
if [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && cs_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi
CAPACITY_TOKEN=hold
case "$TASK_ISSUE" in
  ''|0|0*|*[!0-9]*) TASK_ISSUE= ;;
esac
if [ "$GREEN_PR_POLICY" = release-green-prs ] \
  && [ "$TASK_MODE" = no-mistakes ] \
  && [ -n "$TASK_ISSUE" ] \
  && cs_pr_head_valid "$PR_HEAD"; then
  CAPACITY_TOKEN=release-reviewed-green
fi

META_TMP=
pr_check_cleanup() {
  cs_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
cs_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" \
  "$PR_HEAD" "$CAPACITY_TOKEN" "$SCRIPT_DIR/cs-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_DEVICE=$(cs_pr_file_device "$META") || exit 1
STATE_DEVICE=$(cs_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.cs-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
cs_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
cs_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$CS_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$CS_PR_META_URL" = "$URL" ] \
  && [ "$CS_PR_META_HOST" = "$HOST" ] && [ "$CS_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$CS_PR_META_NUMBER" = "$NUMBER" ] || exit 1
cs_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
cs_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
cs_pr_metadata_identity_parse "$META" || exit 1
[ "$CS_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$CS_PR_META_URL" = "$URL" ] \
  && [ "$CS_PR_META_HOST" = "$HOST" ] && [ "$CS_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$CS_PR_META_NUMBER" = "$NUMBER" ] || exit 1

cs_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh capacity=%s\n' "$ID" "$CAPACITY_TOKEN"
