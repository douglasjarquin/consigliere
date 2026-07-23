#!/usr/bin/env bash
# bin/cs-daemon.sh - presence-gated away-mode sub-supervisor.
#
# Wraps bin/cs-watch.sh: runs it as a one-shot child, classifies each printed
# wake reason, and either SELF-HANDLES the routine majority in bash (no
# consigliere turn) or ESCALATES a batched, distilled digest to consigliere's
# own pane on boss-relevant events (done/needs-decision/blocked/failed/
# persistent-wedge/check-output) plus bounded declared-pause rechecks. This is
# the token-efficient away-mode engine: routine signal/stale/heartbeat wakes
# cost zero consigliere context; only boss-relevant events reach the LLM, and
# even then as one pre-read digest per batch window.
#
# PRESENCE-GATING (the /afk contract). The daemon injects ONLY while the
# durable away-mode flag state/.afk is present. bin/cs-afk-start.sh sets that
# flag and starts this daemon; bin/cs-afk-return.sh stops the daemon and
# clears the flag when the boss returns. While state/.afk exists the watcher
# reverts to daemon-owned one-shot behavior (bin/cs-watch.sh queues and exits
# on every wake), so the two never triage the same wake twice. Buffered
# escalations that remain when afk turns off survive in
# state/.subsuper-escalations and are flushed by the return catch-up.
#
# OPERATIONAL INPUT. Every injection is constructed as away-supervisor by
# bin/cs-operational-input.sh. It starts with the same bare U+2063
# CS_INJECT_MARK, followed by a versioned kind header. Consigliere classifies
# the structure without reading body prose. The labeled from-consigliere
# compatibility form remains byte-distinct.
#
# Reliability model (see skills/afk/SKILL.md):
#   - Nothing is lost: while state/.afk exists the watcher enqueues every wake
#     to state/.wake-queue BEFORE advancing its suppression markers, so a
#     crash/restart/missed injection is recovered by the next cs-wake-drain.
#     The daemon never touches the queue; it only reads the watcher's stdout.
#   - Fail-safe-to-escalate: any wake the classifier cannot confidently mark
#     routine is escalated.
#   - Bounded wedge latency: a stale pane without a declared external wait
#     escalates after CS_STALE_ESCALATE_SECS idle, rechecked once. A declared
#     pause instead re-surfaces on its own long CS_PAUSE_RESURFACE_SECS
#     cadence, never as a wedge.
#   - Max-defer alarm: if a digest stays undelivered past CS_MAX_DEFER_SECS,
#     the daemon retries one normal flush and, if that cannot confirm a
#     submit, writes state/.subsuper-inject-wedged and fires a configurable
#     active alert (config/wedge-alarm; default auto = macOS Notification
#     Center via osascript; `herdr notification show` is also available).
#   - Cheap heartbeat catch-all: every CS_HEARTBEAT_SCAN_SECS the daemon runs
#     scan_boss_relevant_statuses (bin/cs-classify-lib.sh) over state/*.status
#     for a boss-relevant line the per-wake classifier might have missed.
#
# Injection model (herdr + codex only; no backend abstraction):
#   - The target is ONE herdr pane id: argv[1], else CS_SUPERVISOR_PANE, else
#     state/.subsuper-target (recorded by cs-afk-start from the primary's own
#     HERDR_PANE_ID). Refuses to start without one.
#   - Busy-guard: never inject while native agent state reads busy or blocked.
#   - Composer-guard: inject ONLY into an affirmatively EMPTY codex composer
#     (bin/cs-composer-lib.sh, ANSI ghost-text aware); 'pending' and 'unknown'
#     both defer, preserving the buffer.
#   - Type ONCE, then submit with Enter; NEVER retype (a swallowed Enter leaves
#     our text in the composer, and retyping would concatenate two digests).
#     Submit confirmation is native: cs_herdr_submit_confirm waits for the
#     agent's idle->working transition. Enter alone is retried up to
#     CS_INJECT_CONFIRM_RETRIES times; unconfirmed = undelivered (strict).
#
# Robustness shell: single-instance portable lock (bin/cs-wake-lib.sh, no
# flock), crash-loop backoff for a crashing watcher child, pane-gone guard,
# and a signal-trapped shutdown that flushes buffered escalations before exit
# (an unflushable buffer survives in state/.subsuper-escalations for the
# return catch-up).
#
# Usage: cs-daemon.sh [<pane_id>]
#   Long-lived background loop; normally started by bin/cs-afk-start.sh.
#   Env knobs:
#     CS_SUPERVISOR_PANE       injection target pane id (else argv[1], else
#                              state/.subsuper-target)
#     CS_WATCH_BIN             watcher child override (default bin/cs-watch.sh;
#                              tests substitute a scripted stub)
#     CS_INJECT_SKIP           |-separated reason prefixes force-self-handled,
#                              bypassing classification (default "heartbeat";
#                              empty disables). Use sparingly.
#     CS_STALE_ESCALATE_SECS   idle secs before a stale pane escalates as a
#                              possible wedge (default 240)
#     CS_PAUSE_RESURFACE_SECS  idle secs before a declared external wait
#                              re-surfaces as a recheck (default 3600, shared
#                              with the watcher via cs-classify-lib.sh)
#     CS_ESCALATE_BATCH_SECS   buffer window for batched digests; 0 = flush
#                              immediately (default 90)
#     CS_HEARTBEAT_SCAN_SECS   catch-all status-scan cadence (default 300)
#     CS_HOUSEKEEPING_TICK     secs between housekeeping passes (default 15)
#     CS_MAX_DEFER_SECS        max secs a buffered escalation may sit
#                              undelivered before one flush retry then a wedge
#                              alarm (default 300; 0 disables)
#     CS_WEDGE_ALARM_CHANNEL   override config/wedge-alarm with one directive
#                              (off|auto|osascript|herdr|command:<cmd>)
#     CS_WEDGE_ALARM_EXEC      notifier test seam: replaces every channel with
#                              `<cmd> <channel> <summary>`; "discard" fires
#                              nothing. Defaults to "discard" when this file is
#                              SOURCED so no test posts a real notification.
#     CS_WEDGE_ALARM_TIMEOUT_SECS  per-notifier watchdog (default 10)
#     CS_INJECT_CONFIRM_RETRIES    Enter-only retries (default 3)
#     CS_INJECT_CONFIRM_WAIT_MS    native submit-confirm wait (default 4000)
#     CS_LOG_MAX_BYTES / CS_LOG_KEEP_LINES / CS_CRASH_*   log + crash guards
#     CS_STATE_OVERRIDE        alternate state dir (testing)
#   Logs to state/.subsuper-daemon.log (size-capped). Single instance via the
#   portable lock on state/.subsuper-daemon.lock. Trapped SIGTERM/SIGINT shut
#   down within ~1s, flush escalations, release the lock.
set -u

