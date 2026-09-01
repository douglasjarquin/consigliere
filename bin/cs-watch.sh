#!/usr/bin/env bash
# Consigliere watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal and stale path is absorb-only-when-provably-working: a wake
# is absorbed only when the soldier shows POSITIVE evidence it is still working
# (an actively-running made validation step, or herdr's native busy signal), and
# surfaced otherwise, so a soldier that finishes (or stops and waits) without a
# current working signal is never silently swallowed. A declared external-wait
# pause is the separate idle absorb case and re-surfaces only on its long
# bounded cadence, although its initial no-verb status signal still surfaces in
# normal mode. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a boss-relevant verb OR a no-verb signal's soldier
#                          is not provably working
#   stale: <pane>          a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a boss-relevant log
#                          line, since the soldier's own log gets no new entry once
#                          consigliere hands it to a made validation. A declared
#                          external-wait pause is absorbed instead with its own long
#                          re-surface cadence, never as a wedge. Only when neither
#                          absorb class applies does the log's last line decide:
#                          terminal (boss-relevant) or non-terminal (no verb),
#                          both surfaced at once. A provably-working stale past the
#                          wedge threshold also surfaces, with an "escalation N"
#                          count in the reason; at CS_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume. A pane whose native herdr agent state reads
#                          `blocked` (waiting on the human: a trust dialog, an
#                          interactive menu, a wedged prompt) is surfaced
#                          IMMEDIATELY as a stale wake - sub-second from the
#                          herdr plugin event spool when this home has it, and
#                          via the poll loop's level read otherwise - never left
#                          to the wedge timer.
#   check: <script>: <out> authenticated check output, always actionable
#   check: rejected unauthenticated state checks: <paths>
#                          unsafe state checks were refused without execution
#   heartbeat              fleet-scan backstop found an unsurfaced boss-relevant
#                          status
# For normal supervision, resume the supervision protocol after each printed
# reason. Direct duplicate invocations of this script still no-op through the
# watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
mkdir -p "$STATE"

