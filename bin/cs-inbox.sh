#!/usr/bin/env bash
# Drain the current task's durable parent/child messages.
# Usage: cs-inbox.sh [--ack <message-id> [--reply <bounded-answer>]]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${CS_HOME+x}" ] && [ -n "${CS_HOME:-}" ] || {
  echo "error: CS_HOME is not set; cs-inbox refuses to resolve a task without an explicit home" >&2
  exit 1
}
[ -n "${CS_TASK_ID:-}" ] || { echo "error: CS_TASK_ID is required" >&2; exit 2; }
STATE="${CS_STATE_OVERRIDE:-$CS_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 1; }
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"
# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-message-lib.sh
. "$SCRIPT_DIR/cs-message-lib.sh"

TASK_ID=$CS_TASK_ID
cs_message_task "$TASK_ID" || { echo "error: invalid task id '$TASK_ID'" >&2; exit 2; }
TASK_META="$STATE/$TASK_ID.meta"
[ -f "$TASK_META" ] || { echo "error: task metadata is missing at $TASK_META" >&2; exit 1; }
INBOX="$STATE/inbox"
[ -d "$INBOX" ] || { echo "inbox task=$TASK_ID messages=0"; exit 0; }

ACK_ID=
REPLY=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ack)
      [ -z "$ACK_ID" ] || { echo "error: --ack may be supplied once" >&2; exit 2; }
      ACK_ID=${2:?--ack requires a message id}
      shift 2
      ;;
    --reply)
      [ -z "$REPLY" ] || { echo "error: --reply may be supplied once" >&2; exit 2; }
      REPLY=${2:?--reply requires an answer}
      shift 2
      ;;
    --help|-h)
      printf '%s\n' 'usage: cs-inbox.sh [--ack <message-id> [--reply <bounded-answer>]]'
      exit 0
      ;;
    *) echo "error: unknown flag $1" >&2; exit 2 ;;
  esac
done

message_source_valid() {
  local file=$1 source_task source_meta source_parent source_home source_generation from_home
  cs_message_validate_file "$file" || {
    echo "error: malformed inbox message '$file'" >&2
    return 1
  }
  [ "$(cs_message_field "$file" to_task_id)" = "$TASK_ID" ] || return 2
  source_task=$(cs_message_field "$file" from_task_id)
  from_home=$(cs_message_field "$file" from_home)
  source_meta="$from_home/state/$source_task.meta"
  [ -f "$source_meta" ] || {
    echo "error: message '$file' names missing sender metadata '$source_meta'" >&2
    return 1
  }
  cs_meta_validate_parent_edge "$source_meta" || {
    echo "error: message '$file' names a sender with an invalid parent edge" >&2
    return 1
  }
  source_parent=$(cs_meta_get "$source_meta" parent_task_id)
  source_home=$(cs_meta_get "$source_meta" parent_home)
  [ "$source_parent" = "$TASK_ID" ] && [ "$source_home" = "$CS_HOME" ] || {
    echo "error: message '$file' is not owned by task '$TASK_ID'" >&2
    return 1
  }
  source_generation=$(cs_meta_get "$source_meta" endpoint_generation)
  [ "$source_generation" = "$(cs_message_field "$file" from_endpoint_generation)" ] || {
    echo "error: stale sender generation in '$file'" >&2
    return 1
  }
  [ "$(cs_meta_get "$TASK_META" endpoint_generation)" = "$(cs_message_route_generation "$file")" ] || {
    echo "error: stale receiver generation in '$file'" >&2
    return 1
  }
}