CS_DAEMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CS_ROOT="${CS_ROOT_OVERRIDE:-$(cd "$CS_DAEMON_DIR/.." && pwd)}"
CS_HOME="${CS_HOME:-${CS_ROOT_OVERRIDE:-$CS_ROOT}}"

# Shared wake classifier (last_status_line, status_is_boss_relevant,
# pane_to_task, scan_boss_relevant_statuses...). The SAME library backs the
# always-on watcher's triage, so the boss-relevant verb set has exactly one
# definition - never duplicate it here.
# shellcheck source=bin/cs-classify-lib.sh
. "$CS_DAEMON_DIR/cs-classify-lib.sh"
# The one herdr layer: captures, native busy state, submit confirmation.
# shellcheck source=bin/cs-herdr-lib.sh
. "$CS_DAEMON_DIR/cs-herdr-lib.sh"
# Codex-only composer-emptiness classifier (needs cs-herdr-lib above).
# shellcheck source=bin/cs-composer-lib.sh
. "$CS_DAEMON_DIR/cs-composer-lib.sh"
# state/<id>.meta readers (pane_for_task below).
# shellcheck source=bin/cs-meta-lib.sh
. "$CS_DAEMON_DIR/cs-meta-lib.sh"
# --- tunables ----------------------------------------------------------------
INJECT_SKIP_DEFAULT="heartbeat"
STALE_ESCALATE_SECS_DEFAULT=240
ESCALATE_BATCH_SECS_DEFAULT=90
HEARTBEAT_SCAN_SECS_DEFAULT=300
HOUSEKEEPING_TICK_DEFAULT=15
MAX_DEFER_SECS_DEFAULT=300
WEDGE_ALARM_TIMEOUT_SECS_DEFAULT=10
INJECT_FAIL_SLEEP_DEFAULT=30
INJECT_CONFIRM_RETRIES_DEFAULT=3
INJECT_CONFIRM_WAIT_MS_DEFAULT=4000
CRASH_THRESHOLD_DEFAULT=10
CRASH_WINDOW_DEFAULT=60
CRASH_BACKOFF_DEFAULT=60
CRASH_NORMAL_SLEEP_DEFAULT=5
LOG_MAX_BYTES_DEFAULT=1048576
LOG_KEEP_LINES_DEFAULT=2000
AFK_FLAG_NAME=".afk"
WEDGE_ALARM_LAST_EPOCH=0
WEDGE_ALARM_NOTIFIER_PID=

# Resolve the effective state dir. CS_STATE_OVERRIDE wins (testing); otherwise
# $CS_HOME/state. Kept as a function so the pure classifiers can take an
# explicit state arg without depending on globals.
_state_root() { printf '%s' "${CS_STATE_OVERRIDE:-$CS_HOME/state}"; }

# --- portable stat (same trap as cs-watch.sh: no `stat -f || stat -c`) -------
if [ "$(uname)" = Darwin ]; then
  _stat_file_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  _stat_file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
_now() { date +%s; }
_file_age() {  # seconds since mtime; very large if missing
  local f=$1 m
  m=$(_stat_file_mtime "$f") || { echo 999999; return; }
  echo $(( $(_now) - m ))
}

# --- presence-gating helpers -------------------------------------------------
afk_active() {  # <state>
  [ -e "$1/$AFK_FLAG_NAME" ]
}

afk_enter() {  # <state>
  mkdir -p "$1"
  date '+%s' > "$1/$AFK_FLAG_NAME"
}

afk_exit() {  # <state>
  rm -f "$1/$AFK_FLAG_NAME"
}

# message_is_injection: 0 for a structurally typed operational input, 1 for
# boss text. Consigliere's afk-exit contract keys off this; ambiguity biases
# toward exit (a false exit is self-correcting - the boss re-runs /afk).
message_is_injection() {  # <message-text>
  local msg=$1 kind
  [ -n "$msg" ] || return 1
  kind=$(cs_classify_input "$msg")
  [ "$kind" != boss ]
}

# should_exit_afk: the afk-exit contract as a testable function.
#   afk inactive            -> 1 (nothing to exit)
#   message has marker      -> 1 (internal escalation; stay afk)
#   message is /afk command -> 1 (refresh; stay afk)
#   anything else           -> 0 (boss is back; exit afk)
should_exit_afk() {  # <state> <message-text>
  local state=$1 msg=$2
  afk_active "$state" || return 1
  message_is_injection "$msg" && return 1
  case "$msg" in
    /afk*) return 1 ;;
  esac
  return 0
}

# strip_injection_marker: return the typed body once provenance was read.
strip_injection_marker() {  # <message-text>
  cs_operational_input_body "$1"
}

# Collapse newlines to a literal " - " so the injected digest is a single line
# and submission via text + Enter is unambiguous.
_collapse_newlines() {  # <text>
  local s=$1
  s=${s//$'\n'/ - }
  printf '%s' "$s"
}

# --- classification (decision protocol: "<action>|<distilled>") --------------
# Actions: self (routine, no consigliere turn), escalate (buffered digest),
# pause (declared external wait; long re-surface cadence).

classify_signal() {  # <file-list-after-colon> <state>
  local reason=$1 state=$2 f last distilled="" rel="" all_seen=1 task seen
  for f in $reason; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    distilled="${distilled}$(basename "$f"): ${last} | "
    status_is_boss_relevant "$last" || continue
    rel=1
    # Dedupe against the catch-all scan: a status already escalated (seen
    # marker matches) is not escalated again. all_seen stays 1 only if EVERY
    # relevant file was seen.
    task=$(basename "$f"); task="${task%.status}"
    seen="$state/.subsuper-seen-status-$(_stale_key "$task")"
    [ "$(cat "$seen" 2>/dev/null || true)" = "$last" ] || all_seen=0
  done
  distilled="${distilled% | }"
  if [ -z "$rel" ]; then
    printf 'self|routine signal: %s' "$distilled"
  elif [ "$all_seen" = "1" ]; then
    printf 'self|signal already escalated (catch-all scan): %s' "$distilled"
  else
    printf 'escalate|%s' "$distilled"
  fi
}

# classify_stale decides the WAKE itself (the watcher fires one-shot per
# distinct stale hash in afk mode). First sight of a non-terminal stale is
# "self" and the caller records a timestamp marker; PERSISTENCE is escalated
# by housekeeping's recheck, not here.
classify_stale() {  # <pane> <state>
  local pane=$1 state=$2 task last seen
  task=$(pane_to_task "$pane" "$state")
  last=$(last_status_line "$state/$task.status")
  if [ -n "$last" ] && status_is_paused "$last"; then
    printf 'pause|paused (awaiting external), rechecked on a long cadence: %s' "$last"
    return
  fi
  if [ -n "$last" ] && status_is_boss_relevant "$last"; then
    # A nonterminal progress verb must never take the terminal stale path,
    # even when its prose contains a legacy free-text token.
    if ! status_is_terminal_verb "$last"; then
      case "$(status_line_verb "$last")" in
        working|resolved|captain-held)
          printf 'self|transient stale (%s): %s' "$pane" "$last"
          return
          ;;
      esac
    fi
    seen="$state/.subsuper-seen-status-$(_stale_key "$task")"
    if [ "$(cat "$seen" 2>/dev/null || true)" = "$last" ]; then
      printf 'self|stale + terminal (already escalated by signal): %s' "$last"
      return
    fi
    printf 'escalate|stale + terminal status: %s' "$last"
    return
  fi
  printf 'self|transient stale (%s): %s' "$pane" "${last:-no status}"
}

