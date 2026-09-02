#!/usr/bin/env bash
# Spawn a direct report: a soldier in a herdr-native task worktree, or a capo
# in its isolated consigliere home.
# Usage: cs-spawn.sh <task-id> <project-dir> --mode <made|direct-PR|local-only> --yolo <on|off> [--base <ref>] [--issue <n>]
#        cs-spawn.sh <task-id> <project-dir> [--parent <task-id>] [--parent-home <path>] [--parent-pane <pane>] [--parent-generation <generation>] [--parent-herdr-session <name>]
#        cs-spawn.sh <task-id> <project-dir> --scout [--headless] [--base <ref>]
#        cs-spawn.sh <task-id> <capo-home> --capo
#        cs-spawn.sh --relaunch <task-id>
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
#   Model and reasoning level are NOT selectable here: the harness resolves its own
#   profile per task (AGENTS.md's intro; bin/cs-harness-lib.sh owns the facts), so no launch built here names either.
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
#   --backlog-item <id> (ship/scout) names the backlog work item this dispatch
#     begins. The spawn records backlog_item=<id> in meta and moves the item to
#     In flight through tasks-axi as part of dispatch, under the spawn lock and
#     before reporting success, so the task record and the backlog row cannot
#     drift apart. A failed transition fails the spawn loudly and removes the
#     provisional record. With a manual backend or no compatible tasks-axi the
#     transition is skipped with a printed hand-edit reminder; with no
#     --backlog-item the spawn prints a reminder to move the item yourself.
#     Refused on --capo (a capo is never a backlog item) and --relaunch (the
#     dispatch transition already happened).
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
#   - Reports loudly when the launched agent settles in herdr's native `blocked`
#     state - waiting on a HUMAN, e.g. the harness's directory-trust prompt for a
#     repository root it holds no trust record for. The spawn still succeeds and
#     nothing is torn down, because that block clears with one keystroke; the
#     report exists so a worker that cannot start is named as such at the moment
#     it is created rather than reading as ordinary idleness.
#     CS_SPAWN_HUMAN_GATE_SECS (default 10) bounds the settle window. Applies to
#     ship, scout, capo, and relaunch; a headless scout takes no pane agent, so
#     herdr's agent state says nothing about it and it is exempt.
#   - Codegraph index prep (interactive ship/scout spawn and relaunch, both
#     harnesses): when the project's primary checkout carries a built
#     codegraph index (.codegraph/codegraph.db) and the worktree's committed
#     ignore rules already exclude .codegraph, runs `codegraph init
#     <worktree>` so the soldier's first turn has a working index (codegraph
#     indexes by absolute path, so a worktree at a new path never inherits
#     the primary's index on its own). Fail-open and time-bounded by
#     CS_SPAWN_CODEGRAPH_TIMEOUT_SECS (default 10, docs/codegraph.md): no
#     codegraph binary, no primary index, an unclean ignore guard, or an
#     exhausted bound all warn (or stay silent) and never block the spawn.
#     CS_SPAWN_CODEGRAPH_PREP=off disables it entirely.
#
# Relaunch mechanics (--relaunch <task-id>):
#   - ADOPTS the endpoint and worktree recorded in state/<id>.meta instead of
#     creating either, so a wedged soldier is replaced in place with its local
#     copy, its commits, and its uncommitted changes untouched. It is the launch
#     half of bin/cs-control.sh relaunch, which owns the transaction, the
#     journal, the progress note, and stopping the old agent; nothing here
#     removes, closes, or discards anything.
#   - Refuses unless the recorded pane is POSITIVELY agent-free and its shell is
#     sitting in the recorded worktree, so a replacement can never join a live
#     agent or start outside the copy holding the work.
#   - Refuses a kind=capo task (capo-provisioning owns a home's lifecycle) and a
#     headless scout (no interactive agent to replace).
#   - Prefers the harness resume invocation (cs_harness_resume_argv) so the
#     soldier's own session and context survive: both harnesses key sessions by
#     cwd and every soldier owns a unique worktree cwd. It falls back to a cold
#     launch with the brief only once the pane is positively agent-free again,
#     which is exactly what a harness that had no session to resume leaves
#     behind (docs/codex.md, docs/claude.md).
#   - Keeps the recorded harness, kind, mode, and yolo; the harness is
#     deliberately not switchable, since a soldier inherits the root session's
#     harness.
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
# The relaunch path adopts a recorded endpoint, so it shares the control plane's
# definition of "positively agent-free" and "sitting in that worktree" rather
# than keeping a second copy of either.
# shellcheck source=bin/cs-control-lib.sh
. "$SCRIPT_DIR/cs-control-lib.sh"

# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
# cs_lock_path_mtime, the one owner of the portable stat mtime read, for the
# spawn-lock staleness check.
# shellcheck source=bin/cs-lock-lib.sh
. "$SCRIPT_DIR/cs-lock-lib.sh"
# Backlog backend selection and the dispatch transition (--backlog-item).
# shellcheck source=bin/cs-tasks-lib.sh
. "$SCRIPT_DIR/cs-tasks-lib.sh"
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

# report_human_gate <pane> <harness> <subject>: an agent that PRESENTS and then settles in
# herdr's native `blocked` state is waiting on a human, not working. The
# agent-presence gate above cannot tell the two apart - the process is there and
# herdr reports an agent either way - so without this the spawn prints a clean
# success line for a worker that has not read one word of its instructions and
# never will. Verified live (docs/codex.md): a codex TUI launched into a
# repository root it holds no trust record for parks on the directory-trust
# prompt indefinitely, and neither autonomy flag suppresses that prompt.
#
# Deliberately a report, not a failure: the pane, the worktree, and the agent
# are all legitimate and the block clears with one keystroke, so tearing the task
# down would destroy recoverable work over a recoverable state. The spawn still
# succeeds, and the watcher's own immediate `blocked` escalation still applies;
# this only makes the condition legible at the moment it is created, with its
# concrete cause named instead of "stopped responding" four minutes later.
report_human_gate() {  # <pane> <harness> <subject>
  local pane=$1 harness=$2 subject=$3 re detail=''
  if cs_herdr_agent_wait_unblocked "$pane" "$HUMAN_GATE_WAIT"; then
    return 0
  fi
  if re=$(cs_harness_trust_prompt_re "$harness") \
    && cs_herdr_capture "$pane" 60 text 2>/dev/null | grep -Eq "$re"; then
    detail=" at the $harness directory-trust prompt, which it shows once for a repository root it holds no trust record for"
  fi
  printf 'warning: %s is waiting on a human%s in pane %s; it has not read its instructions and will not start until that prompt is answered\n' \
    "$subject" "$detail" "$pane" >&2
}

report_task_metadata() {
  local pane=$1 task_id=$2 display_mode=$3
  if ! cs_herdr_report_task_metadata "$pane" "$task_id" "$display_mode"; then
    printf 'warning: could not publish display labels for %s in pane %s; the durable record remains authoritative\n' \
      "$task_id" "$pane" >&2
  fi
}

