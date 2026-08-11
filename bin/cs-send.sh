#!/usr/bin/env bash
# Send one line of literal text to a direct report's pane, then Enter.
# Usage: cs-send.sh <target> [--resolve-key <key>]... <text...>
#        cs-send.sh <target> --key <Enter|Escape|C-c>
#   <target> is an exact task id resolved through this home's state/<id>.meta,
#   or an explicit herdr pane id (w<N>:p<N>). cs-send refuses unresolved
#   guesses rather than falling back to a label search, because a "successful"
#   send to the wrong endpoint is worse than a loud failure.
#
# CS_HOME must be explicit (exported by the caller or set by the harness);
# cs-send fails closed without it so a steer cannot silently resolve against
# another home's state.
#
# Text submission is verified against native agent state: an idle target must
# reach `working` after the send (Enter is retried alone, never retyped, up to
# CS_SEND_RETRIES times); a target that was already `working` accepts the text
# as queued input (codex queues mid-turn input) and the send reports queued.
# A send that cannot be confirmed exits non-zero so the caller knows the steer
# may not have landed.
#
# A codex `$skill` invocation gets a longer pre-Enter settle
# (CS_SEND_SKILL_SETTLE, default 1.5s) so the completion popup does not
# swallow the Enter; it is sent as send-text + Enter instead of the atomic run.
#
# Operational input: textual sends are typed by bin/cs-operational-input.sh.
# kind=capo keeps the byte-compatible from-consigliere marker so the capo
# routes its reply via its status file. Ship/scout and explicit-pane sends use
# the watcher kind. The --key path carries no text and is never marked.
#
# Pending reply: a marked kind=capo send also creates a durable parent-owned
# pending-reply record under state/pending-replies/ BEFORE delivery and
# appends its privacy-safe corr=<id> token after the marker label
# (bin/cs-pending-reply-lib.sh). Delivery success never resolves the record;
# only a correlated parent status line does. Set
# CS_PENDING_REPLY_EXISTING_CORR to re-send under an existing open record
# instead of creating a second expectation. A send that cannot be confirmed
# leaves the durable delivery-attempt marker for the watcher to reconcile.
#
# Decision closure (answerer-closes): pass --resolve-key <key> (repeatable, and
# before the message) when this send answers an open keyed needs-decision:,
# needs-review:, or blocked: record in the target task's state/<id>.status. Once
# delivery is confirmed, cs-send itself appends the closing
# "resolved [key=<key>]: answered via cs-send: <capped answer>" line to that
# status file, so the boss-facing OPEN DECISIONS record closes at answer time
# instead of depending on the soldier writing a matching resolved line. When the
# answer kicks off work, the soldier's next event is working [key=<workstream>]
# in a different key namespace, so no matching resolved line ever lands and
# without this the answered decision stayed listed forever. Each named key must
# be open in that ledger RIGHT NOW per the ONE authoritative fold
# (status_open_decisions in bin/cs-classify-lib.sh, consulted here and never
# re-implemented) or cs-send refuses before sending, so a mistyped key cannot
# deliver an answer while silently orphaning its decision. A failed or
# unconfirmed send closes nothing; a delivered answer whose closing append fails
# exits nonzero with the exact manual close command, leaving the decision open
# to resurface, which is the safe direction. A send without the flag closes
# nothing at all: a routine steer, a working: line, or a done: line still never
# clears a boss decision. The flag is refused with --key, with an explicit pane
# target (no task ledger in this home), and with an empty message.
#
# After a successful submit cs-send pauses CS_SEND_SETTLE seconds (default 1,
# 0 disables) before returning, so an immediate peek catches the receiving
# turn starting rather than the stale idle pane.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${CS_HOME+x}" ] || [ -z "${CS_HOME:-}" ]; then
  echo "error: CS_HOME is not set; cs-send refuses to resolve targets without an explicit consigliere home" >&2
  exit 1
fi
STATE="${CS_STATE_OVERRIDE:-$CS_HOME/state}"
[ -d "$CS_HOME" ] || { echo "error: CS_HOME '$CS_HOME' is not a directory" >&2; exit 1; }
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing for CS_HOME '$CS_HOME'" >&2; exit 1; }

# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"
# shellcheck source=bin/cs-operational-input.sh
. "$SCRIPT_DIR/cs-operational-input.sh"
# shellcheck source=bin/cs-marker-lib.sh
. "$SCRIPT_DIR/cs-marker-lib.sh"
# shellcheck source=bin/cs-pending-reply-lib.sh
. "$SCRIPT_DIR/cs-pending-reply-lib.sh"
# shellcheck source=bin/cs-harness-lib.sh
. "$SCRIPT_DIR/cs-harness-lib.sh"
# The authoritative open/resolved status fold, consulted (never re-implemented)
# by the --resolve-key path below, plus the shared per-line cap that bounds the
# closing line it appends.
# shellcheck source=bin/cs-classify-lib.sh
. "$SCRIPT_DIR/cs-classify-lib.sh"
# shellcheck source=bin/cs-line-cap-lib.sh
. "$SCRIPT_DIR/cs-line-cap-lib.sh"
# Optional turn telemetry (off unless host/telemetry.conf enables it). It reads
# the CS_HOME this script already resolved above and never touches the layout
# gate, so a steer keeps behaving exactly as it does with telemetry disabled.
# shellcheck source=bin/cs-telemetry-lib.sh
. "$SCRIPT_DIR/cs-telemetry-lib.sh"

RAW=${1:?usage: cs-send.sh <target> <text...>}
shift
[ "$#" -ge 1 ] || { echo "error: nothing to send" >&2; exit 2; }

# Collect --resolve-key flags (answerer-closes; see the header contract). They
# precede --key or the message text, so everything left after the last flag is
# the message exactly as before and an ordinary send stays byte-identical.
RESOLVE_KEYS=
cs_send_add_resolve_key() {  # <key>
  local k=$1
  case "$k" in
    ''|*[!A-Za-z0-9._-]*)
      echo "error: --resolve-key '$k' is not a valid decision key (allowed: A-Z a-z 0-9 . _ -)" >&2
      return 1
      ;;
  esac
  case " $RESOLVE_KEYS " in
    *" $k "*)
      echo "error: duplicate --resolve-key '$k'" >&2
      return 1
      ;;
  esac
  RESOLVE_KEYS="${RESOLVE_KEYS}${RESOLVE_KEYS:+ }$k"
}
while :; do
  case "${1:-}" in
    --resolve-key)
      [ "$#" -ge 2 ] || { echo "error: --resolve-key requires a key" >&2; exit 2; }
      cs_send_add_resolve_key "$2" || exit 2
      shift 2
      ;;
    --resolve-key=*)
      cs_send_add_resolve_key "${1#--resolve-key=}" || exit 2
      shift
      ;;
    *) break ;;
  esac
done

PANE=""
KIND=""
# Target harness drives the skill-invocation syntax and settle. Default codex
# (matches legacy soldiers with no harness= line and explicit-pane sends whose
# harness is unknown); a task meta with harness=claude switches to /skill.
HARNESS=codex
case "$RAW" in
  w*[0-9]:p*[0-9])
    PANE=$RAW
    ;;
  *)
    META="$STATE/$RAW.meta"
    [ -f "$META" ] || { echo "error: no task '$RAW' in this home (missing $META) and not an explicit pane id" >&2; exit 1; }
    PANE=$(cs_meta_get "$META" pane) || { echo "error: no pane recorded in $META" >&2; exit 1; }
    KIND=$(cs_meta_get "$META" kind 2>/dev/null || true)
    META_HARNESS=$(cs_meta_get "$META" harness 2>/dev/null || true)
    if [ -n "$META_HARNESS" ] && cs_harness_valid "$META_HARNESS"; then
      HARNESS=$META_HARNESS
    fi
    ;;
esac

cs_herdr_pane_exists "$PANE" || { echo "error: pane '$PANE' does not exist" >&2; exit 1; }