classify_check() {  # <full reason> - check scripts print only when actionable
  printf 'escalate|%s' "$1"
}

classify_heartbeat() {
  printf 'self|heartbeat (catch-all scan runs in housekeeping)'
}

# Anything unrecognized is escalated (fail-safe).
classify_unknown() {  # <reason>
  printf 'escalate|unknown wake: %s' "$1"
}

# --- stale/pause markers + escalation buffer ---------------------------------
# Marker:  state/.subsuper-stale-<key>   epoch first seen idle (wedge aging).
# Marker:  state/.subsuper-paused-<key>  epoch a declared pause was seen idle.
# Buffer:  state/.subsuper-escalations   one distilled line per escalation.
# Seen:    state/.subsuper-seen-status-<task>  last status line escalated.
# All keys derive from the TASK id via _stale_key.

_stale_key() { printf '%s' "$1" | tr ':/.' '___'; }

# The first whitespace-delimited token of a stale reason is the pane id; the
# watcher may append a parenthetical annotation (wedge count, blocked push).
_stale_pane_of() {  # <stale-arg>
  printf '%s' "${1%% *}"
}

stale_marker_record() {  # <pane> <state> - create if absent
  local pane=$1 state=$2 marker
  marker="$state/.subsuper-stale-$(_stale_key "$(pane_to_task "$pane" "$state")")"
  [ -e "$marker" ] || _now > "$marker"
}

stale_marker_remove() {  # <pane> <state>
  local pane=$1 state=$2
  rm -f "$state/.subsuper-stale-$(_stale_key "$(pane_to_task "$pane" "$state")")"
}

pause_marker_record() {  # <pane> <state> - create if absent (stable timestamp)
  local pane=$1 state=$2 marker
  marker="$state/.subsuper-paused-$(_stale_key "$(pane_to_task "$pane" "$state")")"
  [ -e "$marker" ] || _now > "$marker"
}

pause_marker_remove() {  # <pane> <state>
  local pane=$1 state=$2
  rm -f "$state/.subsuper-paused-$(_stale_key "$(pane_to_task "$pane" "$state")")"
}

# Reconcile daemon pause tracking against a task's current last status line: a
# declared pause converts wedge aging into pause aging; a cleared pause drops
# the pause marker so the pane reverts to normal wedge aging.
reconcile_pause_tracking() {  # <pane> <state> <last-status-line>
  local pane=$1 state=$2 last=$3 key
  key=$(_stale_key "$(pane_to_task "$pane" "$state")")
  if status_is_paused "$last"; then
    rm -f "$state/.subsuper-stale-$key"
    pause_marker_record "$pane" "$state"
  elif [ -e "$state/.subsuper-paused-$key" ]; then
    rm -f "$state/.subsuper-paused-$key"
  fi
}

sync_pause_markers_from_signal() {  # <state> <signal file list>
  local state=$1 paths=$2 f last task pane
  for f in $paths; do
    case "$f" in *.status) ;; *) continue ;; esac
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    task=$(basename "$f"); task=${task%.status}
    pane=$(pane_for_task "$(_stale_key "$task")" "$state" 2>/dev/null || true)
    [ -n "$pane" ] || continue
    reconcile_pause_tracking "$pane" "$state" "$last"
  done
}

# Record the seen-status marker so the heartbeat catch-all does not re-fire a
# status already escalated. Single source of truth for the dedupe state.
mark_status_seen() {  # <state> <task> <last-line>
  printf '%s' "$3" > "$1/.subsuper-seen-status-$(_stale_key "$2")"
}

# Mark every boss-relevant status a per-wake classification escalated as seen.
mark_escalated_seen() {  # <kind> <arg> <state>
  local kind=$1 arg=$2 state=$3 f last task
  case "$kind" in
    signal)
      for f in $arg; do
        [ -e "$f" ] || continue
        last=$(last_status_line "$f")
        [ -n "$last" ] || continue
        status_is_boss_relevant "$last" || continue
        task=$(basename "$f"); task="${task%.status}"
        mark_status_seen "$state" "$task" "$last"
      done ;;
    stale)
      task=$(pane_to_task "$(_stale_pane_of "$arg")" "$state")
      last=$(last_status_line "$state/$task.status")
      [ -n "$last" ] && status_is_boss_relevant "$last" \
        && mark_status_seen "$state" "$task" "$last" ;;
  esac
}