# Durable wake queue + portable lock helpers (cs_wake_append, cs_lock_try_acquire,
# cs_lock_release, cs_path_age), plus cs_pid_identity, which bin/cs-wake-lib.sh
# re-exports from its owner bin/cs-session-pid-lib.sh.
# shellcheck source=bin/cs-wake-lib.sh
. "$SCRIPT_DIR/cs-wake-lib.sh"
# Shared wake classifier (boss-relevant verbs + signal/stale/heartbeat
# predicates), so the triage policy has one definition.
# shellcheck source=bin/cs-classify-lib.sh
. "$SCRIPT_DIR/cs-classify-lib.sh"
# The one herdr layer: captures and native agent busy-state (codex corroboration
# built in). This watcher's poll loop over those pull primitives synthesizes the
# signal/stale/check/heartbeat wake vocabulary; when this home's herdr event
# plugin is installed the watcher additionally replaces its blind terminal sleep
# with a bounded wait on the spooled pane.agent_status_changed edges
# (event_wait_or_sleep below), so a soldier entering `blocked` wakes its
# supervisor sub-second; the poll loop stays live every cycle as the permanent
# fail-closed backstop.
# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# The spool the herdr plugin hook appends to, and its cursor drain
# (bin/cs-herdr-event-plugin.sh installs the plugin that feeds it).
# shellcheck source=bin/cs-herdr-event-lib.sh
. "$SCRIPT_DIR/cs-herdr-event-lib.sh"
# The one made-CLI layer (made status --json, etc.) - made_run_state below
# calls cs_made_status through here, mirroring cs-herdr-lib.sh's own
# separation of concerns for herdr.
# shellcheck source=bin/cs-made-lib.sh
. "$SCRIPT_DIR/cs-made-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"
# PR merge-poll artifact validation (byte-static poll published by cs-pr-check).
# shellcheck source=bin/cs-pr-lib.sh
. "$SCRIPT_DIR/cs-pr-lib.sh"
# Custom-check trust validation (hash-bound snapshots; cs-check-register).
# shellcheck source=bin/cs-check-lib.sh
. "$SCRIPT_DIR/cs-check-lib.sh"
# Armed blocking sources: the per-cycle reconcile predicate only. The runner
# itself (bin/cs-procevent.sh) is invoked as a separate process, never inline,
# so a blocking source can never run inside this watcher.
# shellcheck source=bin/cs-procevent-lib.sh
. "$SCRIPT_DIR/cs-procevent-lib.sh"
# Parent-owned capo missed-report guards (optional until the library lands;
# the tick below is skipped when the function is absent).
if [ -f "$SCRIPT_DIR/cs-pending-reply-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/cs-pending-reply-lib.sh"
fi

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/cs-watch.sh"
WATCHER_STALE_GRACE=${CS_WATCHER_STALE_GRACE:-${CS_GUARD_GRACE:-300}}
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes the runtime.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
  stat_sig()   { stat -f '%z:%Fm' "$1" 2>/dev/null; }   # size:mtime signature
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_sig()   { stat -c '%s:%Y' "$1" 2>/dev/null; }
fi

POLL=${CS_POLL:-15}                   # seconds between cycles
HEARTBEAT=${CS_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${CS_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${CS_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${CS_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
SIGNAL_GRACE=${CS_SIGNAL_GRACE:-30}   # seconds to linger after a NO-VERB signal so
                                      # trailing signals (a status write, then the same
                                      # turn's turn-end hook) coalesce into one wake
SIGNAL_GRACE_ACTIONABLE=${CS_SIGNAL_GRACE_ACTIONABLE:-3}
                                      # the shorter grace for a signal already carrying a
                                      # boss-relevant verb: that wake is surfacing either
                                      # way, so it needs only long enough to coalesce the
                                      # same turn's turn-end hook (which lands ~1s after
                                      # the status write), not the full no-verb grace.
                                      # Every extra second here is added latency on a
                                      # decision the boss is already waiting for.
# Busy signature fallback for the rare cycle where herdr's native agent state
# reads unknown. Consigliere is codex-only, so the single codex signature owned
# by cs-herdr-lib.sh is the default; CS_BUSY_REGEX overrides.
BUSY_REGEX=${CS_BUSY_REGEX:-$CS_CODEX_BUSY_RE}
# Always-on wake triage: most wakes during a long soldier validation are benign
# (a working: note or turn-end while a pipeline runs, a no-change heartbeat).
# Rather than wake consigliere's LLM for each, this watcher classifies every
# wake in bash and ABSORBS the benign majority - it advances the suppression
# marker, logs to a debug log, and keeps blocking WITHOUT enqueuing or exiting.
# The no-verb signal / stale path is absorb-only-when-provably-working: such a
# wake is absorbed ONLY while the soldier shows positive evidence it is still
# working (an actively-running made validation step - a `made status --json`
# socket query, never scraped log text, see made_run_state below - or a busy
# pane, via crew_is_provably_working over cs-crew-state.sh); a soldier that stopped its
# turn with no running pipeline and no busy pane is SURFACED, so a finish
# reported only through interactive pane menus (no done: status) is never
# swallowed. An ACTIONABLE wake (a boss-relevant signal, a no-verb signal whose
# soldier is not provably working, any check, a stale pane whose soldier is not
# provably working, a provably-working stale past the threshold, or anything
# unknown) is written to the durable queue and exits, which is what wakes the
# LLM through the background-task completion.
STALE_ESCALATE_SECS=${CS_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale escalates as a possible wedge
# A busy pane is otherwise UNBOUNDED proof of liveness: the whole stale/wedge
# machinery below is skipped while pane_is_busy holds, and a busy pane's hash
# keeps changing anyway (the harness renders a ticking elapsed counter), so no
# stale hash ever repeats. A hung foreground tool call is therefore invisible
# for as long as it hangs. (Upstream firstmate hit exactly this in 2026-07: a
# catastrophic-backtracking regex hung one bash call for 25 hours behind an
# unchanging "Working..." footer, with no escalation the entire time.)
#
# CS_BUSY_TURN_MAX_SECS bounds how long a pane may run busy with NO COMPLETED
# TURN. The reference is state/<id>.turn-ended, touched by the harness turn-end
# hook at every turn end, falling back to the spawn record before any turn has
# completed. Past the bound the pane enters the ordinary wedge timer and so
# reuses the identical stale reason, escalation counter, and
# demand-deep-inspection marker as every other wedge.
#
# This is for HUMAN INSPECTION only. Nothing here interrupts, signals, or
# restarts the soldier or its tool process; a genuinely long turn is surfaced,
# not killed. Any completed turn resets the age.
BUSY_TURN_MAX_SECS=${CS_BUSY_TURN_MAX_SECS:-3600}
# A soldier that declared a pause is idling on a known external wait, so its
# stale pane is absorbed rather than wedge-escalated.
# A boss-held or paused soldier whose agent has confidently exited uses the same
# bounded cadence, while a live or ambiguously read agent still surfaces once.
# These cases re-surface once for a recheck every PAUSE_RESURFACE_SECS - far
# longer than the wedge threshold, but finite so a forgotten hold cannot rot invisibly.
PAUSE_RESURFACE_SECS=${CS_PAUSE_RESURFACE_SECS:-$CS_PAUSE_RESURFACE_SECS_DEFAULT}
TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${CS_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}

# Append one line to the triage debug log explaining an absorbed (benign) wake,
# size-capped so a long benign stretch cannot grow it without bound. Best-effort:
# a logging hiccup never affects supervision.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# made_run_state: the OTHER form of positive evidence a soldier is still
# working (see the "Always-on wake triage" note above) - an actively-running
# or queued `made` validation run - read directly from made's structured
# socket state (cs_made_status, bin/cs-made-lib.sh) rather than inferred from
# any scraped log/status text. running/queued -> busy; completed/failed ->
# idle. A query that fails for ANY reason (made not installed, daemon not
# running, socket unreachable, unparseable JSON) reports the DISTINCT
# `unreachable` state - never silently treated as idle or busy, and never a
# fallback to stale scraped content (plans/made-rewrite.md Task 28).
made_run_state() {  # [run-id] -> busy|idle|unreachable
  local json state
  json=$(cs_made_status "${1:-}" 2>/dev/null) || { printf 'unreachable'; return 0; }
  [ -n "$json" ] || { printf 'unreachable'; return 0; }
  state=$(printf '%s' "$json" | jq -r '.state // empty' 2>/dev/null) || { printf 'unreachable'; return 0; }
  case "$state" in
    running|queued)   printf 'busy' ;;
    completed|failed) printf 'idle' ;;
    *)                printf 'unreachable' ;;
  esac
}

# made_run_is_busy: 0 iff made_run_state (above) reports busy (running/queued).
made_run_is_busy() {  # [run-id]
  [ "$(made_run_state "${1:-}")" = busy ]
}

# pane_busy_state: one native busy-state read per pane per poll, shared by the
# immediate blocked escalation and the stale machinery. cs_herdr_agent_busy_state
# owns the codex corroboration policy (a native idle/unknown is re-checked
# against the rendered busy signature before a soldier may be read as stopped).
# One session snapshot per poll cycle, refreshed by snapshot_refresh at the top
# of the loop. Empty means "no snapshot this cycle" and every read falls back to
# a per-pane query - the pre-snapshot behavior, never a wrong answer.
CS_WATCH_SNAPSHOT=""

snapshot_refresh() {
  CS_WATCH_SNAPSHOT=$(cs_herdr_snapshot_fetch 2>/dev/null) || CS_WATCH_SNAPSHOT=""
}

pane_busy_state() {  # <pane> -> busy|idle|blocked|done|unknown
  local raw=""
  # Prefer this cycle's snapshot: it already answered every pane in one call.
  # A pane ABSENT from the snapshot is not a negative answer - it may have been
  # created after the snapshot was taken - so that falls through to asking
  # directly rather than being read as idle.
  if [ -n "$CS_WATCH_SNAPSHOT" ]; then
    raw=$(cs_herdr_snapshot_pane_field "$CS_WATCH_SNAPSHOT" "$1" agent_status 2>/dev/null) || raw=""
  fi
  if [ -n "$raw" ]; then
    # Same corroboration policy, same owner, different transport.
    cs_herdr_busy_state_from_raw "$1" "$raw" 2>/dev/null || printf 'unknown'
    return 0
  fi
  cs_herdr_agent_busy_state "$1" 2>/dev/null || printf 'unknown'
}

# pane_is_busy: 0 (busy) iff the pane's harness is actively working, from the
# busy-state token already read this poll. `blocked` counts as busy HERE so the
# stale hash machinery stays quiet for it - the immediate blocked escalation
# path (not the wedge timer) owns surfacing a blocked pane. The regex fallback
# runs only on an unknown reading, over the last 6 non-blank lines of the same
# bounded capture already read for hashing (the TUI footer area) so busy-looking
# strings in displayed content cannot suppress stale detection.
pane_is_busy() {  # <busy-state> <tail40>
  case "$1" in
    busy|blocked) return 0 ;;
    idle|done) return 1 ;;
    *)
      printf '%s' "$2" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"
      ;;
  esac
}

