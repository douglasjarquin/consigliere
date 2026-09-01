#!/usr/bin/env bash
# cs-message-lib.sh - bounded durable parent/child messages and acknowledgements.
# Sourced, never executed. Records contain schema, identity, correlation,
# sequence, kind, sender and receiver task IDs, endpoint generations, summary,
# artifact, commit, pull request, and creation time fields.

CS_MESSAGE_SCHEMA='cs-message.v1'
CS_MESSAGE_PENDING_SCHEMA='cs-message-obligation.v1'
CS_MESSAGE_REPLY_SCHEMA='cs-message-reply.v1'
CS_MESSAGE_ROUTE_SCHEMA='cs-message-route.v1'
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

cs_message_recovery_id() {
  local task=$1 generation=$2 digest
  cs_message_task "$task" && cs_message_generation "$generation" || return 1
  digest=$(printf '%s\n' "$task:$generation" | shasum -a 256 2>/dev/null | awk '{print $1}') || return 1
  [ -n "$digest" ] || return 1
  printf 'recovery-%s\n' "${digest:0:32}"
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
      pull_request)
        case "$value" in *[!0-9]*) return 1 ;; esac
        [ "${#value}" -le 20 ] || return 1
        ;;
      *) return 1 ;;
    esac
  done
  for required in "${required_keys[@]}"; do
    case " $seen " in *" $required "*) ;; *) return 1 ;; esac
  done
}

cs_message_path() { printf '%s/%s.msg\n' "$1" "$2"; }

cs_message_route_path() { printf '%s.route\n' "${1%.msg}"; }

cs_message_filename_id() {
  local file=$1 suffix=$2 filename expected temp
  filename=${file##*/}
  case "$filename" in
    *"$suffix") expected=${filename%$suffix} ;;
    .*)
      temp=${filename#.}
      case "$temp" in
        *"$suffix".tmp.*) expected=${temp%"$suffix".tmp.*} ;;
        *) return 1 ;;
      esac
      ;;
    *"$suffix".tmp.*) expected=${filename%"$suffix".tmp.*} ;;
    *) return 1 ;;
  esac
  cs_message_id "$expected" || return 1
  printf '%s\n' "$expected"
}

cs_message_route_validate_file() {
  local file=$1 line key value seen='' required filename_id
  local -a required_keys=(schema message_id to_task_id endpoint_generation updated_at)
  [ -f "$file" ] || return 1
  [ "$(wc -l < "$file" | tr -d ' ')" = 5 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      schema) [ "$value" = "$CS_MESSAGE_ROUTE_SCHEMA" ] || return 1 ;;
      message_id|to_task_id) cs_message_id "$value" || return 1 ;;
      endpoint_generation) cs_message_generation "$value" || return 1 ;;
      updated_at)
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
  filename_id=$(cs_message_filename_id "$file" .route) || return 1
  [ "$(awk -F= '$1 == "message_id" { print substr($0, 12) }' "$file")" = "$filename_id" ] || return 1
}

cs_message_route_generation() {
  local file=$1 route message_id target
  route=$(cs_message_route_path "$file")
  if [ -e "$route" ]; then
    cs_message_route_validate_file "$route" || return 1
    message_id=$(cs_message_field "$file" message_id)
    target=$(cs_message_field "$file" to_task_id)
    [ "$(awk -F= '$1 == "message_id" { print substr($0, 12) }' "$route")" = "$message_id" ] || return 1
    [ "$(awk -F= '$1 == "to_task_id" { print substr($0, 12) }' "$route")" = "$target" ] || return 1
    awk -F= '$1 == "endpoint_generation" { print substr($0, 21) }' "$route"
  else
    cs_message_field "$file" to_endpoint_generation
  fi
}