# Find the recorded pane whose task id matches a marker key.
pane_for_task() {  # <task-key> [state]
  local key=$1 state=${2:-$(_state_root)} meta task p
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    task=$(basename "$meta"); task=${task%.meta}
    [ "$(_stale_key "$task")" = "$key" ] || continue
    p=$(cs_meta_get "$meta" pane 2>/dev/null) || continue
    [ -n "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# stale_pane_is_busy: 0 busy (still working), 1 idle, 2 unreadable/gone.
# cs_herdr_agent_busy_state already corroborates a native idle/unknown reading
# against the codex busy signature, so no extra regex pass is needed here.
stale_pane_is_busy() {  # <pane>
  local pane=$1 bs
  cs_herdr_pane_exists "$pane" || return 2
  bs=$(cs_herdr_agent_busy_state "$pane" 2>/dev/null) || return 2
  case "$bs" in
    busy|blocked) return 0 ;;
  esac
  return 1
}

escalate_add() {  # <state> <distilled-item>
  local state=$1 item=$2 buf
  buf="$state/.subsuper-escalations"
  [ -s "$buf" ] || _now > "${buf}.since"
  printf '%s\n' "$item" >> "$buf"
}

# Flush the escalation buffer as ONE batched, single-line digest into the
# supervisor pane. 0 on successful inject (or empty buffer); non-zero on
# failure (buffer preserved for retry / the return catch-up).
escalate_flush() {  # <state>
  local state=$1 buf n msg
  buf="$state/.subsuper-escalations"
  [ -s "$buf" ] || return 0
  n=$(wc -l < "$buf" 2>/dev/null | tr -d '[:space:]')
  msg=$(awk 'NR>1{printf " | "} {printf "%s",$0} END{print ""}' "$buf" 2>/dev/null)
  msg=$(printf 'Away-mode escalation (%s event(s)): %s (pre-read digest; watcher is daemon-managed while away mode holds)' "$n" "$msg")
  if inject_msg "$msg" "$state"; then
    : > "$buf"
    rm -f "${buf}.since" "$state/.subsuper-inject-wedged"
    return 0
  fi
  return 1
}

# --- active wedge alert --------------------------------------------------------
# A wedged escalation must never be silent: beyond the log ERROR and the
# durable state/.subsuper-inject-wedged marker, a configurable active alert
# can reach the boss away from the machine. Config: config/wedge-alarm (LOCAL,
# gitignored), one directive per non-empty non-comment line;
# CS_WEDGE_ALARM_CHANNEL overrides the file with a single directive.
#   off              disable the active alert (marker + log remain)
#   auto | default   platform default: macOS -> osascript; otherwise none
#   osascript        macOS Notification Center banner
#   herdr            herdr UI notification (herdr notification show)
#   command:<cmd>    run <cmd> via sh -c, summary on $1 and stdin
# Every channel is best-effort: a missing or failing channel logs and is
# skipped, never crashing the daemon loop.

wedge_alarm_configured_channels() {
  local cfg line found=
  if [ -n "${CS_WEDGE_ALARM_CHANNEL:-}" ]; then
    printf '%s\n' "$CS_WEDGE_ALARM_CHANNEL"
    return 0
  fi
  cfg="${CS_CONFIG_OVERRIDE:-$CS_HOME/config}/wedge-alarm"
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

wedge_alarm_platform_default() {
  case "$(uname)" in
    Darwin) command -v osascript >/dev/null 2>&1 && printf 'osascript' ;;
    *) : ;;
  esac
}

# Run one notifier under a watchdog so a hung notifier can never stall the
# daemon loop.
wedge_alarm_run_bounded() {  # <channel> <cmd...>
  local channel=$1 timeout pid start elapsed rc
  shift
  timeout=${CS_WEDGE_ALARM_TIMEOUT_SECS:-$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT}
  case "$timeout" in
    ''|*[!0-9]*|0) timeout=$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT ;;
  esac
  "$@" &
  pid=$!
  WEDGE_ALARM_NOTIFIER_PID=$pid
  start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      wedge_alarm_stop_active_notifier
      log "wedge alarm: ${channel} notifier timed out after ${elapsed}s (limit ${timeout}s)"
      return 124
    fi
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  WEDGE_ALARM_NOTIFIER_PID=
  return "$rc"
}

wedge_alarm_stop_active_notifier() {
  local pid=${WEDGE_ALARM_NOTIFIER_PID:-}
  [ -n "$pid" ] || return 0
  WEDGE_ALARM_NOTIFIER_PID=
  kill -TERM "$pid" 2>/dev/null || true
  sleep 0.2
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

wedge_alarm_via_osascript() {  # <summary>
  local summary=$1
  command -v osascript >/dev/null 2>&1 || {
    log "wedge alarm: osascript not found; cannot post a macOS notification"; return 1; }
  wedge_alarm_run_bounded osascript osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "consigliere: away-mode escalations WEDGED" sound name "Basso"' \
    -e 'end run' "$summary" >/dev/null 2>&1 && return 0
  log "wedge alarm: osascript notification failed"
  return 1
}

wedge_alarm_via_herdr() {  # <summary>
  local summary=$1
  command -v herdr >/dev/null 2>&1 || {
    log "wedge alarm: herdr not found; cannot post a herdr notification"; return 1; }
  wedge_alarm_run_bounded herdr herdr notification show \
    "consigliere: away-mode escalations WEDGED" --body "$summary" --sound request \
    >/dev/null 2>&1 && return 0
  log "wedge alarm: herdr notification failed"
  return 1
}

wedge_alarm_via_command() {  # <cmd> <summary>
  local cmd=$1 summary=$2 rc
  [ -n "$cmd" ] || { log "wedge alarm: empty command: channel; nothing to run"; return 1; }
  wedge_alarm_run_bounded command sh -c "$cmd" cs-wedge-alarm "$summary" \
    <<< "$summary" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  log "wedge alarm: command channel exited $rc (command redacted)"
  return 1
}

# The single execution seam for every notifier channel. CS_WEDGE_ALARM_EXEC,
# when set, REPLACES the real notifier as `<cmd> <channel> <summary>`; the
# special value "discard" fires nothing. Tests force this seam so no test can
# post a real desktop notification (the library-mode guard at the foot of this
# file defaults it to "discard" whenever the daemon is SOURCED).
wedge_alarm_emit() {  # <channel> <summary> [command-directive]
  local channel=$1 summary=$2 cmd=${3:-} rc exec_override=${CS_WEDGE_ALARM_EXEC:-}
  case "$exec_override" in
    '') ;;
    discard) return 0 ;;
    *)
      wedge_alarm_run_bounded "$channel" "$exec_override" "$channel" "$summary" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      log "wedge alarm: notifier override exited $rc for channel '$channel'"
      return 1 ;;
  esac
  case "$channel" in
    osascript) wedge_alarm_via_osascript "$summary" ;;
    herdr) wedge_alarm_via_herdr "$summary" ;;
    command) wedge_alarm_via_command "$cmd" "$summary" ;;
  esac
}

