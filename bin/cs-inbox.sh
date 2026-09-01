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
if [ "$TASK_ID" != root ] && [ ! -f "$TASK_META" ]; then
  echo "error: task metadata is missing at $TASK_META" >&2
  exit 1
fi
INBOX="$STATE/inbox"
[ -d "$INBOX" ] || { echo "inbox task=$TASK_ID messages=0"; exit 0; }

ACK_ID=
REPLY=
ESCALATE_ID=
ESCALATE_SUMMARY=
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
    --escalate)
      [ -z "$ESCALATE_ID" ] || { echo "error: --escalate may be supplied once" >&2; exit 2; }
      ESCALATE_ID=${2:?--escalate requires a message id}
      shift 2
      ;;
    --summary)
      [ -z "$ESCALATE_SUMMARY" ] || { echo "error: --summary may be supplied once" >&2; exit 2; }
      ESCALATE_SUMMARY=${2:?--summary requires a bounded summary}
      shift 2
      ;;
    --help|-h)
      printf '%s\n' 'usage: cs-inbox.sh [--ack <message-id> [--reply <bounded-answer>]]'
      printf '%s\n' '       cs-inbox.sh --escalate <message-id> --summary <bounded-summary>'
      exit 0
      ;;
    *) echo "error: unknown flag $1" >&2; exit 2 ;;
  esac
done
[ -z "$ACK_ID" ] || [ -z "$ESCALATE_ID" ] || {
  echo "error: --ack and --escalate cannot be combined" >&2
  exit 2
}
[ -z "$ESCALATE_ID" ] || [ -n "$ESCALATE_SUMMARY" ] || {
  echo "error: --escalate requires --summary" >&2
  exit 2
}
[ -z "$ESCALATE_SUMMARY" ] || [ -n "$ESCALATE_ID" ] || {
  echo "error: --summary requires --escalate" >&2
  exit 2
}

message_source_valid() {
  local file=$1 source_task source_meta source_parent source_home source_recorded_home from_home
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
  source_recorded_home=$(cs_meta_get "$source_meta" home 2>/dev/null || true)
  [ "$source_recorded_home" = "$from_home" ] || {
    echo "error: message '$file' does not match the sender metadata home" >&2
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
  cs_meta_endpoint_generation_known "$source_meta" \
    "$(cs_message_field "$file" from_endpoint_generation)" "$(cs_message_field "$file" created_at)" || {
    echo "error: stale sender generation in '$file'" >&2
    return 1
  }
  if [ "$TASK_ID" != root ]; then
    [ "$(cs_meta_get "$TASK_META" endpoint_generation)" = "$(cs_message_route_generation "$file")" ] || {
      echo "error: stale receiver generation in '$file'" >&2
      return 1
    }
  elif [ -f "$STATE/.home-endpoint-generation" ]; then
    root_generation=$(sed -n '1p' "$STATE/.home-endpoint-generation")
    cs_message_generation "$root_generation" && [ "$root_generation" = "$(cs_message_route_generation "$file")" ] || {
      echo "error: stale receiver generation in '$file'" >&2
      return 1
    }
  else
    echo "error: root endpoint generation is unavailable" >&2
    return 1
  fi
}

deliver_reply() {
  local file=$1 kind from_home source_task source_meta source_pane source_worktree source_cwd corr state source_agent
  kind=$(cs_message_field "$file" kind)
  case "$kind" in
    question|decision-required) ;;
    *) echo "error: message '$ACK_ID' does not accept a reply" >&2; return 1 ;;
  esac
  from_home=$(cs_message_field "$file" from_home)
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
  source_agent=$(cs_meta_get "$source_meta" harness 2>/dev/null || true)
  if [ -n "$source_agent" ] && ! cs_herdr_agent_kind_matches "$source_pane" "$source_agent"; then
    echo "error: sender pane '$source_pane' does not contain the recorded $source_agent agent; message '$ACK_ID' remains open" >&2
    return 1
  fi
  cs_message_scalar "$REPLY" "$CS_MESSAGE_MAX_SUMMARY" || {
    echo "error: reply for message '$ACK_ID' exceeds the bounded message field or contains control characters" >&2
    return 1
  }
  state="$from_home/state"
  corr=$(cs_message_field "$file" correlation_id)
  cs_message_reply_publish "$state" "$ACK_ID" "$corr" "$REPLY" "$(cs_message_now)" || {
    echo "error: reply for message '$ACK_ID' could not be durably recorded" >&2
    return 1
  }
  if cs_message_reply_delivery_exists "$state" "$ACK_ID"; then
    return 0
  fi
  source_cwd=$(cs_herdr_pane_cwd "$source_pane" || true)
  [ -n "$source_cwd" ] && [ "$(cd "$source_cwd" 2>/dev/null && pwd -P)" = "$(cd "$source_worktree" 2>/dev/null && pwd -P)" ] || {
    echo "error: sender pane '$source_pane' is unavailable or belongs to another worktree; message '$ACK_ID' remains open" >&2
    return 1
  }
  cs_herdr_agent_prompt_confirmed "$source_pane" "CONSIGLIERE_REPLY v1 message=$ACK_ID correlation=$corr summary=$REPLY" || {
    echo "error: reply for message '$ACK_ID' was not confirmed; obligation remains open" >&2
    return 1
  }
  cs_message_reply_delivery_mark "$state" "$ACK_ID" "$(cs_message_now)" || {
    echo "error: reply for message '$ACK_ID' was accepted but delivery state could not be recorded" >&2
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
    cs_message_validate_ack "$ack" "$ACK_ID" || { echo "error: malformed acknowledgement '$ack'" >&2; return 1; }
    if [ -n "$REPLY" ]; then
      message_source_valid "$file" || return 1
      case "$(cs_message_field "$file" kind)" in
        question|decision-required)
          pending_file=$(cs_message_pending_path "$(cs_message_field "$file" from_home)/state" "$ACK_ID")
          cs_message_pending_matches_message "$pending_file" "$file" || {
            echo "error: response obligation '$ACK_ID' does not match its inbox message; acknowledgement remains absent" >&2
            return 1
          }
          ;;
      esac
      deliver_reply "$file" || return 1
      if [ -f "${pending_file:-}" ]; then
        if [ -e "${pending_file%.pending}.closed" ]; then
          cs_message_pending_close_validate_file "${pending_file%.pending}.closed" "$ACK_ID" || return 1
        else
          cs_message_pending_close "$(cs_message_field "$file" from_home)/state" "$ACK_ID" "handled-by-$TASK_ID" || return 1
        fi
      fi
    fi
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
  if [ "$kind" = question ] || [ "$kind" = decision-required ]; then
    pending_file=$(cs_message_pending_path "$from_home/state" "$ACK_ID")
    cs_message_pending_matches_message "$pending_file" "$file" || {
      echo "error: response obligation '$ACK_ID' does not match its inbox message; acknowledgement remains absent" >&2
      return 1
    }
  fi
  case "$kind" in
    question|decision-required)
      [ -n "$REPLY" ] || {
        echo "error: response-required message '$ACK_ID' needs --reply before acknowledgement" >&2
        return 1
      }
      deliver_reply "$file" || return 1
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

