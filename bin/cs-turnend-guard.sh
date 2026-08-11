#!/usr/bin/env bash
# Turn-end guard for any consigliere PRIMARY session: the main home OR a capo's
# own home. A capo runs its own primary consigliere session and is guarded
# exactly like the main primary; only child soldier/scout worktrees are exempt
# (see the scoping block below).
#
# WHAT IT GUARDS. Ending a turn is the NORMAL, required thing to do: the harness
# delivers queued boss input at a turn boundary, so a primary that never ends a
# turn cannot be spoken to (measured: 6.2 hours across 61 consecutive
# checkpoints). Supervision does not live in the turn either - bin/cs-monitor.sh
# keeps watching this home, and bin/cs-activate.sh starts the next turn when a
# wake lands. So this guard no longer asks "is work under way"; it asks whether
# this home can still WAKE ITSELF, and blocks only when it cannot: no monitor
# could be started, no pane is recorded to prompt, the record names a different
# pane than this one, or state/.activation-stalled says activation already found
# the target unusable. Those are the states where an ended turn is a lost home.
#
# It also clears state/.checkpoint-turn, the per-turn counter that makes
# bin/cs-watch-checkpoint.sh's one-checkpoint-per-turn limit mechanical rather
# than a rule an agent can reinterpret. This hook is the one component that
# observes a turn boundary, so it is the only place that can clear it.
#
# This script is push-based: the harness Stop hook invokes it every time the
# primary is about to end a turn, and blocks the stop by preserving exit status 2
# and stderr. Registration is harness-specific: codex via .codex/hooks.json;
# claude via the launch-scoped --settings Stop hook (cs-harness-lib.sh). Both feed
# the same payload shape and honor an exit-2 block. The blocked message is a
# TYPED turn-end-guard operational input (not raw text), which is what marks it as
# legitimate supervision rather than an injected instruction to the reading agent.
#
# Loop-guard: never block twice in the same turn. codex and claude Stop payloads
# both carry stop_hook_active=true when the CURRENT stop attempt was itself
# already forced by an earlier block this turn; on that signal we always allow the
# stop,
# whether or not watcher supervision actually got resumed. That bounds this to
# at most one forced continuation per turn - never a wedged, un-endable
# session - while still nagging again on a later turn if the problem persists.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
GRACE=${CS_GUARD_GRACE:-300}

# shellcheck source=bin/cs-supervision-lib.sh
. "$SCRIPT_DIR/cs-supervision-lib.sh"
# shellcheck source=bin/cs-primary-scope-lib.sh
. "$SCRIPT_DIR/cs-primary-scope-lib.sh"
# shellcheck source=bin/cs-operational-input.sh
. "$SCRIPT_DIR/cs-operational-input.sh"
# Optional turn telemetry (off unless host/telemetry.conf enables it). The
# library is pure function definitions with no side effects on source, and every
# telemetry entry point swallows its own failures, so sourcing it cannot change
# what this guard decides or what it prints.
# shellcheck source=bin/cs-telemetry-lib.sh
. "$SCRIPT_DIR/cs-telemetry-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# Scope precisely to a PRIMARY checkout: a genuinely marked capo home is
# force-included; an unmarked linked task worktree is exempt.
#
# This scope test sits ABOVE the stop_hook_active loop guard so the telemetry
# emitter below sees every primary turn, including a forced continuation's own
# second stop. It also sits above the jq requirement, so the per-turn counter is
# cleared even on a host missing jq: a counter that never clears would refuse
# every later checkpoint in the session. All three tests are side-effect-free
# reads that exit 0 when they do not match.
cs_primary_scope_matches "$CS_ROOT" "$STATE" || exit 0

# A turn boundary was reached, so the per-turn checkpoint counter is spent. This
# runs unconditionally from here on, including on the block path below: a blocked
# stop continues the turn precisely so the agent can supervise, which needs a
# checkpoint available to it.
rm -f "$STATE/.checkpoint-turn" 2>/dev/null || true

# Without jq we cannot safely read the loop-guard field, so we must never
# block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0

# TELEMETRY, measurement only. This is the per-turn emitter for role=root and
# role=capo: the Stop hook fires here on every turn of the main home and of every
# capo home, and it is where each harness exposes its usage data. It runs BEFORE
# every remaining early exit so a quiet, fully supervised turn - the most common
# supervision turn there is - is counted rather than invisible.
#
# It must never delay, suppress, duplicate, or corrupt the turn-end signal or the
# exit-2 block below. cs_telemetry_turn_end is silent, swallows every failure,
# and always returns 0; the `|| true` is belt and braces under this script's
# `set -u`. Disabled telemetry short-circuits on the absent host/telemetry.conf.
if cs_root_is_capo_home "$CS_ROOT"; then
  cs_telemetry_turn_end capo "$PAYLOAD" || true
else
  cs_telemetry_turn_end root "$PAYLOAD" || true
fi

