#!/usr/bin/env bash
# cs-message-lib.sh - bounded durable parent/child messages and acknowledgements.
# Sourced, never executed. Records contain schema, identity, correlation,
# sequence, kind, sender and receiver task IDs, endpoint generations, summary,
# artifact, commit, pull request, and creation time fields.

CS_MESSAGE_SCHEMA='cs-message.v1'
CS_MESSAGE_PENDING_SCHEMA='cs-message-obligation.v1'
CS_MESSAGE_MAX_SUMMARY=512
CS_MESSAGE_MAX_PATH=512

cs_message_now() { printf '%s\n' "${CS_MESSAGE_NOW:-$(date +%s)}"; }

cs_message_new_id() {
  local raw digest
  if command -v openssl >/dev/null 2>&1; then raw=$(openssl rand -hex 16 2>/dev/null || true); fi
  if [ -z "${raw:-}" ]; then
    digest=$(printf '%s' "$$-$RANDOM-$(date +%s%N 2>/dev/null || date +%s)" | shasum -a 256 | awk '{print $1}')
    raw=${digest:0:32}
  fi
  printf 'message-%s\n' "${raw:0:32}"
}

cs_message_scalar() {
  local value=$1 max=$2 clean
  case "$value" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  clean=$(printf '%s' "$value" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177')
  [ "$clean" = "$value" ] || return 1
  [ "${#value}" -le "$max" ]
}

cs_message_id() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]{1,96}$'
}

cs_message_task() {
  cs_message_id "$1"
}

cs_message_generation() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._:-]{1,128}$'
}

