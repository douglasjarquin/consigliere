#!/usr/bin/env bash
# Spawn a direct report: a soldier in a herdr-native task worktree, or a capo
# in its isolated consigliere home.
# Usage: cs-spawn.sh <task-id> <project-dir> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> [--model <name>] [--effort <level>] [--base <ref>] [--issue <n>]
#        cs-spawn.sh <task-id> <project-dir> --scout [--headless] [--model <name>] [--effort <level>] [--base <ref>]
#        cs-spawn.sh <task-id> <capo-home> --capo [--model <name>] [--effort <level>]
#
#   --mode and --yolo are REQUIRED on a ship spawn and refused on --scout and
#   --capo. A ship task's delivery posture is decided per task at intake, never
#   derived here: cs-brief.sh already shaped the worker's definition of done from
#   the same explicit decision, and this spawn refuses to launch if the brief's
#   recorded "Delivery contract: mode=<mode>" line disagrees with --mode. That
#   refusal happens before the worktree is created, so it never leaves an
#   endpoint, workspace, or branch behind.
#   A brief with no contract line was scaffolded before the contract existed: that
#   warns once and launches on --mode rather than refusing.
#   config/projects.md records the boss's STANDING posture per project and stays
#   advisory: a --mode carrying less rigor than the registry entry prints a
#   deviation notice and continues, and a project absent from the registry has no
#   standing posture, so it gets no notice at all.
#   A scout records no mode= and no yolo= in its metadata: its deliverable is a
#   report, so there is no delivery contract to honour. cs-promote.sh is where a
#   promoted scout first states one.
#
#   --model <name> and --effort <default|low|medium|high|xhigh|max|ultra> override the optional
#   config/dispatch-policy.conf entry for the resolved harness and task kind.
#   The policy's exact format is in docs/configuration.md.
#   Codex accepts max and ultra through model_reasoning_effort; default omits it.
#   Claude accepts max but not ultra.
#   A claude home whose account policy forbids --dangerously-skip-permissions
#   selects a narrower launch mode in config/permission-mode.conf (auto|acceptEdits|
#   bypassPermissions); an unusable or malformed record blocks the dispatch.
#   The exact format is in docs/configuration.md.
#   --scout marks the task kind=scout (report deliverable, scratch worktree).
#   --headless (scout only) runs `codex exec` instead of the interactive TUI:
#     fire-and-forget for bounded investigations. Turn-end is process exit;
#     the launch itself appends the terminal `done:`/`failed:` status line, so
#     the watcher surfaces completion through the ordinary signal path. A
#     headless scout cannot be steered mid-flight; use the interactive default
#     when follow-up questions are likely.
#   --base <ref> bases the task branch on <ref> instead of the current HEAD, and
#     skips the base-freshness refresh below (the ref was chosen explicitly).
#   --issue <n> records issue=<n> in meta for board-driven work (the Closes-#n
#     contract itself lives in the brief via cs-brief.sh --issue). Correlates
#     the task to a GitHub issue for the fleet view and the contracts skill.
#
# Ship/scout mechanics:
#   - Requires the brief at data/<id>/brief.md (scaffold with cs-brief.sh first).
#   - Base freshness (no --base only): refreshes the clone through
#     cs-fleet-sync.sh - its own safety rules, not a second fast-forward - under a
#     CS_SPAWN_BASE_FRESHNESS_TIMEOUT_SECS bound (default 25), so the task branch
#     does not start on a main this home never saw merged. Fail-open: an
#     unreachable origin, a stuck clone, or an exhausted bound warns loudly to
#     stderr and the spawn continues on the local HEAD.
#   - Creates the isolated worktree + task workspace with
#     `herdr worktree create --cwd <project> --branch cs/<id> --label <id>`;
#     the root pane is the task pane.
#   - Fail-closed isolation assertion: the physically-resolved worktree root
#     must be a real git toplevel distinct from the physically-resolved project
#     primary checkout. A failed assertion aborts before launch.
#   - A pre-existing worktree directory for the branch is a stop-and-report
#     blocker (docs/herdr.md "Known gaps"): it may hold unlanded work; never
#     pre-delete it to make the create succeed.
#   - Writes state/<id>.meta, then launches codex in the task pane with the
#     turn-end notify hook touching state/<id>.turn-ended.
#
# Capo mechanics:
#   - The capo home must already be seeded (cs-home-seed.sh); this script
#     creates the capo home workspace (label capo-<id>) at the home path and
#     launches codex there with CS_HOME pointing at the home. No notify hook:
#     a capo is a supervisor, not a supervised turn-taker.
#
# Every invocation holds a task-id-scoped lock across creation through
# metadata publication, so concurrent same-id spawns serialize.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"
# shellcheck source=bin/cs-operational-input.sh
. "$SCRIPT_DIR/cs-operational-input.sh"
# shellcheck source=bin/cs-harness-lib.sh
. "$SCRIPT_DIR/cs-harness-lib.sh"
# shellcheck source=bin/cs-delivery-lib.sh
. "$SCRIPT_DIR/cs-delivery-lib.sh"
# shellcheck source=bin/cs-timeout-lib.sh
. "$SCRIPT_DIR/cs-timeout-lib.sh"

# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
# Optional turn telemetry (off unless host/telemetry.conf enables it). Sourced
# after cs_resolve_root so it sees this home's resolved DATA/STATE/HOST_DIR.
# shellcheck source=bin/cs-telemetry-lib.sh
. "$SCRIPT_DIR/cs-telemetry-lib.sh"
mkdir -p "$STATE"

# A soldier/capo always inherits the ROOT session's harness. Resolved once here;
# persisted per-soldier as harness= in state/<id>.meta so the watcher, cs-send,
# and cs-crew-state read it back without re-detecting.
HARNESS=$(cs_harness_detect_root)

cs_spawn_apply_dispatch_policy() {
  local file="$CONFIG/dispatch-policy.conf" line entry_harness entry_kind entry_model entry_effort extra
  local line_no=0 seen='|' match_model='' match_effort=''
  # A symlink is allowed as long as it resolves to a regular file, so a home may
  # keep its policy under external configuration management. A symlink that does
  # not resolve stops dispatch rather than falling back to the harness default:
  # silently ignoring a broken policy is indistinguishable from having none.
  if [ -L "$file" ] && [ ! -e "$file" ]; then
    echo "error: dispatch policy symlink does not resolve: $file" >&2
    exit 2
  fi
  [ -e "$file" ] || return 0
  if [ ! -f "$file" ]; then
    echo "error: dispatch policy must be a regular file or a symlink to one: $file" >&2
    exit 2
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    entry_harness='' entry_kind='' entry_model='' entry_effort='' extra=''
    IFS=$' \t' read -r entry_harness entry_kind entry_model entry_effort extra <<EOF
$line
EOF
    case "$entry_harness" in
      ''|'#'*) continue ;;
    esac
    if [ -z "$entry_kind" ] || [ -z "$entry_model" ] || [ -z "$entry_effort" ] || [ -n "$extra" ]; then
      echo "error: dispatch policy line $line_no must be: <harness> <kind> <model> <effort>" >&2
      exit 2
    fi
    if ! cs_harness_valid "$entry_harness"; then
      echo "error: dispatch policy line $line_no has unknown harness '$entry_harness'" >&2
      exit 2
    fi
    case "$entry_kind" in ship|scout|capo) ;; *)
      echo "error: dispatch policy line $line_no has unknown kind '$entry_kind'" >&2
      exit 2
    esac
    case "$entry_model" in default|*[!A-Za-z0-9._:-]*|'')
      echo "error: dispatch policy line $line_no has invalid model '$entry_model'" >&2
      exit 2
    esac
    if ! cs_harness_effort_valid "$entry_harness" "$entry_effort"; then
      echo "error: dispatch policy line $line_no has invalid $entry_harness effort '$entry_effort'" >&2
      exit 2
    fi
    case "$seen" in *"|$entry_harness:$entry_kind|"*)
      echo "error: dispatch policy line $line_no duplicates $entry_harness $entry_kind" >&2
      exit 2
    esac
    seen="$seen$entry_harness:$entry_kind|"
    if [ "$entry_harness" = "$HARNESS" ] && [ "$entry_kind" = "$KIND" ]; then
      match_model=$entry_model
      match_effort=$entry_effort
    fi
  done < "$file"

  [ -n "$MODEL" ] || MODEL=$match_model
  [ -n "$EFFORT" ] || EFFORT=$match_effort
}

