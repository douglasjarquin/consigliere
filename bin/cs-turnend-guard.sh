#!/usr/bin/env bash
# Turn-end guard for any consigliere PRIMARY session: the main home OR a capo's
# own home. A capo runs its own primary consigliere session and is guarded
# exactly like the main primary; only child soldier/scout worktrees are exempt
# (see the scoping block below).
#
# cs-guard.sh is pull-based: it only warns when some other supervision script
# happens to run. A primary session that ends a turn without resuming the
# foreground checkpoint, and then never runs another fleet-touching command
# itself, can sit blind for hours.
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
WATCH="$SCRIPT_DIR/cs-watch.sh"

# shellcheck source=bin/cs-supervision-lib.sh
. "$SCRIPT_DIR/cs-supervision-lib.sh"
# shellcheck source=bin/cs-primary-scope-lib.sh
. "$SCRIPT_DIR/cs-primary-scope-lib.sh"
# shellcheck source=bin/cs-operational-input.sh
. "$SCRIPT_DIR/cs-operational-input.sh"
# Optional turn telemetry (off unless host/telemetry.conf enables it). Both libs
# are pure function definitions with no side effects on source, and every
# telemetry entry point swallows its own failures, so sourcing them cannot change
# what this guard decides or what it prints.
# shellcheck source=bin/cs-harness-lib.sh
. "$SCRIPT_DIR/cs-harness-lib.sh"
# shellcheck source=bin/cs-telemetry-lib.sh
. "$SCRIPT_DIR/cs-telemetry-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# Without jq we cannot safely read the loop-guard field, so we must never
# block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0

# Scope precisely to a PRIMARY checkout: a genuinely marked capo home is
# force-included; an unmarked linked task worktree is exempt.
#
# This scope test moved ABOVE the stop_hook_active loop guard so the telemetry
# emitter below sees every primary turn, including a forced continuation's own
# second stop. Both tests are side-effect-free reads that exit 0 when they do not
# match, so the reordering is observationally identical: the same inputs still
# produce the same exit status, the same stdout, and the same stderr.
cs_primary_scope_matches "$CS_ROOT" "$STATE" || exit 0

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
# falls through to the supervision logic so a genuine primary is still guarded
# when it ends a turn blind.
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

cs_supervision_status "$STATE" "$GRACE"
[ "$CS_SUP_SUPERVISED" -gt 0 ] || exit 0
cs_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$CS_HOME" && exit 0

# While away mode owns supervision, the daemon (not the checkpoint) is the live
# cycle; its own liveness is guarded separately, so do not block here.
[ -e "$STATE/.afk" ] && exit 0

rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
GUARD_BODY=$(
  printf '●%s\n' "$rule"
  printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
  printf '●  %s, but no live watcher holds this home lock (last beat: %s).\n' "$(cs_supervision_work_desc)" "$CS_SUP_BEACON_DESC"
# shellcheck disable=SC2016 # the ${CS_WATCH_CHECKPOINT:-180} is literal advice text for the reading agent
  printf '●  Drain queued wakes with bin/cs-wake-drain.sh, then start the foreground checkpoint: bin/cs-watch-checkpoint.sh --seconds "${CS_WATCH_CHECKPOINT:-180}". No turn ends blind while work is under way.\n'
  printf '●%s\n' "$rule"
)
cs_operational_input_construct turn-end-guard "$GUARD_BODY" GUARD_INPUT
printf '%s\n' "$GUARD_INPUT" >&2
exit 2
