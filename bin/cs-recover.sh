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
# shellcheck source=bin/cs-harness-lib.sh
. "$SCRIPT_DIR/cs-harness-lib.sh"
# shellcheck source=bin/cs-message-lib.sh
. "$SCRIPT_DIR/cs-message-lib.sh"

MAX_RECORDS=${CS_RECOVER_MAX_RECORDS:-64}
case "$MAX_RECORDS" in ''|*[!0-9]*|0) MAX_RECORDS=64 ;; esac
seen=''
checked=0
rewoken=0
failed=0
requested=0

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
  expected_agent=$(cs_meta_get "$meta" harness 2>/dev/null || true)
  if [ -n "$expected_agent" ] && ! cs_herdr_agent_kind_matches "$pane" "$expected_agent"; then
    echo "error: $label endpoint '$pane' does not contain the recorded $expected_agent agent" >&2
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

 wake_root_message() {
  local file=$1 root_state=$2 root_home=$3 message_id pane root_generation cwd source_task source_home source_meta expected_agent
  message_id=$(cs_message_field "$file" message_id)
  pane=$(sed -n '1p' "$root_state/.home-pane" 2>/dev/null || true)
  root_generation=$(sed -n '1p' "$root_state/.home-endpoint-generation" 2>/dev/null || true)
  [ -n "$pane" ] && [ -n "$root_generation" ] || {
    echo "error: message '$message_id' root endpoint identity is unavailable" >&2
    return 1
  }
  cwd=$(cs_herdr_pane_cwd "$pane" 2>/dev/null || true)
  [ -n "$cwd" ] && [ "$(cd "$cwd" 2>/dev/null && pwd -P)" = "$(cd "$root_home" 2>/dev/null && pwd -P)" ] || {
    echo "error: message '$message_id' root endpoint '$pane' is unavailable or belongs to another home" >&2
    return 1
  }
  source_task=$(cs_message_field "$file" from_task_id)
  source_home=$(cs_message_field "$file" from_home)
  source_meta="$source_home/state/$source_task.meta"
  expected_agent=$(CS_HOME="$root_home" cs_harness_detect_root)
  if [ -n "$expected_agent" ] && ! cs_herdr_agent_kind_matches "$pane" "$expected_agent"; then
    echo "error: message '$message_id' root endpoint '$pane' does not contain the recorded $expected_agent agent" >&2
    return 1
  fi
  cs_message_route_write "$file" root "$root_generation" || {
    echo "error: message '$message_id' root route could not be repaired" >&2
    return 1
  }
  cs_herdr_agent_prompt_confirmed "$pane" "CONSIGLIERE_WAKE v1 message=$message_id" || {
    echo "error: message '$message_id' root wake was not confirmed" >&2
    return 1
  }
  printf 'recover: re-woke message=%s task=root\n' "$message_id"
}