KIND=ship
MODEL=
EFFORT=
MODE=
YOLO=
BASE=
HEADLESS=0
# Seconds to wait for an agent to appear after the launch line is delivered.
# Generous on purpose: a cold codex/claude start on a busy machine is slow, and
# a false abort tears down a worktree that was about to work.
LAUNCH_WAIT=${CS_SPAWN_LAUNCH_WAIT_SECS:-60}
case "$LAUNCH_WAIT" in ''|*[!0-9]*|0) LAUNCH_WAIT=60 ;; esac
ISSUE=
POS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scout) KIND=scout ;;
    --capo) KIND=capo ;;
    --headless) HEADLESS=1 ;;
    --model) MODEL=${2:?--model requires a value}; shift ;;
    --effort) EFFORT=${2:?--effort requires a value}; shift ;;
    --mode) MODE=${2:?--mode requires a value}; shift ;;
    --yolo) YOLO=${2:?--yolo requires a value}; shift ;;
    --base) BASE=${2:?--base requires a value}; shift ;;
    --issue) ISSUE=${2:?--issue requires a value}; shift ;;
    -*) echo "error: unknown flag $1" >&2; exit 2 ;;
    *) POS+=("$1") ;;
  esac
  shift
done
if [ -n "$ISSUE" ]; then
  case "$ISSUE" in *[!0-9]*) echo "error: --issue must be a number, got '$ISSUE'" >&2; exit 2 ;; esac
fi
[ "${#POS[@]}" -ge 2 ] || { usage >&2; exit 2; }
ID=${POS[0]}
TARGET=${POS[1]}

case "$ID" in
  *[!A-Za-z0-9._-]*|'') echo "error: task id must be [A-Za-z0-9._-]+: '$ID'" >&2; exit 2 ;;
esac
cs_spawn_apply_dispatch_policy
if ! cs_harness_effort_valid "$HARNESS" "$EFFORT"; then
  case "$HARNESS:$EFFORT" in
    claude:ultra) echo "error: claude does not accept effort=ultra; choose default|low|medium|high|xhigh|max" >&2 ;;
    *) echo "error: unknown effort '$EFFORT'" >&2 ;;
  esac
  exit 2
fi
# Resolve config/permission-mode.conf up front. The launch builders read it too, but
# they run after the worktree and metadata exist; validating here keeps a
# malformed file from leaving a half-created task behind.
cs_harness_permission_mode "$HARNESS" >/dev/null || exit 2
if [ "$HEADLESS" -eq 1 ] && [ "$KIND" != scout ]; then
  echo "error: --headless applies only to --scout tasks" >&2
  exit 2
fi

# The delivery contract is validated with the other pre-flight checks, ahead of
# the spawn lock and the worktree, so a bad or missing flag cannot leave an
# endpoint, workspace, branch, or metadata file behind.
if [ "$KIND" = ship ]; then
  if [ -z "$MODE" ]; then
    echo "error: a ship spawn requires --mode <$CS_DELIVERY_MODES>; the delivery contract is decided per task, not derived from the project registry" >&2
    exit 2
  fi
  if ! cs_delivery_mode_valid "$MODE"; then
    echo "error: --mode must be one of $CS_DELIVERY_MODES, got '$MODE'" >&2
    exit 2
  fi
  if [ -z "$YOLO" ]; then
    echo "error: a ship spawn requires --yolo <$CS_DELIVERY_YOLOS>" >&2
    exit 2
  fi
  if ! cs_delivery_yolo_valid "$YOLO"; then
    echo "error: --yolo must be one of $CS_DELIVERY_YOLOS, got '$YOLO'" >&2
    exit 2
  fi
else
  if [ -n "$MODE" ]; then
    echo "error: --mode applies only to ship spawns; a $KIND deliverable has no delivery mode" >&2
    exit 2
  fi
  if [ -n "$YOLO" ]; then
    echo "error: --yolo applies only to ship spawns; approval posture belongs to a ship task's contract" >&2
    exit 2
  fi
fi

cs_herdr_protocol_check

