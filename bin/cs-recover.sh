#!/usr/bin/env bash
# Reconcile durable message delivery once.
# Usage: cs-recover.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${CS_HOME+x}" ] && [ -n "${CS_HOME:-}" ] || {
  echo "error: CS_HOME is not set; recovery refuses to guess a home" >&2
  exit 1
}
STATE="${CS_STATE_OVERRIDE:-$CS_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 1; }
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"
# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-message-lib.sh
. "$SCRIPT_DIR/cs-message-lib.sh"

MAX_RECORDS=${CS_RECOVER_MAX_RECORDS:-64}
case "$MAX_RECORDS" in ''|*[!0-9]*|0) MAX_RECORDS=64 ;; esac
seen=''
checked=0
rewoken=0
failed=0

seen_message() {
  case " $seen " in *" $1 "*) return 0 ;; esac
  seen="$seen $1"
  return 1
}

endpoint_ready() {
  local meta=$1 pane=$2 label=$3 expected actual
  expected=$(cs_meta_get "$meta" worktree 2>/dev/null || true)
  expected=${expected:-$(cs_meta_get "$meta" home 2>/dev/null || true)}
  actual=$(cs_herdr_pane_cwd "$pane" 2>/dev/null || true)
  if [ -z "$actual" ] || [ -z "$expected" ] ||
    [ "$(cd "$actual" 2>/dev/null && pwd -P)" != "$(cd "$expected" 2>/dev/null && pwd -P)" ]; then
    echo "error: $label endpoint '$pane' is unavailable or belongs to the wrong worktree" >&2
    return 1
  fi
}

wake_message() {
  local file=$1 recipient_meta=$2 message_id to_generation pane recipient_task
  message_id=$(cs_message_field "$file" message_id)
  recipient_task=$(cs_message_field "$file" to_task_id)
  pane=$(cs_meta_get "$recipient_meta" pane 2>/dev/null || true)
  [ -n "$pane" ] || { echo "error: message '$message_id' recipient has no pane" >&2; return 1; }
  endpoint_ready "$recipient_meta" "$pane" "message '$message_id' recipient" || return 1
  to_generation=$(cs_meta_get "$recipient_meta" endpoint_generation 2>/dev/null || true)
  [ -n "$to_generation" ] || { echo "error: message '$message_id' recipient has no endpoint generation" >&2; return 1; }
  cs_message_route_write "$file" "$recipient_task" "$to_generation" || {
    echo "error: message '$message_id' route could not be repaired" >&2
    return 1
  }
  cs_herdr_agent_prompt_confirmed "$pane" "CONSIGLIERE_WAKE v1 message=$message_id" || {
    echo "error: message '$message_id' wake was not confirmed" >&2
    return 1
  }
  printf 'recover: re-woke message=%s task=%s\n' "$message_id" "$(cs_message_field "$file" to_task_id)"
}

for pending in "$STATE"/pending/*.pending; do
  [ -f "$pending" ] || continue
  [ "$checked" -lt "$MAX_RECORDS" ] || break
  checked=$((checked + 1))
  if ! cs_message_pending_validate_file "$pending"; then
    echo "error: malformed pending obligation '$pending'" >&2
    failed=1
    continue
  fi
  message_id=$(cs_message_field "$pending" message_id 2>/dev/null || true)
  if seen_message "$message_id"; then continue; fi
  task=$(cs_message_field "$pending" task_id)
  child_meta="$STATE/$task.meta"
  if [ ! -f "$child_meta" ]; then
    echo "error: pending message '$message_id' names missing sender metadata '$child_meta'" >&2
    failed=1
    continue
  fi
  if ! cs_meta_validate_parent_edge "$child_meta"; then
    echo "error: pending message '$message_id' names a sender with an invalid parent edge" >&2
    failed=1
    continue
  fi
  parent_state=$(cs_meta_get "$child_meta" parent_state 2>/dev/null || true)
  parent_task=$(cs_meta_get "$child_meta" parent_task_id 2>/dev/null || true)
  message_file="$parent_state/inbox/$message_id.msg"
  if [ ! -f "$message_file" ] || ! cs_message_validate_file "$message_file"; then
    echo "error: pending message '$message_id' has no valid durable inbox record" >&2
    failed=1
    continue
  fi
  [ -e "${message_file%.msg}.ack" ] && continue
  recipient_meta="$parent_state/$parent_task.meta"
  if [ ! -f "$recipient_meta" ]; then
    echo "error: pending message '$message_id' names missing recipient metadata '$recipient_meta'" >&2
    failed=1
    continue
  fi
  if wake_message "$message_file" "$recipient_meta"; then
    rewoken=$((rewoken + 1))
  else
    failed=1
  fi
done

for message_file in "$STATE"/inbox/*.msg; do
  [ -f "$message_file" ] || continue
  [ "$checked" -lt "$MAX_RECORDS" ] || break
  [ -e "${message_file%.msg}.ack" ] && continue
  checked=$((checked + 1))
  if ! cs_message_validate_file "$message_file"; then
    echo "error: malformed inbox message '$message_file'" >&2
    failed=1
    continue
  fi
  message_id=$(cs_message_field "$message_file" message_id)
  if seen_message "$message_id"; then continue; fi
  task=$(cs_message_field "$message_file" to_task_id)
  recipient_meta="$STATE/$task.meta"
  if [ ! -f "$recipient_meta" ]; then
    echo "error: inbox message '$message_id' names missing recipient metadata '$recipient_meta'" >&2
    failed=1
    continue
  fi
  if wake_message "$message_file" "$recipient_meta"; then
    rewoken=$((rewoken + 1))
  else
    failed=1
  fi
done

printf 'recover: checked=%s re-woke=%s\n' "$checked" "$rewoken"
if [ "$failed" -ne 0 ]; then
  printf 'recover: next=inspect the named endpoint, metadata, or message before retrying\n'
  exit 1
fi
if [ "$rewoken" -gt 0 ]; then
  printf 'recover: next=drain each re-woken recipient inbox\n'
else
  printf 'recover: next=none\n'
fi
