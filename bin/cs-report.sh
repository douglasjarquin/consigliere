#!/usr/bin/env bash
# Report one bounded semantic message to the recorded immediate parent.
# Usage: cs-report.sh <kind> <summary> [--artifact <relative-path>] [--commit <sha>] [--pr <number>] [--correlation <id>] [--sequence <n>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ -n "${CS_HOME+x}" ] && [ -n "${CS_HOME:-}" ] || { echo "error: CS_HOME is not set" >&2; exit 1; }
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"
# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-message-lib.sh
. "$SCRIPT_DIR/cs-message-lib.sh"
cs_resolve_root

KIND=${1:?usage: cs-report.sh <kind> <summary> [options]}
SUMMARY=${2:?usage: cs-report.sh <kind> <summary> [options]}
shift 2
ARTIFACT=
COMMIT=
PULL_REQUEST=
CORRELATION=
SEQUENCE=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifact) ARTIFACT=${2:?--artifact requires a path}; shift ;;
    --commit) COMMIT=${2:?--commit requires a SHA}; shift ;;
    --pr) PULL_REQUEST=${2:?--pr requires a number}; shift ;;
    --correlation) CORRELATION=${2:?--correlation requires an id}; shift ;;
    --sequence) SEQUENCE=${2:?--sequence requires a number}; shift ;;
    *) echo "error: unknown flag $1" >&2; exit 2 ;;
  esac
  shift
done

TASK_ID=${CS_TASK_ID:-}
[ -n "$TASK_ID" ] || { echo "error: CS_TASK_ID is required" >&2; exit 2; }
META="$STATE/$TASK_ID.meta"
[ -f "$META" ] || { echo "error: task metadata is missing at $META" >&2; exit 1; }
cs_meta_validate_parent_edge "$META" || { echo "error: task '$TASK_ID' has no valid immediate-parent edge" >&2; exit 1; }
PARENT_TASK=$(cs_meta_get "$META" parent_task_id)
PARENT_STATE=$(cs_meta_get "$META" parent_state)
PARENT_PANE=$(cs_meta_get "$META" parent_pane)
FROM_GENERATION=$(cs_meta_get "$META" endpoint_generation)
TO_GENERATION=$(cs_meta_get "$META" parent_generation)
[ -d "$PARENT_STATE/inbox" ] || mkdir -p "$PARENT_STATE/inbox"
PARENT_HOME_REAL=$(cd "$(cs_meta_get "$META" parent_home)" && pwd -P)
PARENT_CWD=$(cs_herdr_pane_cwd "$PARENT_PANE" || true)
if [ -z "$PARENT_CWD" ] || [ "$(cd "$PARENT_CWD" 2>/dev/null && pwd -P)" != "$PARENT_HOME_REAL" ]; then
  echo "warning: parent pane '$PARENT_PANE' is unavailable or belongs to another home; the durable report remains in $PARENT_STATE/inbox" >&2
  PARENT_ROUTE_OK=0
else
  PARENT_ROUTE_OK=1
fi

MESSAGE_ID=$(cs_message_new_id)
[ -n "$CORRELATION" ] || CORRELATION=$MESSAGE_ID
CREATED_AT=$(cs_message_now)
case "$KIND" in
  question|decision-required)
    cs_message_pending_create "$STATE" "$MESSAGE_ID" "$CORRELATION" "$TASK_ID" "$PARENT_TASK" "$KIND" "$CREATED_AT" || {
      echo "error: could not create pending obligation for report $MESSAGE_ID" >&2
      exit 1
    }
    ;;
esac
FIELDS=(
  "schema=$CS_MESSAGE_SCHEMA"
  "message_id=$MESSAGE_ID"
  "correlation_id=$CORRELATION"
  "sequence=$SEQUENCE"
  "kind=$KIND"
    "from_task_id=$TASK_ID"
    "to_task_id=$PARENT_TASK"
    "from_home=$CS_HOME"
    "from_endpoint_generation=$FROM_GENERATION"
  "to_endpoint_generation=$TO_GENERATION"
  "summary=$SUMMARY"
  "artifact=$ARTIFACT"
  "commit_sha=$COMMIT"
  "pull_request=$PULL_REQUEST"
  "created_at=$CREATED_AT"
)
cs_message_publish "$PARENT_STATE/inbox" "${FIELDS[@]}" || { echo "error: could not publish report to $PARENT_STATE/inbox" >&2; exit 1; }
if [ "$PARENT_ROUTE_OK" -ne 1 ]; then
  exit 1
fi
if ! cs_herdr_agent_prompt_confirmed "$PARENT_PANE" "CONSIGLIERE_WAKE v1 message=$MESSAGE_ID"; then
  echo "warning: report $MESSAGE_ID is durable but the parent doorbell was not confirmed" >&2
  exit 1
fi
printf 'reported message=%s parent=%s inbox=%s\n' "$MESSAGE_ID" "$PARENT_TASK" "$PARENT_STATE/inbox"