# Task-id-scoped spawn lock: held from creation through metadata publication so
# concurrent same-id spawns serialize. The lock is a mkdir-atomic directory that
# records the holder's PID. This makes it signal-safe and stale-recoverable: the
# terminating signals are trapped (not only EXIT), so a spawn killed by Ctrl-C or
# a signal releases the lock instead of wedging every later spawn of this id; and
# a lock left behind by a holder that died without running any trap is reclaimed
# on the "already exists" branch. Reclaim can only ever remove a provably
# abandoned lock - a lock whose recorded PID is still live (kill -0), including a
# reused PID, is never treated as stale, and concurrent reclaimers are serialized
# so a live holder's fresh lock is never removed out from under it. A false
# reclaim is worse than a stuck lock, so every uncertain case refuses.
SPAWN_LOCK="$STATE/.spawn-$ID.lock"
SPAWN_RECLAIM_LOCK="$SPAWN_LOCK.reclaim"
SPAWN_LOCK_OWNED=0
SPAWN_RECLAIM_OWNED=0
# A lock with a dead recorded PID is reclaimable at once. A lock with no PID yet
# (holder caught between its mkdir and its PID write, or a legacy pre-PID lock)
# is reclaimed only once it is older than this, so a live holder that is merely
# slow to record its PID is never mistaken for stale.
SPAWN_LOCK_STALE_AFTER=2

_cs_spawn_pid_alive() { # <pid>: 0 iff a live process currently holds this PID
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null
}

_cs_spawn_path_age() { # <path>: whole-second mtime age on stdout; non-zero on failure
  local m now
  if [ "$(uname)" = Darwin ]; then
    m=$(stat -f %m "$1" 2>/dev/null) || m=
  else
    m=$(stat -c %Y "$1" 2>/dev/null) || m=
  fi
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  printf '%s\n' "$(( now - m ))"
}

# _cs_spawn_lock_is_stale: 0 iff the lock currently at $SPAWN_LOCK is provably
# abandoned - a dead recorded PID, or no PID on a lock past the grace window.
_cs_spawn_lock_is_stale() {
  local pid age
  pid=$(cat "$SPAWN_LOCK/pid" 2>/dev/null || true)
  if [ -n "$pid" ]; then
    _cs_spawn_pid_alive "$pid" && return 1
    return 0
  fi
  age=$(_cs_spawn_path_age "$SPAWN_LOCK") || return 1
  [ "$age" -ge "$SPAWN_LOCK_STALE_AFTER" ]
}

# _cs_spawn_lock_acquire: 0 with the lock held (PID recorded, SPAWN_LOCK_OWNED=1),
# 1 if a genuinely live spawn holds it. Reclaim of a stale lock is serialized by
# an atomic mkdir on a sibling reclaim lock and re-verified under it, so at most
# one reclaimer removes-and-recreates the lock; racers that lose the reclaim, or
# find the lock freshly recreated, refuse rather than delete a live lock.
_cs_spawn_lock_acquire() {
  if mkdir "$SPAWN_LOCK" 2>/dev/null; then
    printf '%s\n' "$$" > "$SPAWN_LOCK/pid" 2>/dev/null || true
    SPAWN_LOCK_OWNED=1
    return 0
  fi
  _cs_spawn_lock_is_stale || return 1
  mkdir "$SPAWN_RECLAIM_LOCK" 2>/dev/null || return 1
  SPAWN_RECLAIM_OWNED=1
  local rc=1
  # No other reclaimer can remove/recreate the lock while we hold the reclaim
  # lock, so this second staleness read is authoritative before we delete.
  if _cs_spawn_lock_is_stale; then
    rm -f "$SPAWN_LOCK/pid" 2>/dev/null || true
    rmdir "$SPAWN_LOCK" 2>/dev/null || true
    if mkdir "$SPAWN_LOCK" 2>/dev/null; then
      printf '%s\n' "$$" > "$SPAWN_LOCK/pid" 2>/dev/null || true
      SPAWN_LOCK_OWNED=1
      rc=0
    fi
  fi
  rmdir "$SPAWN_RECLAIM_LOCK" 2>/dev/null || true
  SPAWN_RECLAIM_OWNED=0
  return "$rc"
}