# Fire every configured channel, best-effort; always returns 0. Any `off`
# directive disables the alert entirely; an unresolvable `auto` logs that the
# durable marker is the only signal.
wedge_alarm_notify() {  # <summary> <marker>
  local summary=$1 marker=$2 ch
  local -a channels=()
  while IFS= read -r ch; do
    [ -n "$ch" ] || continue
    channels+=("$ch")
  done < <(wedge_alarm_configured_channels)
  for ch in "${channels[@]}"; do
    [ "$ch" = off ] && return 0
  done
  for ch in "${channels[@]}"; do
    case "$ch" in auto|default) ch=$(wedge_alarm_platform_default) ;; esac
    case "$ch" in
      '') log "wedge alarm: no OS-level alert channel on $(uname); durable marker $marker is the only signal - set config/wedge-alarm (e.g. a command: directive)" ;;
      osascript|herdr) wedge_alarm_emit "$ch" "$summary" || true ;;
      command:*) wedge_alarm_emit command "$summary" "${ch#command:}" || true ;;
      *) log "wedge alarm: unrecognized active-alert channel directive (redacted); marker still written" ;;
    esac
  done
  return 0
}

# Raise a loud, rate-limited alarm when escalations cannot be delivered past
# max-defer. The daemon must NEVER silently wedge: ERROR log, durable marker
# for consigliere/recovery to surface, and the configurable active alert.
# Nothing is lost - the buffer and the wake queue both survive - but the stall
# stops being invisible.
inject_wedge_alarm() {  # <state> <age-seconds>
  local state=$1 age=$2 marker max_defer now notify=1
  marker="$state/.subsuper-inject-wedged"
  max_defer="${CS_MAX_DEFER_SECS:-$MAX_DEFER_SECS_DEFAULT}"
  # Re-alarm at most once per max-defer window so a long wedge does not spam.
  if [ "$(_file_age "$marker")" -lt "$max_defer" ]; then
    return 0
  fi
  now=$(_now)
  if [ "$WEDGE_ALARM_LAST_EPOCH" -gt 0 ] && [ $((now - WEDGE_ALARM_LAST_EPOCH)) -lt "$max_defer" ]; then
    notify=0
  else
    WEDGE_ALARM_LAST_EPOCH=$now
    log "ERROR: away-mode escalation undelivered ${age}s; inject could not confirm a submit (supervisor pane busy or composer not empty). Buffer + wake queue preserved; alarm marker written."
  fi
  {
    printf 'cs away-mode inject WEDGED: %ss undelivered as of %s\n' "$age" "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'The supervisor pane could not accept an escalation. Buffered items:\n'
    cat "$state/.subsuper-escalations" 2>/dev/null
  } 2>/dev/null > "$marker" || true
  if [ "$notify" -eq 1 ]; then
    wedge_alarm_notify "away-mode escalations WEDGED ${age}s undelivered - see $marker" "$marker"
  fi
}

_oldest_line_age() {  # <buf> -> secs since the oldest buffered item arrived
  local f=$1 since
  [ -s "$f" ] || { echo 999999; return; }
  since="${f}.since"
  if [ -r "$since" ]; then
    echo $(( $(_now) - $(cat "$since" 2>/dev/null || echo 0) ))
  else
    echo 999999
  fi
}

# --- housekeeping (runs every CS_HOUSEKEEPING_TICK while the watcher blocks) --
# 1)  batch flush past CS_ESCALATE_BATCH_SECS (or immediately when 0).
# 1b) max-defer escape: still undelivered past CS_MAX_DEFER_SECS -> one normal
#     flush retry; unconfirmed -> wedge alarm. Never silently defer forever.
# 2)  stale recheck: each stale marker past CS_STALE_ESCALATE_SECS re-peeks the
#     pane; still idle -> escalate a possible wedge; busy/gone -> clear.
# 2b) pause re-surface: each pause marker past CS_PAUSE_RESURFACE_SECS
#     re-peeks; still idle + still declared -> escalate one recheck and reset
#     the window (bounded repeat, never a wedge).
# 3)  heartbeat catch-all: every CS_HEARTBEAT_SCAN_SECS scan state/*.status via
#     scan_boss_relevant_statuses for a line the per-wake path missed.
housekeeping() {  # <state>
  local state=$1 now due marker key task pane age last max_defer oldest pause_secs seen f
  now=$(_now)

  # (1) batch flush
  if [ "${CS_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}" -le 0 ]; then
    escalate_flush "$state" || true
  else
    due=$(_oldest_line_age "$state/.subsuper-escalations")
    if [ "$due" -ge "${CS_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}" ]; then
      escalate_flush "$state" || true
    fi
  fi

  # (1b) max-defer escape
  max_defer=${CS_MAX_DEFER_SECS:-$MAX_DEFER_SECS_DEFAULT}
  if afk_active "$state" && [ "$max_defer" -gt 0 ] && [ -s "$state/.subsuper-escalations" ]; then
    oldest=$(_oldest_line_age "$state/.subsuper-escalations")
    if [ "$oldest" -ge "$max_defer" ] \
       && [ "$(_file_age "$state/.subsuper-inject-wedged")" -ge "$max_defer" ]; then
      if escalate_flush "$state"; then
        log "inject recovered: max-defer flush succeeded after ${oldest}s undelivered"
        rm -f "$state/.subsuper-inject-wedged"
      else
        inject_wedge_alarm "$state" "$oldest"
      fi
    fi
  fi

  # (2) stale persistence recheck
  for marker in "$state"/.subsuper-stale-*; do
    [ -e "$marker" ] || continue
    key="${marker##*.subsuper-stale-}"
    pane=$(pane_for_task "$key" "$state" 2>/dev/null || true)
    if [ -z "$pane" ]; then
      rm -f "$marker"; continue      # task torn down: nothing to escalate
    fi
    task=$(pane_to_task "$pane" "$state")
    last=$(last_status_line "$state/$task.status")
    if [ -n "$last" ] && status_is_paused "$last"; then
      reconcile_pause_tracking "$pane" "$state" "$last"
      continue
    fi
    age=$(( now - $(cat "$marker" 2>/dev/null || echo "$now") ))
    [ "$age" -ge "${CS_STALE_ESCALATE_SECS:-$STALE_ESCALATE_SECS_DEFAULT}" ] || continue
    stale_pane_is_busy "$pane"
    case "$?" in
      0) rm -f "$marker" ;;
      2) rm -f "$marker" ;;
      *) escalate_add "$state" "stale persisted ${age}s (possible wedge): $pane"
         stale_marker_remove "$pane" "$state" ;;
    esac
  done

  # (2b) pause re-surface recheck
  pause_secs=${CS_PAUSE_RESURFACE_SECS:-$CS_PAUSE_RESURFACE_SECS_DEFAULT}
  for marker in "$state"/.subsuper-paused-*; do
    [ -e "$marker" ] || continue
    key="${marker##*.subsuper-paused-}"
    pane=$(pane_for_task "$key" "$state" 2>/dev/null || true)
    if [ -z "$pane" ]; then
      rm -f "$marker"; continue
    fi
    task=$(pane_to_task "$pane" "$state")
    last=$(last_status_line "$state/$task.status")
    if [ -z "$last" ] || ! status_is_paused "$last"; then
      reconcile_pause_tracking "$pane" "$state" "$last"
      continue
    fi
    age=$(( now - $(cat "$marker" 2>/dev/null || echo "$now") ))
    [ "$age" -ge "$pause_secs" ] || continue
    stale_pane_is_busy "$pane"
    case "$?" in
      0) rm -f "$marker" ;;
      2) rm -f "$marker" ;;
      *)
        last=$(last_status_line "$state/$task.status")
        if [ -n "$last" ] && status_is_paused "$last"; then
          escalate_add "$state" "paused ${age}s (awaiting external, recheck whether the wait still holds): $pane"
          _now > "$marker"
        else
          rm -f "$marker"
        fi
        ;;
    esac
  done

  # (3) heartbeat catch-all scan (shared classifier's fleet scan; daemon
  #     layers its digest dedupe on top). Cheap: status files only.
  if [ "$(_file_age "$state/.subsuper-last-scan")" -ge "${CS_HEARTBEAT_SCAN_SECS:-$HEARTBEAT_SCAN_SECS_DEFAULT}" ]; then
    _now > "$state/.subsuper-last-scan"
    while IFS="$(printf '\t')" read -r f task last; do
      [ -n "$f" ] || continue
      seen="$state/.subsuper-seen-status-$(_stale_key "$task")"
      [ "$(cat "$seen" 2>/dev/null || true)" = "$last" ] && continue
      escalate_add "$state" "$(basename "$f"): $last (catch-all scan)"
      mark_status_seen "$state" "$task" "$last"
    done < <(scan_boss_relevant_statuses "$state")
  fi
}

