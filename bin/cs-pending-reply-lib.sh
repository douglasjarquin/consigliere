#!/usr/bin/env bash
# cs-pending-reply-lib.sh - parent-owned capo missed-report guards.
#
# When the main consigliere delivers a marked from-consigliere request to a
# capo, this library records a durable parent-owned pending-reply expectation
# BEFORE delivery, embeds a privacy-safe correlation id in the outbound
# message, and later resolves that expectation only from a correlated parent
# status line or status-pointed document - never from transport success, chat
# content, or unrelated status activity.
#
# Safety property: a capo agent may ignore the marker and answer only in its
# visible conversation, which the main consigliere never reads. The parent
# must notice the missing correlated report without scraping that
# conversation, send exactly one automatic recovery request asking for a
# repost through the parent channel, and escalate once if the recovery turn
# also completes without a correlated report. Never loop, never repeatedly
# inject, never silently expire unresolved records, and never treat wrong-home
# sightings as acknowledgement.
#
# Record location (parent CS_HOME): state/pending-replies/<corr_id>
# Each record is a key=value file owned by this library. Schema:
# SCHEMA-OWNER: pending-reply record fields - the one full statement; every
# other mention of these fields is a pointer only.
#   schema=cs-pending-reply.v1
#   corr_id=                privacy-safe correlation token (16 lowercase hex)
#   source_kind=             empty (an outbound marked-send expectation)
#   task_id=                capo task id in the parent home
#   parent_home=            absolute parent CS_HOME
#   parent_status=          absolute path of parent state/<task_id>.status
#   parent_status_scan_signature=
#   request_summary=        short sanitized summary (no secrets by design)
#   created_epoch=          when the expectation was created
#   delivered_epoch=        when the marked request was confirmed delivered
#                           (empty until delivery; delivery never resolves)
#   phase=                  awaiting_report | delivery_unknown |
#                           recovery_sending | recovery_sent | recovery_failed |
#                           recovery_unknown | escalated | resolved
#   turn_seen_busy=         0|1 after delivery for the original request turn
#   request_turn_completed_epoch=
#   recovery_attempted_epoch= recovery_sender_pid= recovery_sender_identity=
#   recovery_sent_epoch= recovery_delivery_outcome= recovery_turn_seen_busy=
#   recovery_turn_completed_epoch=
#   escalated_epoch= resolved_epoch=
#   resolved_via=           status | document | empty
#   wrong_home_hits= wrong_home_sightings= wrong_home_scan_signature=
#   grace_secs=             bounded grace before recovery is eligible
#
# A record with a NUL byte anywhere in it is rejected as corrupt before any
# field is parsed, in the same fail-closed bucket as a missing or unreadable
# record: bash's read drops NUL bytes and bash generations disagree on the
# result (3.2 truncates the value at the NUL, 5.x splices the surrounding bytes
# together), so a NUL-bearing parent_home= could resolve to a home the record's
# bytes never name contiguously - and which home a recovery send then wrote to
# would depend on the interpreter running it.
#
#
# Sourced by bin/cs-send.sh, bin/cs-watch.sh, and the tests. No side effects
# on source. set -u / set -e safe. The watcher calls cs_pending_reply_tick
# <state-dir> once per poll.
#
# Tunables (env):
#   CS_PENDING_REPLY_GRACE_SECS    default 120
#   CS_PENDING_REPLY_DIR_OVERRIDE  override the pending-replies dir (tests)
#   CS_PENDING_REPLY_SEND_HOOK     optional command for recovery delivery
#                                  (tests); receives task_id and message args
#   CS_PENDING_REPLY_NOW           optional fixed epoch for deterministic tests
#   CS_PENDING_REPLY_EXISTING_CORR reuse an existing corr on a re-send instead
#                                  of creating a second expectation (cs-send)

_CS_PENDING_REPLY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _CS_PENDING_REPLY_LIB_DIR="."
# shellcheck source=bin/cs-marker-lib.sh
. "$_CS_PENDING_REPLY_LIB_DIR/cs-marker-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$_CS_PENDING_REPLY_LIB_DIR/cs-meta-lib.sh"
# shellcheck source=bin/cs-herdr-lib.sh
. "$_CS_PENDING_REPLY_LIB_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-classify-lib.sh
. "$_CS_PENDING_REPLY_LIB_DIR/cs-classify-lib.sh"
# Self-announced status appends: the escalation close is this home's own
# bookkeeping and must not re-wake the session that wrote it.
# shellcheck source=bin/cs-wake-lib.sh
. "$_CS_PENDING_REPLY_LIB_DIR/cs-wake-lib.sh"

CS_PENDING_REPLY_SCHEMA='cs-pending-reply.v1'
CS_PENDING_REPLY_CORR_RE='corr=[A-Fa-f0-9]{16}'
CS_PENDING_REPLY_GRACE_DEFAULT=120

cs_pending_reply_now() {
  if [ -n "${CS_PENDING_REPLY_NOW:-}" ]; then
    printf '%s' "$CS_PENDING_REPLY_NOW"
    return 0
  fi
  date +%s
}

cs_pending_reply_grace_secs() {
  local g=${CS_PENDING_REPLY_GRACE_SECS:-$CS_PENDING_REPLY_GRACE_DEFAULT}
  case "$g" in
    *[!0-9]*) g=$CS_PENDING_REPLY_GRACE_DEFAULT ;;
    '') g=$CS_PENDING_REPLY_GRACE_DEFAULT ;;
  esac
  printf '%s' "$g"
}

# Directory holding durable pending-reply records for <state-dir>.
cs_pending_reply_dir() {  # <state-dir>
  if [ -n "${CS_PENDING_REPLY_DIR_OVERRIDE:-}" ]; then
    printf '%s' "$CS_PENDING_REPLY_DIR_OVERRIDE"
    return 0
  fi
  printf '%s/pending-replies' "$1"
}

cs_pending_reply_path() {  # <state-dir> <corr_id>
  printf '%s/%s' "$(cs_pending_reply_dir "$1")" "$2"
}

