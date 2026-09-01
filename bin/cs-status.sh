#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${CS_HOME+x}" ] && [ -n "${CS_HOME:-}" ] || {
  echo "error: CS_HOME is not set; status refuses to guess a home" >&2
  exit 1
}
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"
# shellcheck source=bin/cs-message-lib.sh
. "$SCRIPT_DIR/cs-message-lib.sh"
cs_resolve_root

MAX_RECORDS=${CS_STATUS_MAX_RECORDS:-64}
case "$MAX_RECORDS" in ''|*[!0-9]*|0) MAX_RECORDS=64 ;; esac

task_count=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  task_count=$((task_count + 1))
done

open_messages=0
malformed=0
for file in "$STATE"/inbox/*.msg; do
  [ -f "$file" ] || continue
  if ! cs_message_validate_file "$file"; then
    malformed=$((malformed + 1))
    continue
  fi
  [ -e "${file%.msg}.ack" ] && continue
  open_messages=$((open_messages + 1))
done

pending=0
for file in "$STATE"/pending/*.pending; do
  [ -f "$file" ] || continue
  [ -e "${file%.pending}.closed" ] || pending=$((pending + 1))
done

printf 'status home=%s tasks=%s open_messages=%s pending_obligations=%s malformed_messages=%s\n' \
  "$CS_HOME" "$task_count" "$open_messages" "$pending" "$malformed"

shown=0
for file in "$STATE"/inbox/*.msg; do
  [ -f "$file" ] || continue
  [ "$shown" -lt "$MAX_RECORDS" ] || break
  cs_message_validate_file "$file" || continue
  [ -e "${file%.msg}.ack" ] && continue
  shown=$((shown + 1))
  message_id=$(cs_message_field "$file" message_id)
  kind=$(cs_message_field "$file" kind)
  from_task=$(cs_message_field "$file" from_task_id)
  to_task=$(cs_message_field "$file" to_task_id)
  printf 'message=%s kind=%s from=%s to=%s next=CS_TASK_ID=%s bin/cs-inbox.sh\n' \
    "$message_id" "$kind" "$from_task" "$to_task" "$to_task"
done

if [ "$open_messages" -gt 0 ] || [ "$pending" -gt 0 ] || [ "$malformed" -gt 0 ]; then
  printf 'next=CS_HOME=%s bin/cs-recover.sh\n' "$CS_HOME"
else
  printf 'next=none\n'
fi