# --- injection -----------------------------------------------------------------
# daemon_target_pane: the ONE injection target - CS_SUPERVISOR_PANE, else
# state/.subsuper-target (recorded by cs-afk-start / daemon startup).
daemon_target_pane() {  # <state>
  local state=$1 pane
  pane="${CS_SUPERVISOR_PANE:-}"
  [ -n "$pane" ] || pane=$(cat "$state/.subsuper-target" 2>/dev/null || true)
  [ -n "$pane" ] || return 1
  printf '%s' "$pane"
}

# inject_msg: send one escalation digest into the supervisor pane. 0 on a
# confirmed submit; non-zero when the pane is gone, busy, the composer is not
# affirmatively empty, afk is inactive, or the submit cannot be confirmed. On
# non-zero the caller preserves the buffer.
inject_msg() {  # <message> [state]
  local msg=$1 state pane bs composer retries wait_ms attempt
  state="${2:-$(_state_root)}"
  # (1) Presence-gate: inject ONLY while afk is active.
  afk_active "$state" || { log "inject deferred: afk inactive"; return 1; }
  pane=$(daemon_target_pane "$state") || { log "inject failed: no supervisor pane recorded"; return 1; }
  # (2) Single-line digest, then the typed away-supervisor envelope.
  msg=$(_collapse_newlines "$msg")
  cs_operational_input_construct away-supervisor "$msg" msg
  cs_herdr_pane_exists "$pane" || { log "inject deferred: supervisor pane '$pane' gone"; return 1; }
  # (3) Busy-guard: never inject into a mid-turn or human-blocked pane.
  bs=$(cs_herdr_agent_busy_state "$pane" 2>/dev/null) || bs=unknown
  case "$bs" in
    busy|blocked)
      log "inject deferred: supervisor pane busy (agent state=$bs)"
      return 1 ;;
  esac
  # (4) Composer-guard: only an affirmatively EMPTY codex composer is a safe
  # target. 'pending' protects half-typed or swallowed input; 'unknown'
  # protects unreadable panes and dead-shell prompts. Both defer.
  composer=$(cs_composer_state "$pane" 2>/dev/null)
  if [ "$composer" != empty ]; then
    log "inject deferred: supervisor composer not confirmed-empty (state=${composer:-unknown})"
    return 1
  fi
  # (5) Type ONCE, then submit with Enter; retry Enter only, never retype.
  # Native confirmation: the agent's idle->working transition.
  if ! cs_herdr_send_text "$pane" "$msg" >/dev/null 2>&1; then
    log "inject failed: send-text to '$pane' failed"
    return 1
  fi
  retries=${CS_INJECT_CONFIRM_RETRIES:-$INJECT_CONFIRM_RETRIES_DEFAULT}
  wait_ms=${CS_INJECT_CONFIRM_WAIT_MS:-$INJECT_CONFIRM_WAIT_MS_DEFAULT}
  attempt=0
  while [ "$attempt" -le "$retries" ]; do
    cs_herdr_send_keys "$pane" Enter >/dev/null 2>&1 || true
    if cs_herdr_submit_confirm "$pane" "$wait_ms"; then
      return 0
    fi
    attempt=$((attempt + 1))
  done
  log "inject failed: submit unconfirmed after $retries Enter retries (text may be in composer)"
  return 1
}

# --- CS_INJECT_SKIP prefix match (literal prefixes, no regex) ------------------
should_force_self() {  # <reason>
  local reason=$1 skip="${CS_INJECT_SKIP:-$INJECT_SKIP_DEFAULT}" prefix
  [ -n "$skip" ] || return 1
  local -a prefixes
  IFS='|' read -ra prefixes <<<"$skip"
  for prefix in "${prefixes[@]}"; do
    [ -n "$prefix" ] || continue
    [ "$reason" != "${reason#"$prefix"}" ] && return 0
  done
  return 1
}

# A real watcher WAKE reason starts with one of these prefixes. Anything else
# on the child's stdout (e.g. "watcher: already running" on a singleton-lock
# collision) is a STATUS line, not a wake: the main loop treats it as idle
# (log + sleep + continue) so a collision cannot hot-loop escalations.
is_wake_reason() {  # <reason>
  case "$1" in
    signal:*|stale:*|check:*|heartbeat|heartbeat:*) return 0 ;;
  esac
  return 1
}