# _cs_spawn_env_export_confirmed <pane> <env-prefix-string>: exports a
# non-empty space-separated VAR=val prefix (the same shape cs_harness_launch_env
# returns) into the pane and confirms it landed before the caller starts an
# agent there - `agent start`'s trailing argv has no shell prefix-assignment
# support and neither it nor `worktree create` has an --env flag, so this
# pre-step is how a launch's environment reaches the agent at all. A no-op
# (success) when the prefix is empty.
_cs_spawn_env_export_confirmed() {
  local pane=$1 prefix=$2 started=$SECONDS elapsed remaining_ms attempt_ms
  [ -n "$prefix" ] || return 0
  while :; do
    elapsed=$((SECONDS - started))
    [ "$elapsed" -lt "$ENV_STEP_WAIT" ] || return 1
    remaining_ms=$(( (ENV_STEP_WAIT - elapsed) * 1000 ))
    attempt_ms=$remaining_ms
    [ "$attempt_ms" -gt 1000 ] && attempt_ms=1000
    cs_herdr_pane_run_confirmed "$pane" "export $prefix" "$attempt_ms" && return 0
  done
}

# _cs_spawn_deliver_brief <pane> <encoded-brief>: delivers the brief as the
# agent's first prompt on a pane cs-spawn.sh just bare-started itself (agent
# start with no positional argument - see above). Deliberately does NOT go
# through bin/cs-prompt-lib.sh's general-purpose cs_prompt_guarded: its
# composer-empty check (live-verified 2026-08-13) misreads a genuinely fresh
# claude session as "unknown" forever, because the VERY FIRST frame after
# launch shows a project-title banner where the classifier expects a rule
# immediately above the composer glyph - a frame shape distinct from every
# case its own test suite covers, and one that never resolves on its own
# since nothing changes the render until a first prompt actually lands. That
# check exists to stop a prompt from concatenating onto text something ELSE
# already typed, a risk that cannot apply here: this pane was created by this
# same spawn moments ago and nothing else has ever had the chance to type into
# it. The busy/blocked check still applies (cheap, unaffected by the same
# blind spot, and a real signal), and cs_herdr_agent_prompt_confirmed's own
# idle->working confirmation is still what proves the turn actually started.
# Retries because a prompt sent within ~40s of agent start can be silently
# lost while herdr still reports interactive_ready (measured on both
# harnesses, bin/cs-prompt-lib.sh); that same confirmation catches a miss, so
# retrying is safe.
_cs_spawn_deliver_brief() {
  local pane=$1 brief=$2 start=$SECONDS bs
  while [ $((SECONDS - start)) -lt "$BRIEF_DELIVER_WAIT" ]; do
    bs=$(cs_herdr_agent_busy_state "$pane" 2>/dev/null) || bs=unknown
    case "$bs" in
      busy|blocked) : ;;
      *) cs_herdr_agent_prompt_confirmed "$pane" "$brief" >/dev/null 2>&1 && return 0 ;;
    esac
    sleep "$BRIEF_DELIVER_RETRY_SECS"
  done
  return 1
}

KIND=ship
MODE=
YOLO=
BASE=
HEADLESS=0
PARENT_TASK=
PARENT_HOME=
PARENT_PANE=
PARENT_GENERATION=
PARENT_HERDR_SESSION=
# Seconds to wait for an agent to appear after the launch line is delivered.
# Generous on purpose: a cold codex/claude start on a busy machine is slow, and
# a false abort tears down a worktree that was about to work.
LAUNCH_WAIT=${CS_SPAWN_LAUNCH_WAIT_SECS:-60}
case "$LAUNCH_WAIT" in ''|*[!0-9]*|0) LAUNCH_WAIT=60 ;; esac
# Seconds a freshly launched agent may sit in herdr's native `blocked` state
# before the spawn says so out loud. Short on purpose: this window only has to
# outlast a startup transient, and the agent-presence wait above has already
# absorbed the slow part of a cold start.
HUMAN_GATE_WAIT=${CS_SPAWN_HUMAN_GATE_SECS:-10}
case "$HUMAN_GATE_WAIT" in ''|*[!0-9]*) HUMAN_GATE_WAIT=10 ;; esac
# Seconds to wait for the pre-agent-start environment export (CLAUDE_CONFIG_DIR
# under a work/personal account split; a capo's CS_HOME and override clears) to
# be confirmed on the pane before starting the agent. Short on purpose: the
# export itself is near-instant once the shell is ready to read it.
ENV_STEP_WAIT=${CS_SPAWN_ENV_STEP_WAIT_SECS:-10}
case "$ENV_STEP_WAIT" in ''|*[!0-9]*|0) ENV_STEP_WAIT=10 ;; esac
# Seconds to keep retrying brief delivery after a bare agent start. A prompt
# sent within ~40s of agent start can be silently lost while herdr still
# reports interactive_ready (bin/cs-prompt-lib.sh, measured on both harnesses);
# this window is generous enough to retry past it.
BRIEF_DELIVER_WAIT=${CS_SPAWN_BRIEF_DELIVER_WAIT_SECS:-50}
case "$BRIEF_DELIVER_WAIT" in ''|*[!0-9]*|0) BRIEF_DELIVER_WAIT=50 ;; esac
BRIEF_DELIVER_RETRY_SECS=${CS_SPAWN_BRIEF_DELIVER_RETRY_SECS:-5}
case "$BRIEF_DELIVER_RETRY_SECS" in ''|*[!0-9]*|0) BRIEF_DELIVER_RETRY_SECS=5 ;; esac
ISSUE=
BACKLOG_ITEM=
RELAUNCH=0
POS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scout) KIND=scout ;;
    --capo) KIND=capo ;;
    --relaunch) RELAUNCH=1 ;;
    --headless) HEADLESS=1 ;;
    --mode) MODE=${2:?--mode requires a value}; shift ;;
    --yolo) YOLO=${2:?--yolo requires a value}; shift ;;
    --base) BASE=${2:?--base requires a value}; shift ;;
    --issue) ISSUE=${2:?--issue requires a value}; shift ;;
    --backlog-item) BACKLOG_ITEM=${2:?--backlog-item requires a value}; shift ;;
    --parent) PARENT_TASK=${2:?--parent requires a task id}; shift ;;
    --parent-home) PARENT_HOME=${2:?--parent-home requires a path}; shift ;;
    --parent-pane) PARENT_PANE=${2:?--parent-pane requires a pane}; shift ;;
    --parent-generation) PARENT_GENERATION=${2:?--parent-generation requires a generation}; shift ;;
    --parent-herdr-session) PARENT_HERDR_SESSION=${2:?--parent-herdr-session requires a session}; shift ;;
    -*) echo "error: unknown flag $1" >&2; exit 2 ;;
    *) POS+=("$1") ;;
  esac
  shift
done
if [ -n "$ISSUE" ]; then
  case "$ISSUE" in *[!0-9]*) echo "error: --issue must be a number, got '$ISSUE'" >&2; exit 2 ;; esac