# Validate the answerer-closes request BEFORE any durable mutation or delivery:
# the target must own a task status ledger in THIS home, the send must carry an
# answer message, and every named key must be open right now per the ONE
# authoritative fold. Refusing here is what keeps a mistyped key loud instead of
# delivering an answer that silently leaves its decision open.
RESOLVE_STATUS_FILE=
if [ -n "$RESOLVE_KEYS" ]; then
  if [ -z "${META:-}" ]; then
    echo "error: --resolve-key needs a task id resolved through this home's records; an explicit pane target has no decision ledger here" >&2
    exit 2
  fi
  if [ "${1:-}" = "--key" ]; then
    echo "error: --resolve-key cannot accompany --key; answering a decision requires a text answer" >&2
    exit 2
  fi
  if [ -z "$*" ]; then
    echo "error: --resolve-key requires a nonempty answer message" >&2
    exit 2
  fi
  RESOLVE_STATUS_FILE="$STATE/$RAW.status"
  RESOLVE_OPEN_SET=$(status_open_decisions "$RESOLVE_STATUS_FILE")
  for resolve_key in $RESOLVE_KEYS; do
    case "$RESOLVE_OPEN_SET" in
      "$resolve_key"$'\t'*|*$'\n'"$resolve_key"$'\t'*) ;;
      *)
        echo "error: --resolve-key '$resolve_key': no open decision or blocker with that key in $RESOLVE_STATUS_FILE (already closed, mistyped, or transferred). Re-check the open-decisions listing, then resend without that key or with the right one; nothing was sent." >&2
        exit 1
        ;;
    esac
  done
fi

# Close each answered decision in this home's ledger, only after delivery is
# confirmed. An append failure exits nonzero with the manual close command, so
# the decision stays open and resurfaces instead of vanishing silently.
cs_send_close_resolved_keys() {  # <answer-text>
  local note=$1 k line
  note=$(printf '%s' "$note" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
  for k in $RESOLVE_KEYS; do
    line="resolved [key=$k]: answered via cs-send: $note"
    cs_cap_line_var "$line"
    if ! printf '%s\n' "$CS_LINE_CAP_LINE" >> "$RESOLVE_STATUS_FILE"; then
      echo "error: the answer was delivered to '$RAW' ($PANE), but decision key '$k' could not be closed in $RESOLVE_STATUS_FILE. Close it manually with: echo 'resolved [key=$k]: <how it was answered>' >> $RESOLVE_STATUS_FILE - do not resend the answer." >&2
      return 1
    fi
  done
}

if [ "${1:-}" = "--key" ]; then
  # A --resolve-key AFTER --key never reached the flag loop above, so refuse it
  # loudly here: silently ignoring a close request is exactly the orphaned
  # decision this flag exists to prevent.
  case " $* " in
    *" --resolve-key "*|*" --resolve-key="*)
      echo "error: --resolve-key cannot accompany --key and must precede the message; answering a decision requires a text answer" >&2
      exit 2
      ;;
  esac
  KEY=${2:?--key requires a key name}
  case "$KEY" in
    Enter|Escape|C-c) ;;
    *) echo "error: unsupported key '$KEY' (Enter|Escape|C-c)" >&2; exit 2 ;;
  esac
  cs_herdr_send_keys "$PANE" "$KEY" >/dev/null
  exit 0
fi

RAW_TEXT="$*"
TEXT=$RAW_TEXT
PENDING_CORR=
PENDING_CREATED=0
if [ "$KIND" = capo ]; then
  # Create (or reuse) the durable parent pending-reply expectation BEFORE
  # delivery, then embed marker + corr token; transport success never
  # resolves it (bin/cs-pending-reply-lib.sh).
  existing_corr=${CS_PENDING_REPLY_EXISTING_CORR:-$(cs_pending_reply_extract_corr "$TEXT")}
  if [ -n "$existing_corr" ] && cs_pending_reply_corr_reusable "$STATE" "$existing_corr" "$RAW"; then
    PENDING_CORR=$existing_corr
  else
    PENDING_CORR=$(cs_pending_reply_create "$CS_HOME" "$STATE" "$RAW" "$TEXT") \
      || { echo "error: failed to create parent pending-reply expectation for '$RAW'" >&2; exit 1; }
    PENDING_CREATED=1
  fi
  cs_pending_reply_embed_corr "$TEXT" "$PENDING_CORR" TEXT
  if [ "$PENDING_CREATED" = 1 ] \
    && ! cs_pending_reply_prepare_delivery "$STATE" "$PENDING_CORR"; then
    cs_pending_reply_discard_undelivered "$STATE" "$PENDING_CORR" || true
    echo "error: failed to durably prepare pending-reply delivery for '$RAW'" >&2
    exit 1
  fi
