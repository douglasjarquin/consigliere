#!/usr/bin/env bash
# cs-prompt-lib.sh - the one guarded way to make an agent take a turn.
#
# Sourced, never executed. Requires cs-herdr-lib.sh and cs-composer-lib.sh to be
# sourced first.
#
# Every path that puts text into an agent's pane needs the same four guards, and
# they were previously written once inside the away daemon and nowhere else. A
# second caller (per-home activation, bin/cs-activate.sh) would have copied them,
# so they live here instead:
#
#   1. pane exists;
#   2. busy-guard  - never prompt a mid-turn (`busy`) or human-blocked pane;
#   3. composer-guard - only an affirmatively EMPTY composer is a safe target;
#   4. submit confirmation - the agent must actually enter `working`.
#
# WHY THE COMPOSER GUARD SURVIVES, measured 2026-08-01 in an isolated lab:
# `herdr agent prompt` CONCATENATES its text onto whatever is already in the
# composer and submits the merged line, reporting success. So does `pane run`.
# Typing "HUMAN_HALF_TYPED_LINE" and then prompting "ZZMARKER_THREE" submitted
# `HUMAN_HALF_TYPED_LINEZZMARKER_THREE` as one message, on both codex and claude.
# Concatenation is a property of every submit path, not of any one primitive, so
# no primitive change can retire this guard.
#
# WHY SUBMIT CONFIRMATION SURVIVES: `agent prompt` returns `agent_prompted` and
# exit 0 for a prompt that was never delivered. Measured on both harnesses: a
# prompt sent within ~40s of `agent start` is silently lost while herdr reports
# `agent_status: idle` and `interactive_ready: true`. Only the idle->working
# transition proves a turn began.
#
# WHY `agent prompt` RATHER THAN send-text + Enter: it is atomic (no swallowed
# Enter, so no retype-vs-retry hazard) and it delivers MULTILINE text as ONE
# message - verified; a three-line prompt arrived intact with no premature
# submit on the first newline. Daemon digests are multiline.
#
# The U+2063 operational-input marker survives `agent prompt` intact (verified
# byte-level: the receiving agent reported a leading e2 81 a3), so the
# away-supervisor typing contract is unaffected.

# cs_prompt_guarded <pane> <text> [log-fn]
# 0 = a turn provably started. 1 = not delivered; the reason went to log-fn.
cs_prompt_guarded() {
  local pane=$1 text=$2 logfn=${3:-:} bs composer wait_ms

  cs_herdr_pane_exists "$pane" || { "$logfn" "prompt deferred: pane '$pane' is gone"; return 1; }

  bs=$(cs_herdr_agent_busy_state "$pane" 2>/dev/null) || bs=unknown
  case "$bs" in
    busy|blocked)
      "$logfn" "prompt deferred: pane busy (agent state=$bs)"
      return 1 ;;
  esac

  composer=$(cs_composer_state "$pane" 2>/dev/null)
  if [ "$composer" != empty ]; then
    "$logfn" "prompt deferred: composer not confirmed-empty (state=${composer:-unknown}); prompting now would concatenate onto it"
    return 1
  fi

  # Submit and confirm in one native call; herdr's own agent_prompt_stalled
  # distinguishes "sent but the agent never left its pre-submit state" from a
  # hard rejection, so the two log messages below still mean what they said.
  wait_ms=${CS_PROMPT_CONFIRM_WAIT_MS:-8000}
  local out
  if out=$(cs_herdr_agent_prompt_confirmed "$pane" "$text" "$wait_ms" 2>&1); then
    return 0
  fi
  case "$out" in
    *agent_prompt_stalled*|*'"timeout"'*)
      "$logfn" "prompt unconfirmed: no idle->working transition within ${wait_ms}ms (agent may not have been ready)" ;;
    *)
      "$logfn" "prompt failed: herdr rejected the prompt for '$pane' (no agent there?)" ;;
  esac
  return 1
}

# --- wedge alarm: the one active-alert channel shared by every guarded-prompt
# caller. Ported from the away-mode daemon (bin/cs-daemon.sh), which was the
# only caller before per-home activation (bin/cs-activate.sh) needed it too.
# Config: config/wedge-alarm.conf (LOCAL, gitignored), one directive per
# non-empty non-comment line; CS_WEDGE_ALARM_CHANNEL overrides the file with a
# single directive.
#   off              disable the active alert (caller's own durable marker remains)
#   auto | default   platform default: macOS -> osascript; otherwise none
#   osascript        macOS Notification Center banner
#   herdr            herdr UI notification (herdr notification show)
#   command:<cmd>    run <cmd> via sh -c, summary on $1 and stdin
# Every channel is best-effort: a missing or failing channel logs (via the
# caller's own log-fn) and is skipped, never propagating a failure to the caller.

CS_WEDGE_ALARM_TIMEOUT_SECS_DEFAULT=10

cs_wedge_alarm_configured_channels() {
  local cfg line found=
  if [ -n "${CS_WEDGE_ALARM_CHANNEL:-}" ]; then
    printf '%s\n' "$CS_WEDGE_ALARM_CHANNEL"
    return 0
  fi
  cfg="${CS_CONFIG_OVERRIDE:-$CS_HOME/config}/wedge-alarm.conf"
  if [ -f "$cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] || continue
      case "$line" in '#'*) continue ;; esac
      printf '%s\n' "$line"
      found=1
    done < "$cfg"
  fi
  [ -n "$found" ] || printf 'auto\n'
}