fi
if [ "$RELAUNCH" -eq 1 ]; then
  # A relaunch adopts one recorded task: everything that describes a NEW task is
  # refused rather than silently ignored, because the recorded posture is the
  # authority and a flag here would look like it had changed something.
  [ "${#POS[@]}" -eq 1 ] || { echo "error: --relaunch takes exactly one task id (the project, branch, and posture come from state/<id>.meta)" >&2; exit 2; }
  relaunch_refuse_flag() { # <flag> <value>
    [ -z "$2" ] && return 0
    echo "error: $1 does not apply to --relaunch; the task's recorded metadata owns it" >&2
    exit 2
  }
  [ "$KIND" = ship ] || relaunch_refuse_flag "--$KIND" 1
  [ "$HEADLESS" -eq 0 ] || relaunch_refuse_flag --headless 1
  relaunch_refuse_flag --mode "$MODE"
  relaunch_refuse_flag --yolo "$YOLO"
  relaunch_refuse_flag --base "$BASE"
  relaunch_refuse_flag --issue "$ISSUE"
  relaunch_refuse_flag --backlog-item "$BACKLOG_ITEM"
  relaunch_refuse_flag --parent "$PARENT_TASK"
  relaunch_refuse_flag --parent-home "$PARENT_HOME"
  relaunch_refuse_flag --parent-pane "$PARENT_PANE"
  relaunch_refuse_flag --parent-generation "$PARENT_GENERATION"
  relaunch_refuse_flag --parent-herdr-session "$PARENT_HERDR_SESSION"
  ID=${POS[0]}
else
  [ "${#POS[@]}" -ge 2 ] || { usage >&2; exit 2; }
  ID=${POS[0]}
  TARGET=${POS[1]}
fi

case "$ID" in
  *[!A-Za-z0-9._-]*|'') echo "error: task id must be [A-Za-z0-9._-]+: '$ID'" >&2; exit 2 ;;
esac

if [ -n "$PARENT_TASK" ] && [ -z "$PARENT_HOME" ]; then
  PARENT_META="$STATE/$PARENT_TASK.meta"
  if [ -f "$PARENT_META" ]; then
    PARENT_HOME=$(cs_meta_get "$PARENT_META" home 2>/dev/null || true)
    PARENT_PANE=${PARENT_PANE:-$(cs_meta_get "$PARENT_META" pane 2>/dev/null || true)}
    PARENT_GENERATION=${PARENT_GENERATION:-$(cs_meta_get "$PARENT_META" endpoint_generation 2>/dev/null || true)}
    PARENT_HERDR_SESSION=${PARENT_HERDR_SESSION:-$(cs_meta_get "$PARENT_META" herdr_session 2>/dev/null || true)}
  elif [ "$PARENT_TASK" != root ]; then
    echo "error: immediate parent '$PARENT_TASK' is not recorded in $STATE; pass a complete cross-home parent edge or repair the parent first" >&2
    exit 2
  fi
fi
if [ -n "$PARENT_TASK" ] && [ "$PARENT_TASK" != root ] && {
  [ -z "$PARENT_HOME" ] || [ -z "$PARENT_PANE" ] || [ -z "$PARENT_GENERATION" ];
}; then
  echo "error: nested spawn requires parent home, pane, and endpoint generation" >&2
  exit 2
fi
PARENT_TASK=${PARENT_TASK:-root}
PARENT_HOME=${PARENT_HOME:-$CS_HOME}
PARENT_STATE=${PARENT_HOME}/state
PARENT_PANE=${PARENT_PANE:-${HERDR_PANE_ID:-unknown}}
if [ -z "$PARENT_HERDR_SESSION" ] && [ -f "$PARENT_STATE/$PARENT_TASK.meta" ]; then
  PARENT_HERDR_SESSION=$(cs_meta_get "$PARENT_STATE/$PARENT_TASK.meta" herdr_session 2>/dev/null || true)
fi
if [ -z "$PARENT_GENERATION" ] && [ "$PARENT_TASK" = root ] && [ -f "$PARENT_STATE/.home-endpoint-generation" ]; then
  PARENT_GENERATION=$(sed -n '1p' "$PARENT_STATE/.home-endpoint-generation")
fi
PARENT_GENERATION=${PARENT_GENERATION:-${CS_PARENT_ENDPOINT_GENERATION:-unknown}}
PARENT_HERDR_SESSION=${PARENT_HERDR_SESSION:-${CS_PARENT_HERDR_SESSION:-$(cs_herdr_session)}}
ENDPOINT_GENERATION=${CS_ENDPOINT_GENERATION:-task-$$-$(date +%s)-$RANDOM}
if ! cs_meta_validate_parent_values "$PARENT_TASK" "$PARENT_HOME" "$PARENT_STATE" \
  "$PARENT_PANE" "$PARENT_GENERATION" "$ENDPOINT_GENERATION"; then
  echo "error: invalid or unavailable immediate-parent edge for '$ID'" >&2
  exit 2
fi
cs_meta_validate_herdr_session "$PARENT_HERDR_SESSION" || {
  echo "error: invalid immediate-parent Herdr session for '$ID'" >&2
  exit 2
}
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
if [ "$RELAUNCH" -eq 1 ]; then
  # The delivery contract was stated when the task was dispatched and lives in
  # state/<id>.meta; a relaunch neither restates nor revisits it.
  :
elif [ "$KIND" = ship ]; then
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
  if [ "$KIND" = capo ] && [ -n "$BACKLOG_ITEM" ]; then
    echo "error: --backlog-item applies only to ship and scout spawns; a capo is never a backlog item" >&2
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
  m=$(cs_lock_path_mtime "$1") || return 1
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

if [ "$RELAUNCH" -eq 1 ]; then
  [ -f "$STATE/$ID.meta" ] || {
    echo "error: cannot relaunch '$ID': no metadata at $STATE/$ID.meta, so there is no recorded endpoint or worktree to adopt" >&2
    exit 1
  }
elif [ -e "$STATE/$ID.meta" ]; then
  echo "error: task '$ID' already has metadata at $STATE/$ID.meta; tear it down or pick a new id" >&2
  exit 1