else
  cs_operational_input_construct watcher "$TEXT" TEXT
fi

# Delivery confirmed: mark the pending expectation delivered without
# resolving it - only a correlated parent report acknowledges the request.
pending_confirm_delivery() {
  [ -n "$PENDING_CORR" ] || return 0
  if cs_pending_reply_confirm_delivery "$STATE" "$PENDING_CORR"; then
    return 0
  fi
  echo "error: text was delivered to '$RAW' but its pending-reply delivery commit failed; a durable recovery marker was stored and the watcher will reconcile it. Do not resend." >&2
  exit 1
}

RETRIES=${CS_SEND_RETRIES:-3}
SETTLE=${CS_SEND_SETTLE:-1}
SKILL_SETTLE=${CS_SEND_SKILL_SETTLE:-1.5}

pre_status=$(cs_herdr_agent_busy_state "$PANE")

SKILL_PREFIX=$(cs_harness_skill_prefix "$HARNESS")
SKILL_NEEDS_SETTLE=$(cs_harness_skill_needs_settle "$HARNESS")
case "$RAW_TEXT" in
  "$SKILL_PREFIX"*)
    # Skill invocation ($skill on codex, /skill on claude): send the literal
    # text, then Enter separately. codex needs a pre-Enter settle so its
    # completion popup does not swallow the Enter; claude does not.
    cs_herdr_send_text "$PANE" "$TEXT" >/dev/null
    [ "$SKILL_NEEDS_SETTLE" = 1 ] && sleep "$SKILL_SETTLE"
    cs_herdr_send_keys "$PANE" Enter >/dev/null
    ;;
  *)
    cs_herdr_run "$PANE" "$TEXT" >/dev/null
    ;;
esac

if [ "$pre_status" = busy ]; then
  # Mid-turn steer: the harness queues the input for after the turn; native state
  # cannot distinguish queued from swallowed, so report queued and succeed. That
  # is a confirmed delivery for the decision close too - the same verdict that
  # commits the pending-reply expectation - because the harness holds the answer
  # and will process it when the turn ends.
  pending_confirm_delivery
  if [ -n "$RESOLVE_KEYS" ]; then
    cs_send_close_resolved_keys "$RAW_TEXT" || exit 1
  fi
  # TELEMETRY, measurement only: a delivered steer is what turns a supervision
  # turn's outcome from "reviewed, nothing to do" into "messaged the worker".
  cs_telemetry_crumb steer "$KIND" || true
  echo "queued (target was mid-turn)"
  [ "$SETTLE" = 0 ] || sleep "$SETTLE"
  exit 0
fi

attempt=0
while [ "$attempt" -le "$RETRIES" ]; do
  if cs_herdr_submit_confirm "$PANE" 4000; then
    pending_confirm_delivery
    if [ -n "$RESOLVE_KEYS" ]; then
      cs_send_close_resolved_keys "$RAW_TEXT" || exit 1
    fi
    cs_telemetry_crumb steer "$KIND" || true
    echo "submitted"
    [ "$SETTLE" = 0 ] || sleep "$SETTLE"
    exit 0
  fi
  attempt=$((attempt + 1))
  [ "$attempt" -le "$RETRIES" ] || break
  # Enter only, never retype: a swallowed Enter leaves the text in the composer.
  cs_herdr_send_keys "$PANE" Enter >/dev/null
done

echo "error: send to '$RAW' ($PANE) not confirmed after $RETRIES Enter retries; the text may sit unsubmitted in the composer" >&2
exit 1