_cs_spawn_cleanup() {
  if [ "$SPAWN_RECLAIM_OWNED" = 1 ]; then
    rmdir "$SPAWN_RECLAIM_LOCK" 2>/dev/null || true
  fi
  if [ "$SPAWN_LOCK_OWNED" = 1 ]; then
    rm -f "$SPAWN_LOCK/pid" 2>/dev/null || true
    rmdir "$SPAWN_LOCK" 2>/dev/null || true
  fi
}
trap _cs_spawn_cleanup EXIT INT TERM HUP

if ! _cs_spawn_lock_acquire; then
  echo "error: another spawn for '$ID' is in flight (lock $SPAWN_LOCK)" >&2
  exit 1
fi

if [ -e "$STATE/$ID.meta" ]; then
  echo "error: task '$ID' already has metadata at $STATE/$ID.meta; tear it down or pick a new id" >&2
  exit 1
fi

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

BRIEF="$DATA/$ID/brief.md"
sq_operational=$(shell_quote "$SCRIPT_DIR/cs-operational-input.sh")

# ---------------------------------------------------------------- capo spawn
if [ "$KIND" = capo ]; then
  HOME_DIR=$TARGET
  [ -d "$HOME_DIR" ] || { echo "error: capo home '$HOME_DIR' does not exist; seed it with cs-home-seed.sh first" >&2; exit 1; }
  [ -f "$HOME_DIR/.cs-capo-home" ] || { echo "error: '$HOME_DIR' is not a seeded capo home (missing .cs-capo-home)" >&2; exit 1; }
  [ -f "$BRIEF" ] || { echo "error: charter brief missing at $BRIEF; scaffold with cs-brief.sh --capo first" >&2; exit 1; }
  HOME_ABS=$(cd "$HOME_DIR" && pwd -P)

  WS=$(cs_herdr_home_workspace_ensure "capo-$ID" "$HOME_ABS") || {
    echo "error: cannot resolve a single workspace for capo home '$HOME_ABS' (see the herdr diagnostic above)" >&2; exit 1; }
  # The home workspace root pane is the capo's supervisor pane.
  PANE=$(cs_herdr_workspace_root_pane "$WS") || {
    echo "error: cannot resolve a pane in capo workspace $WS" >&2; exit 1; }

  cs_meta_write "$STATE/$ID.meta" \
    "workspace=$WS" \
    "pane=$PANE" \
    "worktree=$HOME_ABS" \
    "project=$HOME_ABS" \
    "model=${MODEL:-default}" \
    "effort=${EFFORT:-default}" \
    "kind=capo" \
    "mode=capo" \
    "yolo=off" \
    "harness=$HARNESS" \
    "home=$HOME_ABS"

  sq_brief=$(shell_quote "$BRIEF")
  sq_home=$(shell_quote "$HOME_ABS")
  LAUNCH=$(cs_harness_capo_launch "$HARNESS" "${MODEL:-default}" "${EFFORT:-default}" "$sq_operational" "$sq_brief" "$sq_home")
  cs_herdr_run "$PANE" "$LAUNCH" >/dev/null
  # `pane run` reports success even when a not-yet-ready shell swallowed the
  # line, so a capo could be recorded as provisioned while its pane sits at a
  # bare prompt forever. Require the agent to actually appear.
  if ! cs_herdr_agent_wait_present "$PANE" "$LAUNCH_WAIT"; then
    echo "error: capo $ID launched into $PANE but no agent appeared within ${LAUNCH_WAIT}s; the launch line was likely swallowed by a shell that was not ready. The home and its workspace are left intact - retry the spawn." >&2
    exit 1
  fi
  # TELEMETRY, measurement only: attribute this turn to dispatch. A capo is a
  # supervisor, not a supervised turn-taker, so its launch carries no turn-end
  # wiring here; the capo's OWN home emits its turns through its own Stop hook
  # once that home enables telemetry itself (host/ never propagates).
  cs_telemetry_crumb spawn capo || true
  echo "spawned $ID kind=capo home=$HOME_ABS workspace=$WS pane=$PANE"
  exit 0
fi