fi

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# spawn_codegraph_prep <project-abs> <worktree-real>: build the project's
# codegraph index into a fresh task worktree, fail-open. codegraph indexes by
# absolute path in a store keyed to that path (docs/codegraph.md), so a
# worktree at a new path never inherits the primary's index automatically -
# unlike graft, codegraph has no built-in worktree seeding. `codegraph init`
# is itself idempotent (a second run detects "Already initialized" and
# no-ops in well under a second, verified in docs/codegraph.md), so this
# needs no existence guard of its own before calling it - re-running on
# relaunch is cheap. Every negative case is a silent or warned no-op: the
# kill switch, the binary, the primary's index, then the worktree's committed
# ignore rules (codegraph's own .gitignore lives INSIDE .codegraph/ and never
# touches the project root, but the root itself still needs a committed rule
# for the directory - or symlink - itself; both `.codegraph` and `.codegraph/`
# count as that rule, so the guard asks in both forms - git matches a
# directory-only pattern against a path that does not exist yet, which is
# every fresh worktree, only when the query carries the slash too). Only
# `codegraph init` runs,
# positionally against $wt_real, never against $proj_abs. A failed or killed
# init leaves a locked, truncated index that no later run repairs
# (docs/codegraph.md), so an index this call created and did not finish is
# removed again - leaving a worktree with no index, which the next prep run
# can rebuild - while an index the worktree already had survives untouched.
# That removal is best-effort and reported, never fatal: a spawn is already
# holding a created worktree by this point, so nothing here may abort it.
# Because it can fail, a leftover can outlive it, so the SAME judgement runs
# before init too: an existing .codegraph counts as an index only with a
# codegraph.db and no codegraph.lock, and anything else is removed first, since
# init short-circuits on "Already initialized" and would otherwise report a
# build it never did over a locked, truncated index.
spawn_codegraph_prep() {  # <project-abs> <worktree-real>
  local proj_abs=$1 wt_real=$2 timeout out rc had_index stale aftermath
  [ "${CS_SPAWN_CODEGRAPH_PREP:-}" = off ] && return 0
  command -v codegraph >/dev/null 2>&1 || return 0
  [ -n "$proj_abs" ] && [ -f "$proj_abs/.codegraph/codegraph.db" ] || return 0
  if ! git -C "$wt_real" check-ignore -q .codegraph 2>/dev/null &&
     ! git -C "$wt_real" check-ignore -q .codegraph/ 2>/dev/null; then
    echo "warn: $wt_real's committed rules do not ignore .codegraph; skipping codegraph index build there" >&2
    return 0
  fi
  if [ -z "$wt_real" ] || [ "$wt_real" = "$proj_abs" ]; then
    echo "warn: refusing to run codegraph init against the primary checkout; skipping codegraph index prep" >&2
    return 0
  fi
  timeout=${CS_SPAWN_CODEGRAPH_TIMEOUT_SECS:-10}
  case "$timeout" in ''|*[!0-9]*|0) timeout=10 ;; esac
  had_index=no
  stale=no
  if [ -e "$wt_real/.codegraph" ]; then
    if [ -f "$wt_real/.codegraph/codegraph.db" ] && [ ! -e "$wt_real/.codegraph/codegraph.lock" ]; then
      had_index=yes
    else
      rm -rf "${wt_real:?}/.codegraph" 2>/dev/null || true
      [ -e "$wt_real/.codegraph" ] && stale=yes
    fi
  fi
  out=$(cs_run_timed "$timeout" codegraph init "$wt_real" 2>&1) && rc=0 || rc=$?
  aftermath='the worktree has no codegraph index'
  if [ "$rc" != 0 ] && [ "$had_index" = no ]; then
    [ -e "$wt_real/.codegraph" ] && { rm -rf "${wt_real:?}/.codegraph" 2>/dev/null || true; }
    [ -e "$wt_real/.codegraph" ] &&
      aftermath="a half-written codegraph index remains at $wt_real/.codegraph and could not be removed"
  elif [ "$rc" != 0 ]; then
    aftermath="the worktree keeps the codegraph index it already had"
  fi
  case "$rc" in
    0)
      if [ "$stale" = yes ]; then
        echo "warn: an unusable codegraph index at $wt_real/.codegraph could not be removed, so codegraph init had nothing to rebuild" >&2
      else
        echo "notice: built codegraph index in $wt_real" >&2
      fi
      ;;
    124) echo "warn: codegraph init did not finish within ${timeout}s in $wt_real; $aftermath" >&2 ;;
    "$CS_TIMEOUT_UNAVAILABLE") echo "warn: could not run codegraph init under a time bound; skipping codegraph index prep in $wt_real" >&2 ;;
    *) echo "warn: codegraph init exited $rc in $wt_real; $aftermath (output: ${out//$'\n'/ })" >&2 ;;
  esac
}

BRIEF="$DATA/$ID/brief.md"
sq_operational=$(shell_quote "$SCRIPT_DIR/cs-operational-input.sh")