cs_message_route_write() {
  local file=$1 target=$2 generation=$3 preserve_existing=${4:-0}
  local route tmp existing_message existing_target existing_generation
  cs_message_validate_file "$file" || return 1
  cs_message_task "$target" && cs_message_generation "$generation" || return 1
  [ "$(cs_message_field "$file" to_task_id)" = "$target" ] || return 1
  route=$(cs_message_route_path "$file")
  if [ -e "$route" ]; then
    cs_message_route_validate_file "$route" || return 1
    existing_message=$(awk -F= '$1 == "message_id" { print substr($0, 12) }' "$route")
    existing_target=$(awk -F= '$1 == "to_task_id" { print substr($0, 12) }' "$route")
    existing_generation=$(awk -F= '$1 == "endpoint_generation" { print substr($0, 21) }' "$route")
    [ "$existing_message" = "$(cs_message_field "$file" message_id)" ] || return 1
    [ "$existing_target" = "$target" ] || return 1
    [ "$existing_generation" = "$generation" ] && return 0
    [ "$preserve_existing" = 1 ] && return 0
  fi
  tmp="$route.tmp.$$.$RANDOM"
  printf 'schema=%s\nmessage_id=%s\nto_task_id=%s\nendpoint_generation=%s\nupdated_at=%s\n' \
    "$CS_MESSAGE_ROUTE_SCHEMA" "$(cs_message_field "$file" message_id)" "$target" \
    "$generation" "$(cs_message_now)" > "$tmp" || { rm -f "$tmp"; return 1; }
  cs_message_route_validate_file "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$route"
}

cs_message_validate_file() {
  local file=$1 line key value filename expected_id embedded_id
  [ -f "$file" ] || return 1
  [ "$(LC_ALL=C tr -d '\000' < "$file" | LC_ALL=C wc -c)" = "$(LC_ALL=C wc -c < "$file")" ] || return 1
  local -a fields=()
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *=*) ;; *) return 1 ;; esac
    key=${line%%=*}
    value=${line#*=}
    fields+=("$key=$value")
  done < "$file"
  cs_message_validate_fields "${fields[@]}" || return 1
  case "$file" in
    *.msg)
      filename=${file##*/}
      expected_id=${filename%.msg}
      cs_message_id "$expected_id" || return 1
      embedded_id=$(awk -F= '$1 == "message_id" { print substr($0, 12) }' "$file")
      [ "$embedded_id" = "$expected_id" ] || return 1
      ;;
  esac
}

cs_message_field() {
  local file=$1 key=$2
  cs_message_validate_file "$file" || return 1
  awk -F= -v wanted="$key" '$1 == wanted { print substr($0, length(wanted) + 2); found=1 } END { exit !found }' "$file"
}