# Privacy-safe correlation id: 16 lowercase hex chars (64 bits of entropy).
cs_pending_reply_new_id() {
  local raw='' hex
  if command -v openssl >/dev/null 2>&1; then
    raw=$(openssl rand -hex 8 2>/dev/null || true)
  fi
  if [ -z "$raw" ]; then
    hex=$(printf '%s' "$$-$(date +%s%N 2>/dev/null || date +%s)-$RANDOM$RANDOM" | shasum -a 256 2>/dev/null | awk '{print $1}')
    raw=${hex:0:16}
  fi
  printf '%s' "$(printf '%s' "$raw" | tr 'A-F' 'a-f' | tr -cd 'a-f0-9' | cut -c1-16)"
}

cs_pending_reply_corr_token() {  # <corr_id>
  printf 'corr=%s' "$1"
}

# Extract the first corr=<16hex> token from free text, or empty.
cs_pending_reply_extract_corr() {  # <text>
  printf '%s' "$1" | grep -oE "$CS_PENDING_REPLY_CORR_RE" 2>/dev/null | head -1 | cut -d= -f2- | tr 'A-F' 'a-f' || true
}

# 0 if <text> carries the exact correlation token for <corr_id>.
cs_pending_reply_text_has_corr() {  # <text> <corr_id>
  local token
  token=$(cs_pending_reply_corr_token "$2")
  case "$1" in
    *"$token"*) return 0 ;;
  esac
  return 1
}

