#!/usr/bin/env bash
# Send one line of literal text to a direct report's pane, then Enter.
# Usage: cs-send.sh <target> <text...>
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

RAW=${1:?usage: cs-send.sh <target> <text...>}
shift
[ "$#" -ge 1 ] || { echo "error: nothing to send" >&2; exit 2; }

PANE=""
KIND=""
case "$RAW" in
  w*[0-9]:p*[0-9])
    PANE=$RAW
    ;;
  *)
    META="$STATE/$RAW.meta"
    [ -f "$META" ] || { echo "error: no task '$RAW' in this home (missing $META) and not an explicit pane id" >&2; exit 1; }
    PANE=$(cs_meta_get "$META" pane) || { echo "error: no pane recorded in $META" >&2; exit 1; }
    KIND=$(cs_meta_get "$META" kind 2>/dev/null || true)
    ;;
esac

cs_herdr_pane_exists "$PANE" || { echo "error: pane '$PANE' does not exist" >&2; exit 1; }

if [ "${1:-}" = "--key" ]; then
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

case "$RAW_TEXT" in
  '$'*)
    # Skill invocation: literal text, settle for the popup, then Enter.
    cs_herdr_send_text "$PANE" "$TEXT" >/dev/null
    sleep "$SKILL_SETTLE"
    cs_herdr_send_keys "$PANE" Enter >/dev/null
    ;;
  *)
    cs_herdr_run "$PANE" "$TEXT" >/dev/null
    ;;
esac

if [ "$pre_status" = busy ]; then
  # Mid-turn steer: codex queues the input for after the turn; native state
  # cannot distinguish queued from swallowed, so report queued and succeed.
  pending_confirm_delivery
  echo "queued (target was mid-turn)"
  [ "$SETTLE" = 0 ] || sleep "$SETTLE"
  exit 0
fi

attempt=0
while [ "$attempt" -le "$RETRIES" ]; do
  if cs_herdr_submit_confirm "$PANE" 4000; then
    pending_confirm_delivery
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