# ---------------------------------------------------------- ship/scout spawn
PROJ=$TARGET
[ -d "$PROJ" ] || { echo "error: project dir '$PROJ' does not exist" >&2; exit 1; }
[ -f "$BRIEF" ] || { echo "error: brief missing at $BRIEF; scaffold with cs-brief.sh first" >&2; exit 1; }
PROJ_ABS=$(cd "$PROJ" && pwd -P)
git -C "$PROJ_ABS" rev-parse --show-toplevel >/dev/null 2>&1 || {
  echo "error: '$PROJ_ABS' is not a git checkout" >&2; exit 1; }

PROJECT_NAME=$(basename "$PROJ_ABS")

# Cross-check the brief against --mode, and note an advisory deviation from the
# project's standing registry posture. Both run here, ahead of
# cs_herdr_task_create, so a refusal leaves no worktree, workspace, or branch.
if [ "$KIND" = ship ]; then
  if BRIEF_MODE=$(cs_delivery_brief_mode "$BRIEF"); then
    if [ "$BRIEF_MODE" != "$MODE" ]; then
      echo "error: brief $BRIEF records '$CS_DELIVERY_CONTRACT_PREFIX$BRIEF_MODE' but this spawn passed --mode $MODE" >&2
      echo "The worker's definition of done and the task's durable record would disagree. Re-scaffold the brief for $MODE, or spawn with --mode $BRIEF_MODE." >&2
      exit 2
    fi
  else
    echo "warn: brief $BRIEF carries no '$CS_DELIVERY_CONTRACT_PREFIX<mode>' line (scaffolded before the explicit delivery contract); launching on --mode $MODE" >&2
  fi
  # --standing prints the registry posture only for a REGISTERED project and stays
  # silent otherwise, so an unregistered project (the consigliere repo itself, for
  # one) has no standing posture to deviate from and reports nothing.
  if STANDING=$("$CS_ROOT/bin/cs-project-mode.sh" --standing "$PROJECT_NAME" 2>/dev/null); then
    STANDING_MODE=${STANDING%% *}
    if [ "$(cs_delivery_mode_rigor "$MODE")" -lt "$(cs_delivery_mode_rigor "$STANDING_MODE")" ]; then
      echo "notice: $PROJECT_NAME's standing registry posture is $STANDING_MODE; this task ships $MODE, which carries less rigor. The registry is advisory - continuing." >&2
    fi
  fi
fi

BRANCH="cs/$ID"
if git -C "$PROJ_ABS" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "error: branch '$BRANCH' already exists in $PROJ_ABS; a previous task '$ID' was not fully cleaned up" >&2
  exit 1
fi

# ------------------------------------------------------------ base freshness
# Without --base, the task branch starts from the clone's current HEAD, and this
# home refreshes a clone only at session start or after a merged-PR wake IT saw.
# A merge this home never saw - the boss merging from a phone, another home or a
# capo landing work - leaves the clone behind origin, so the soldier would build
# on old main and only find out late, in a rebase or a conflicting PR.
# cs-fleet-sync.sh already owns every rule for refreshing a clone safely (the
# fetch guard, the off-default/dirty/diverged STUCK semantics, fast-forward only,
# never forcing or stashing), so this reuses it whole rather than fast-forwarding
# a second way here.
# It is deliberately fail-OPEN and bounded: a dead network must not block
# dispatch. But a stale base must never be silent, so anything short of a clone
# confirmed current with origin prints a loud warning and the spawn proceeds on
# the local HEAD.
FRESHNESS_TIMEOUT=${CS_SPAWN_BASE_FRESHNESS_TIMEOUT_SECS:-25}
case "$FRESHNESS_TIMEOUT" in ''|*[!0-9]*|0) FRESHNESS_TIMEOUT=25 ;; esac

warn_stale_base() {  # <reason>
  echo "warn: could not confirm $PROJECT_NAME is current with origin ($1); '$BRANCH' starts from the local HEAD, which may be behind" >&2
}