cs_message_verify_result() {
  local file=$1 source_meta=$2 worktree artifact commit pull_request
  local pull_request_view
  [ "$(cs_message_field "$file" kind)" = result ] || {
    printf 'result message has the wrong kind\n' >&2
    return 1
  }
  worktree=$(cs_meta_get "$source_meta" worktree 2>/dev/null) || {
    printf 'result message sender metadata has no worktree\n' >&2
    return 1
  }
  case "$worktree" in /*) ;; *) printf 'result message worktree is not absolute\n' >&2; return 1 ;; esac
  [ -d "$worktree" ] || {
    printf 'result message worktree is unavailable\n' >&2
    return 1
  }
  artifact=$(cs_message_field "$file" artifact)
  commit=$(cs_message_field "$file" commit_sha)
  pull_request=$(cs_message_field "$file" pull_request)
  [ -n "$artifact" ] || [ -n "$commit" ] || [ -n "$pull_request" ] || {
    printf 'result message has no evidence reference\n' >&2
    return 1
  }
  if [ -n "$artifact" ]; then
    cs_message_path_value "$artifact" || {
      printf 'result artifact path is invalid: %s\n' "$artifact" >&2
      return 1
    }
    worktree=$(cd "$worktree" && pwd -P) || return 1
    artifact_dir=${artifact%/*}
    [ "$artifact_dir" = "$artifact" ] && artifact_dir=.
    resolved_dir=$(CDPATH='' cd -P "$worktree/$artifact_dir" 2>/dev/null && pwd -P) || {
      printf 'result artifact directory is unavailable: %s\n' "$artifact_dir" >&2
      return 1
    }
    case "$resolved_dir/" in
      "$worktree"/*) ;;
      *) printf 'result artifact directory escapes the worktree: %s\n' "$artifact_dir" >&2; return 1 ;;
    esac
    [ -f "$worktree/$artifact" ] && [ ! -L "$worktree/$artifact" ] || {
      printf 'result artifact is missing or not a regular file: %s\n' "$artifact" >&2
      return 1
    }
  fi
  if [ -n "$commit" ]; then
    git -C "$worktree" cat-file -e "${commit}^{commit}" 2>/dev/null || {
      printf 'result commit does not exist: %s\n' "$commit" >&2
      return 1
    }
    if [ -n "$artifact" ] && [ "$(git -C "$worktree" cat-file -t "${commit}:${artifact}" 2>/dev/null || true)" != blob ]; then
      printf 'result artifact is not a file in commit %s: %s\n' "$commit" "$artifact" >&2
      return 1
    fi
  fi
  if [ -n "$pull_request" ]; then
    pull_request_view=$(cd "$worktree" && gh-axi pr view "$pull_request" 2>/dev/null) || {
      printf 'result pull request could not be verified: %s\n' "$pull_request" >&2
      return 1
    }
    printf '%s\n' "$pull_request_view" | grep -Eq "^[[:space:]]+number: $pull_request$" || {
      printf 'result pull request identity did not match: %s\n' "$pull_request" >&2
      return 1
    }
  fi
  return 0
}

cs_message_validate_ack() {
  local file=$1 expected=${2:-} embedded filename_id
  [ -f "$file" ] || return 1
  [ "$(wc -l < "$file" | tr -d ' ')" = 3 ] || return 1
  grep -Eq '^schema=cs-message\.v1$' "$file" || return 1
  grep -Eq '^message_id=[A-Za-z0-9._-]{1,96}$' "$file" || return 1
  grep -Eq '^acked_at=[0-9]{1,20}$' "$file" || return 1
  embedded=$(awk -F= '$1 == "message_id" { print substr($0, 12) }' "$file")
  filename_id=$(cs_message_filename_id "$file" .ack) || return 1
  [ "$embedded" = "$filename_id" ] || return 1
  [ -z "$expected" ] || [ "$embedded" = "$expected" ]
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
    cs_message_validate_ack "$ack" "$message_id"
    return
  fi
  if ln "$tmp" "$ack" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
  [ -e "$ack" ] && cs_message_validate_ack "$ack" "$message_id"
}

cs_message_pending_path() { printf '%s/pending/%s.pending\n' "$1" "$2"; }

cs_message_pending_close_path() { printf '%s/pending/%s.closed\n' "$1" "$2"; }

cs_message_pending_validate_file() {
  local file=$1 line key value seen='' required filename_id
  local -a required_keys=(schema message_id correlation_id task_id parent_task_id kind phase from_home from_endpoint_generation to_endpoint_generation created_at)
  [ -f "$file" ] || return 1
  [ "$(wc -l < "$file" | tr -d ' ')" = 11 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      schema) [ "$value" = "$CS_MESSAGE_PENDING_SCHEMA" ] || return 1 ;;
      message_id|correlation_id|task_id|parent_task_id) cs_message_id "$value" || return 1 ;;
      kind) case "$value" in question|decision-required) ;; *) return 1 ;; esac ;;
      phase) [ "$value" = awaiting-response ] || return 1 ;;
      from_home) cs_message_absolute_path_value "$value" || return 1 ;;
      from_endpoint_generation|to_endpoint_generation) cs_message_generation "$value" || return 1 ;;
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
  filename_id=$(cs_message_filename_id "$file" .pending) || return 1
  [ "$(awk -F= '$1 == "message_id" { print substr($0, 12) }' "$file")" = "$filename_id" ] || return 1
}

cs_message_pending_field() {
  local file=$1 key=$2
  cs_message_pending_validate_file "$file" || return 1
  awk -F= -v wanted="$key" '$1 == wanted { print substr($0, length(wanted) + 2); found=1 } END { exit !found }' "$file"
}

cs_message_pending_matches_message() {
  local pending=$1 message=$2
  cs_message_pending_validate_file "$pending" || return 1
  cs_message_validate_file "$message" || return 1
  [ "$(cs_message_pending_field "$pending" message_id)" = "$(cs_message_field "$message" message_id)" ] &&
    [ "$(cs_message_pending_field "$pending" correlation_id)" = "$(cs_message_field "$message" correlation_id)" ] &&
    [ "$(cs_message_pending_field "$pending" task_id)" = "$(cs_message_field "$message" from_task_id)" ] &&
    [ "$(cs_message_pending_field "$pending" parent_task_id)" = "$(cs_message_field "$message" to_task_id)" ] &&
    [ "$(cs_message_pending_field "$pending" kind)" = "$(cs_message_field "$message" kind)" ] &&
    [ "$(cs_message_pending_field "$pending" from_home)" = "$(cs_message_field "$message" from_home)" ] &&
    [ "$(cs_message_pending_field "$pending" from_endpoint_generation)" = "$(cs_message_field "$message" from_endpoint_generation)" ] &&
    [ "$(cs_message_pending_field "$pending" to_endpoint_generation)" = "$(cs_message_field "$message" to_endpoint_generation)" ] &&
    [ "$(cs_message_pending_field "$pending" created_at)" = "$(cs_message_field "$message" created_at)" ]
}

cs_message_pending_create() {
  local state=$1 message_id=$2 correlation_id=$3 task_id=$4 parent_task_id=$5 kind=$6 created_at=$7
  local from_home=${8:-} from_endpoint_generation=${9:-} to_endpoint_generation=${10:-}
  local dir file tmp same
  cs_message_id "$message_id" && cs_message_id "$correlation_id" && cs_message_task "$task_id" &&
    cs_message_task "$parent_task_id" || return 1
  case "$kind" in question|decision-required) ;; *) return 1 ;; esac
  cs_message_absolute_path_value "$from_home" && cs_message_generation "$from_endpoint_generation" &&
    cs_message_generation "$to_endpoint_generation" || return 1
  case "$created_at" in ''|*[!0-9]*) return 1 ;; esac
  dir="$state/pending"
  [ -d "$state" ] || return 1
  mkdir -p "$dir" || return 1
  file=$(cs_message_pending_path "$state" "$message_id")
  tmp="$dir/.$message_id.pending.tmp.$$.$RANDOM"
  printf 'schema=%s\nmessage_id=%s\ncorrelation_id=%s\ntask_id=%s\nparent_task_id=%s\nkind=%s\nphase=awaiting-response\nfrom_home=%s\nfrom_endpoint_generation=%s\nto_endpoint_generation=%s\ncreated_at=%s\n' \
    "$CS_MESSAGE_PENDING_SCHEMA" "$message_id" "$correlation_id" "$task_id" "$parent_task_id" "$kind" \
    "$from_home" "$from_endpoint_generation" "$to_endpoint_generation" "$created_at" > "$tmp" || {
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
  if [ -e "$closed" ]; then
    cs_message_pending_close_validate_file "$closed" "$message_id" || return 1
    return 0
  fi
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

cs_message_reply_path() { printf '%s/pending/%s.reply\n' "$1" "$2"; }
cs_message_reply_delivery_path() { printf '%s/pending/%s.reply-delivered\n' "$1" "$2"; }

cs_message_reply_validate_file() {
  local file=$1 expected=${2:-} line key value seen='' required embedded filename_id
  local -a required_keys=(schema message_id correlation_id summary replied_at)
  [ -f "$file" ] || return 1
  [ "$(wc -l < "$file" | tr -d ' ')" = 5 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      schema) [ "$value" = "$CS_MESSAGE_REPLY_SCHEMA" ] || return 1 ;;
      message_id|correlation_id) cs_message_id "$value" || return 1 ;;
      summary) cs_message_scalar "$value" "$CS_MESSAGE_MAX_SUMMARY" || return 1 ;;
      replied_at)
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
  embedded=$(awk -F= '$1 == "message_id" { print substr($0, 12) }' "$file")
  filename_id=$(cs_message_filename_id "$file" .reply) || return 1
  [ "$embedded" = "$filename_id" ] || return 1
  [ -z "$expected" ] || [ "$embedded" = "$expected" ]
}

cs_message_reply_publish() {
  local state=$1 message_id=$2 correlation_id=$3 summary=$4 replied_at=$5
  local dir file tmp same
  cs_message_id "$message_id" && cs_message_id "$correlation_id" || return 1
  cs_message_scalar "$summary" "$CS_MESSAGE_MAX_SUMMARY" || return 1
  case "$replied_at" in ''|*[!0-9]*) return 1 ;; esac
  dir="$state/pending"
  [ -d "$dir" ] || return 1
  file=$(cs_message_reply_path "$state" "$message_id")
  tmp="$dir/.$message_id.reply.tmp.$$.$RANDOM"
  printf 'schema=%s\nmessage_id=%s\ncorrelation_id=%s\nsummary=%s\nreplied_at=%s\n' \
    "$CS_MESSAGE_REPLY_SCHEMA" "$message_id" "$correlation_id" "$summary" "$replied_at" > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  cs_message_reply_validate_file "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -e "$file" ]; then
    cs_message_reply_validate_file "$file" "$message_id" || { rm -f "$tmp"; return 1; }
    [ "$(awk -F= '$1 == "correlation_id" { print substr($0, 16) }' "$file")" = "$correlation_id" ] || {
      rm -f "$tmp"
      return 1
    }
    [ "$(awk -F= '$1 == "summary" { print substr($0, 9) }' "$file")" = "$summary" ] || {
      rm -f "$tmp"
      return 1
    }
    rm -f "$tmp"
    return 0
  fi
  if ln "$tmp" "$file" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  if [ -e "$file" ] && cmp -s "$tmp" "$file"; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
  return 1
}

cs_message_reply_delivery_mark() {
  local state=$1 message_id=$2 delivered_at=$3 file tmp
  cs_message_id "$message_id" || return 1
  case "$delivered_at" in ''|*[!0-9]*) return 1 ;; esac
  file=$(cs_message_reply_delivery_path "$state" "$message_id")
  if [ -e "$file" ]; then
    cs_message_reply_delivery_validate_file "$file" "$message_id"
    return $?
  fi
  tmp="$file.tmp.$$.$RANDOM"
  printf 'schema=%s\nmessage_id=%s\ndelivered_at=%s\n' "$CS_MESSAGE_REPLY_SCHEMA" "$message_id" "$delivered_at" > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  if ln "$tmp" "$file" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
  [ -e "$file" ] && cs_message_reply_delivery_mark "$state" "$message_id" "$delivered_at"
}

cs_message_reply_delivery_exists() {
  local file
  file=$(cs_message_reply_delivery_path "$1" "$2")
  cs_message_reply_delivery_validate_file "$file" "$2"
}

cs_message_reply_delivery_validate_file() {
  local file=$1 expected=${2:-} embedded filename_id
  [ -f "$file" ] || return 1
  [ "$(wc -l < "$file" | tr -d ' ')" = 3 ] || return 1
  grep -Eq "^schema=$CS_MESSAGE_REPLY_SCHEMA$" "$file" || return 1
  grep -Eq '^message_id=[A-Za-z0-9._-]{1,96}$' "$file" || return 1
  grep -Eq '^delivered_at=[0-9]{1,20}$' "$file" || return 1
  embedded=$(awk -F= '$1 == "message_id" { print substr($0, 12) }' "$file")
  filename_id=$(cs_message_filename_id "$file" .reply-delivered) || return 1
  [ "$embedded" = "$filename_id" ] || return 1
  [ -z "$expected" ] || [ "$embedded" = "$expected" ]
}

cs_message_pending_close_validate_file() {
  local file=$1 expected=${2:-} line key value seen='' required embedded filename_id
  local -a required_keys=(schema message_id closed_at reason)
  [ -f "$file" ] || return 1
  [ "$(wc -l < "$file" | tr -d ' ')" = 4 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      schema) [ "$value" = "$CS_MESSAGE_PENDING_SCHEMA" ] || return 1 ;;
      message_id) cs_message_id "$value" || return 1 ;;
      closed_at)
        case "$value" in ''|*[!0-9]*) return 1 ;; esac
        [ "${#value}" -le 20 ] || return 1
        ;;
      reason) cs_message_scalar "$value" "$CS_MESSAGE_MAX_SUMMARY" || return 1 ;;
      *) return 1 ;;
    esac
    case " $seen " in *" $key "*) return 1 ;; esac
    seen="$seen $key"
  done < "$file"
  for required in "${required_keys[@]}"; do
    case " $seen " in *" $required "*) ;; *) return 1 ;; esac
  done
  embedded=$(awk -F= '$1 == "message_id" { print substr($0, 12) }' "$file")
  filename_id=$(cs_message_filename_id "$file" .closed) || return 1
  [ "$embedded" = "$filename_id" ] || return 1
  [ -z "$expected" ] || [ "$embedded" = "$expected" ]
}