[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

# Defer when ANOTHER live consigliere session holds this home's lock. The guard
# scopes to a primary checkout but that says nothing about whether THIS session
# is the supervisor: a second window, a read-only helper, or a tooling session
# started in the repo root shares the scope yet must not be nagged to drive a
# fleet it does not own. cs-session-start.sh already turns the same signal into a
# read-only session ("ANOTHER LIVE CONSIGLIERE SESSION HOLDS THE FLEET LOCK");
# mirror that here so the two components stop giving a secondary session opposite
# instructions. Query the lock non-mutatingly via `cs-lock.sh status` - NEVER
# acquire, which would take the lock as a side effect. Fail open: only an
# affirmative live holder that is provably NOT part of this session's process
# tree adds the defer. A free, stale, or own lock - or any unreadable condition -
# falls through to the wake-up predicate so a genuine primary is still guarded.
cs_lock_holder_is_foreign() {  # <holder-pid>: 0 only if provably a different session
  local holder=$1 pid=$$ ppid hops=0
  case "$holder" in
    ''|*[!0-9]*) return 1 ;;  # unparseable -> not provably foreign (fail open)
  esac
  while [ "$hops" -lt 64 ]; do
    # The holder is this process or one of its ancestors -> this session owns the
    # lock; not foreign.
    [ "$pid" = "$holder" ] && return 1
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$ppid" in
      ''|*[!0-9]*) return 1 ;;  # cannot read ancestry -> fail open (do not defer)
    esac
    # Reached init/reaper without meeting the holder: it lives outside this
    # session's process tree -> another live session holds the lock.
    [ "$ppid" -gt 1 ] || return 0
    pid=$ppid
    hops=$((hops + 1))
  done
  return 1  # ran out of hops -> cannot prove foreign, fail open
}

LOCK_STATUS=$(CS_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/cs-lock.sh" status 2>/dev/null || true)
case "$LOCK_STATUS" in
  'lock: held by live harness pid '*)
    if cs_lock_holder_is_foreign "${LOCK_STATUS##* }"; then
      exit 0
    fi
    ;;
esac

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/cs-wake-lib.sh
. "$SCRIPT_DIR/cs-wake-lib.sh"
# shellcheck source=bin/cs-monitor-lib.sh
. "$SCRIPT_DIR/cs-monitor-lib.sh"

cs_supervision_status "$STATE" "$GRACE"
[ "$CS_SUP_SUPERVISED" -gt 0 ] || exit 0

# While away mode owns supervision, the daemon (not this home's own activation)
# is what restarts turns; its own liveness is guarded separately, so do not
# block here.
[ -e "$STATE/.afk" ] && exit 0

# Can this home wake itself once this turn ends? These are the DURABLE
# preconditions bin/cs-activate.sh needs before it will prompt anything; that
# script owns the live revalidation (the pane still exists, still runs an agent,
# is still rooted here) and writes state/.activation-stalled when it does not.
# Read only local records here: the Stop hook runs on every turn of the primary,
# so it must stay cheap and must never hang on a backend.
PROBLEM=
FIX=
if [ -e "$STATE/.activation-stalled" ]; then
  PROBLEM='this home cannot start its own turns; activation found its recorded pane unusable'
  FIX="recover the pane (bin/cs-monitor.sh logs the reason in state/.monitor.log), re-record it by running bin/cs-session-start.sh from this home's own pane, then remove state/.activation-stalled"
elif [ ! -s "$STATE/.home-pane" ]; then
  PROBLEM='no pane is recorded for this home, so nothing can start its next turn'
  FIX="run bin/cs-session-start.sh from this home's own pane, which is the one place that can record it"
elif [ -n "${HERDR_PANE_ID:-}" ] &&
     [ "$HERDR_PANE_ID" != "$(tr -dc 'A-Za-z0-9:_-' < "$STATE/.home-pane" 2>/dev/null)" ]; then
  PROBLEM="the recorded home pane is not this one, so a wake would be delivered somewhere else"
  FIX='run bin/cs-session-start.sh from this pane so the record names it'
elif ! cs_monitor_ensure "$STATE"; then
  PROBLEM='no watcher is running for this home and none could be started'
  FIX='start one with bin/cs-watch-checkpoint.sh, and check state/.monitor.err if it still cannot launch'
fi
[ -n "$PROBLEM" ] || exit 0

rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
GUARD_BODY=$(
  printf '●%s\n' "$rule"
  printf '●  THIS HOME CANNOT WAKE ITSELF - DO NOT END THE TURN YET\n'
  printf '●  %s, and %s.\n' "$(cs_supervision_work_desc)" "$PROBLEM"
  printf '●  %s. Ending a turn is otherwise fine: the monitor keeps watching and a queued wake starts the next turn.\n' "$FIX"
  printf '●%s\n' "$rule"
)
cs_operational_input_construct turn-end-guard "$GUARD_BODY" GUARD_INPUT
printf '%s\n' "$GUARD_INPUT" >&2
exit 2