reconcile_settled_child() {
  local meta=$1 task kind status last generation pane recovery_id marker native_state
  task=$(basename "$meta" .meta)
  kind=$(cs_meta_get "$meta" kind 2>/dev/null || true)
  [ "$kind" != capo ] || return 0
  status="$STATE/$task.status"
  generation=$(cs_meta_get "$meta" endpoint_generation 2>/dev/null || true)
  pane=$(cs_meta_get "$meta" pane 2>/dev/null || true)
  [ -n "$generation" ] && [ -n "$pane" ] || return 1
  if [ -f "$status" ]; then
    last=$(tail -n 1 "$status" 2>/dev/null || true)
    case "$last" in
      done:*|done\ *|failed:*|failed\ *) ;;
      *) return 0 ;;
    esac
  else
    native_state=$(cs_herdr_agent_busy_state "$pane" 2>/dev/null || true)
    case "$native_state" in
      done) ;;
      idle) [ -f "$STATE/$task.turn-ended" ] || return 0 ;;
      *) return 0 ;;
    esac
  fi
  for file in "$STATE"/inbox/*.msg; do
    [ -f "$file" ] || continue
    cs_message_validate_file "$file" || continue
    [ "$(cs_message_field "$file" from_task_id)" = "$task" ] || continue
    [ "$(cs_message_field "$file" from_endpoint_generation)" = "$generation" ] || continue
    case "$(cs_message_field "$file" kind)" in result|failed) return 0 ;; esac
  done
  recovery_id=$(cs_message_recovery_id "$task" "$generation") || return 1
  marker="$STATE/.report-requested-$recovery_id"
  [ ! -e "$marker" ] || return 0
  : > "$marker" || return 1
  if endpoint_ready "$meta" "$pane" "settled child '$task'" && cs_herdr_agent_alive "$pane"; then
    cs_herdr_agent_prompt_confirmed "$pane" "CONSIGLIERE_REPORT_REQUIRED v1 task=$task" || {
      rm -f "$marker"
      echo "error: settled child '$task' did not accept the one-time report request" >&2
      return 1
    }
    printf 'recover: requested-report task=%s\n' "$task"
    requested=$((requested + 1))
    return 0
  fi
  recover_data_dir=${CS_DATA_OVERRIDE:-$CS_HOME/data}
  CS_HOME="$CS_HOME" CS_ROOT_OVERRIDE="${CS_ROOT:-}" CS_STATE_OVERRIDE="$STATE" \
    CS_DATA_OVERRIDE="$recover_data_dir" CS_TASK_ID="$task" \
    "$SCRIPT_DIR/cs-worker-turnend.sh" >/dev/null 2>&1 || true
  if [ -f "$(cs_meta_get "$meta" parent_state 2>/dev/null || true)/inbox/$recovery_id.msg" ]; then
    printf 'recover: escalated-gone task=%s message=%s\n' "$task" "$recovery_id"
    requested=$((requested + 1))
    return 0
  fi
  rm -f "$marker"
  echo "error: settled child '$task' has no recoverable endpoint or semantic result" >&2
  return 1
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
  message_id=$(cs_message_pending_field "$pending" message_id 2>/dev/null || true)
  if seen_message "$message_id"; then continue; fi
  task=$(cs_message_pending_field "$pending" task_id)
  pending_parent=$(cs_message_pending_field "$pending" parent_task_id)
  pending_correlation=$(cs_message_pending_field "$pending" correlation_id)
  pending_kind=$(cs_message_pending_field "$pending" kind)
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
  child_home=$(cs_meta_get "$child_meta" home 2>/dev/null || true)
  [ "$(cs_message_field "$message_file" from_task_id)" = "$task" ] &&
    [ "$(cs_message_field "$message_file" from_home)" = "$child_home" ] &&
    [ "$(cs_message_field "$message_file" to_task_id)" = "$pending_parent" ] &&
    [ "$(cs_message_field "$message_file" correlation_id)" = "$pending_correlation" ] &&
    [ "$(cs_message_field "$message_file" kind)" = "$pending_kind" ] || {
      echo "error: pending message '$message_id' does not match its inbox identity" >&2
      failed=1
      continue
    }
  ack_file="${message_file%.msg}.ack"
  if [ -e "$ack_file" ]; then
    cs_message_validate_ack "$ack_file" "$message_id" || {
      echo "error: malformed acknowledgement '$ack_file'" >&2
      failed=1
    }
    continue
  fi
  recipient_meta="$parent_state/$parent_task.meta"
  if [ "$parent_task" = root ]; then
    if wake_root_message "$message_file" "$parent_state" "$(cs_meta_get "$child_meta" parent_home)"; then
      rewoken=$((rewoken + 1))
    else
      failed=1
    fi
  elif [ ! -f "$recipient_meta" ]; then
    echo "error: pending message '$message_id' names missing recipient metadata '$recipient_meta'" >&2
    failed=1
    continue
  elif wake_message "$message_file" "$recipient_meta"; then
    rewoken=$((rewoken + 1))
  else
    failed=1
  fi
done

for message_file in "$STATE"/inbox/*.msg; do
  [ -f "$message_file" ] || continue
  [ "$checked" -lt "$MAX_RECORDS" ] || break
  message_id=$(basename "$message_file" .msg)
  cs_message_id "$message_id" || {
    echo "error: inbox message '$message_file' has an invalid filename identity" >&2
    failed=1
    continue
  }
  ack_file="${message_file%.msg}.ack"
  if [ -e "$ack_file" ]; then
    cs_message_validate_ack "$ack_file" "$message_id" || {
      echo "error: malformed acknowledgement '$ack_file'" >&2
      failed=1
    }
    continue
  fi
  checked=$((checked + 1))
  if ! cs_message_validate_file "$message_file"; then
    echo "error: malformed inbox message '$message_file'" >&2
    failed=1
    continue
  fi
  message_id=$(cs_message_field "$message_file" message_id)
  if seen_message "$message_id"; then continue; fi
  task=$(cs_message_field "$message_file" to_task_id)
  source_task=$(cs_message_field "$message_file" from_task_id)
  source_home=$(cs_message_field "$message_file" from_home)
  source_meta="$source_home/state/$source_task.meta"
  if [ ! -f "$source_meta" ] || ! cs_meta_validate_parent_edge "$source_meta" ||
    [ "$(cs_meta_get "$source_meta" home 2>/dev/null || true)" != "$source_home" ] ||
    [ "$(cs_meta_get "$source_meta" parent_task_id 2>/dev/null || true)" != "$task" ] ||
    [ "$(cs_meta_get "$source_meta" parent_home 2>/dev/null || true)" != "$CS_HOME" ] ||
    ! cs_meta_endpoint_generation_known "$source_meta" \
      "$(cs_message_field "$message_file" from_endpoint_generation)" \
      "$(cs_message_field "$message_file" created_at)"; then
    echo "error: inbox message '$message_id' has invalid sender lineage or generation" >&2
    failed=1
    continue
  fi
  recipient_meta="$STATE/$task.meta"
  if [ "$task" = root ]; then
    if wake_root_message "$message_file" "$STATE" "$CS_HOME"; then
      rewoken=$((rewoken + 1))
    else
      failed=1
    fi
    continue
  fi
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

for meta in "$STATE"/*.meta; do
  [ "$checked" -lt "$MAX_RECORDS" ] || break
  [ -f "$meta" ] || continue
  checked=$((checked + 1))
  reconcile_settled_child "$meta" || failed=1
done

printf 'recover: checked=%s re-woke=%s requested=%s\n' "$checked" "$rewoken" "$requested"
if [ "$failed" -ne 0 ]; then
  printf 'recover: next=inspect the named endpoint, metadata, or message before retrying\n'
  exit 1
fi
if [ "$rewoken" -gt 0 ] || [ "$requested" -gt 0 ]; then
  printf 'recover: next=drain re-woken inboxes and collect requested reports\n'
else
  printf 'recover: next=none\n'
fi