# Refresh the clone's default branch, then report what happened. fleet-sync
# prints one classification line per project on stdout; cs-guard.sh banners share
# that stream, so only the recognized classifications are matched, and the last
# one is the verdict (a packed-refs "recovered:" line precedes the final line).
refresh_base() {
  local out rc line
  out=$(cs_run_timed "$FRESHNESS_TIMEOUT" "$CS_ROOT/bin/cs-fleet-sync.sh" "$PROJ_ABS" 2>/dev/null) && rc=0 || rc=$?
  case "$rc" in
    0) ;;
    124) warn_stale_base "the origin check did not finish within ${FRESHNESS_TIMEOUT}s"; return 0 ;;
    "$CS_TIMEOUT_UNAVAILABLE") warn_stale_base "the origin check could not be run under a time bound"; return 0 ;;
    *) warn_stale_base "the refresh exited $rc"; return 0 ;;
  esac
  line=$(printf '%s\n' "$out" \
    | grep -E ': (STUCK: |skipped: |synced |already current|recovered: )' | tail -1)
  case "$line" in
    # Nothing to be fresh against: these clones have no origin to compare to.
    *": skipped: local-only project"*|*": skipped: no origin remote"*) ;;
    *": STUCK: "*)
      # fleet-sync left the clone alone on purpose - it may hold real work.
      warn_stale_base "${line#*: }" ;;
    *": skipped: "*) warn_stale_base "${line#*: skipped: }" ;;
    *": synced "*|*": recovered: "*)
      echo "notice: refreshed $PROJECT_NAME from origin before branching (${line#*: })" >&2 ;;
    *": already current"*) ;;
    *) warn_stale_base "the refresh reported no recognizable result" ;;
  esac
}

# An explicit --base names the ref the boss/consigliere chose, so there is no
# implicit current-HEAD base to keep fresh: skip the check entirely.
[ -n "$BASE" ] || refresh_base

if ! TUPLE=$(cs_herdr_task_create "$PROJ_ABS" "$BRANCH" "$ID" "$BASE"); then
  echo "error: herdr worktree create failed for '$ID' (a pre-existing worktree directory may hold unlanded work; inspect ~/.herdr/worktrees/$PROJECT_NAME/ - never pre-delete it to force the spawn)" >&2
  exit 1
fi
WS=$(printf '%s' "$TUPLE" | cut -f1)
PANE=$(printf '%s' "$TUPLE" | cut -f2)
WT=$(printf '%s' "$TUPLE" | cut -f3)

abort_task() { # <message>
  echo "error: $1" >&2
  cs_herdr_worktree_remove "$WS" >/dev/null 2>&1 || true
  exit 1
}

# Fail-closed isolation assertion on physically-resolved paths.
WT_REAL=$(cd "$WT" 2>/dev/null && pwd -P) || WT_REAL=
WT_TOP=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
WT_TOP_REAL=$(cd "$WT_TOP" 2>/dev/null && pwd -P) || WT_TOP_REAL=
if [ -z "$WT_REAL" ] || [ -z "$WT_TOP_REAL" ] || [ "$WT_REAL" != "$WT_TOP_REAL" ] || [ "$WT_REAL" = "$PROJ_ABS" ]; then
  abort_task "spawn did not yield an isolated worktree (resolved '$WT'; worktree root '${WT_TOP:-none}'; primary '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout"
fi

TURNEND="$STATE/$ID.turn-ended"
META_LINES=(
  "workspace=$WS"
  "pane=$PANE"
  "worktree=$WT_REAL"
  "project=$PROJ_ABS"
  "model=${MODEL:-default}"
  "effort=${EFFORT:-default}"
  "kind=$KIND"
)
# A scout records no delivery posture at all: its deliverable is a report, so
# there is no mode to honour and no approval posture to apply. cs-promote.sh
# states both explicitly when a scout is promoted to ship.
[ "$KIND" = ship ] && META_LINES+=("mode=$MODE" "yolo=$YOLO")
META_LINES+=("harness=$HARNESS")
[ "$HEADLESS" -eq 1 ] && META_LINES+=("headless=1")
[ -n "$ISSUE" ] && META_LINES+=("issue=$ISSUE")
cs_meta_write "$STATE/$ID.meta" "${META_LINES[@]}"

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
MODEL_ARG=${MODEL:-default}
EFFORT_ARG=${EFFORT:-default}
# TELEMETRY, measurement only. Resolved HERE, at spawn, so a soldier launched
# while telemetry is off carries a byte-identical launch line and settings file:
# with no command to add, every builder below produces exactly what it produced
# before this instrumentation existed. A headless scout gets none - its turn end
# is process exit, and the launch line's terminal status append is the signal
# that must not be complicated. The stdin mode differs per harness: claude feeds
# the Stop payload to every hook command, while codex's notify program is called
# with an argument and no piped payload, so reading stdin there would block.
TELEMETRY_HOOK=
if [ "$HEADLESS" -eq 0 ]; then
  case "$HARNESS" in
    claude) TELEMETRY_HOOK=$(cs_telemetry_worker_hook_command "$ID" "$SCRIPT_DIR" stdin) ;;
    codex) TELEMETRY_HOOK=$(cs_telemetry_worker_hook_command "$ID" "$SCRIPT_DIR" nostdin) ;;
  esac