# ----------------------------------------------------------------- relaunch
if [ "$RELAUNCH" -eq 1 ]; then
  META="$STATE/$ID.meta"
  R_KIND=$(cs_meta_get "$META" kind 2>/dev/null || true)
  [ -n "$R_KIND" ] || R_KIND=ship
  R_PANE=$(cs_meta_get "$META" pane) || { echo "error: no pane recorded in $META" >&2; exit 1; }
  R_WT=$(cs_meta_get "$META" worktree 2>/dev/null || true)
  R_PROJ=$(cs_meta_get "$META" project 2>/dev/null || true)
  # A meta with no harness= predates the two-harness layer, when codex was the
  # only one; bin/cs-send.sh reads such a record the same way.
  R_HARNESS=$(cs_meta_get "$META" harness 2>/dev/null || true)
  [ -n "$R_HARNESS" ] || R_HARNESS=codex
  cs_harness_valid "$R_HARNESS" || { echo "error: task '$ID' records an unsupported harness '$R_HARNESS'" >&2; exit 1; }
  if [ "$(cs_meta_get "$META" headless 2>/dev/null || true)" = 1 ]; then
    echo "error: task '$ID' is a headless scout: it runs as a plain process whose turn end is its exit, so there is no interactive agent to relaunch" >&2
    exit 1
  fi
  if [ "$R_KIND" = capo ]; then
    echo "error: task '$ID' is a capo: relaunching a persistent home belongs to the capo-provisioning skill, which owns its state, backlog, and child work" >&2
    exit 1
  fi
  [ -f "$BRIEF" ] || { echo "error: brief missing at $BRIEF; a relaunch needs it as the replacement's instructions" >&2; exit 1; }
  [ -n "$R_WT" ] || { echo "error: task '$ID' records no worktree; reconcile it before relaunching" >&2; exit 1; }
  [ -d "$R_WT" ] || { echo "error: task '$ID' records worktree $R_WT, which is gone; recover it with 'herdr worktree open --path' first" >&2; exit 1; }
  R_WT_REAL=$(cd "$R_WT" && pwd -P) || { echo "error: cannot resolve recorded worktree $R_WT" >&2; exit 1; }
  R_WT_TOP=$(git -C "$R_WT_REAL" rev-parse --show-toplevel 2>/dev/null || true)
  R_WT_TOP_REAL=$(cd "${R_WT_TOP:-/nonexistent}" 2>/dev/null && pwd -P) || R_WT_TOP_REAL=
  R_PROJ_REAL=$(cd "${R_PROJ:-/nonexistent}" 2>/dev/null && pwd -P) || R_PROJ_REAL=
  if [ -z "$R_WT_TOP_REAL" ] || [ "$R_WT_TOP_REAL" != "$R_WT_REAL" ] ||
    { [ -n "$R_PROJ_REAL" ] && [ "$R_WT_REAL" = "$R_PROJ_REAL" ]; }; then
    echo "error: recorded worktree $R_WT_REAL is not an isolated git worktree root (git reports '${R_WT_TOP:-none}'; primary '${R_PROJ_REAL:-unknown}'); refusing to relaunch into it" >&2
    exit 1
  fi

  # The endpoint must be there, positively agent-free, and sitting in the
  # worktree that holds the work. Each of the three is refused on "cannot tell",
  # never assumed: joining a live agent or launching in the wrong directory are
  # both worse than a refusal.
  R_PRESENCE=$(cs_herdr_pane_presence "$R_PANE")
  [ "$R_PRESENCE" = present ] || {
    echo "error: herdr reports pane $R_PANE as '$R_PRESENCE' for task '$ID'; a relaunch adopts an existing endpoint and never creates one" >&2
    exit 1
  }
  if ! cs_control_agent_gone "$R_PANE"; then
    echo "error: pane $R_PANE is not positively agent-free (pid $(cs_control_agent_pid "$R_PANE" 2>/dev/null || echo unreadable)); stop the agent through bin/cs-control.sh exit before relaunching" >&2
    exit 1
  fi
  cwd_rc=0
  cs_control_pane_in_dir "$R_PANE" "$R_WT_REAL" || cwd_rc=$?
  case "$cwd_rc" in
    0) ;;
    1) echo "error: pane $R_PANE's shell is not in $R_WT_REAL; a replacement launched there would run outside the copy holding the work" >&2; exit 1 ;;
    *) echo "error: herdr did not report a working directory for pane $R_PANE; refusing to launch into an unverified location" >&2; exit 1 ;;
  esac

  R_TURNEND="$STATE/$ID.turn-ended"
  R_TELEMETRY=
  case "$R_HARNESS" in
    claude|grok) R_TELEMETRY=$(cs_telemetry_worker_hook_command "$ID" "$SCRIPT_DIR" stdin) ;;
    codex) R_TELEMETRY=$(cs_telemetry_worker_hook_command "$ID" "$SCRIPT_DIR" nostdin) ;;
  esac
  R_WORKER_HOOK=$(shell_quote "$SCRIPT_DIR/cs-worker-turnend.sh")
  if [ -n "$R_TELEMETRY" ]; then R_TELEMETRY="$R_TELEMETRY; $R_WORKER_HOOK"; else R_TELEMETRY=$R_WORKER_HOOK; fi
  SETTINGS_FILE=''
  if [ "$R_HARNESS" = claude ]; then
    SETTINGS_FILE="$STATE/$ID.claude-settings.json"
    cs_harness_claude_settings_json "$R_TURNEND" "$R_TELEMETRY" > "$SETTINGS_FILE" || {
      rm -f "$SETTINGS_FILE"
      echo "error: turn-end path $R_TURNEND cannot be embedded safely in claude's Stop hook command (it carries a quote or backslash); the pane is untouched" >&2
      exit 1
    }
    cs_harness_claude_trust_dir "$R_WT_REAL" || {
      echo "error: could not pre-trust claude worktree $R_WT_REAL; the pane is untouched" >&2
      exit 1
    }
  elif [ "$R_HARNESS" = codex ]; then
    # Same dialog, same non-bypass (docs/codex.md). Normally a no-op because the
    # spawn already trusted this worktree, but a relaunch must not depend on that:
    # if the entry is gone the replacement would park on the dialog instead of
    # resuming the work.
    cs_harness_codex_trust_dir "$R_WT_REAL" || {
      echo "error: could not pre-trust codex worktree $R_WT_REAL; the pane is untouched" >&2
      exit 1
    }
  elif [ "$R_HARNESS" = grok ]; then
    cs_grok_turnend_arm "$R_TURNEND" "$STATE" "$ID" "$R_WT_REAL" "$R_TELEMETRY" || {
      echo "error: could not arm grok turn-end wiring for $ID; the pane is untouched" >&2
      exit 1
    }
  elif [ "$R_HARNESS" = cursor ]; then
    cs_cursor_write_session_sidecar "$STATE" "$ID" "$R_WT_REAL"
  fi

  spawn_codegraph_prep "$R_PROJ_REAL" "$R_WT_REAL"

  # CLAUDE_CONFIG_DIR under a work/personal account split, exported once here
  # (this pane's shell keeps it for both the resume attempt and any cold-launch
  # fallback below) rather than per-attempt - see _cs_spawn_env_export_confirmed.
  R_ENV_PREFIX="$(cs_harness_launch_env "$R_HARNESS")CS_ROOT_OVERRIDE=$(shell_quote "$CS_ROOT") CS_HOME=$(shell_quote "$CS_HOME") CS_DATA_OVERRIDE=$(shell_quote "$DATA") CS_STATE_OVERRIDE=$(shell_quote "$STATE") CS_TASK_ID=$(shell_quote "$ID")"
  if ! _cs_spawn_env_export_confirmed "$R_PANE" "$R_ENV_PREFIX"; then
    echo "error: could not confirm $ID's launch environment landed on pane $R_PANE before relaunching; the export line was typed at the pane's shell but never confirmed executed, and no replacement agent was started" >&2
    exit 1
  fi

  # Resume first. The wait is generous for a slow cold start, and breaks out as
  # soon as the pane is positively agent-free again - which is what a harness
  # that had nothing to resume leaves behind once it exits.
  R_RESUME_WAIT=${CS_CONTROL_RESUME_WAIT_SECS:-$LAUNCH_WAIT}
  case "$R_RESUME_WAIT" in ''|*[!0-9]*|0) R_RESUME_WAIT=$LAUNCH_WAIT ;; esac
  R_RESUME_GRACE=${CS_CONTROL_RESUME_GRACE_SECS:-6}
  case "$R_RESUME_GRACE" in ''|*[!0-9]*) R_RESUME_GRACE=6 ;; esac
  # A harness with nothing to resume still RUNS for a second or two before it
  # prints its refusal and exits, and herdr's detector sees an agent in that
  # window (measured: `claude --continue` with no recorded session; live-verified
  # this session that native `agent start` is fooled by the exact same window -
  # docs/herdr.md). So a resume counts only once the agent is still there after
  # a settle, and it must be a real agent PROCESS, not just herdr's belief about
  # the pane. `agent start` below is used only to TRIGGER the resume command
  # with correct argv; this loop, unchanged, is what actually decides resumed
  # vs falls through to a cold launch.
  R_RESUME_CONFIRM=${CS_CONTROL_RESUME_CONFIRM_SECS:-4}
  case "$R_RESUME_CONFIRM" in ''|*[!0-9]*) R_RESUME_CONFIRM=4 ;; esac
  r_agent_running() { cs_herdr_agent_alive "$R_PANE" && cs_control_agent_pid "$R_PANE" >/dev/null 2>&1; }
  declare -a RESUME_ARGV=()
  cs_harness_resume_argv RESUME_ARGV "$R_HARNESS" || { echo "error: unsupported harness '$R_HARNESS' for $ID" >&2; exit 1; }
  cs_harness_autonomy_argv RESUME_ARGV "$R_HARNESS" || { echo "error: unsupported harness '$R_HARNESS' for $ID" >&2; exit 1; }
  if [ "$R_HARNESS" = claude ]; then
    RESUME_ARGV+=(--settings "$SETTINGS_FILE")
  elif [ "$R_HARNESS" = codex ]; then
    cs_harness_codex_notify_argv RESUME_ARGV "$R_TURNEND" "$R_TELEMETRY" || {
      echo "error: turn-end path $R_TURNEND cannot be embedded safely in codex's notify value (it carries a quote or backslash); no replacement agent was started" >&2
      exit 1
    }
  elif [ "$R_HARNESS" = cursor ]; then
    cs_harness_cursor_workspace_argv RESUME_ARGV "$R_WT_REAL" || {
      echo "error: could not bind cursor workspace for $ID" >&2
      exit 1
    }
  fi
  # A short trigger timeout on purpose: its own result is not the resume
  # decision (the loop below is), so it must not block waiting for the
  # false-positive-prone interactive_ready read a genuine slow resume can take
  # longer than this to reach.
  R_NATIVE_NAME=$(cs_herdr_agent_name "$ID") || {
    echo "error: could not derive a native agent name for '$ID'; no replacement agent was started" >&2
    exit 1
  }
  cs_herdr agent start "$R_NATIVE_NAME" --kind "$R_HARNESS" --pane "$R_PANE" --timeout 2000 -- "${RESUME_ARGV[@]}" >/dev/null 2>&1 || true
  R_PATH=resume
  waited=0
  resumed=0
  while [ "$waited" -lt "$R_RESUME_WAIT" ]; do
    if r_agent_running; then
      sleep "$R_RESUME_CONFIRM"
      waited=$((waited + R_RESUME_CONFIRM))
      if r_agent_running; then resumed=1; break; fi
    fi
    if [ "$waited" -ge "$R_RESUME_GRACE" ] && cs_control_agent_gone "$R_PANE"; then break; fi
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$resumed" -eq 0 ]; then
    if ! cs_control_agent_gone "$R_PANE"; then
      echo "error: the resume of '$ID' was not confirmed within ${R_RESUME_WAIT}s and pane $R_PANE is not positively agent-free (pid $(cs_control_agent_pid "$R_PANE" 2>/dev/null || echo unreadable)); refusing to launch a second agent over it" >&2
      exit 1
    fi
    R_PATH=cold
    encoded_brief=$("$SCRIPT_DIR/cs-operational-input.sh" encode launch-brief < "$BRIEF") || { echo "error: could not encode the launch brief for $ID" >&2; exit 1; }
    declare -a COLD_ARGV=()
    cs_harness_autonomy_argv COLD_ARGV "$R_HARNESS" || { echo "error: unsupported harness '$R_HARNESS' for $ID" >&2; exit 1; }
    if [ "$R_HARNESS" = claude ]; then
      COLD_ARGV+=(--settings "$SETTINGS_FILE")
    elif [ "$R_HARNESS" = codex ]; then
      cs_harness_codex_notify_argv COLD_ARGV "$R_TURNEND" "$R_TELEMETRY" || {
        echo "error: turn-end path $R_TURNEND cannot be embedded safely in codex's notify value (it carries a quote or backslash); no cold launch was attempted" >&2
        exit 1
      }
    elif [ "$R_HARNESS" = cursor ]; then
      cs_harness_cursor_workspace_argv COLD_ARGV "$R_WT_REAL" || {
        echo "error: could not bind cursor workspace for $ID" >&2
        exit 1
      }
    fi
    if ! cs_herdr_agent_start "$R_PANE" "$ID" "$R_HARNESS" "$(cs_herdr_agent_start_timeout_ms "$LAUNCH_WAIT")" "${COLD_ARGV[@]}"; then
      echo "error: no session was resumable for '$ID' and the cold launch brought up no agent within ${LAUNCH_WAIT}s; no replacement is running on pane $R_PANE and the work is preserved in $R_WT_REAL" >&2
      exit 1
    fi
    # Same stability requirement as the resume path: report a running agent only
    # when its process is actually readable on the pane.
    sleep "$R_RESUME_CONFIRM"
    if ! r_agent_running; then
      echo "error: the cold launch of '$ID' started an agent that did not stay on pane $R_PANE; the worktree $R_WT_REAL is untouched" >&2
      exit 1
    fi
    _cs_spawn_deliver_brief "$R_PANE" "$encoded_brief" ||
      echo "warning: the cold launch of '$ID' started an agent on pane $R_PANE but its brief was never confirmed delivered within ${BRIEF_DELIVER_WAIT}s - steer it manually" >&2
  fi

  previous_generation=$(cs_meta_get "$META" endpoint_generation 2>/dev/null || true)
  [ -n "$previous_generation" ] || previous_generation=unknown
  cs_meta_set "$META" previous_endpoint_generation "$previous_generation"
  cs_meta_set "$META" previous_endpoint_generation_at "$(date +%s)"
  cs_meta_set "$META" endpoint_generation "$ENDPOINT_GENERATION"

  report_human_gate "$R_PANE" "$R_HARNESS" "$ID"
  report_task_metadata "$R_PANE" "$ID" \
    "$(cs_meta_get "$META" mode 2>/dev/null || printf '%s' "$R_KIND")"

  # TELEMETRY, measurement only: a relaunch is a dispatch of this task's work.
  cs_telemetry_crumb spawn "$R_KIND" || true
  # LOCKSTEP: bin/cs-control.sh reads `path=` off this line to decide whether the
  # session survived (and so whether the progress note must be steered in, and
  # whether an unchanged agent session id is evidence of failure). It refuses
  # rather than assuming a path, so keep this token if the line is reworded.
  echo "relaunched $ID kind=$R_KIND path=$R_PATH harness=$R_HARNESS pane=$R_PANE worktree=$R_WT_REAL"
  exit 0