# Sanitize a short request summary: single line, bounded, no control chars.
cs_pending_reply_summarize() {  # <text>
  local cleaned
  cleaned=$(printf '%s' "$1" | tr '\t\r\n' '   ' | tr -cd '\11\12\15\40-\176' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  cleaned=${cleaned#"$CS_FROMCONS_MARK"}
  cleaned=$(printf '%s' "$cleaned" | sed -E "s/^corr=[A-Fa-f0-9]{16}[[:space:]]*//")
  if [ "${#cleaned}" -gt 120 ]; then
    cleaned="${cleaned:0:117}..."
  fi
  printf '%s' "$cleaned"
}

# 0 when <record-path> is a regular file whose bytes contain no NUL. Records are
# read field-by-field with bash's read, which DROPS NUL bytes, and bash
# generations disagree on what is left: 3.2 truncates the value at the NUL while
# 5.x splices the surrounding bytes together. A NUL-bearing parent_home= could
# therefore resolve to a home the record's bytes never name contiguously, and
# which home a recovery send wrote to would depend on the interpreter. Reject the
# whole record as corrupt before any field is parsed rather than letting the
# interpreter pick.
cs_pending_reply_record_intact() {  # <record-path>
  local rec=$1 total stripped
  [ -f "$rec" ] || return 1
  total=$(LC_ALL=C wc -c < "$rec" 2>/dev/null) || return 1
  stripped=$(LC_ALL=C tr -d '\000' < "$rec" 2>/dev/null | LC_ALL=C wc -c) || return 1
  total=${total//[[:space:]]/}
  stripped=${stripped//[[:space:]]/}
  case "$total$stripped" in ''|*[!0-9]*) return 1 ;; esac
  [ "$total" = "$stripped" ]
}

# Read one field. The corrupt-record refusal above is enforced here because this
# is the single funnel every field read passes through: a rejected record yields
# no value for any field, so every caller's existing "field is empty" refusal
# turns a corrupt record into a fail-closed no-op instead of an action taken on
# interpreter-dependent bytes.
cs_pending_reply_get() {  # <record-path> <key>
  local rec=$1 key=$2
  cs_pending_reply_record_intact "$rec" || return 0
  grep "^${key}=" "$rec" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# 0 if an existing corr may guard a re-send to the SAME task (recovery resend).
cs_pending_reply_corr_reusable() {  # <state-dir> <corr_id> <task_id>
  local state=$1 corr=$2 task_id=$3 rec phase
  printf '%s' "$corr" | grep -Eq '^[A-Fa-f0-9]{16}$' || return 1
  rec=$(cs_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  [ "$(cs_pending_reply_get "$rec" task_id)" = "$task_id" ] || return 1
  phase=$(cs_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|recovery_sending|recovery_sent) return 0 ;;
  esac
  return 1
}

# Rewrite one key in a pending-reply record atomically. Other keys preserved.
# Refuses a corrupt record for the same reason reads do: the rewrite loop below
# is exactly the bash read that would silently drop the NUL bytes and normalize
# a corrupt record into a plausible-looking one.
cs_pending_reply_set() {  # <record-path> <key> <value>
  local rec=$1 key=$2 value=$3 dir base tmp line
  [ -f "$rec" ] || return 1
  cs_pending_reply_record_intact "$rec" || return 1
  dir=$(dirname "$rec")
  base=$(basename "$rec")
  tmp="$dir/.${base}.tmp.$$"
  : > "$tmp" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${key}="*) continue ;;
    esac
    printf '%s\n' "$line" >> "$tmp" || return 1
  done < "$rec"
  printf '%s=%s\n' "$key" "$value" >> "$tmp" || return 1
  mv -f "$tmp" "$rec"
}

# Embed or replace a correlation token after the from-consigliere marker.
# Idempotent for the same corr; replaces a different leading corr token.
# Result is assigned to <result-var>. Trailing newlines in the request body
# are preserved (never strip via bare $(...) on the body).
cs_pending_reply_embed_corr() {  # <message> <corr_id> <result-var>
  local message=$1 corr=$2 result_var=$3 body token marked existing
  [ -n "$result_var" ] || return 2
  token=$(cs_pending_reply_corr_token "$corr")
  cs_message_mark_from_consigliere "$message" marked
  body=${marked#"$CS_FROMCONS_MARK"}
  existing=${body:0:21}
  case "$existing" in
    corr=[a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9])
      body=${body:21}
      while [ "${body# }" != "$body" ]; do body=${body# }; done
      while [ "${body#$'\t'}" != "$body" ]; do body=${body#$'\t'}; done
      ;;
  esac
  printf -v "$result_var" '%s' "${CS_FROMCONS_MARK}${token} ${body}"
}

# Create a durable pending-reply expectation. Prints corr_id on success.
# Does not deliver anything. Fails if parent paths cannot be prepared.
cs_pending_reply_create() {  # <parent-home> <state-dir> <task_id> <request-text>
  local parent_home=$1 state=$2 task_id=$3 request_text=$4
  local dir rec corr now summary status_path tmp
  [ -n "$parent_home" ] && [ -n "$state" ] && [ -n "$task_id" ] || return 2
  dir=$(cs_pending_reply_dir "$state")
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  corr=$(cs_pending_reply_new_id)
  [ "${#corr}" -eq 16 ] || return 1
  rec=$(cs_pending_reply_path "$state" "$corr")
  # Extremely unlikely collision; regenerate once.
  if [ -e "$rec" ]; then
    corr=$(cs_pending_reply_new_id)
    rec=$(cs_pending_reply_path "$state" "$corr")
    [ ! -e "$rec" ] || return 1
  fi
  now=$(cs_pending_reply_now)
  summary=$(cs_pending_reply_summarize "$request_text")
  status_path="$state/${task_id}.status"
  case "$status_path" in
    /*) ;;
    *) status_path="$(cd "$state" 2>/dev/null && pwd)/${task_id}.status" ;;
  esac
  case "$parent_home" in
    /*) ;;
    *) parent_home=$(cd "$parent_home" 2>/dev/null && pwd) || parent_home=$1 ;;
  esac
  tmp="$dir/.${corr}.tmp.$$"
  cat > "$tmp" <<EOF
schema=$CS_PENDING_REPLY_SCHEMA
corr_id=$corr
task_id=$task_id
parent_home=$parent_home
parent_status=$status_path
parent_status_scan_signature=
request_summary=$summary
created_epoch=$now
delivered_epoch=
phase=awaiting_report
turn_seen_busy=0
request_turn_completed_epoch=
recovery_attempted_epoch=
recovery_sender_pid=
recovery_sender_identity=
recovery_sent_epoch=
recovery_delivery_outcome=
recovery_turn_seen_busy=0
recovery_turn_completed_epoch=
escalated_epoch=
escalation_closed_epoch=
resolved_epoch=
resolved_via=
wrong_home_hits=0
wrong_home_sightings=
wrong_home_scan_signature=
grace_secs=$(cs_pending_reply_grace_secs)
EOF
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$rec" || return 1
  printf '%s' "$corr"
}

# Mark delivery success for an existing expectation. Never resolves.
cs_pending_reply_mark_delivered() {  # <state-dir> <corr_id> [confirmed-epoch]
  local state=$1 corr=$2 confirmed_epoch=${3-} rec phase delivered now
  rec=$(cs_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(cs_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|delivery_unknown|recovery_sending|recovery_sent|escalated|resolved) ;;
    *) return 1 ;;
  esac
  delivered=$(cs_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    now=${confirmed_epoch:-$(cs_pending_reply_now)}
    cs_pending_reply_set "$rec" delivered_epoch "$now" || return 1
  fi
  if [ "$phase" = delivery_unknown ]; then
    cs_pending_reply_set "$rec" phase awaiting_report || return 1
  fi
  return 0
}

cs_pending_reply_delivery_confirmation_path() {  # <state-dir> <corr_id>
  printf '%s/.delivery-confirmed-%s' "$(cs_pending_reply_dir "$1")" "$2"
}

cs_pending_reply_write_delivery_confirmation() {  # <state-dir> <corr_id> <state> <value>
  local pending_state=$1 corr=$2 delivery_state=$3 value=$4 marker dir tmp
  marker=$(cs_pending_reply_delivery_confirmation_path "$pending_state" "$corr")
  dir=$(dirname "$marker")
  mkdir -p "$dir" || return 1
  tmp="$marker.tmp.$$"
  printf '%s=%s\n' "$delivery_state" "$value" > "$tmp" || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$marker"
}

# Durably record that a delivery attempt is about to happen, so a crash
# between send and confirm leaves reconcilable evidence instead of nothing.
cs_pending_reply_prepare_delivery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec delivered marker now
  rec=$(cs_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  delivered=$(cs_pending_reply_get "$rec" delivered_epoch)
  [ -z "$delivered" ] || return 0
  marker=$(cs_pending_reply_delivery_confirmation_path "$state" "$corr")
  [ -f "$marker" ] && return 0
  now=$(cs_pending_reply_now)
  cs_pending_reply_write_delivery_confirmation "$state" "$corr" attempted "$now"
}

cs_pending_reply_confirm_delivery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 now marker
  marker=$(cs_pending_reply_delivery_confirmation_path "$state" "$corr")
  if ! cs_pending_reply_prepare_delivery "$state" "$corr"; then
    return 1
  fi
  now=$(cs_pending_reply_now)
  cs_pending_reply_write_delivery_confirmation "$state" "$corr" confirmed "$now" || return 1
  if cs_pending_reply_mark_delivered "$state" "$corr" "$now"; then
    rm -f "$marker" 2>/dev/null || true
    return 0
  fi
  return 2
}

cs_pending_reply_reconcile_delivery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec delivered marker entry delivery_state value epoch
  local grace now age phase
  rec=$(cs_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  marker=$(cs_pending_reply_delivery_confirmation_path "$state" "$corr")
  delivered=$(cs_pending_reply_get "$rec" delivered_epoch)
  if [ -n "$delivered" ]; then
    rm -f "$marker" 2>/dev/null || true
    return 0
  fi
  [ -f "$marker" ] || return 1
  entry=$(cat "$marker" 2>/dev/null || true)
  delivery_state=${entry%%=*}
  value=${entry#*=}
  case "$delivery_state" in
    confirmed)
      epoch=$value
      case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
      cs_pending_reply_mark_delivered "$state" "$corr" "$epoch" || return 1
      rm -f "$marker" 2>/dev/null || true
      return 0
      ;;
    attempted)
      epoch=$value
      case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
      grace=$(cs_pending_reply_get "$rec" grace_secs)
      case "$grace" in ''|*[!0-9]*) grace=$(cs_pending_reply_grace_secs) ;; esac
      now=$(cs_pending_reply_now)
      age=$((now - epoch))
      [ "$age" -ge "$grace" ] || return 1
      phase=$(cs_pending_reply_get "$rec" phase)
      [ "$phase" = awaiting_report ] || return 1
      cs_pending_reply_set "$rec" phase delivery_unknown || return 1
      return 0
      ;;
  esac
  return 1
}

# Drop an undelivered expectation after a failed send so transport failure
# does not masquerade as a missed report later.
cs_pending_reply_discard_undelivered() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec delivered marker
  rec=$(cs_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 0
  delivered=$(cs_pending_reply_get "$rec" delivered_epoch)
  [ -z "$delivered" ] || return 1
  marker=$(cs_pending_reply_delivery_confirmation_path "$state" "$corr")
  rm -f "$marker" 2>/dev/null || true
  rm -f "$rec"
}

# 0 if a status line is a correlated acknowledgement for <corr_id>.
# Accepts short status replies and status lines that point at a document.
# Unrelated verbs without the token never match. Stale/wrong corr never match.
# The parent's own pending-reply-missed escalation line must not self-resolve:
# it names the request with pending-reply-id= rather than corr=.
cs_pending_reply_line_resolves() {  # <line> <corr_id>
  local line=$1 corr=$2
  [ -n "$line" ] && [ -n "$corr" ] || return 1
  case "$line" in
    *pending-reply-missed*|*pending-reply-delivery-unknown*|*pending-reply-recovery-delivery-*) return 1 ;;
  esac
  cs_pending_reply_text_has_corr "$line" "$corr"
}

# Scan a status file for a correlated resolve. Prints the matching line or empty.
cs_pending_reply_find_resolve_line() {  # <status-file> <corr_id>
  local status_file=$1 corr=$2 line
  [ -f "$status_file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if cs_pending_reply_line_resolves "$line" "$corr"; then
      printf '%s' "$line"
      return 0
    fi
  done < "$status_file"
  return 0
}

cs_pending_reply_file_signature() {  # <path>
  local path=$1
  [ -f "$path" ] || { printf 'missing'; return 0; }
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C stat -f '%d:%i:%z:%m:%c' "$path" 2>/dev/null || printf 'unreadable'
  else
    LC_ALL=C stat -c '%d:%i:%s:%Y:%Z' "$path" 2>/dev/null || printf 'unreadable'
  fi
}

cs_pending_reply_status_set_signature() {  # <status-dir>
  local status_dir=$1 status_file signature
  {
    for status_file in "$status_dir"/*.status; do
      [ -f "$status_file" ] || continue
      signature=$(cs_pending_reply_file_signature "$status_file")
      printf '%s:%s:%s\n' "${#status_file}" "$status_file" "$signature"
    done
  } | cksum 2>/dev/null | awk '{printf "%s-%s", $1, $2}'
}

# Classify how a resolving line acknowledged the request.
cs_pending_reply_resolve_via_of_line() {  # <line>
  case "$1" in
    *data/*report*|*report.md*|*document*|*pointer*) printf 'document' ;;
    *) printf 'status' ;;
  esac
}

# Idempotently resolve an expectation from a correlated parent report.
# Returns 0 when the record is resolved after the call (already or newly).
cs_pending_reply_try_resolve() {  # <state-dir> <corr_id> [status-file-override]
  local state=$1 corr=$2 status_override=${3-}
  local rec phase delivered marker delivery_entry delivery_state status_file signature previous line via now
  local unconfirmed=0
  rec=$(cs_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(cs_pending_reply_get "$rec" phase)
  if [ "$phase" = resolved ]; then
    cs_pending_reply_close_escalation "$state" "$corr" || true
    return 0
  fi
  delivered=$(cs_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    marker=$(cs_pending_reply_delivery_confirmation_path "$state" "$corr")
    [ -f "$marker" ] || return 1
    delivery_entry=$(cat "$marker" 2>/dev/null || true)
    delivery_state=${delivery_entry%%=*}
    case "$delivery_state" in attempted|confirmed) ;; *) return 1 ;; esac
    unconfirmed=1
  fi
  status_file=${status_override:-$(cs_pending_reply_get "$rec" parent_status)}
  if [ -z "$status_override" ] && [ "$unconfirmed" = 0 ]; then
    signature=$(cs_pending_reply_file_signature "$status_file")
    previous=$(cs_pending_reply_get "$rec" parent_status_scan_signature)
    [ "$signature" != "$previous" ] || return 1
  fi
  line=$(cs_pending_reply_find_resolve_line "$status_file" "$corr")
  if [ -z "$line" ]; then
    if [ -z "$status_override" ] && [ "$unconfirmed" = 0 ]; then
      cs_pending_reply_set "$rec" parent_status_scan_signature "$signature" || return 1
    fi
    return 1
  fi
  via=$(cs_pending_reply_resolve_via_of_line "$line")
  now=$(cs_pending_reply_now)
  cs_pending_reply_set "$rec" phase resolved || return 1
  if [ -z "$delivered" ]; then
    cs_pending_reply_mark_delivered "$state" "$corr" "$now" || return 1
    rm -f "$marker" 2>/dev/null || true
  fi
  cs_pending_reply_set "$rec" resolved_epoch "$now" || return 1
  cs_pending_reply_set "$rec" resolved_via "$via" || return 1
  # The record is resolved either way; a failed close stays retryable from the
  # watcher tick rather than turning a settled request back into a failure.
  cs_pending_reply_close_escalation "$state" "$corr" || true
  return 0
}

# Observe endpoint busy/idle evidence for the active turn without reading chat.
# busy_state must be one of: busy | idle | unknown.
cs_pending_reply_observe_busy() {  # <state-dir> <corr_id> <busy_state>
  local state=$1 corr=$2 busy_state=$3
  local rec phase delivered now seen completed field_seen field_completed
  rec=$(cs_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(cs_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|recovery_sent) ;;
    *) return 0 ;;
  esac
  delivered=$(cs_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ] || return 0
  if [ "$phase" = awaiting_report ]; then
    field_seen=turn_seen_busy
    field_completed=request_turn_completed_epoch
  else
    field_seen=recovery_turn_seen_busy
    field_completed=recovery_turn_completed_epoch
  fi
  seen=$(cs_pending_reply_get "$rec" "$field_seen")
  completed=$(cs_pending_reply_get "$rec" "$field_completed")
  case "$busy_state" in
    busy)
      if [ "$seen" != 1 ]; then
        cs_pending_reply_set "$rec" "$field_seen" 1 || return 1
      fi
      ;;
    idle)
      if [ -z "$completed" ]; then
        # Prefer a busy->idle transition. Also accept a pure idle after
        # delivery when the first observation already missed the busy window
        # (fast turns).
        if [ "$seen" = 1 ] || [ "$seen" = 0 ]; then
          now=$(cs_pending_reply_now)
          cs_pending_reply_set "$rec" "$field_completed" "$now" || return 1
        fi
      fi
      ;;
    unknown)
      # No independent proof; leave completion unset.
      ;;
    *)
      return 2
      ;;
  esac
  return 0
}

# One herdr endpoint read mapped to busy|idle|unknown. blocked and done both
# mean the receiving turn has ENDED without further input, so for reply
# accounting they count as idle (turn complete). Overridable in tests.
cs_pending_reply_endpoint_observation() {  # <pane_id>
  local s
  s=$(cs_herdr_agent_busy_state "$1" 2>/dev/null) || s=unknown
  case "$s" in
    busy) printf 'busy' ;;
    idle|blocked|done) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# Explicit turn-completion proof (for tests and callers that surface a
# completion event without a busy/idle pair).
cs_pending_reply_mark_turn_completed() {  # <state-dir> <corr_id> [which: request|recovery]
  local state=$1 corr=$2 which=${3:-request}
  local rec field now
  rec=$(cs_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  case "$which" in
    request) field=request_turn_completed_epoch ;;
    recovery) field=recovery_turn_completed_epoch ;;
    *) return 2 ;;
  esac
  now=$(cs_pending_reply_now)
  cs_pending_reply_set "$rec" "$field" "$now" || return 1
  return 0
}

# Build the one automatic recovery message for a pending record.
cs_pending_reply_recovery_message() {  # <record-path>
  local rec=$1 corr summary token msg
  corr=$(cs_pending_reply_get "$rec" corr_id)
  summary=$(cs_pending_reply_get "$rec" request_summary)
  token=$(cs_pending_reply_corr_token "$corr")
  msg="REPOST REQUIRED: previous marked request had no correlated parent report. Reply on the parent status channel including ${token}. Original request: ${summary}"
  cs_pending_reply_embed_corr "$msg" "$corr" msg
  printf '%s' "$msg"
}

cs_pending_reply_pid_identity() {  # <pid>
  local pid=$1 identity
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  identity=$(COLUMNS=10000 LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  printf '%s' "$identity"
}

cs_pending_reply_sender_alive() {  # <record-path>
  local rec=$1 pid expected actual
  pid=$(cs_pending_reply_get "$rec" recovery_sender_pid)
  expected=$(cs_pending_reply_get "$rec" recovery_sender_identity)
  [ -n "$expected" ] || return 1
  actual=$(cs_pending_reply_pid_identity "$pid") || return 1
  [ "$actual" = "$expected" ]
}

# Deliver the recovery message once. Caller must hold phase awaiting_report
# with turn completed and grace elapsed. Uses CS_PENDING_REPLY_SEND_HOOK when
# set (tests), otherwise invokes cs-send with CS_PENDING_REPLY_EXISTING_CORR
# so a second expectation is not created.
cs_pending_reply_send_recovery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2
  local rec phase completed delivered attempted grace now age task_id msg parent_home send_status=0
  local sender_pid sender_identity
  rec=$(cs_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(cs_pending_reply_get "$rec" phase)
  [ "$phase" = awaiting_report ] || return 1
  attempted=$(cs_pending_reply_get "$rec" recovery_attempted_epoch)
  if [ -n "$attempted" ]; then
    cs_pending_reply_reconcile_recovery "$state" "$corr" || true
    return 1
  fi
  completed=$(cs_pending_reply_get "$rec" request_turn_completed_epoch)
  [ -n "$completed" ] || return 1
  delivered=$(cs_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ] || return 1
  grace=$(cs_pending_reply_get "$rec" grace_secs)
  case "$grace" in ''|*[!0-9]*) grace=$(cs_pending_reply_grace_secs) ;; esac
  now=$(cs_pending_reply_now)
  age=$((now - delivered))
  [ "$age" -ge "$grace" ] || return 1
  task_id=$(cs_pending_reply_get "$rec" task_id)
  parent_home=$(cs_pending_reply_get "$rec" parent_home)
  msg=$(cs_pending_reply_recovery_message "$rec")
  sender_pid=${BASHPID:-$$}
  sender_identity=$(cs_pending_reply_pid_identity "$sender_pid") || return 1
  cs_pending_reply_set "$rec" recovery_sender_pid "$sender_pid" || return 1
  cs_pending_reply_set "$rec" recovery_sender_identity "$sender_identity" || return 1
  cs_pending_reply_set "$rec" recovery_attempted_epoch "$now" || return 1
  cs_pending_reply_set "$rec" phase recovery_sending || return 1
  if [ -n "${CS_PENDING_REPLY_SEND_HOOK:-}" ]; then
    # Hook receives: task_id message
    # shellcheck disable=SC2086
    if ! eval "$CS_PENDING_REPLY_SEND_HOOK" "$(printf '%q' "$task_id")" "$(printf '%q' "$msg")"; then
      send_status=1
    fi
  else
    if [ -z "$parent_home" ] || [ ! -d "$parent_home" ]; then
      send_status=1
    elif ! env CS_HOME="$parent_home" CS_PENDING_REPLY_EXISTING_CORR="$corr" \
      "$_CS_PENDING_REPLY_LIB_DIR/cs-send.sh" "$task_id" "$msg"; then
      send_status=1
    fi
  fi
  if [ "$send_status" = 0 ]; then
    cs_pending_reply_finish_recovery "$state" "$corr" confirmed
    return $?
  fi
  cs_pending_reply_finish_recovery "$state" "$corr" failed || return 1
  return 1
}

cs_pending_reply_finish_recovery() {  # <state-dir> <corr_id> <confirmed|failed>
  local state=$1 corr=$2 outcome=$3 rec phase now sent
  rec=$(cs_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(cs_pending_reply_get "$rec" phase)
  [ "$phase" = recovery_sending ] || return 1
  cs_pending_reply_set "$rec" recovery_delivery_outcome "$outcome" || return 1
  if [ "$outcome" = confirmed ]; then
    sent=$(cs_pending_reply_get "$rec" recovery_sent_epoch)
    if [ -z "$sent" ]; then
      now=$(cs_pending_reply_now)
      cs_pending_reply_set "$rec" recovery_sent_epoch "$now" || return 1
    fi
    cs_pending_reply_set "$rec" recovery_turn_seen_busy 0 || return 1
    cs_pending_reply_set "$rec" recovery_turn_completed_epoch "" || return 1
    cs_pending_reply_set "$rec" phase recovery_sent || return 1
  else
    [ "$outcome" = failed ] || return 1
    cs_pending_reply_set "$rec" phase recovery_failed || return 1
  fi
}

cs_pending_reply_reconcile_recovery() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec phase attempted outcome
  rec=$(cs_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(cs_pending_reply_get "$rec" phase)
  case "$phase" in awaiting_report|recovery_sending) ;; *) return 1 ;; esac
  attempted=$(cs_pending_reply_get "$rec" recovery_attempted_epoch)
  [ -n "$attempted" ] || return 1
  case "$attempted" in *[!0-9]*) return 1 ;; esac
  outcome=$(cs_pending_reply_get "$rec" recovery_delivery_outcome)
  case "$outcome" in
    confirmed) cs_pending_reply_finish_recovery "$state" "$corr" confirmed; return $? ;;
    failed) cs_pending_reply_finish_recovery "$state" "$corr" failed; return $? ;;
    unknown)
      cs_pending_reply_set "$rec" phase recovery_unknown || return 1
      return 0
      ;;
  esac
  cs_pending_reply_sender_alive "$rec" && return 1
  cs_pending_reply_set "$rec" recovery_delivery_outcome unknown || return 1
  cs_pending_reply_set "$rec" phase recovery_unknown || return 1
}

# The decision key an escalation for <corr_id> opens in the parent status log.
# Per-request rather than the bare default key, so one request's escalation
# neither masks nor is masked by an unrelated decision on the same task.
cs_pending_reply_escalation_key() {  # <corr_id>
  printf 'pending-reply-%s' "$1"
}

# The exact escalation note for one record and escalation kind. Built in one
# place so the open and the close agree by construction instead of by two
# hand-kept format strings. Uses pending-reply-id= (not corr=) so this
# parent-written line cannot be mistaken for a capo acknowledgement by
# cs_pending_reply_line_resolves.
cs_pending_reply_escalation_payload() {  # <record-path> <kind>
  local rec=$1 kind=$2 task_id corr summary outcome token
  task_id=$(cs_pending_reply_get "$rec" task_id)
  corr=$(cs_pending_reply_get "$rec" corr_id)
  summary=$(cs_pending_reply_get "$rec" request_summary)
  [ -n "$task_id" ] && [ -n "$corr" ] || return 1
  case "$kind" in
    missed) token=pending-reply-missed ;;
    delivery-unknown) token=pending-reply-delivery-unknown ;;
    recovery-delivery)
      outcome=$(cs_pending_reply_get "$rec" recovery_delivery_outcome)
      case "$outcome" in failed|unknown) ;; *) return 1 ;; esac
      token="pending-reply-recovery-delivery-$outcome"
      ;;
    *) return 1 ;;
  esac
  printf '%s: task=%s pending-reply-id=%s request=%s' "$token" "$task_id" "$corr" "$summary"
}

# The escalation line this library published for <corr_id>, or empty when none of
# its own escalation notes appear in the status file. Only the keyed form is
# matched. A legacy unkeyed "blocked: <payload>" line written before escalations
# carried a key holds the SHARED default key, and closing that key would clear
# whatever unrelated decision happens to hold it now - a worse outcome than
# leaving one old line for the boss to close by hand.
cs_pending_reply_escalation_line() {  # <status-file> <record-path> <corr_id>
  local status_file=$1 rec=$2 corr=$3 line found='' kind payload own_key
  [ -f "$status_file" ] || return 0
  [ "$(cs_pending_reply_get "$rec" corr_id)" = "$corr" ] || return 0
  own_key=$(cs_pending_reply_escalation_key "$corr")
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$(status_line_verb "$line")" = blocked ] || continue
    for kind in missed delivery-unknown recovery-delivery; do
      payload=$(cs_pending_reply_escalation_payload "$rec" "$kind") || continue
      case "$line" in
        "blocked [key=$own_key]: $payload") found=$line; break ;;
      esac
    done
  done < "$status_file"
  printf '%s' "$found"
}

# Close the durable status decision a previous escalation opened for <corr_id>.
# Idempotent, and safe to retry until it succeeds: it appends the closing line
# only while that exact keyed decision is still open per bin/cs-classify-lib.sh's
# fold AND still carries this library's own escalation note, so it can neither
# double-close nor clear an unrelated decision that has since taken the key. A
# record that never escalated is left untouched.
cs_pending_reply_close_escalation() {  # <state-dir> <corr_id>
  local state=$1 corr=$2 rec escalated closed parent_status escalation key note
  local open_line open_key open_note now
  rec=$(cs_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  [ "$(cs_pending_reply_get "$rec" phase)" = resolved ] || return 0
  escalated=$(cs_pending_reply_get "$rec" escalated_epoch)
  [ -n "$escalated" ] || return 0
  closed=$(cs_pending_reply_get "$rec" escalation_closed_epoch)
  [ -z "$closed" ] || return 0
  parent_status=$(cs_pending_reply_get "$rec" parent_status)
  [ -n "$parent_status" ] || return 1
  escalation=$(cs_pending_reply_escalation_line "$parent_status" "$rec" "$corr")
  if [ -n "$escalation" ]; then
    key=$(_cs_decision_key "$escalation") || key=''
    note=$(status_line_note "$escalation")
    while IFS= read -r open_line; do
      [ -n "$open_line" ] || continue
      open_key=${open_line%%$'\t'*}
      [ "$open_key" = "$key" ] || continue
      open_note=${open_line#*$'\t'}
      open_note=${open_note#*$'\t'}
      [ "$open_note" = "$note" ] || continue
      cs_wake_status_append_self_announced "$(dirname "$parent_status")" "$parent_status" \
        "$(printf 'resolved [key=%s]: pending-reply-resolved: task=%s pending-reply-id=%s via=%s' \
          "$key" "$(cs_pending_reply_get "$rec" task_id)" "$corr" \
          "$(cs_pending_reply_get "$rec" resolved_via)")" 2>/dev/null || return 1
      break
    done <<EOF
$(status_open_decisions "$parent_status")
EOF
  fi
  now=$(cs_pending_reply_now)
  cs_pending_reply_set "$rec" escalation_closed_epoch "$now"
}

# Escalate once after a missed recovery report or failed delivery outcome.
# Retains the durable unresolved record. Never loops. Opens a keyed decision
# under this library's per-request key; cs_pending_reply_close_escalation is the
# only thing that closes it.
cs_pending_reply_maybe_escalate() {  # <state-dir> <corr_id>
  local state=$1 corr=$2
  local rec phase completed now payload parent_status line kind
  rec=$(cs_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  phase=$(cs_pending_reply_get "$rec" phase)
  if [ "$phase" = delivery_unknown ]; then
    cs_pending_reply_reconcile_delivery "$state" "$corr" || true
    phase=$(cs_pending_reply_get "$rec" phase)
    [ "$phase" = delivery_unknown ] || return 0
  fi
  case "$phase" in
    recovery_sent)
      completed=$(cs_pending_reply_get "$rec" recovery_turn_completed_epoch)
      [ -n "$completed" ] || return 1
      ;;
    delivery_unknown|recovery_failed|recovery_unknown) ;;
    *) return 1 ;;
  esac
  # Resolve wins if a late report arrived between completion and this call.
  if cs_pending_reply_try_resolve "$state" "$corr"; then
    return 0
  fi
  parent_status=$(cs_pending_reply_get "$rec" parent_status)
  case "$phase" in
    delivery_unknown) kind=delivery-unknown ;;
    recovery_failed|recovery_unknown) kind=recovery-delivery ;;
    *) kind=missed ;;
  esac
  payload=$(cs_pending_reply_escalation_payload "$rec" "$kind") || return 1
  [ -n "$parent_status" ] || return 1
  mkdir -p "$(dirname "$parent_status")" 2>/dev/null || return 1
  line="blocked [key=$(cs_pending_reply_escalation_key "$corr")]: $payload"
  if ! grep -Fqx "$line" "$parent_status" 2>/dev/null; then
    printf '%s\n' "$line" >> "$parent_status" 2>/dev/null || return 1
  fi
  now=$(cs_pending_reply_now)
  cs_pending_reply_set "$rec" escalated_epoch "$now" || return 1
  cs_pending_reply_set "$rec" phase escalated || return 1
  return 0
}

# Detect a correlated report written under the capo home (wrong home) without
# treating it as acknowledgement.
cs_pending_reply_detect_wrong_home() {  # <state-dir> <corr_id> <capo-home>
  local state=$1 corr=$2 capo_home=$3
  local rec delivered hits sightings snapshot previous status_file line line_no sighting_id phase changed=0
  rec=$(cs_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  [ -n "$capo_home" ] && [ -d "$capo_home" ] || return 0
  phase=$(cs_pending_reply_get "$rec" phase)
  [ "$phase" != resolved ] || return 0
  delivered=$(cs_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ] || return 0
  snapshot=$(cs_pending_reply_status_set_signature "$capo_home/state")
  previous=$(cs_pending_reply_get "$rec" wrong_home_scan_signature)
  [ "$snapshot" != "$previous" ] || return 0
  hits=$(cs_pending_reply_get "$rec" wrong_home_hits)
  case "$hits" in ''|*[!0-9]*) hits=0 ;; esac
  sightings=$(cs_pending_reply_get "$rec" wrong_home_sightings)
  for status_file in "$capo_home"/state/*.status; do
    [ -e "$status_file" ] || continue
    line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      cs_pending_reply_line_resolves "$line" "$corr" || continue
      sighting_id=$(printf '%s:%s:%s:%s' "${#status_file}" "$status_file" "$line_no" "$line" \
        | cksum 2>/dev/null | awk '{printf "%s-%s", $1, $2}')
      [ -n "$sighting_id" ] || continue
      case ",$sightings," in
        *",$sighting_id,"*) continue ;;
      esac
      if [ -n "$sightings" ]; then
        sightings="$sightings,$sighting_id"
      else
        sightings=$sighting_id
      fi
      hits=$((hits + 1))
      changed=1
    done < "$status_file"
  done
  if [ "$changed" = 1 ]; then
    cs_pending_reply_set "$rec" wrong_home_sightings "$sightings" || return 1
    cs_pending_reply_set "$rec" wrong_home_hits "$hits" || return 1
  fi
  cs_pending_reply_set "$rec" wrong_home_scan_signature "$snapshot" || return 1
  return 0
}

# One reconciliation tick for a single record: resolve, observe, recover,
# escalate. busy_state is busy|idle|unknown for the capo endpoint.
# capo_home may be empty when unknown.
cs_pending_reply_tick_one() {  # <state-dir> <corr_id> <busy_state> [capo-home]
  local state=$1 corr=$2 busy_state=$3 capo_home=${4-}
  local rec phase delivered
  rec=$(cs_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || return 1
  cs_pending_reply_reconcile_delivery "$state" "$corr" || true
  phase=$(cs_pending_reply_get "$rec" phase)
  delivered=$(cs_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    case "$phase" in
      delivery_unknown) cs_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null || true ;;
      escalated) cs_pending_reply_try_resolve "$state" "$corr" >/dev/null 2>&1 || true ;;
    esac
    return 0
  fi
  # Correlated parent report always wins and is idempotent.
  if cs_pending_reply_try_resolve "$state" "$corr"; then
    return 0
  fi
  phase=$(cs_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report|recovery_sending)
      if [ -n "$(cs_pending_reply_get "$rec" recovery_attempted_epoch)" ]; then
        cs_pending_reply_reconcile_recovery "$state" "$corr" || true
        phase=$(cs_pending_reply_get "$rec" phase)
      fi
      ;;
  esac
  case "$phase" in
    resolved) return 0 ;;
    escalated)
      # Unresolved durable record retained; never auto-delete.
      if [ -n "$capo_home" ]; then
        cs_pending_reply_detect_wrong_home "$state" "$corr" "$capo_home" || true
      fi
      return 0
      ;;
    recovery_sending) return 0 ;;
    recovery_failed|recovery_unknown)
      cs_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null || true
      return 0
      ;;
  esac
  if [ -n "$capo_home" ]; then
    cs_pending_reply_detect_wrong_home "$state" "$corr" "$capo_home" || true
  fi
  cs_pending_reply_observe_busy "$state" "$corr" "$busy_state" || true
  # Re-check resolve after observation in case a concurrent status write landed.
  if cs_pending_reply_try_resolve "$state" "$corr"; then
    return 0
  fi
  phase=$(cs_pending_reply_get "$rec" phase)
  if [ "$phase" = awaiting_report ]; then
    cs_pending_reply_send_recovery "$state" "$corr" 2>/dev/null || true
  fi
  phase=$(cs_pending_reply_get "$rec" phase)
  case "$phase" in
    recovery_sent|recovery_failed|recovery_unknown)
      cs_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null || true
      ;;
  esac
  return 0
}

# Scan every pending record for this parent state. Safe to call every poll -
# the watcher (bin/cs-watch.sh) calls this once per cycle. Never scrapes capo
# conversation; uses only the parent status files, the herdr native
# busy-state, and optional capo-home wrong-home path checks.
cs_pending_reply_tick() {  # <state-dir>
  local state=$1 dir rec corr task_id phase delivered meta pane busy capo_home
  local observation observation_task found i
  local -a observation_tasks=() observation_values=()
  dir=$(cs_pending_reply_dir "$state")
  [ -d "$dir" ] || return 0
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    case "$(basename "$rec")" in
      .*) continue ;;
    esac
    corr=$(cs_pending_reply_get "$rec" corr_id)
    [ -n "$corr" ] || corr=$(basename "$rec")
    task_id=$(cs_pending_reply_get "$rec" task_id)
    phase=$(cs_pending_reply_get "$rec" phase)
    if [ "$phase" = resolved ]; then
      # A cheap no-op unless an escalation for this record is still open; this is
      # the retry that makes the close converge after a transient write failure.
      cs_pending_reply_close_escalation "$state" "$corr" || true
      continue
    fi
    cs_pending_reply_reconcile_delivery "$state" "$corr" || true
    phase=$(cs_pending_reply_get "$rec" phase)
    delivered=$(cs_pending_reply_get "$rec" delivered_epoch)
    if [ -z "$delivered" ]; then
      case "$phase" in
        delivery_unknown|escalated)
          cs_pending_reply_tick_one "$state" "$corr" unknown "" || true
          ;;
      esac
      continue
    fi
    case "$phase" in
      awaiting_report|recovery_sending)
        if [ -n "$(cs_pending_reply_get "$rec" recovery_attempted_epoch)" ]; then
          cs_pending_reply_reconcile_recovery "$state" "$corr" || true
          phase=$(cs_pending_reply_get "$rec" phase)
        fi
        ;;
    esac
    meta="$state/${task_id}.meta"
    if [ "$phase" = escalated ]; then
      if cs_pending_reply_try_resolve "$state" "$corr"; then
        continue
      fi
      if [ -f "$meta" ]; then
        capo_home=$(cs_meta_get "$meta" home 2>/dev/null || true)
        if [ -n "$capo_home" ]; then
          cs_pending_reply_detect_wrong_home "$state" "$corr" "$capo_home" || true
        fi
      fi
      continue
    fi
    case "$phase" in
      recovery_failed|recovery_unknown)
        cs_pending_reply_tick_one "$state" "$corr" unknown "" || true
        continue
        ;;
    esac
    case "$phase" in
      awaiting_report|recovery_sent) ;;
      *) continue ;;
    esac
    pane=
    busy=unknown
    capo_home=
    if [ -f "$meta" ]; then
      pane=$(cs_meta_get "$meta" pane 2>/dev/null || true)
      capo_home=$(cs_meta_get "$meta" home 2>/dev/null || true)
      if [ -n "$pane" ]; then
        observation=
        found=0
        for ((i = 0; i < ${#observation_tasks[@]}; i++)); do
          observation_task=${observation_tasks[$i]}
          [ "$observation_task" = "$task_id" ] || continue
          observation=${observation_values[$i]}
          found=1
          break
        done
        if [ "$found" = 0 ]; then
          observation=$(cs_pending_reply_endpoint_observation "$pane")
          observation_tasks+=("$task_id")
          observation_values+=("$observation")
        fi
        busy=$observation
      fi
    fi
    cs_pending_reply_tick_one "$state" "$corr" "$busy" "$capo_home" || true
  done
  return 0
}

# True when any open (non-resolved) pending reply exists for a task.
cs_pending_reply_task_has_open() {  # <state-dir> <task_id>
  local state=$1 task_id=$2 dir rec phase tid
  dir=$(cs_pending_reply_dir "$state")
  [ -d "$dir" ] || return 1
  for rec in "$dir"/*; do
    [ -f "$rec" ] || continue
    tid=$(cs_pending_reply_get "$rec" task_id)
    [ "$tid" = "$task_id" ] || continue
    phase=$(cs_pending_reply_get "$rec" phase)
    [ "$phase" != resolved ] || continue
    return 0
  done
  return 1
}