fi
if [ "$HEADLESS" -eq 1 ]; then
  # Fire-and-forget scout: the harness runs the brief non-interactively (codex
  # exec / claude -p); the launch line appends the terminal status event, so
  # completion surfaces through the watcher's ordinary signal path with no
  # special classification. No turn-end hook: process exit IS the turn end.
  sq_status=$(shell_quote "$STATE/$ID.status")
  LAUNCH=$(cs_harness_scout_launch "$HARNESS" "$MODEL_ARG" "$EFFORT_ARG" "$sq_operational" "$sq_brief" "$sq_status")
else
  # Interactive supervised soldier. codex wires turn-end inline via -c notify;
  # claude via a launch-scoped --settings Stop hook written per-soldier here
  # (claude resolves a repo .claude/settings.json to the main checkout, so a
  # worktree file would pollute the boss's project and not isolate the soldier).
  sq_settings=''
  if [ "$HARNESS" = claude ]; then
    SETTINGS_FILE="$STATE/$ID.claude-settings.json"
    cs_harness_claude_settings_json "$TURNEND" "$TELEMETRY_HOOK" > "$SETTINGS_FILE"
    sq_settings=$(shell_quote "$SETTINGS_FILE")
    # Interactive claude blocks at the folder-trust dialog for a fresh worktree;
    # pre-trust it so the unattended soldier can take its first turn.
    cs_harness_claude_trust_dir "$WT_REAL" || abort_task "could not pre-trust claude worktree $WT_REAL"
  fi
  LAUNCH=$(cs_harness_soldier_launch "$HARNESS" "$MODEL_ARG" "$EFFORT_ARG" "$sq_operational" "$sq_brief" "$sq_turnend" "$sq_settings" "$TELEMETRY_HOOK")
fi
cs_herdr_run "$PANE" "$LAUNCH" >/dev/null

# Verify the launch actually started something. `pane run` hands the line to the
# pane's SHELL and reports success whether or not the shell was ready to read
# it; a freshly created worktree pane frequently is not, and the line is then
# lost with no way to recover it from the buffer. Without this check cs-spawn
# prints "spawned", consigliere records the task as under way, and the pane sits
# at a prompt until the stale timer eventually notices - a soldier that reported
# success and never existed.
#
# Interactive soldiers are gated on agent detection. A HEADLESS scout is not: it
# runs `codex exec` / `claude -p`, a plain process rather than an interactive
# agent taking the pane, so herdr agent detection is not a valid signal for it.
# Its swallowed-launch case is caught instead by the absence of the terminal
# done:/failed: status event its launch line appends, via the ordinary stale
# path - slower, but not silent. Gating headless properly needs a verified
# process-level signal and is deliberately not guessed at here.
if [ "$HEADLESS" -eq 0 ] && ! cs_herdr_agent_wait_present "$PANE" "$LAUNCH_WAIT"; then
  abort_task "launched $ID into $PANE but no agent appeared within ${LAUNCH_WAIT}s; the launch line was likely swallowed by a shell that was not ready"
fi

# TELEMETRY, measurement only: attribute the CONSIGLIERE turn that ran this
# spawn to dispatch. The soldier's own turns are recorded separately by the
# turn-end wiring above, in this same home.
cs_telemetry_crumb spawn "$KIND" || true

HEADLESS_NOTE=""
[ "$HEADLESS" -eq 1 ] && HEADLESS_NOTE=" headless=1"
POSTURE_NOTE=""
[ "$KIND" = ship ] && POSTURE_NOTE=" mode=$MODE yolo=$YOLO"
echo "spawned $ID kind=$KIND$POSTURE_NOTE workspace=$WS pane=$PANE worktree=$WT_REAL$HEADLESS_NOTE"
