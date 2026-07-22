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
# From-consigliere marker: when the resolved target's meta records kind=capo,
# the text is prefixed with the from-consigliere marker (bin/cs-marker-lib.sh)
# so the capo routes its reply via its status file instead of stranding it in
# chat the main consigliere never reads. Ship/scout targets, explicit pane
# targets, and the --key path are never marked.
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
# shellcheck source=bin/cs-marker-lib.sh
. "$SCRIPT_DIR/cs-marker-lib.sh"

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

TEXT="$*"
if [ "$KIND" = capo ]; then
  cs_message_mark_from_consigliere "$TEXT" TEXT
fi

RETRIES=${CS_SEND_RETRIES:-3}
SETTLE=${CS_SEND_SETTLE:-1}
SKILL_SETTLE=${CS_SEND_SKILL_SETTLE:-1.5}

pre_status=$(cs_herdr_agent_busy_state "$PANE")

case "$TEXT" in
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
  echo "queued (target was mid-turn)"
  [ "$SETTLE" = 0 ] || sleep "$SETTLE"
  exit 0
fi

attempt=0
while [ "$attempt" -le "$RETRIES" ]; do
  if cs_herdr_submit_confirm "$PANE" 4000; then
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