fi

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
    "kind=capo" \
    "mode=capo" \
    "yolo=off" \
    "harness=$HARNESS" \
    "home=$HOME_ABS" \
    "parent_task_id=$PARENT_TASK" \
    "parent_home=$PARENT_HOME" \
    "parent_state=$PARENT_STATE" \
    "parent_pane=$PARENT_PANE" \
    "parent_generation=$PARENT_GENERATION" \
    "parent_herdr_session=$PARENT_HERDR_SESSION" \
    "endpoint_generation=$ENDPOINT_GENERATION" \
    "herdr_session=$(cs_herdr_session)"
  mkdir -p "$HOME_ABS/state"
  cs_meta_write "$HOME_ABS/state/$ID.meta" \
    "workspace=$WS" \
    "pane=$PANE" \
    "worktree=$HOME_ABS" \
    "project=$HOME_ABS" \
    "kind=capo" \
    "mode=capo" \
    "yolo=off" \
    "harness=$HARNESS" \
    "home=$HOME_ABS" \
    "parent_task_id=$PARENT_TASK" \
    "parent_home=$PARENT_HOME" \
    "parent_state=$PARENT_STATE" \
    "parent_pane=$PARENT_PANE" \
    "parent_generation=$PARENT_GENERATION" \
    "parent_herdr_session=$PARENT_HERDR_SESSION" \
    "endpoint_generation=$ENDPOINT_GENERATION" \
    "herdr_session=$(cs_herdr_session)"
  report_task_metadata "$PANE" "$ID" capo

  encoded_brief=$("$SCRIPT_DIR/cs-operational-input.sh" encode launch-brief < "$BRIEF") || {
    echo "error: could not encode the charter brief for capo $ID" >&2
    exit 1
  }
  # Unconditional, every capo launch: clear any inherited override so the capo
  # never picks up the ROOT session's overrides, then point CS_HOME at its own
  # home. `agent start`'s trailing argv has no shell prefix-assignment support
  # and neither it nor `worktree create` has an --env flag, so this must land
  # via its own confirmed pane-shell export before the agent starts.
  ENV_PREFIX="$(cs_harness_launch_env "$HARNESS")CS_ROOT_OVERRIDE= CS_STATE_OVERRIDE= CS_DATA_OVERRIDE= CS_CONFIG_OVERRIDE= CS_PROJECTS_OVERRIDE= CS_HOME=$(shell_quote "$HOME_ABS") CS_TASK_ID=$(shell_quote "$ID")"
  if ! _cs_spawn_env_export_confirmed "$PANE" "$ENV_PREFIX"; then
    echo "error: could not confirm capo $ID's launch environment landed on pane $PANE before starting the agent; the home and its workspace are left intact - retry the spawn" >&2
    exit 1
  fi
  # A capo is a supervisor, not a supervised turn-taker: no turn-end wiring on
  # either harness.
  declare -a AGENT_ARGV=()
  cs_harness_autonomy_argv AGENT_ARGV "$HARNESS" || { echo "error: unsupported harness '$HARNESS' for capo $ID" >&2; exit 1; }
  # The colon is native-only identity syntax: it normalizes into Herdr's n
  # namespace, keeping capo foo distinct from ship/scout task id capo-foo.
  # Metadata, paths, and operator-facing IDs stay keyed by the raw capo ID;
  # capo relaunch is refused, so this native-only delimiter does not alter any
  # relaunch identity path.
  if ! cs_herdr_agent_start "$PANE" "capo:$ID" "$HARNESS" "$(cs_herdr_agent_start_timeout_ms "$LAUNCH_WAIT")" "${AGENT_ARGV[@]}"; then
    echo "error: capo $ID launched into $PANE but no agent appeared within ${LAUNCH_WAIT}s. The home and its workspace are left intact - retry the spawn." >&2
    exit 1
  fi
  _cs_spawn_deliver_brief "$PANE" "$encoded_brief" ||
    echo "warning: capo $ID's agent started but its charter brief was never confirmed delivered within ${BRIEF_DELIVER_WAIT}s on pane $PANE - steer it manually" >&2
  report_human_gate "$PANE" "$HARNESS" "capo $ID"
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
  "kind=$KIND"
  "parent_task_id=$PARENT_TASK"
  "parent_home=$PARENT_HOME"
  "parent_state=$PARENT_STATE"
  "parent_pane=$PARENT_PANE"
  "parent_generation=$PARENT_GENERATION"
  "parent_herdr_session=$PARENT_HERDR_SESSION"
  "endpoint_generation=$ENDPOINT_GENERATION"
)
# A scout records no delivery posture at all: its deliverable is a report, so
# there is no mode to honour and no approval posture to apply. cs-promote.sh
# states both explicitly when a scout is promoted to ship.
[ "$KIND" = ship ] && META_LINES+=("mode=$MODE" "yolo=$YOLO")
META_LINES+=("harness=$HARNESS" "herdr_session=$(cs_herdr_session)")
[ "$HEADLESS" -eq 1 ] && META_LINES+=("headless=1")
[ -n "$ISSUE" ] && META_LINES+=("issue=$ISSUE")
[ -n "$BACKLOG_ITEM" ] && META_LINES+=("backlog_item=$BACKLOG_ITEM")