escalate_message() {
  local file="$INBOX/$ESCALATE_ID.msg" kind from_home source_task source_meta corr
  local parent_task parent_state escalation_id pending_file closed_file transfer_file data_dir
  cs_message_id "$ESCALATE_ID" || { echo "error: invalid message id '$ESCALATE_ID'" >&2; return 1; }
  [ -f "$file" ] || { echo "error: message '$ESCALATE_ID' is missing" >&2; return 1; }
  message_source_valid "$file" || return 1
  kind=$(cs_message_field "$file" kind)
  case "$kind" in
    question|decision-required) ;;
    *) echo "error: only question or decision-required messages can be escalated" >&2; return 1 ;;
  esac
  from_home=$(cs_message_field "$file" from_home)
  source_task=$(cs_message_field "$file" from_task_id)
  pending_file=$(cs_message_pending_path "$from_home/state" "$ESCALATE_ID")
  [ -f "$pending_file" ] || {
    echo "error: message '$ESCALATE_ID' has no open response obligation to transfer" >&2
    return 1
  }
  cs_message_pending_validate_file "$pending_file" || {
    echo "error: message '$ESCALATE_ID' has a malformed response obligation" >&2
    return 1
  }
  cs_message_pending_matches_message "$pending_file" "$file" || {
    echo "error: response obligation '$ESCALATE_ID' does not match its inbox message" >&2
    return 1
  }
  cs_meta_validate_parent_edge "$TASK_META" || {
    echo "error: task '$TASK_ID' has no parent to receive an escalation" >&2
    return 1
  }
  parent_task=$(cs_meta_get "$TASK_META" parent_task_id)
  parent_state=$(cs_meta_get "$TASK_META" parent_state)
  corr=$(cs_message_field "$file" correlation_id)
  escalation_id=$(cs_message_recovery_id "$TASK_ID" "$ESCALATE_ID") || {
    echo "error: could not derive the idempotent escalation identity" >&2
    return 1
  }
  closed_file=$(cs_message_pending_close_path "$from_home/state" "$ESCALATE_ID")
  transfer_file="$parent_state/inbox/$escalation_id.msg"
  if [ -e "$INBOX/$ESCALATE_ID.ack" ] && [ -e "$closed_file" ]; then
    cs_message_validate_file "$transfer_file" || {
      echo "error: acknowledged escalation '$ESCALATE_ID' has no valid durable transfer" >&2
      return 1
    }
    printf 'already escalated message=%s transfer=%s parent=%s\n' "$ESCALATE_ID" "$escalation_id" "$parent_task"
    return 0
  fi
  data_dir=${CS_DATA_OVERRIDE:-$CS_HOME/data}
  if ! CS_HOME="$CS_HOME" CS_STATE_OVERRIDE="$STATE" \
    CS_DATA_OVERRIDE="$data_dir" CS_TASK_ID="$TASK_ID" \
    "$SCRIPT_DIR/cs-report.sh" decision-required "$ESCALATE_SUMMARY" \
      --message-id "$escalation_id" --correlation "$corr" >/dev/null; then
    echo "error: escalation '$ESCALATE_ID' was not durably transferred to parent '$parent_task'" >&2
    return 1
  fi
  cs_message_pending_close "$from_home/state" "$ESCALATE_ID" "transferred-to-$TASK_ID" || {
    echo "error: escalation transferred but child obligation '$ESCALATE_ID' could not be closed" >&2
    return 1
  }
  cs_message_ack "$INBOX" "$ESCALATE_ID" || {
    echo "error: escalation transferred but child message '$ESCALATE_ID' could not be acknowledged" >&2
    return 1
  }
  printf 'escalated message=%s transfer=%s parent=%s\n' "$ESCALATE_ID" "$escalation_id" "$parent_task"
}

if [ -n "$ACK_ID" ]; then
  ack_message
  exit 0
fi
if [ -n "$ESCALATE_ID" ]; then
  [ -z "$REPLY" ] || { echo "error: --reply cannot accompany --escalate" >&2; exit 2; }
  escalate_message
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
      cs_message_validate_ack "$ack" "$(cs_message_field "$file" message_id)" || {
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