cs_wedge_alarm_platform_default() {
  case "$(uname)" in
    Darwin) command -v osascript >/dev/null 2>&1 && printf 'osascript' ;;
    *) : ;;
  esac
}

# Run one notifier under a watchdog so a hung notifier can never stall the caller.
cs_wedge_alarm_run_bounded() {  # <logfn> <channel> <cmd...>
  local logfn=$1 channel=$2 timeout pid start elapsed rc
  shift 2
  timeout=${CS_WEDGE_ALARM_TIMEOUT_SECS:-$CS_WEDGE_ALARM_TIMEOUT_SECS_DEFAULT}
  case "$timeout" in
    ''|*[!0-9]*|0) timeout=$CS_WEDGE_ALARM_TIMEOUT_SECS_DEFAULT ;;
  esac
  "$@" &
  pid=$!
  CS_WEDGE_ALARM_NOTIFIER_PID=$pid
  start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      cs_wedge_alarm_stop_active_notifier
      "$logfn" "wedge alarm: ${channel} notifier timed out after ${elapsed}s (limit ${timeout}s)"
      return 124
    fi
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  CS_WEDGE_ALARM_NOTIFIER_PID=
  return "$rc"
}

cs_wedge_alarm_stop_active_notifier() {
  local pid=${CS_WEDGE_ALARM_NOTIFIER_PID:-}
  [ -n "$pid" ] || return 0
  CS_WEDGE_ALARM_NOTIFIER_PID=
  kill -TERM "$pid" 2>/dev/null || true
  sleep 0.2
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cs_wedge_alarm_via_osascript() {  # <logfn> <title> <summary>
  local logfn=$1 title=$2 summary=$3
  command -v osascript >/dev/null 2>&1 || {
    "$logfn" "wedge alarm: osascript not found; cannot post a macOS notification"; return 1; }
  cs_wedge_alarm_run_bounded "$logfn" osascript osascript -e 'on run argv' \
    -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Basso"' \
    -e 'end run' "$title" "$summary" >/dev/null 2>&1 && return 0
  "$logfn" "wedge alarm: osascript notification failed"
  return 1
}

cs_wedge_alarm_via_herdr() {  # <logfn> <title> <summary>
  local logfn=$1 title=$2 summary=$3
  command -v herdr >/dev/null 2>&1 || {
    "$logfn" "wedge alarm: herdr not found; cannot post a herdr notification"; return 1; }
  cs_wedge_alarm_run_bounded "$logfn" herdr herdr notification show \
    "$title" --body "$summary" --sound request >/dev/null 2>&1 && return 0
  "$logfn" "wedge alarm: herdr notification failed"
  return 1
}

cs_wedge_alarm_via_command() {  # <logfn> <cmd> <summary>
  local logfn=$1 cmd=$2 summary=$3 rc
  [ -n "$cmd" ] || { "$logfn" "wedge alarm: empty command: channel; nothing to run"; return 1; }
  cs_wedge_alarm_run_bounded "$logfn" command sh -c "$cmd" cs-wedge-alarm "$summary" \
    <<< "$summary" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  "$logfn" "wedge alarm: command channel exited $rc (command redacted)"
  return 1
}

# The single execution seam for every notifier channel. CS_WEDGE_ALARM_EXEC,
# when set, REPLACES the real notifier as `<cmd> <channel> <summary>`; the
# special value "discard" fires nothing. Tests force this seam so no test can
# post a real desktop notification.
cs_wedge_alarm_emit() {  # <logfn> <title> <channel> <summary> [command-directive]
  local logfn=$1 title=$2 channel=$3 summary=$4 cmd=${5:-} rc exec_override=${CS_WEDGE_ALARM_EXEC:-}
  case "$exec_override" in
    '') ;;
    discard) return 0 ;;
    *)
      cs_wedge_alarm_run_bounded "$logfn" "$channel" "$exec_override" "$channel" "$summary" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      "$logfn" "wedge alarm: notifier override exited $rc for channel '$channel'"
      return 1 ;;
  esac
  case "$channel" in
    osascript) cs_wedge_alarm_via_osascript "$logfn" "$title" "$summary" ;;
    herdr) cs_wedge_alarm_via_herdr "$logfn" "$title" "$summary" ;;
    command) cs_wedge_alarm_via_command "$logfn" "$cmd" "$summary" ;;
  esac
}

# Fire every configured channel, best-effort; always returns 0. Any `off`
# directive disables the alert entirely; an unresolvable `auto` logs that the
# caller's own durable marker is the only signal.
cs_wedge_alarm_notify() {  # <logfn> <title> <summary>
  local logfn=$1 title=$2 summary=$3 ch
  local -a channels=()
  while IFS= read -r ch; do
    [ -n "$ch" ] || continue
    channels+=("$ch")
  done < <(cs_wedge_alarm_configured_channels)
  for ch in "${channels[@]}"; do
    [ "$ch" = off ] && return 0
  done
  for ch in "${channels[@]}"; do
    case "$ch" in auto|default) ch=$(cs_wedge_alarm_platform_default) ;; esac
    case "$ch" in
      '') "$logfn" "wedge alarm: no OS-level alert channel on $(uname); the durable marker is the only signal - set config/wedge-alarm.conf (e.g. a command: directive)" ;;
      osascript|herdr) cs_wedge_alarm_emit "$logfn" "$title" "$ch" "$summary" || true ;;
      command:*) cs_wedge_alarm_emit "$logfn" "$title" command "$summary" "${ch#command:}" || true ;;
      *) "$logfn" "wedge alarm: unrecognized active-alert channel directive (redacted); marker still written" ;;
    esac
  done
  return 0
}