cs_message_path_value() {
  local value=$1
  [ -z "$value" ] && return 0
  case "$value" in /*|*..*|*\\*) return 1 ;; esac
  cs_message_scalar "$value" "$CS_MESSAGE_MAX_PATH"
}

cs_message_absolute_path_value() {
  local value=$1
  case "$value" in /*) ;; *) return 1 ;; esac
  cs_message_scalar "$value" "$CS_MESSAGE_MAX_PATH"
}

cs_message_validate_fields() {
  local field key value seen='' required
  local -a required_keys=(schema message_id correlation_id sequence kind from_task_id to_task_id from_home
    from_endpoint_generation to_endpoint_generation summary created_at)
  [ "$#" -eq 15 ] || return 1
  for field in "$@"; do
    case "$field" in *=*) ;; *) return 1 ;; esac
    key=${field%%=*}
    value=${field#*=}
    case " $seen " in *" $key "*) return 1 ;; esac
    seen="$seen $key"
    case "$key" in
      schema) [ "$value" = "$CS_MESSAGE_SCHEMA" ] || return 1 ;;
      message_id|correlation_id) cs_message_id "$value" || return 1 ;;
      sequence|created_at)
        case "$value" in ''|*[!0-9]*) return 1 ;; esac
        [ "${#value}" -le 20 ] || return 1
        ;;
      kind) case "$value" in question|blocked|decision-required|checkpoint|result|failed) ;; *) return 1 ;; esac ;;
      from_task_id|to_task_id) cs_message_task "$value" || return 1 ;;
      from_home) cs_message_absolute_path_value "$value" || return 1 ;;
      from_endpoint_generation|to_endpoint_generation) cs_message_generation "$value" || return 1 ;;
      summary) cs_message_scalar "$value" "$CS_MESSAGE_MAX_SUMMARY" || return 1 ;;
      artifact) cs_message_path_value "$value" || return 1 ;;
      commit_sha) printf '%s\n' "$value" | grep -Eq '^$|^[0-9a-fA-F]{40}$' || return 1 ;;
      pull_request) case "$value" in *[!0-9]*) return 1 ;; esac ;;
      *) return 1 ;;
    esac
  done
  for required in "${required_keys[@]}"; do
    case " $seen " in *" $required "*) ;; *) return 1 ;; esac
  done
}

cs_message_path() { printf '%s/%s.msg\n' "$1" "$2"; }

cs_message_validate_file() {
  local file=$1 line key value
  [ -f "$file" ] || return 1
  [ "$(LC_ALL=C tr -d '\000' < "$file" | LC_ALL=C wc -c)" = "$(LC_ALL=C wc -c < "$file")" ] || return 1
  local -a fields=()
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *=*) ;; *) return 1 ;; esac
    key=${line%%=*}
    value=${line#*=}
    fields+=("$key=$value")
  done < "$file"
  cs_message_validate_fields "${fields[@]}"
}

cs_message_field() {
  local file=$1 key=$2
  cs_message_validate_file "$file" || return 1
  awk -F= -v wanted="$key" '$1 == wanted { print substr($0, length(wanted) + 2); found=1 } END { exit !found }' "$file"
}

cs_message_validate_ack() {
  local file=$1
  [ -f "$file" ] || return 1
  [ "$(wc -l < "$file" | tr -d ' ')" = 3 ] || return 1
  grep -Eq '^schema=cs-message\.v1$' "$file" || return 1
  grep -Eq '^message_id=[A-Za-z0-9._-]{1,96}$' "$file" || return 1
  grep -Eq '^acked_at=[0-9]{1,20}$' "$file"
}

cs_message_publish() {
  local inbox=$1 field message_id='' file tmp same
  shift
  case "$inbox" in /*) ;; *) return 1 ;; esac
  [ -d "$inbox" ] || return 1
  cs_message_validate_fields "$@" || return 1
  for field in "$@"; do
    [ "${field%%=*}" = message_id ] && message_id=${field#*=}
  done
  file=$(cs_message_path "$inbox" "$message_id")
  tmp="$inbox/.$message_id.msg.tmp.$$.$RANDOM"
  umask 077
  printf '%s\n' "$@" > "$tmp" || { rm -f "$tmp"; return 1; }
  cs_message_validate_file "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -e "$file" ]; then
    cmp -s "$tmp" "$file"; same=$?
    rm -f "$tmp"
    [ "$same" -eq 0 ]
    return
  fi
  if ln "$tmp" "$file" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  if [ -e "$file" ] && cmp -s "$tmp" "$file"; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
  return 1
}

cs_message_ack() {
  local inbox=$1 message_id=$2 ack tmp
  cs_message_id "$message_id" || return 1
  case "$inbox" in /*) ;; *) return 1 ;; esac
  [ -d "$inbox" ] || return 1
  cs_message_validate_file "$(cs_message_path "$inbox" "$message_id")" || return 1
  ack="$inbox/$message_id.ack"
  tmp="$inbox/.$message_id.ack.tmp.$$.$RANDOM"
  printf 'schema=%s\nmessage_id=%s\nacked_at=%s\n' "$CS_MESSAGE_SCHEMA" "$message_id" "$(cs_message_now)" > "$tmp"
  if [ -e "$ack" ]; then
    rm -f "$tmp"
    cs_message_validate_ack "$ack"
    return
  fi
  if ln "$tmp" "$ack" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
  [ -e "$ack" ] && cs_message_validate_ack "$ack"
}

cs_message_pending_path() { printf '%s/pending/%s.pending\n' "$1" "$2"; }

cs_message_pending_close_path() { printf '%s/pending/%s.closed\n' "$1" "$2"; }

cs_message_pending_validate_file() {
  local file=$1 line key value seen='' required
  local -a required_keys=(schema message_id correlation_id task_id parent_task_id kind phase created_at)
  [ -f "$file" ] || return 1
  [ "$(wc -l < "$file" | tr -d ' ')" = 8 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      schema) [ "$value" = "$CS_MESSAGE_PENDING_SCHEMA" ] || return 1 ;;
      message_id|correlation_id|task_id|parent_task_id) cs_message_id "$value" || return 1 ;;
      kind) case "$value" in question|decision-required) ;; *) return 1 ;; esac ;;
      phase) [ "$value" = awaiting-response ] || return 1 ;;
      created_at)
        case "$value" in ''|*[!0-9]*) return 1 ;; esac
        [ "${#value}" -le 20 ] || return 1
        ;;
      *) return 1 ;;
    esac
    case " $seen " in *" $key "*) return 1 ;; esac
    seen="$seen $key"
  done < "$file"
  for required in "${required_keys[@]}"; do
    case " $seen " in *" $required "*) ;; *) return 1 ;; esac
  done
}

cs_message_pending_create() {
  local state=$1 message_id=$2 correlation_id=$3 task_id=$4 parent_task_id=$5 kind=$6 created_at=$7
  local dir file tmp same
  cs_message_id "$message_id" && cs_message_id "$correlation_id" && cs_message_task "$task_id" &&
    cs_message_task "$parent_task_id" || return 1
  case "$kind" in question|decision-required) ;; *) return 1 ;; esac
  case "$created_at" in ''|*[!0-9]*) return 1 ;; esac
  dir="$state/pending"
  [ -d "$state" ] || return 1
  mkdir -p "$dir" || return 1
  file=$(cs_message_pending_path "$state" "$message_id")
  tmp="$dir/.$message_id.pending.tmp.$$.$RANDOM"
  printf 'schema=%s\nmessage_id=%s\ncorrelation_id=%s\ntask_id=%s\nparent_task_id=%s\nkind=%s\nphase=awaiting-response\ncreated_at=%s\n' \
    "$CS_MESSAGE_PENDING_SCHEMA" "$message_id" "$correlation_id" "$task_id" "$parent_task_id" "$kind" "$created_at" > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  cs_message_pending_validate_file "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -e "$file" ]; then
    cmp -s "$tmp" "$file"; same=$?
    rm -f "$tmp"
    [ "$same" -eq 0 ]
    return
  fi
  if ln "$tmp" "$file" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  if [ -e "$file" ] && cmp -s "$tmp" "$file"; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
  return 1
}

cs_message_pending_close() {
  local state=$1 message_id=$2 reason=$3 pending closed tmp same
  cs_message_id "$message_id" || return 1
  cs_message_scalar "$reason" "$CS_MESSAGE_MAX_SUMMARY" || return 1
  pending=$(cs_message_pending_path "$state" "$message_id")
  [ -f "$pending" ] || return 1
  cs_message_pending_validate_file "$pending" || return 1
  closed=$(cs_message_pending_close_path "$state" "$message_id")
  tmp="${closed}.tmp.$$.$RANDOM"
  printf 'schema=%s\nmessage_id=%s\nclosed_at=%s\nreason=%s\n' \
    "$CS_MESSAGE_PENDING_SCHEMA" "$message_id" "$(cs_message_now)" "$reason" > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  if [ -e "$closed" ]; then
    cmp -s "$tmp" "$closed"; same=$?
    rm -f "$tmp"
    [ "$same" -eq 0 ]
    return
  fi
  if ln "$tmp" "$closed" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  if [ -e "$closed" ] && cmp -s "$tmp" "$closed"; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
  return 1
}