# --- dispatch one wake reason to self-handle or escalate -----------------------
handle_wake() {  # <reason> <state>
  local reason=$1 state=$2 decision action distilled pane last _clear_wedge
  local kind="" arg=""
  if should_force_self "$reason"; then
    log "wake force-self (CS_INJECT_SKIP): $reason"
    return
  fi
  case "$reason" in
    signal:*) kind=signal; arg="${reason#signal:}"; arg="${arg# }"
              decision=$(classify_signal "$arg" "$state") ;;
    stale:*)  kind=stale; arg="${reason#stale:}"; arg="${arg# }"
              decision=$(classify_stale "$(_stale_pane_of "$arg")" "$state") ;;
    check:*)  decision=$(classify_check "$reason") ;;
    heartbeat|heartbeat:*) decision=$(classify_heartbeat) ;;
    *)        decision=$(classify_unknown "$reason") ;;
  esac
  action=${decision%%|*}
  distilled=${decision#*|}
  [ "$kind" = signal ] && sync_pause_markers_from_signal "$state" "$arg"
  case "$action" in
    escalate)
      log "escalate: $reason -> $distilled"
      escalate_add "$state" "$distilled"
      # A terminal-stale escalate must not leave a persistence marker behind,
      # or housekeeping re-escalates the same pane as a false wedge later.
      [ "$kind" = "stale" ] && stale_marker_remove "$(_stale_pane_of "$arg")" "$state"
      mark_escalated_seen "$kind" "$arg" "$state"
      [ "${CS_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}" -le 0 ] && { escalate_flush "$state" || true; }
      ;;
    pause)
      # Declared external-wait pause: long re-surface cadence, never a wedge.
      if [ "$kind" = "stale" ]; then
        pane=$(_stale_pane_of "$arg")
        stale_marker_remove "$pane" "$state"
        pause_marker_record "$pane" "$state"
      fi
      log "self-handle (paused): $reason -> $distilled"
      ;;
    *)
      # Transient (non-terminal) stale: record/refresh the wedge marker so
      # housekeeping can age it; drop any pause marker (a crew that left its
      # pause reverts to normal wedge aging). Persistence, not this wake,
      # escalates a wedge.
      if [ "$kind" = "stale" ]; then
        pane=$(_stale_pane_of "$arg")
        last=$(last_status_line "$state/$(pane_to_task "$pane" "$state").status")
        _clear_wedge=0
        if [ -n "$last" ] && status_is_boss_relevant "$last"; then
          if status_is_terminal_verb "$last"; then
            _clear_wedge=1
          else
            case "$(status_line_verb "$last")" in
              working|resolved|captain-held) _clear_wedge=0 ;;
              *) _clear_wedge=1 ;;
            esac
          fi
        fi
        if [ "$_clear_wedge" = 1 ]; then
          stale_marker_remove "$pane" "$state"
        else
          pause_marker_remove "$pane" "$state"
          stale_marker_record "$pane" "$state"
        fi
      fi
      log "self-handle: $reason -> $distilled"
      ;;
  esac
}