ack_message() {
  local file="$INBOX/$ACK_ID.msg" kind from_home source_task source_meta source_pane source_worktree
  local source_cwd corr
  cs_message_id "$ACK_ID" || { echo "error: invalid message id '$ACK_ID'" >&2; return 1; }
  [ -f "$file" ] || { echo "error: message '$ACK_ID' is missing" >&2; return 1; }
  ack="$INBOX/$ACK_ID.ack"
  if [ -e "$ack" ]; then
    cs_message_validate_ack "$ack" || { echo "error: malformed acknowledgement '$ack'" >&2; return 1; }
    printf 'already acknowledged message=%s task=%s\n' "$ACK_ID" "$TASK_ID"
    return 0
  fi
  message_source_valid "$file" || return 1
  kind=$(cs_message_field "$file" kind)
  from_home=$(cs_message_field "$file" from_home)
  source_task=$(cs_message_field "$file" from_task_id)
  if [ "$kind" = result ] && ! cs_message_verify_result "$file" "$from_home/state/$source_task.meta"; then
    echo "error: result message '$ACK_ID' has unverifiable artifact, commit, or pull request evidence; acknowledgement remains absent" >&2
    return 1
  fi
  case "$kind" in
    question|decision-required)
      [ -n "$REPLY" ] || {
        echo "error: response-required message '$ACK_ID' needs --reply before acknowledgement" >&2
        return 1
      }
      cs_message_scalar "$REPLY" "$CS_MESSAGE_MAX_SUMMARY" || {
        echo "error: reply for message '$ACK_ID' exceeds the bounded message field or contains control characters" >&2
        return 1
      }
      source_task=$(cs_message_field "$file" from_task_id)
      source_meta="$from_home/state/$source_task.meta"
      source_pane=$(cs_meta_get "$source_meta" pane) || {
        echo "error: sender metadata for message '$ACK_ID' has no pane" >&2
        return 1
      }
      source_worktree=$(cs_meta_get "$source_meta" worktree) || {
        echo "error: sender metadata for message '$ACK_ID' has no worktree" >&2
        return 1
      }
      source_cwd=$(cs_herdr_pane_cwd "$source_pane" || true)
      [ -n "$source_cwd" ] && [ "$(cd "$source_cwd" 2>/dev/null && pwd -P)" = "$(cd "$source_worktree" 2>/dev/null && pwd -P)" ] || {
        echo "error: sender pane '$source_pane' is unavailable or belongs to another worktree; message '$ACK_ID' remains open" >&2
        return 1
      }
      corr=$(cs_message_field "$file" correlation_id)
      cs_herdr_agent_prompt_confirmed "$source_pane" "CONSIGLIERE_REPLY v1 message=$ACK_ID correlation=$corr summary=$REPLY" || {
        echo "error: reply for message '$ACK_ID' was not confirmed; obligation remains open" >&2
        return 1
      }
      cs_message_pending_close "$from_home/state" "$ACK_ID" "handled-by-$TASK_ID" || {
        echo "error: response obligation for message '$ACK_ID' could not be closed" >&2
        return 1
      }
      ;;
  esac
  cs_message_ack "$INBOX" "$ACK_ID" || {
    echo "error: could not acknowledge message '$ACK_ID'" >&2
    return 1
  }
  printf 'acknowledged message=%s task=%s\n' "$ACK_ID" "$TASK_ID"
}

if [ -n "$ACK_ID" ]; then
  ack_message
  exit 0
fi
[ -z "$REPLY" ] || { echo "error: --reply requires --ack" >&2; exit 2; }

count=0
failed=0
for file in "$INBOX"/*.msg; do
  [ -f "$file" ] || continue
  if ! cs_message_validate_file "$file"; then
    echo "error: malformed inbox message '$file'" >&2
    failed=1
    continue
  fi
  [ "$(cs_message_field "$file" to_task_id)" = "$TASK_ID" ] || continue
  ack="$INBOX/$(basename "$file" .msg).ack"
  if [ -e "$ack" ]; then
    cs_message_validate_ack "$ack" || {
      echo "error: malformed acknowledgement '$ack'" >&2
      failed=1
    }
    continue
  fi
  if ! message_source_valid "$file"; then
    failed=1
    continue
  fi
  printf 'message=%s kind=%s from=%s sequence=%s summary=%s artifact=%s commit=%s pull_request=%s\n' \
    "$(cs_message_field "$file" message_id)" \
    "$(cs_message_field "$file" kind)" \
    "$(cs_message_field "$file" from_task_id)" \
    "$(cs_message_field "$file" sequence)" \
    "$(cs_message_field "$file" summary)" \
    "$(cs_message_field "$file" artifact)" \
    "$(cs_message_field "$file" commit_sha)" \
    "$(cs_message_field "$file" pull_request)"
  count=$((count + 1))
done
printf 'inbox task=%s messages=%s\n' "$TASK_ID" "$count"
[ "$failed" -eq 0 ]