# Record the phase-2 context-pack audit trail: the deterministic
# role/workflow/harness scaffold hash this task's brief was rendered from
# (bin/cs-context-pack.sh, issue #151). Measurement/reproducibility only -
# never a dispatch gate, so a failure here (missing sha256 tool, unexpected
# state) warns and proceeds exactly like the base-freshness check above,
# rather than aborting a real dispatch over audit metadata.
PACK_ROLE=$KIND
case "$KIND" in
  ship) PACK_WORKFLOW=$MODE ;;
  scout) PACK_WORKFLOW=report-only ;;
  capo) PACK_WORKFLOW=none ;;
esac
if PACK_JSON=$("$CS_ROOT/bin/cs-context-pack.sh" "$PACK_ROLE" "$PACK_WORKFLOW" "$HARNESS" 2>/dev/null); then
  PACK_HASH=$(printf '%s\n' "$PACK_JSON" | sed -n 's/.*"pack_sha256": "\([^"]*\)".*/\1/p')
  PACK_SCHEMA=$(printf '%s\n' "$PACK_JSON" | sed -n 's/.*"schema": "\([^"]*\)".*/\1/p')
  if [ -n "$PACK_HASH" ] && [ -n "$PACK_SCHEMA" ]; then
    META_LINES+=("pack_sha256=$PACK_HASH" "pack_schema=$PACK_SCHEMA")
  else
    echo "warn: cs-context-pack.sh produced no parseable pack_sha256/schema for $PACK_ROLE/$PACK_WORKFLOW/$HARNESS; dispatch proceeds without the pack audit fields" >&2
  fi
else
  echo "warn: cs-context-pack.sh failed composing the $PACK_ROLE/$PACK_WORKFLOW/$HARNESS audit pack; dispatch proceeds without the pack audit fields" >&2
fi

cs_meta_write "$STATE/$ID.meta" "${META_LINES[@]}"

# The dispatch backlog transition, folded into the same physical change under
# the same spawn lock: the record above and the In-flight row land together,
# before this spawn can report success. A write failure fails the dispatch and
# removes the provisional record, so the two can never disagree.
if [ -n "$BACKLOG_ITEM" ]; then
  backlog_rc=0
  cs_tasks_backlog_transition "$CONFIG" start "$BACKLOG_ITEM" || backlog_rc=$?
  if [ "$backlog_rc" -eq 1 ]; then
    rm -f "$STATE/$ID.meta"
    abort_task "backlog item '$BACKLOG_ITEM' could not be moved to In flight, so dispatch of '$ID' failed; its provisional record was removed"
  fi
else
  echo "reminder: no --backlog-item was named; move the backlog work item for '$ID' to In flight yourself" >&2
fi
DISPLAY_MODE=$KIND
[ "$KIND" = ship ] && DISPLAY_MODE=$MODE
report_task_metadata "$PANE" "$ID" "$DISPLAY_MODE"