# meta_for_pane: the state/<id>.meta whose pane= field matches <pane>.
meta_for_pane() {  # <pane>
  local p=$1 meta mp
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    mp=$(cs_meta_get "$meta" pane 2>/dev/null) || continue
    [ "$mp" = "$p" ] || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

pane_kind() {  # <pane> -> ship|scout|capo|unknown
  local p=$1 meta kind
  meta=$(meta_for_pane "$p" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(cs_meta_get "$meta" kind 2>/dev/null) || kind=
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# 0 if <pane>'s task is a headless scout (meta headless=1). A headless scout runs
# non-interactively (codex exec / claude -p) and presents no TUI activity, so the
# interactive stale-triage heuristics do not apply to it while it runs.
pane_is_headless() {  # <pane>
  local p=$1 meta
  meta=$(meta_for_pane "$p" 2>/dev/null || true)
  [ -n "$meta" ] || return 1
  [ "$(cs_meta_get "$meta" headless 2>/dev/null || true)" = 1 ]
}

# pane_agent_state: CONFIDENT liveness of a real codex agent in the pane, for
# the pause reconciliation below. Only a successful agent read showing no agent
# is `dead`; an unreadable pane (server down, pane gone) is `unknown`, so an
# ambiguous read never recovers the bounded pause cadence.
pane_agent_state() {  # <pane> -> alive|dead|unknown
  local out
  out=$(cs_herdr agent get "$1" 2>/dev/null) || { printf 'unknown'; return 0; }
  if printf '%s' "$out" | jq -e '.result.agent.agent // empty | select(. != "")' >/dev/null 2>&1; then
    printf 'alive'
  else
    printf 'dead'
  fi
}

recorded_panes() {
  local meta p seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    p=$(cs_meta_get "$meta" pane 2>/dev/null) || continue
    [ -n "$p" ] || continue
    case "$seen" in
      *"|$p|"*) continue ;;
    esac
    seen="$seen|$p|"
    printf '%s\n' "$p"
  done
}

# Exit reporting a wake. Consecutive heartbeats with no other wake in between
# mean an idle fleet, so the heartbeat interval backs off exponentially
# (base * 2^streak, capped at HEARTBEAT_MAX); any real wake resets the cadence.
wake() {
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  echo "$1"
  exit 0
}

# Consecutive wedge-escalation count for a pane past CS_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a pane's
# hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
CS_WEDGE_DEMAND_INSPECT_COUNT=${CS_WEDGE_DEMAND_INSPECT_COUNT:-3}

# busy_turn_age <task>: seconds since this task last COMPLETED a turn, or rc=1
# when that cannot be read. See CS_BUSY_TURN_MAX_SECS above for why a busy pane
# needs a bound at all.
#
# state/<id>.turn-ended is touched by the harness turn-end hook (codex notify /
# claude Stop) at every turn end, so its mtime is the last completed turn. Before
# any turn has completed it does not exist yet, and the spawn record stands in -
# otherwise a soldier that hangs inside its very first turn would have no
# reference at all and would be exempt from the bound for good.
busy_turn_age() {  # <task> -> seconds since last completed turn
  local task=$1 ref since
  [ -n "$task" ] || return 1
  ref="$STATE/$task.turn-ended"
  [ -e "$ref" ] || ref="$STATE/$task.meta"
  [ -e "$ref" ] || return 1
  since=$(stat_mtime "$ref") || return 1
  case "$since" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$(( $(date +%s) - since ))"
}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Never re-reads the soldier
# state (the costly check already ran once, at classification time). Shared by
# both places a hash can be absorbed this way: the plain non-terminal path,
# and the stale_is_terminal-overridden path (a boss-relevant status-log
# line that an active run/busy pane outranked).
wedge_timer_check() {  # <pane> <since-file> <triage-label> <escalation-count-file>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 since age n reason
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n)"
        if [ "$n" -ge "$CS_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
        fi
        cs_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        wake "$reason"
      fi
      ;;
  esac
}

# Absorb a stale pane under a declared external-wait pause (paused:) or a
# dead-agent boss-held transfer, and re-surface it once every
# PAUSE_RESURFACE_SECS for a recheck so it cannot rot invisibly. Called on any
# stale poll once pause_state_class permits the bounded cadence, so it must be
# cheap: it NEVER re-reads soldier state. The re-surface age is anchored on the
# status file mtime, not a per-hash marker, so a churny idle pane (a ticking
# clock, a token counter) cannot keep resetting the cadence the way a hash-tied
# timer would. A .paused-resurfaced-<key> throttle marker records the last
# re-surface epoch so, once past the window, it fires once per pane rather than
# every poll. Advances the stale suppressor to <hash> and flags the key paused.
handle_paused_stale() {  # <pane> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf mtime age rf rf_age reason
  key=$(printf '%s' "$win" | tr ':/.' '___')
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  rf="$STATE/.paused-resurfaced-$key"
  rf_age=$(age_of "$rf")   # 999999 when no prior re-surface
  if [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] && [ "$rf_age" -ge "$PAUSE_RESURFACE_SECS" ]; then
    reason="stale: $win (paused ${age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)"
    cs_wake_append stale "$win" "$reason" || exit 1
    date +%s > "$rf"
    wake "$reason"
  fi
  triage_log "absorbed stale (paused, awaiting external, age ${age}s): $win"
}

clear_pause_state() {  # <pane>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
}

clear_pause_tracking() {  # <pane>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  clear_pause_state "$win"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
}

# Reconcile a declared pause or boss-held status with authoritative soldier state.
# Only a confidently dead ordinary soldier may recover paused classification after
# cs-crew-state has fallen back to stopped or unknown.
pause_state_class() {  # <pane> <task>
  local win=$1 task=$2 key last recheck_file class agent_alive
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  last=$(last_status_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_is_paused_or_boss_held "$last"; then
    rm -f "$recheck_file"
    crew_absorb_class "$task"
    return
  fi
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    if [ "$(pane_kind "$win")" != capo ]; then
      agent_alive=$(pane_agent_state "$win")
      if [ "$agent_alive" != dead ]; then
        rm -f "$recheck_file"
        printf 'none'
        return
      fi
    fi
    printf 'paused'
    return
  fi
  class=$(crew_absorb_class "$task")
  if [ "$class" = working ]; then
    rm -f "$recheck_file"
    printf 'working'
    return
  fi
  if [ "$(pane_kind "$win")" != capo ]; then
    agent_alive=$(pane_agent_state "$win")
    if [ "$agent_alive" != dead ]; then
      rm -f "$recheck_file"
      printf 'none'
      return
    fi
  fi
  [ "$class" = none ] && [ "${agent_alive:-unknown}" = dead ] && class=paused
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

surface_nonterminal_stale() {  # <pane> <hash>
  local win=$1 h=$2 key task last
  key=$(printf '%s' "$win" | tr ':/.' '___')
  cs_wake_append stale "$win" "stale: $win" || exit 1
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key"
  task=$(pane_to_task "$win" "$STATE")
  last=$(last_status_line "$STATE/$task.status")
  if status_is_paused_or_boss_held "$last"; then
    : > "$STATE/.paused-$key"
    date +%s > "$STATE/.paused-rechecked-$key"
    date +%s > "$STATE/.paused-resurfaced-$key"
  else
    rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
  fi
  wake "stale: $win"
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

# The deduplicated file list of a scan_signals blob, as the space-separated,
# leading-space string the "signal:" wake reason and the classifier's file
# arguments both take. One owner so the pre-grace verb probe and the post-grace
# reason cannot disagree about which files a signal covers.
signal_files_of() {  # <pending-blob> -> " <file> <file> ..."
  local blob=$1 sf sig f files=""
  while IFS=$(printf '\t') read -r sf sig f; do
    [ -n "$sf" ] || continue
    case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
  done <<EOF
$blob
EOF
  printf '%s' "$files"
}

run_check_process() {
  local c=$1
  shift
  if [ "${CS_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$CHECK_TIMEOUT" bash "$c" "$@"
  elif [ "${CS_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$CHECK_TIMEOUT" bash "$c" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "${CS_CHECK_OWNED_GROUP:-0}" bash "$c" "$@"
  fi
}

run_check() {
  ( run_check_process "$@" ) 2>/dev/null || true
}

CS_ACTIVE_CHECK_PID=
CS_ACTIVE_CHECK_PGID=
CS_CHECK_OUTPUT=
CS_CHECK_RESULT=
CS_CHECK_SIGNAL_PENDING=

cs_check_output_cleanup() {
  [ -z "$CS_CHECK_OUTPUT" ] || rm -f -- "$CS_CHECK_OUTPUT"
  CS_CHECK_OUTPUT=
}

cs_active_check_stop() {
  local pid=${CS_ACTIVE_CHECK_PID:-} pgid=${CS_ACTIVE_CHECK_PGID:-} i
  [ -n "$pid" ] || [ -n "$pgid" ] || return 0
  [ -z "$pgid" ] || kill -TERM -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -z "$pgid" ] || kill -KILL -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  CS_ACTIVE_CHECK_PID=
  CS_ACTIVE_CHECK_PGID=
}

run_check_capture() {
  local pgid
  cs_check_output_cleanup
  CS_CHECK_RESULT=
  CS_CHECK_OUTPUT=$(mktemp "$STATE/.cs-check-output.XXXXXX") || return 1
  chmod 0600 "$CS_CHECK_OUTPUT" || { cs_check_output_cleanup; return 1; }
  CS_CHECK_SIGNAL_PENDING=
  trap 'CS_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  ( CS_CHECK_OWNED_GROUP=1 run_check_process "$@" ) > "$CS_CHECK_OUTPUT" 2>/dev/null &
  CS_ACTIVE_CHECK_PID=$!
  CS_ACTIVE_CHECK_PGID=$CS_ACTIVE_CHECK_PID
  set +m
  pgid=$(ps -o pgid= -p "$CS_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  trap 'exit 1' HUP INT TERM
  if [ -n "$pgid" ] && [ "$pgid" != "$CS_ACTIVE_CHECK_PGID" ]; then
    cs_active_check_stop || true
    cs_check_output_cleanup
    return 1
  fi
  [ -z "$CS_CHECK_SIGNAL_PENDING" ] || exit 1
  wait "$CS_ACTIVE_CHECK_PID" 2>/dev/null || true
  CS_ACTIVE_CHECK_PID=
  cs_active_check_stop || return 1
  CS_CHECK_RESULT=$(cat "$CS_CHECK_OUTPUT" 2>/dev/null || true)
  cs_check_output_cleanup
}

# Surfaced-marker bookkeeping for the heartbeat backstop. The watcher records the
# boss-relevant status line it SURFACED (woke consigliere for) in
# .hb-surfaced-<task>. Unlike .seen-* (a size:mtime signature advanced on BOTH
# surface and absorb), .hb-surfaced is advanced ONLY on surface, so the heartbeat
# fleet-scan can tell apart a boss-relevant status that already woke consigliere
# from one that has not - the latter being a per-wake-path miss it must surface.
_hb_surfaced_path() { printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"; }

# Record a status file's boss-relevant last line as surfaced (no-op for a
# non-boss-relevant or empty status). Call AFTER the wake is enqueued, so the
# enqueue-before-suppress ordering holds for this marker too.
mark_surfaced() {  # <status-file>
  local f=$1 task last
  task=$(basename "$f"); task="${task%.status}"
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 0
  status_is_boss_relevant "$last" || return 0
  printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
}

# Mark every current boss-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_boss_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
  done < <(scan_boss_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan, the always-on catch-all backstop. 0 if
# any boss-relevant status has NOT already been surfaced to consigliere (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# boss-relevant signal/stale already marks itself surfaced when it wakes
# consigliere, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a boss-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_boss_relevant_statuses "$STATE")
  return 1
}

# --- normalized transition shape + status->action policy ---------------------
#
# The NORMALIZED TRANSITION RECORD is the one shape herdr's events are
# projected into before any policy runs. A single TAB-separated line:
#     <pane_id>\t<workspace_id>\t<from_status>\t<to_status>\t<agent>
# Only `to_status` is authoritative for the policy below; the other fields are
# identity/telemetry and MAY be empty. herdr's pane.agent_status_changed event
# carries no previous status and it is edge-triggered, so from_status
# is left empty. Statuses use the shared agent-state vocabulary
# (idle|working|blocked|done|unknown), the same enum herdr's `agent get` and
# `pane.agent_status_changed` report.

CS_TRANSITION_FIELD_SEP=$'\t'

cs_transition_clean_field() {  # <value>
  printf '%s' "${1:-}" | LC_ALL=C tr '\t\r\n' '   '
}

cs_transition_record() {  # <pane_id> <workspace_id> <from_status> <to_status> <agent>
  local pane_id ws from to agent
  pane_id=$(cs_transition_clean_field "${1:-}")
  ws=$(cs_transition_clean_field "${2:-}")
  from=$(cs_transition_clean_field "${3:-}")
  to=$(cs_transition_clean_field "${4:-}")
  agent=$(cs_transition_clean_field "${5:-}")
  printf '%s\t%s\t%s\t%s\t%s' "$pane_id" "$ws" "$from" "$to" "$agent"
}

# THE single normalize point: both the spooled event lines AND the
# level-reconcile's `agent get` reads flow through here.
cs_transition_normalize() {  # <pane_id> <workspace_id> <agent_status> <agent>
  cs_transition_record "${1:-}" "${2:-}" "" "${3:-}" "${4:-}"
}

cs_transition_field() {  # <record> <n>
  printf '%s' "$1" | cut -d"$CS_TRANSITION_FIELD_SEP" -f"$2"
}

cs_transition_pane_id()   { cs_transition_field "$1" 1; }
cs_transition_workspace() { cs_transition_field "$1" 2; }
cs_transition_to_status() { cs_transition_field "$1" 4; }
cs_transition_agent()     { cs_transition_field "$1" 5; }

cs_transition_validate_route() { # <state_dir> <record>
  local state=$1 record=$2 pane meta route parent_state state_real
  pane=$(cs_transition_pane_id "$record")
  meta=$(meta_for_pane "$pane" 2>/dev/null || true)
  [ -n "$meta" ] || return 0
  route=$(cs_meta_event_route "$state" "$pane" "$(cs_transition_workspace "$record")" \
    "$(cs_transition_agent "$record")") || return 1
  parent_state=$(printf '%s' "$route" | cut -f4)
  state_real=$(cd "$state" 2>/dev/null && pwd -P) || return 1
  [ "$parent_state" = "$state" ] || {
    parent_state=$(cd "$parent_state" 2>/dev/null && pwd -P) || return 1
    [ "$parent_state" = "$state_real" ] || return 1
  }
}

cs_transition_validate_event_generation() { # <state_dir> <record>
  local state=$1 record=$2 pane workspace agent event_generation route expected_generation first
  first=$(printf '%s' "$record" | cut -f1)
  event_generation=$(printf '%s' "$record" | cut -f6)
  if [ "$first" = status ]; then
    pane=$(printf '%s' "$record" | cut -f2)
    workspace=$(printf '%s' "$record" | cut -f3)
    agent=$(printf '%s' "$record" | cut -f5)
  else
    pane=$first
    workspace=$(printf '%s' "$record" | cut -f2)
    agent=$(printf '%s' "$record" | cut -f5)
  fi
  [ -n "$workspace" ] && [ -n "$agent" ] && [ -n "$event_generation" ] || return 1
  route=$(cs_meta_event_route "$state" "$pane" "$workspace" "$agent" 2>/dev/null || true)
  expected_generation=$(printf '%s' "$route" | cut -f7)
  [ -n "$expected_generation" ] && [ "$event_generation" = "$expected_generation" ]
}

# cs_transition_policy: THE single-owner status -> supervision-action table.
#   actionable - escalate IMMEDIATELY. `blocked` is the only immediately-
#                actionable status: herdr reports it precisely when a harness
#                is waiting on the human (a permission/trust dialog, an
#                interactive menu, a wedged prompt) - the cases that write no
#                status file and otherwise sit until the stale-pane wedge timer.
#   absorb     - do NOT wake, but CLEAR this pane's per-pane escalation dedupe
#                marker so a later `->blocked` edge re-escalates. `working`
#                (a soldier resumed/started a turn) is the clearing edge.
#   defer      - do NOTHING on the fast path; `idle`/`done` blip transiently
#                between tool calls and are already covered by the debounced
#                signal/stale machinery.
#   fallback   - unknown/unrecognized: fall back to polling for this pane,
#                taking no fast action from an ambiguous read.
cs_transition_policy() {  # <to_status> -> actionable|absorb|defer|fallback
  case "$1" in
    blocked) printf 'actionable' ;;
    working) printf 'absorb' ;;
    idle|done) printf 'defer' ;;
    *) printf 'fallback' ;;
  esac
}

# Per-pane dedupe marker path, keyed identically to the watcher's .stale-<key>.
cs_transition_marker() {  # <state_dir> <pane>
  local state=$1 pane=$2 key
  key=$(printf '%s' "$pane" | tr ':/.' '___')
  printf '%s/.herdr-escalated-%s' "$state" "$key"
}

# Route one normalized record through the policy table, maintaining the
# per-pane dedupe marker under <state_dir>. On a fresh `actionable` (blocked)
# edge - policy actionable AND no marker yet - it prints the record on stdout
# and returns 0 (the caller stops and hands the record up). The caller commits
# the marker only after handling the record. `absorb` (working) clears the
# marker and returns 1. `defer`/`fallback`, and an already-marked `actionable`,
# return 1 with no output.
cs_transition_apply() {  # <state_dir> <record>
  local state=$1 record=$2 pane_id to action marker
  pane_id=$(cs_transition_pane_id "$record")
  [ -n "$pane_id" ] || return 1
  to=$(cs_transition_to_status "$record")
  action=$(cs_transition_policy "$to")
  marker=$(cs_transition_marker "$state" "$pane_id")
  case "$action" in
    actionable)
      if [ ! -e "$marker" ]; then
        printf '%s' "$record"
        return 0
      fi
      ;;
    absorb)
      rm -f "$marker" 2>/dev/null || true
      ;;
  esac
  return 1
}

cs_transition_commit() {  # <state_dir> <pane>
  local marker
  marker=$(cs_transition_marker "$1" "$2")
  : > "$marker"
}

cs_transition_clear() {  # <state_dir> <pane>
  local marker
  [ -n "$2" ] || return 0
  marker=$(cs_transition_marker "$1" "$2")
  rm -f "$marker" 2>/dev/null || true
}

# --- native event push: the herdr plugin event spool -------------------------

# cs_watch_events_capable: capability gate for the event fast-path. The spool
# file is created by bin/cs-herdr-event-plugin.sh only after herdr accepts the
# plugin link, so its presence IS the proof that this machine has the transport;
# without it the watcher keeps its poll loop unchanged. CS_HERDR_EVENTS_FORCE
# overrides the whole verdict for tests (1 = capable, 0 = incapable).
cs_watch_events_capable() {
  case "${CS_HERDR_EVENTS_FORCE:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [ -e "$(cs_event_spool_path "$STATE")" ]
}

# How often the bounded wait re-checks the spool. An idle tick costs two
# short-lived processes - one `stat` of the spool and the `sleep` itself; the
# cursor is read with bash's own `read`, and the drain's `tail` runs only when
# the spool actually grew. That is the trade between escalation latency and the
# idle cost of a watcher with panes but no events; half a second keeps a blocked
# soldier's wake sub-second in practice (the hook itself runs the moment herdr
# sees the edge).
EVENT_SPOOL_TICK=${CS_EVENT_SPOOL_TICK:-0.5}

# cs_watch_wait_transition: the bounded event wait. Blocks up to <timeout_secs>
# for one of <pane...> to reach a fresh `blocked` edge, then prints the
# normalized record and returns 0. Returns 1 on a clean timeout (no fresh
# actionable edge - the caller has effectively already slept and just continues)
# and 2 when the transport is unusable (no spool: this machine has no event
# plugin installed - the caller sleeps the budget itself, the fail-closed
# backstop). Capability is the caller's responsibility (event_wait_or_sleep
# checks cs_watch_events_capable first).
#
# Unlike the socket subscriber this replaced, there is no connection to lose:
# herdr writes the spool from its own process, so edges that fired while this
# watcher was down are drained here on the next wait, from the persisted cursor.
cs_watch_wait_transition() {  # <timeout_secs> <state_dir> <pane...>
  local timeout=$1 state=$2
  shift 2
  local panes=("$@")
  [ "${#panes[@]}" -gt 0 ] || return 2
  local spool cursor
  spool=$(cs_event_spool_path "$state")
  cursor=$(cs_event_cursor_path "$state")
  [ -e "$spool" ] || return 2

  local p raw record hit line kind ws status agent event_generation route expected_generation mine=
  local expected_agent expected_workspace expected_generation actual_worktree session event_line
  for p in "${panes[@]}"; do
    mine="$mine|$p|"
  done

  # Level reconcile first: a pane already `blocked` before this wait started -
  # because the edge predates the plugin install, or was lost to a spool
  # rotation - is returned now, once. `working` panes clear their marker here too.
  for p in "${panes[@]}"; do
    meta=$(meta_for_pane "$p" 2>/dev/null || true)
    [ -n "$meta" ] || continue
    session=$(cs_meta_get "$meta" herdr_session 2>/dev/null || true)
    expected_agent=$(cs_meta_get "$meta" harness 2>/dev/null || true)
    expected_workspace=$(cs_meta_get "$meta" workspace 2>/dev/null || true)
    expected_generation=$(cs_meta_get "$meta" endpoint_generation 2>/dev/null || true)
    [ -n "$session" ] && [ -n "$expected_agent" ] && [ -n "$expected_workspace" ] &&
      [ -n "$expected_generation" ] || continue
    CS_HERDR_SESSION="$session" cs_herdr_agent_kind_matches "$p" "$expected_agent" || continue
    expected_worktree=$(cs_meta_get "$meta" worktree 2>/dev/null || true)
    actual_worktree=$(CS_HERDR_SESSION="$session" cs_herdr_pane_cwd "$p" 2>/dev/null || true)
    [ -n "$actual_worktree" ] && [ -n "$expected_worktree" ] &&
      [ "$(cd "$actual_worktree" 2>/dev/null && pwd -P)" = "$(cd "$expected_worktree" 2>/dev/null && pwd -P)" ] || continue
    raw=$(CS_HERDR_SESSION="$session" cs_herdr_agent_status_raw "$p")
    [ -n "$raw" ] || continue
    record=$(cs_transition_normalize "$p" "$expected_workspace" "$raw" "$expected_agent")
    cs_transition_validate_route "$state" "$record" || continue
    event_line=$(printf 'status\t%s\t%s\t%s\t%s\t%s' \
      "$p" "$expected_workspace" "$raw" "$expected_agent" "$expected_generation")
    cs_transition_validate_event_generation "$state" "$event_line" || continue
    if hit=$(cs_transition_apply "$state" "$record"); then
      printf '%s' "$hit"
      return 0
    fi
  done

  # Then drain spooled edges until an actionable one or the timeout.
  # Split each spooled line with `cut`, NOT `IFS=$'\t' read`: a tab is
  # IFS-whitespace, so `read` would collapse an empty middle field (e.g. an
  # absent workspace_id) and shift the remaining columns. `cut` preserves them.
  # $SECONDS is a bash builtin, so the tick loop costs no extra process to
  # know the time.
  local started=$SECONDS i n idx
  local -a pending_panes pending_recs
  while :; do
    # A drained batch is consumed whether or not it holds an actionable edge,
    # so EVERY line in it is applied before returning: stopping at the first hit
    # would silently discard the rest of that batch, including the `working`
    # edges that clear other panes' dedupe markers.
    #
    # Actionable hits are therefore held PER PANE, in the order the panes first
    # became actionable, and only the earliest survivor is handed up (the rest
    # keep their markers uncommitted and surface on the next wait). Records for
    # one pane are in time order inside a batch, so a later record for a pane
    # that already holds a hit SUPERSEDES it: actionable replaces that pane's
    # entry in place, anything else (a `working` absorb) drops it. Without that,
    # a `blocked` then `working` pair drained together would escalate a pane the
    # same batch already proved is working, and the caller's commit would then
    # arm a dedupe marker no `working` edge is left to clear - suppressing the
    # pane's NEXT genuine block on the fast path. Keying by pane is what keeps
    # the supersede from also swallowing a DIFFERENT pane's genuine block that
    # arrived in the same batch, in any order.
    pending_panes=()
    pending_recs=()
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      kind=$(printf '%s' "$line" | cut -f1)
      [ "$kind" = status ] || continue
      p=$(printf '%s' "$line" | cut -f2)
      [ -n "$p" ] || continue
      # The spool carries every pane the herdr server knows about; this home
      # supervises only its own recorded panes.
      case "$mine" in
        *"|$p|"*) ;;
        *) continue ;;
      esac
      ws=$(printf '%s' "$line" | cut -f3)
      status=$(printf '%s' "$line" | cut -f4)
      agent=$(printf '%s' "$line" | cut -f5)
      event_generation=$(printf '%s' "$line" | cut -f6)
      record=$(cs_transition_normalize "$p" "$ws" "$status" "$agent")
      cs_transition_validate_route "$state" "$record" || continue
      cs_transition_validate_event_generation "$state" "$line" || continue
      idx=-1
      n=${#pending_panes[@]}
      for ((i = 0; i < n; i++)); do
        if [ "${pending_panes[i]}" = "$p" ]; then
          idx=$i
          break
        fi
      done
      if hit=$(cs_transition_apply "$state" "$record"); then
        if [ "$idx" -ge 0 ]; then
          pending_recs[idx]=$hit
        else
          pending_panes[n]=$p
          pending_recs[n]=$hit
        fi
      elif [ "$idx" -ge 0 ]; then
        pending_panes[idx]=''
        pending_recs[idx]=''
      fi
    done < <(cs_event_drain "$spool" "$cursor")
    n=${#pending_panes[@]}
    for ((i = 0; i < n; i++)); do
      [ -n "${pending_panes[i]}" ] || continue
      printf '%s' "${pending_recs[i]}"
      return 0
    done
    [ "$((SECONDS - started))" -lt "$timeout" ] || return 1
    sleep "$EVENT_SPOOL_TICK"
  done
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with recorded soldier panes and this home's herdr event plugin installed, it
# replaces the blind `sleep POLL` with a bounded wait on the event spool, so a
# soldier going `blocked` wakes the supervisor sub-second instead of after the
# poll loop's next level read. For every other case - no panes, or no plugin on
# this machine - it sleeps POLL.
# The poll loop above still runs every cycle, so this only ever SHORTENS
# latency; it can never drop an escalation (the poll loop is the permanent
# fail-closed backstop).
event_wait_or_sleep() {
  local w rec rc
  local panes=()
  while IFS= read -r w; do
    # Capo endpoints are supervised via status writes, not pane/agent state (an
    # idle or blocked capo agent pane is healthy by design), so they are
    # excluded from the fast escalation exactly as the stale loop skips them.
    [ "$(pane_kind "$w")" = capo ] && continue
    panes+=("$w")
  done < <(recorded_panes)

  if [ "${#panes[@]}" -eq 0 ]; then
    sleep "$POLL"
    return
  fi

  # The capability check is one stat of a local file, so it is re-read every
  # cycle: a plugin installed (or removed) mid-run takes effect on the next one.
  if ! cs_watch_events_capable; then
    sleep "$POLL"
    return
  fi

  rec=$(cs_watch_wait_transition "$POLL" "$STATE" "${panes[@]}")
  rc=$?
  case "$rc" in
    0) handle_push_transition "$rec" ;;
    2)
      # The transport vanished between the check and the wait (an uninstall, a
      # rotated-away spool). Sleep the budget; the poll loop above already ran.
      sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the wait already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      ;;
  esac
}

# handle_push_transition: act on a fresh actionable (blocked) transition record
# - from the spooled herdr events, or from the poll loop's level read of the
# same native state. Maps the pane back to its task, applies the declared-pause
# exemption (a soldier waiting on a known external dependency is not a surprise
# block - absorb it on the poll loop's long pause cadence instead), and
# otherwise enqueues an immediate `stale` wake and wakes the supervisor. The
# `stale` kind is deliberate: the supervisor's handler for it ("peek the pane
# to diagnose") is exactly right for a blocked soldier, and the drain/dedupe/
# guard machinery already understands it (queued by key=pane, so a later
# poll-path stale for the same pane collapses on drain).
handle_push_transition() {  # <record>
  local record=$1 pane_id to task reason
  pane_id=$(cs_transition_pane_id "$record")
  to=$(cs_transition_to_status "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  task=$(pane_to_task "$pane_id" "$STATE")
  if status_is_paused "$(last_status_line "$STATE/$task.status")"; then
    triage_log "absorbed push $to (declared pause, awaiting external): $pane_id"
    cs_transition_commit "$STATE" "$pane_id" || exit 1
    return
  fi
  reason="stale: $pane_id (herdr: agent $to - waiting on human, escalated immediately, not via wedge timer)"
  cs_wake_append stale "$pane_id" "$reason" || exit 1
  cs_transition_commit "$STATE" "$pane_id" || exit 1
  mark_surfaced "$STATE/$task.status"
  wake "$reason"
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

if ! cs_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${CS_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(cs_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $CS_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(cs_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $CS_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $CS_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
watcher_cleanup() {
  cs_active_check_stop || return 1
  cs_check_output_cleanup
  cs_custom_check_snapshot_cleanup
  cs_lock_release "$WATCH_LOCK"
}
trap watcher_cleanup EXIT
trap 'exit 1' HUP INT TERM
# This watcher's own pid, as recorded in the lock by the wake-lib claim (which
# writes ${BASHPID:-$$} from this same main shell). Read directly, never via a
# command substitution, so it matches the stored holder pid for the
# self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$CS_HOME" > "$WATCH_LOCK/cs-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
cs_pid_identity "$WATCHER_PID" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for guard scripts: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # One session snapshot for this whole cycle, so N panes cost one round-trip
  # instead of N. Best-effort: on failure every pane read falls back to its own
  # query, which is exactly the pre-snapshot behavior.
  snapshot_refresh

  # Parent-owned capo pending-reply reconciliation (once its library lands):
  # resolve correlated parent reports, observe turn completion, send one
  # recovery repost after grace, and escalate once if the recovery turn is also
  # missed. No conversation scraping; unresolved records never silently expire.
  if command -v cs_pending_reply_tick >/dev/null 2>&1 || declare -F cs_pending_reply_tick >/dev/null 2>&1; then
    cs_pending_reply_tick "$STATE" || true
  fi

  # Armed blocking sources (bin/cs-procevent.sh). Liveness repair only: it
  # republishes captured results that have no durable acknowledgement yet and
  # restarts a source with no live owner. It never polls a source and never
  # blocks - the child does the blocking, in its own process group. Guarded by a
  # predicate so a home with nothing armed pays one directory test per cycle.
  # A republished result reaches the agent as an ordinary `check` wake on the
  # durable queue, which the bounded checkpoint, the persistent monitor's
  # activation path, and session start all already read, so no watcher-side
  # surfacing machinery is needed to deliver it.
  # The home is passed explicitly rather than relied on from the environment, so
  # a capo's watcher can never reconcile against the main home's records.
  if cs_procevent_needs_reconcile "$STATE"; then
    CS_HOME="$CS_HOME" CS_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/cs-procevent.sh" reconcile >/dev/null 2>&1 || true
  fi

  # Slow per-task checks (consigliere writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling soldier
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  # A PR merge poll is dispatched ONLY through the trusted repository script
  # (bin/cs-pr-poll.sh) with byte-validated data; a registered custom check
  # runs ONLY from a hash-validated private snapshot; anything else is rejected
  # WITHOUT execution.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      id=$(basename "$c" .check.sh)
      pr_poll_id=
      if cs_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/cs-pr-poll.sh"; then
        provider=$CS_PR_DATA_PROVIDER
        url=$CS_PR_DATA_URL
        host=$CS_PR_DATA_HOST
        path=$CS_PR_DATA_PATH
        number=$CS_PR_DATA_NUMBER
        run_check_capture "$SCRIPT_DIR/cs-pr-poll.sh" --validated \
          "$provider" "$url" "$host" "$path" "$number" || exit 1
        out=$CS_CHECK_RESULT
        pr_poll_id=$id
      elif cs_custom_check_snapshot_prepare "$STATE" "$id"; then
        custom_snapshot=$CS_CUSTOM_CHECK_SNAPSHOT
        run_check_capture "$custom_snapshot" || exit 1
        out=$CS_CHECK_RESULT
        cs_custom_check_snapshot_cleanup
      else
        cs_custom_check_snapshot_cleanup
        rejected_checks="$rejected_checks $c"
        continue
      fi
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        cs_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        # A merged PR is terminal for its poll: retire the poll only AFTER the
        # wake is durably queued, so the merge is never lost, and never
        # re-notified on every later cycle until teardown. Retirement
        # revalidates the same identity before removal. A replacement published
        # after validation can still race the unlink; see cs_pr_poll_retire for
        # the bounded lifecycle limitation. A failure here is not fatal - the
        # merge is already queued and teardown still owns full cleanup.
        if [ -n "$pr_poll_id" ] && [ "$out" = merged ]; then
          cs_pr_poll_retire "$STATE" "$pr_poll_id" "$SCRIPT_DIR/cs-pr-poll.sh" \
            "$provider" "$url" "$number" || true
        fi
        wake "$reason"
      fi
    done
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state checks:$rejected_checks"
      cs_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    touch "$STATE/.last-check"
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a soldier's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full consigliere turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  #
  # The grace LENGTH is chosen from what the first scan already proves, because
  # the two purposes of waiting are not the same:
  #   - A no-verb signal (a bare turn-end, a working: note) waits the full
  #     SIGNAL_GRACE. Here the wait decides the outcome: a boss-relevant line
  #     landing inside the window turns one costly triage into one wake.
  #   - A signal ALREADY carrying a boss-relevant verb is surfacing no matter
  #     what the re-scan adds, so waiting cannot change the verdict - only the
  #     coalescing still matters. It takes SIGNAL_GRACE_ACTIONABLE, long enough
  #     for the same turn's turn-end hook and no longer, because the rest of the
  #     window is pure latency on a decision, a blocker, or a review-ready PR
  #     that consigliere and the boss are already waiting on.
  # A status line written mid-turn is unaffected either way: its turn-end hook
  # lands minutes later, outside every grace window.
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    # shellcheck disable=SC2046  # deliberate word split: a space-separated status-path list (ids carry no spaces)
    if signal_reason_is_actionable $(signal_files_of "$pending"); then
      grace=$SIGNAL_GRACE_ACTIONABLE
    else
      grace=$SIGNAL_GRACE
    fi
    sleep "$grace"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    files=$(signal_files_of "$pending")
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when either of these holds (cheapest first):
    #   - any status file carries a boss-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose
    #     soldier is NOT provably working - the soldier stopped its turn with no
    #     actively-running pipeline and no busy pane, so it may be done (even
    #     via an interactive menu that wrote no done: status), waiting on a
    #     decision, or wedged. Absorbing such a turn-end is exactly the
    #     swallowed-finish this triage guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb
    # wake whose soldier IS provably working) -> advance the markers so it will
    # not re-fire, log, and keep blocking without enqueuing. The
    # provably-working check is the only costly one (it may run a bounded
    # made status query - crew_is_provably_working over cs-crew-state.sh, a
    # `made status --json` read, never a log scrape), so the || ordering
    # evaluates it only for a no-boss-verb signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if signal_reason_is_actionable $files || ! signal_crew_provably_working $files; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        cs_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
        mark_surfaced "$f"
      done <<EOF
$pending
EOF
      wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      triage_log "absorbed benign $reason"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no
  # busy signal means the soldier finished, is waiting, or is wedged. Each
  # distinct stale hash is surfaced, absorbed, or timed toward escalation once
  # (.stale-* remembers the hash already classified). A native `blocked`
  # reading short-circuits first: it is surfaced immediately (deduped by the
  # push-escalation marker, exempted by a declared pause), never left to the
  # hash cadence.
  while IFS= read -r w; do
    kind=$(pane_kind "$w")
    task=$(pane_to_task "$w" "$STATE")
    key=${w//:/_}
    key=${key//\//_}
    key=${key//./_}
    last=$(last_status_line "$STATE/$task.status")
    if ! status_is_paused_or_boss_held "$last" && [ -e "$STATE/.paused-$key" ]; then
      clear_pause_tracking "$w"
    fi
    if [ "$kind" = capo ] && ! status_is_paused "$last"; then
      continue
    fi
    # A live headless scout (codex exec / claude -p) has no interactive composer
    # or TUI busy banner, so the stale-triage heuristics below would raise a
    # spurious "went quiet" wake while it is legitimately working. Skip its stale
    # triage until it is terminal; completion still surfaces through its
    # done:/failed: status line on the ordinary signal path. (docs/headless-scouts.md)
    if pane_is_headless "$w" && ! status_is_terminal_verb "$last"; then
      continue
    fi
    tail40=$(cs_herdr_capture "$w" 40 text 2>/dev/null) || continue
    bs=$(pane_busy_state "$w")
    case "$bs" in
      blocked)
        # Native blocked: waiting on the human. Surface immediately through the
        # same policy/dedupe/pause machinery the event splice uses, so the poll
        # loop is a complete backstop on a machine with no event plugin. A
        # capo's blocked pane is healthy by design and stays excluded.
        if [ "$kind" != capo ] && rec=$(cs_transition_apply "$STATE" "$(cs_transition_normalize "$w" "" blocked "")"); then
          handle_push_transition "$rec"
        fi
        ;;
      busy)
        # A soldier back at work is the clearing edge for the blocked dedupe
        # marker, so a LATER blocked edge re-escalates.
        cs_transition_clear "$STATE" "$w"
        ;;
    esac
    h=$(printf '%s' "$tail40" | hash_pane)
    key=$(printf '%s' "$w" | tr ':/.' '___')
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's stale is using the bounded pause cadence
    btf="$STATE/.busy-turn-since-$key"  # wedge timer for a busy pane whose turn never ends

    # Busy-turn bound (see CS_BUSY_TURN_MAX_SECS). This runs BEFORE and
    # independently of the hash comparison below, because a busy pane's hash
    # keeps changing - the elapsed counter ticks - so the stale path it would
    # otherwise reach is unreachable by construction. A capo's pane is a
    # supervisor's, not a supervised turn-taker's, so it is exempt.
    if [ "$kind" != capo ] && pane_is_busy "$bs" "$tail40"; then
      if bage=$(busy_turn_age "$task") && [ "$bage" -ge "$BUSY_TURN_MAX_SECS" ]; then
        wedge_timer_check "$w" "$btf" "busy ${bage}s with no completed turn" "$ewf"
      else
        # Within the bound, or unreadable: no wedge in progress.
        rm -f "$btf"
      fi
    else
      # Not busy: the ordinary stale machinery below owns this pane.
      rm -f "$btf"
    fi

    prev=$(cat "$hf" 2>/dev/null || true)
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      # Busy match: herdr's native semantic state, with the codex busy-regex
      # fallback over the last 6 non-blank lines only (the TUI footer area) when
      # the native read is ambiguous.
      if [ "$n" -ge 2 ] && ! pane_is_busy "$bs" "$tail40"; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # consigliere. Detection itself is unchanged from above.
        if [ "$kind" = capo ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            *)      clear_pause_tracking "$w" ;;
          esac
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is boss-relevant - but that alone is not proof
          # the soldier is actually done: a soldier's own status log gets no new
          # entry once consigliere hands it to a made validation (the
          # sparse status-reporting contract), so the log can keep showing a
          # "done:"/needs-decision/blocked leftover from BEFORE that validation
          # started for the run's entire (possibly many-minutes) duration,
          # while stale_is_terminal - which has no run-step awareness - keeps
          # reporting it as still-current on every poll. On a NEW hash, give an
          # active run/busy pane (the same authoritative source cs-crew-state.sh
          # itself already prioritizes over the log) a chance to override
          # before trusting the log.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            if crew_is_provably_working "$(pane_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              triage_log "absorbed stale (provably working, overriding a stale boss-relevant status): $w"
            else
              cs_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              mark_surfaced "$STATE/$(pane_to_task "$w" "$STATE").status"
              wake "stale: $w"
            fi
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the soldier state every poll, and without
            # letting the still-boss-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do.
        else
          # Non-terminal stale: a soldier gone quiet without a boss-relevant
          # status. Decided once per distinct stale hash (the costly state
          # reads run only on first sight, never every poll) via
          # pause_state_class, which returns:
          #   - working: an actively-running pipeline legitimately sits on a
          #     static pane (e.g. waiting on CI), so absorb and start the wedge
          #     timer so a genuinely frozen run still escalates past
          #     STALE_ESCALATE_SECS;
          #   - paused: the soldier declared an external wait, or a declared
          #     pause or boss hold is paired with a confidently dead agent, so
          #     absorb on the long PAUSE_RESURFACE_SECS cadence instead of
          #     wedge-escalating;
          #   - none: no running pipeline, idle pane, no busy signal, no
          #     declared pause - the soldier has STOPPED. Surface immediately
          #     so consigliere peeks (it may be done via an interactive menu
          #     that wrote no done: status, waiting on a decision, or wedged)
          #     instead of leaving the finish to wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(pane_to_task "$w" "$STATE")
            case "$(pause_state_class "$w" "$task")" in
              working)
                clear_pause_tracking "$w"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(pane_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused_or_boss_held "$(last_status_line "$STATE/$task.status")"; then
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$w"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf"
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                *)       handle_paused_stale "$w" "$task" "$h" ;;
              esac
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf"
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping.
        rm -f "$ssf" "$ewf"
        if [ -e "$pf" ] && { [ "$n" -ge 2 ] || ! status_is_paused_or_boss_held "$(last_status_line "$STATE/$(pane_to_task "$w" "$STATE").status")"; }; then
          clear_pause_tracking "$w"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      rm -f "$ssf" "$ewf"
      task=$(pane_to_task "$w" "$STATE")
      if status_is_paused_or_boss_held "$(last_status_line "$STATE/$task.status")" && ! pane_is_busy "$bs" "$tail40"; then
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          *)      clear_pause_tracking "$w" ;;
        esac
      else
        [ -e "$pf" ] && clear_pause_tracking "$w"
      fi
    fi
  done < <(recorded_panes)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: a heartbeat is benign unless the cheap fleet-scan turns up a
    # boss-relevant status the per-wake path missed. Absorb the no-change case
    # (advance the schedule and back off exactly as wake() would, without
    # exiting).
    if heartbeat_scan_finds_actionable; then
      # Backstop: a boss-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every boss-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      cs_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_boss_relevant_surfaced
      wake "heartbeat"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no boss-relevant change)"
    fi
  fi

  # Terminal wait: a bounded wait on the herdr event spool when this home has
  # the plugin, else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
