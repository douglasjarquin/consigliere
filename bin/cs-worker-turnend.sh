#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${CS_HOME+x}" ] && [ -n "${CS_HOME:-}" ] || exit 0
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"
# shellcheck source=bin/cs-message-lib.sh
. "$SCRIPT_DIR/cs-message-lib.sh"
cs_resolve_root || exit 0

task=${CS_TASK_ID:-}
[ -n "$task" ] || exit 0
meta="$STATE/$task.meta"
[ -f "$meta" ] || exit 0
[ "$(cs_meta_get "$meta" kind 2>/dev/null || true)" != capo ] || exit 0
status="$STATE/$task.status"
[ -f "$status" ] || exit 0
last=$(tail -n 1 "$status" 2>/dev/null || true)
case "$last" in
  done:*|done\ *|failed:*|failed\ *) ;;
  *) exit 0 ;;
esac

parent_state=$(cs_meta_get "$meta" parent_state 2>/dev/null || true)
parent_task=$(cs_meta_get "$meta" parent_task_id 2>/dev/null || true)
child_home=$(cs_meta_home "$meta" 2>/dev/null || true)
generation=$(cs_meta_get "$meta" endpoint_generation 2>/dev/null || true)
[ -d "$parent_state/inbox" ] && [ -n "$generation" ] || exit 0
for file in "$parent_state/inbox"/*.msg; do
  [ -f "$file" ] || continue
  cs_message_validate_file "$file" || continue
  [ "$(cs_message_field "$file" from_task_id)" = "$task" ] || continue
  [ "$(cs_message_field "$file" from_home)" = "$child_home" ] || continue
  [ "$(cs_message_field "$file" from_endpoint_generation)" = "$generation" ] || continue
  [ "$(cs_message_field "$file" to_task_id)" = "$parent_task" ] || continue
  case "$(cs_message_field "$file" kind)" in result|failed) exit 0 ;; esac
done

recovery_id=$(cs_message_recovery_id "$task" "$generation") || exit 0
marker="$STATE/.message-recovery-$recovery_id"
if [ -e "$marker" ]; then
  [ -f "$marker" ] || exit 0
  exit 0
fi
CS_HOME="$CS_HOME" CS_ROOT_OVERRIDE="$CS_ROOT" CS_STATE_OVERRIDE="$STATE" \
  CS_DATA_OVERRIDE="$DATA" CS_TASK_ID="$task" \
  "$SCRIPT_DIR/cs-report.sh" failed \
    "settled child has no semantic result; inspect its durable work" \
    --message-id "$recovery_id" >/dev/null 2>&1 || true
if [ -f "$parent_state/inbox/$recovery_id.msg" ]; then
  (set -C; : > "$marker") 2>/dev/null || true
fi