# --- log -----------------------------------------------------------------------
# Uses LOG set by cs_daemon_main; a harmless no-op when unset (tests source
# the pure functions and pass state explicitly).
log() { [ -n "${LOG:-}" ] && printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

trim_log() {
  local sz tmp
  [ -n "${LOG:-}" ] || return 0
  sz=$(wc -c < "$LOG" 2>/dev/null) || return 0
  [ "$sz" -ge "${CS_LOG_MAX_BYTES:-$LOG_MAX_BYTES_DEFAULT}" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/cs-daemon-log.XXXXXX") || return 0
  tail -n "${CS_LOG_KEEP_LINES:-$LOG_KEEP_LINES_DEFAULT}" "$LOG" >"$tmp" 2>/dev/null && mv -f "$tmp" "$LOG"
}

# ==============================================================================
# Everything below runs only when the script is EXECUTED, not sourced. The pure
# classifiers above are sourceable for unit tests.
# ==============================================================================

cs_daemon_main() {
  local STATE
  STATE="$(_state_root)"
  mkdir -p "$STATE"

  # Portable lock helpers (no flock on macOS). Export the state override so
  # the lib resolves the same state dir.
  # shellcheck source=bin/cs-wake-lib.sh
  CS_STATE_OVERRIDE="$STATE" . "$CS_DAEMON_DIR/cs-wake-lib.sh"

  local WATCH="${CS_WATCH_BIN:-$CS_DAEMON_DIR/cs-watch.sh}"
  local LOG="$STATE/.subsuper-daemon.log"
  local WATCH_ERR="$STATE/.subsuper-daemon.watcher.err"
  local LOCK="$STATE/.subsuper-daemon.lock"
  local PIDFILE="$STATE/.subsuper-daemon.pid"
  local INJECT_FAIL_SLEEP=${CS_INJECT_FAIL_SLEEP:-$INJECT_FAIL_SLEEP_DEFAULT}
  local CRASH_THRESHOLD=${CS_CRASH_THRESHOLD:-$CRASH_THRESHOLD_DEFAULT}
  local CRASH_WINDOW=${CS_CRASH_WINDOW:-$CRASH_WINDOW_DEFAULT}
  local CRASH_BACKOFF=${CS_CRASH_BACKOFF:-$CRASH_BACKOFF_DEFAULT}
  local CRASH_NORMAL_SLEEP=${CS_CRASH_NORMAL_SLEEP:-$CRASH_NORMAL_SLEEP_DEFAULT}

  [ -x "$WATCH" ] || { echo "error: watcher not found or not executable: $WATCH" >&2; exit 1; }

  # --- single instance (portable lock, no flock dependency) ------------------
  if ! cs_lock_try_acquire "$LOCK"; then
    if [ -n "${CS_LOCK_HELD_PID:-}" ]; then
      echo "error: another cs-daemon is already running (pid $CS_LOCK_HELD_PID, lock $LOCK held)" >&2
    else
      echo "error: another cs-daemon is already running (lock $LOCK held)" >&2
    fi
    exit 1
  fi
  echo "$$" > "$PIDFILE"
  cs_pid_identity "${BASHPID:-$$}" > "$LOCK/pid-identity" 2>/dev/null || true

  # --- resolve the single injection target pane ------------------------------
  # argv[1] > CS_SUPERVISOR_PANE > state/.subsuper-target (from cs-afk-start).
  local PANE
  PANE="${1:-${CS_SUPERVISOR_PANE:-}}"
  [ -n "$PANE" ] || PANE=$(cat "$STATE/.subsuper-target" 2>/dev/null || true)
  if [ -z "$PANE" ]; then
    echo "error: no supervisor pane; pass a pane id, set CS_SUPERVISOR_PANE, or run bin/cs-afk-start.sh from consigliere's own herdr pane" >&2
    cs_lock_release "$LOCK" 2>/dev/null || true
    rm -f "$PIDFILE" 2>/dev/null || true
    exit 1
  fi
  if ! cs_herdr_pane_exists "$PANE"; then
    echo "error: supervisor pane '$PANE' does not resolve to a herdr pane" >&2
    log "startup failed: pane '$PANE' not found"
    cs_lock_release "$LOCK" 2>/dev/null || true
    rm -f "$PIDFILE" 2>/dev/null || true
    exit 1
  fi
  printf '%s\n' "$PANE" > "$STATE/.subsuper-target"
  export CS_SUPERVISOR_PANE="$PANE"

  local afk_status="off"
  afk_active "$STATE" && afk_status="on"
  log "daemon starting (pid $$); pane=$PANE; afk=$afk_status; inject_skip='${CS_INJECT_SKIP:-$INJECT_SKIP_DEFAULT}'; stale_escalate=${CS_STALE_ESCALATE_SECS:-$STALE_ESCALATE_SECS_DEFAULT}s; batch=${CS_ESCALATE_BATCH_SECS:-$ESCALATE_BATCH_SECS_DEFAULT}s; max_defer=${CS_MAX_DEFER_SECS:-$MAX_DEFER_SECS_DEFAULT}s"

  # --- shutdown: flush buffered escalations, reap child, release lock --------
  local WATCHER_PID="" CUR_TMP=""
  cleanup() {
    trap - TERM INT
    wedge_alarm_stop_active_notifier
    # Best-effort flush; a still-guarded pane keeps the buffer in
    # state/.subsuper-escalations for the return catch-up.
    escalate_flush "$STATE" 2>/dev/null || true
    if [ -n "${WATCHER_PID:-}" ]; then
      kill "$WATCHER_PID" 2>/dev/null || true
      wait "$WATCHER_PID" 2>/dev/null || true
    fi
    if [ -n "${CUR_TMP:-}" ]; then
      rm -f "$CUR_TMP" 2>/dev/null || true
    fi
    cs_lock_release "$LOCK" 2>/dev/null || true
    rm -f "$PIDFILE" 2>/dev/null || true
    log "daemon shutting down"
    exit 0
  }
  trap cleanup TERM INT

  # --- crash-loop guard -------------------------------------------------------
  local crash_times=() backoff_secs=$CRASH_NORMAL_SLEEP
  record_crash() {
    local now t
    now=$(_now)
    local -a keep=()
    for t in "${crash_times[@]:-}"; do
      [ -n "$t" ] && [ $((now - t)) -lt "$CRASH_WINDOW" ] && keep+=("$t")
    done
    keep+=("$now")
    crash_times=("${keep[@]}")
    if [ "${#crash_times[@]}" -gt "$CRASH_THRESHOLD" ]; then
      log "ERROR: watcher crashed ${#crash_times[@]} times within ${CRASH_WINDOW}s; backing off ${CRASH_BACKOFF}s"
      crash_times=()
      backoff_secs=$CRASH_BACKOFF
    else
      backoff_secs=$CRASH_NORMAL_SLEEP
    fi
  }

  start_watcher() {
    CUR_TMP=$(mktemp "${TMPDIR:-/tmp}/cs-watch.XXXXXX") || { log "error: mktemp failed; retrying in 5s"; sleep 5; return 1; }
    "$WATCH" >"$CUR_TMP" 2>>"$WATCH_ERR" &
    WATCHER_PID=$!
  }

  local rc reason
  while true; do
    # --- pane-gone guard -----------------------------------------------------
    # Self-handling needs no pane, but escalation has nowhere to go without
    # one, and consigliere itself is the consumer. Back off; catch-up signals
    # persist in state/*.status and the durable wake queue, so this delays
    # rather than loses work.
    if ! cs_herdr_pane_exists "$PANE"; then
      log "warn: supervisor pane '$PANE' gone; backing off ${INJECT_FAIL_SLEEP}s, will retry"
      sleep "$INJECT_FAIL_SLEEP"
      continue
    fi

    # --- (re)start watcher if it has exited ----------------------------------
    if [ -z "${WATCHER_PID:-}" ] || ! kill -0 "${WATCHER_PID:-}" 2>/dev/null; then
      if [ -n "${WATCHER_PID:-}" ]; then
        if wait "${WATCHER_PID}"; then rc=0; else rc=$?; fi
        reason=""
        if [ -n "${CUR_TMP:-}" ] && [ -e "${CUR_TMP:-}" ]; then
          reason=$(<"${CUR_TMP}")
        fi
        if [ -n "${CUR_TMP:-}" ]; then
          rm -f "${CUR_TMP}" 2>/dev/null || true
        fi
        CUR_TMP=""
        if [ "$rc" -ne 0 ] || [ -z "$reason" ]; then
          record_crash
          log "watcher exited rc=$rc reason='$reason'; restarting after ${backoff_secs}s"
          WATCHER_PID=""
          sleep "$backoff_secs"
          continue
        fi
        # Non-wake stdout (e.g. a watcher singleton-collision status line) is
        # NOT a wake: idle here, no crash accounting, no escalation flood.
        if ! is_wake_reason "$reason"; then
          log "watcher non-wake stdout, idling: $reason"
          WATCHER_PID=""
          sleep "${CS_HOUSEKEEPING_TICK:-$HOUSEKEEPING_TICK_DEFAULT}"
          continue
        fi
        log "wake: $reason"
        handle_wake "$reason" "$STATE"
        trim_log
      fi
      start_watcher || continue
    fi

    # --- one housekeeping tick, then poll -------------------------------------
    sleep 1
    if [ "$(_file_age "$STATE/.subsuper-last-housekeep")" -ge "${CS_HOUSEKEEPING_TICK:-$HOUSEKEEPING_TICK_DEFAULT}" ]; then
      _now > "$STATE/.subsuper-last-housekeep"
      housekeeping "$STATE"
    fi
  done
}

# Run only when executed, not when sourced (tests source the classifiers).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cs_daemon_main "$@"
else
  # Library mode (only tests source this file): make it structurally
  # impossible for a sourced context to fire a real desktop notification.
  # Exported so a real daemon a test later spawns inherits the safe default.
  : "${CS_WEDGE_ALARM_EXEC:=discard}"
  export CS_WEDGE_ALARM_EXEC
fi
