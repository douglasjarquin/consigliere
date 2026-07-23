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
# This script is push-based: the codex Stop hook (.codex/hooks.json) invokes it
# every time the primary is about to end a turn, and blocks the stop by
# preserving exit status 2 and stderr.
#
# Loop-guard: never block twice in the same turn. Codex Stop payloads carry
# stop_hook_active=true when the CURRENT stop attempt was itself already forced
# by an earlier block this turn; on that signal we always allow the stop,
# whether or not watcher supervision actually got resumed. That bounds this to
# at most one forced continuation per turn - never a wedged, un-endable
# session - while still nagging again on a later turn if the problem persists.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CS_ROOT="${CS_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CS_HOME="${CS_HOME:-${CS_ROOT_OVERRIDE:-$CS_ROOT}}"
STATE="${CS_STATE_OVERRIDE:-$CS_HOME/state}"
GRACE=${CS_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/cs-watch.sh"

# shellcheck source=bin/cs-supervision-lib.sh
. "$SCRIPT_DIR/cs-supervision-lib.sh"
# shellcheck source=bin/cs-primary-scope-lib.sh
. "$SCRIPT_DIR/cs-primary-scope-lib.sh"
# shellcheck source=bin/cs-operational-input.sh
. "$SCRIPT_DIR/cs-operational-input.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# Without jq we cannot safely read the loop-guard field, so we must never
# block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

# Scope precisely to a PRIMARY checkout: a genuinely marked capo home is
# force-included; an unmarked linked task worktree is exempt.
cs_primary_scope_matches "$CS_ROOT" "$STATE" || exit 0

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/cs-wake-lib.sh
. "$SCRIPT_DIR/cs-wake-lib.sh"

cs_supervision_status "$STATE" "$GRACE"
[ "$CS_SUP_IN_FLIGHT" -gt 0 ] || exit 0
cs_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$CS_HOME" && exit 0

# While away mode owns supervision, the daemon (not the checkpoint) is the live
# cycle; its own liveness is guarded separately, so do not block here.
[ -e "$STATE/.afk" ] && exit 0

rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
GUARD_BODY=$(
  printf '●%s\n' "$rule"
  printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
  printf '●  %s task(s) in flight, but no live watcher holds this home lock (last beat: %s).\n' "$CS_SUP_IN_FLIGHT" "$CS_SUP_BEACON_DESC"
# shellcheck disable=SC2016 # the ${CS_WATCH_CHECKPOINT:-180} is literal advice text for the reading agent
  printf '●  Drain queued wakes with bin/cs-wake-drain.sh, then start the foreground checkpoint: bin/cs-watch-checkpoint.sh --seconds "${CS_WATCH_CHECKPOINT:-180}". No turn ends blind while work is under way.\n'
  printf '●%s\n' "$rule"
)
cs_operational_input_construct turn-end-guard "$GUARD_BODY" GUARD_INPUT
printf '%s\n' "$GUARD_INPUT" >&2
exit 2