sq_brief=$(shell_quote "$BRIEF")
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
    claude|grok) TELEMETRY_HOOK=$(cs_telemetry_worker_hook_command "$ID" "$SCRIPT_DIR" stdin) ;;
    codex) TELEMETRY_HOOK=$(cs_telemetry_worker_hook_command "$ID" "$SCRIPT_DIR" nostdin) ;;
  esac
  WORKER_HOOK=$(shell_quote "$SCRIPT_DIR/cs-worker-turnend.sh")
  if [ -n "$TELEMETRY_HOOK" ]; then TELEMETRY_HOOK="$TELEMETRY_HOOK; $WORKER_HOOK"; else TELEMETRY_HOOK=$WORKER_HOOK; fi
fi
if [ "$HEADLESS" -eq 1 ]; then
  # Fire-and-forget scout: the harness runs the brief non-interactively (codex
  # exec / claude -p); the launch line appends the terminal status event, so
  # completion surfaces through the watcher's ordinary signal path with no
  # special classification. No turn-end hook: process exit IS the turn end.
  # A headless process has no composer or agent_status lifecycle, so it stays
  # on the shell-string mechanism permanently; `agent start` does not apply.
  sq_status=$(shell_quote "$STATE/$ID.status")
  LAUNCH=$(cs_harness_scout_launch "$HARNESS" "$sq_operational" "$sq_brief" "$sq_status" "$WT_REAL")
  cs_herdr_run "$PANE" "$LAUNCH" >/dev/null
  # No launch verification follows, deliberately. `pane run` hands the line to
  # the pane's SHELL and reports success whether or not the shell was ready to
  # read it, and a headless scout takes no pane agent, so herdr agent detection
  # is not a valid signal for it; its swallowed-launch case is instead caught
  # by the absence of the terminal done:/failed: status event its launch line
  # appends, via the ordinary stale path - slower, but not silent.
else
  # Interactive supervised soldier. codex wires turn-end inline via -c notify;
  # claude via a launch-scoped --settings Stop hook written per-soldier here
  # (claude resolves a repo .claude/settings.json to the main checkout, so a
  # worktree file would pollute the boss's project and not isolate the soldier).
  SETTINGS_FILE=''
  if [ "$HARNESS" = claude ]; then
    SETTINGS_FILE="$STATE/$ID.claude-settings.json"
    cs_harness_claude_settings_json "$TURNEND" "$TELEMETRY_HOOK" > "$SETTINGS_FILE" || {
      rm -f "$SETTINGS_FILE"
      abort_task "turn-end path $TURNEND cannot be embedded safely in claude's Stop hook command (it carries a quote or backslash)"
    }
    # Interactive claude blocks at the folder-trust dialog for a fresh worktree;
    # pre-trust it so the unattended soldier can take its first turn.
    cs_harness_claude_trust_dir "$WT_REAL" || abort_task "could not pre-trust claude worktree $WT_REAL"
  elif [ "$HARNESS" = codex ]; then
    # Interactive codex has the same dialog, and its bypass flag does not skip it
    # either. A codex parked there takes no turn until a human answers, so an
    # unattended soldier needs the dialog gone before launch, not escalated after.
    cs_harness_codex_trust_dir "$WT_REAL" || abort_task "could not pre-trust codex worktree $WT_REAL"
  elif [ "$HARNESS" = grok ]; then
    cs_grok_turnend_arm "$TURNEND" "$STATE" "$ID" "$WT_REAL" "$TELEMETRY_HOOK" ||
      abort_task "could not arm grok turn-end wiring for $ID"
  elif [ "$HARNESS" = cursor ]; then
    cs_cursor_resolve_binary >/dev/null ||
      abort_task "cursor-agent is not installed or not reachable"
    cs_cursor_write_session_sidecar "$STATE" "$ID" "$WT_REAL"
  fi
  spawn_codegraph_prep "$PROJ_ABS" "$WT_REAL"

  encoded_brief=$("$SCRIPT_DIR/cs-operational-input.sh" encode launch-brief < "$BRIEF") || abort_task "could not encode the launch brief for $ID"

  # CLAUDE_CONFIG_DIR under a work/personal account split, only when this home
  # itself runs under one. `agent start`'s trailing argv has no shell
  # prefix-assignment support and neither it nor `worktree create` has an
  # --env flag, so this must land via its own confirmed pane-shell export
  # before the agent starts - skipped entirely when there is nothing to export.
  ENV_PREFIX="$(cs_harness_launch_env "$HARNESS")CS_ROOT_OVERRIDE=$(shell_quote "$CS_ROOT") CS_HOME=$(shell_quote "$CS_HOME") CS_DATA_OVERRIDE=$(shell_quote "$DATA") CS_STATE_OVERRIDE=$(shell_quote "$STATE") CS_TASK_ID=$(shell_quote "$ID")"
  if ! _cs_spawn_env_export_confirmed "$PANE" "$ENV_PREFIX"; then
    abort_task "could not confirm $ID's launch environment landed on pane $PANE before starting the agent"
  fi

  declare -a AGENT_ARGV=()
  cs_harness_autonomy_argv AGENT_ARGV "$HARNESS" || abort_task "unsupported harness '$HARNESS' for $ID"
  if [ "$HARNESS" = claude ]; then
    AGENT_ARGV+=(--settings "$SETTINGS_FILE")
  elif [ "$HARNESS" = codex ]; then
    cs_harness_codex_notify_argv AGENT_ARGV "$TURNEND" "$TELEMETRY_HOOK" ||
      abort_task "turn-end path $TURNEND cannot be embedded safely in codex's notify value (it carries a quote or backslash)"
  elif [ "$HARNESS" = cursor ]; then
    cs_harness_cursor_workspace_argv AGENT_ARGV "$WT_REAL" ||
      abort_task "could not bind cursor workspace for $ID"
  fi

  # Verify the launch actually started an agent. Native `agent start` waits
  # for interactive_ready itself instead of the old cs_herdr_run + hand-rolled
  # poll pair, and reports a distinct failure (agent_pane_not_found,
  # agent_kind_mismatch, agent_not_ready, agent_start_failed) instead of a
  # generic timeout. Without this check cs-spawn prints "spawned", consigliere
  # records the task as under way, and the pane sits at a prompt until the
  # stale timer eventually notices - a soldier that reported success and never
  # existed. The brief carries no launch argument here (agent start's trailing
  # argv cannot hold multi-line text - docs/herdr.md); it is delivered as a
  # follow-up prompt just below.
  if ! cs_herdr_agent_start "$PANE" "$ID" "$HARNESS" "$(cs_herdr_agent_start_timeout_ms "$LAUNCH_WAIT")" "${AGENT_ARGV[@]}"; then
    abort_task "launched $ID into $PANE but no agent appeared within ${LAUNCH_WAIT}s"
  fi
  _cs_spawn_deliver_brief "$PANE" "$encoded_brief" ||
    echo "warning: $ID's agent started but its brief was never confirmed delivered within ${BRIEF_DELIVER_WAIT}s on pane $PANE - steer it manually" >&2
  report_human_gate "$PANE" "$HARNESS" "$KIND $ID"
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
