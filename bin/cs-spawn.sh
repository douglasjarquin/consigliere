#!/usr/bin/env bash
# Spawn a direct report: a soldier in a herdr-native task worktree, or a capo
# in its isolated consigliere home.
# Usage: cs-spawn.sh <task-id> <project-dir> [--model <name>] [--effort <level>] [--scout] [--base <ref>]
#        cs-spawn.sh <task-id> <capo-home> --capo [--model <name>] [--effort <level>]
#
#   --model <name> and --effort <low|medium|high|xhigh> are concrete profile
#   axes chosen by consigliere at intake. The codex config schema uses
#   model_reasoning_effort with low|medium|high|xhigh; max is omitted rather
#   than passed as an unsupported value.
#   --scout marks the task kind=scout (report deliverable, scratch worktree).
#   --headless (scout only) runs `codex exec` instead of the interactive TUI:
#     fire-and-forget for bounded investigations. Turn-end is process exit;
#     the launch itself appends the terminal `done:`/`failed:` status line, so
#     the watcher surfaces completion through the ordinary signal path. A
#     headless scout cannot be steered mid-flight; use the interactive default
#     when follow-up questions are likely.
#   --base <ref> bases the task branch on <ref> instead of the current HEAD.
#   --issue <n> records issue=<n> in meta for board-driven work (the Closes-#n
#     contract itself lives in the brief via cs-brief.sh --issue). Correlates
#     the task to a GitHub issue for the fleet view and the contracts skill.
#
# Ship/scout mechanics:
#   - Requires the brief at data/<id>/brief.md (scaffold with cs-brief.sh first).
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
# Delivery mode and yolo are resolved from data/projects.md at spawn time and
# recorded in meta; cs-project-mode.sh owns the registry parse.
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

CS_ROOT="${CS_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CS_HOME="${CS_HOME:-${CS_ROOT_OVERRIDE:-$CS_ROOT}}"
DATA="${CS_DATA_OVERRIDE:-$CS_HOME/data}"
STATE="${CS_STATE_OVERRIDE:-$CS_HOME/state}"
mkdir -p "$STATE"

KIND=ship
MODEL=
EFFORT=
BASE=
HEADLESS=0
ISSUE=
POS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scout) KIND=scout ;;
    --capo) KIND=capo ;;
    --headless) HEADLESS=1 ;;
    --model) MODEL=${2:?--model requires a value}; shift ;;
    --effort) EFFORT=${2:?--effort requires a value}; shift ;;
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
case "$EFFORT" in
  ''|low|medium|high|xhigh) ;;
  max) echo "error: codex does not accept effort=max; choose low|medium|high|xhigh" >&2; exit 2 ;;
  *) echo "error: unknown effort '$EFFORT'" >&2; exit 2 ;;
esac
if [ "$HEADLESS" -eq 1 ] && [ "$KIND" != scout ]; then
  echo "error: --headless applies only to --scout tasks" >&2
  exit 2
fi

cs_herdr_protocol_check

# Task-id-scoped spawn lock: creation through metadata publication.
SPAWN_LOCK="$STATE/.spawn-$ID.lock"
if ! mkdir "$SPAWN_LOCK" 2>/dev/null; then
  echo "error: another spawn for '$ID' is in flight (lock $SPAWN_LOCK)" >&2
  exit 1
fi
trap 'rmdir "$SPAWN_LOCK" 2>/dev/null || true' EXIT

if [ -e "$STATE/$ID.meta" ]; then
  echo "error: task '$ID' already has metadata at $STATE/$ID.meta; tear it down or pick a new id" >&2
  exit 1
fi

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

model_flag() {
  [ -n "$MODEL" ] && [ "$MODEL" != default ] || return 0
  printf -- '--model %s ' "$(shell_quote "$MODEL")"
}

effort_flag() {
  [ -n "$EFFORT" ] && [ "$EFFORT" != default ] || return 0
  printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$EFFORT\"")"
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

  WS=$(cs_herdr_home_workspace_ensure "capo-$ID" "$HOME_ABS")
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
    "home=$HOME_ABS"

  sq_brief=$(shell_quote "$BRIEF")
  sq_home=$(shell_quote "$HOME_ABS")
  LAUNCH="CS_ROOT_OVERRIDE= CS_STATE_OVERRIDE= CS_DATA_OVERRIDE= CS_HOME=$sq_home codex $(model_flag)$(effort_flag)--dangerously-bypass-approvals-and-sandbox \"\$($sq_operational encode launch-brief < $sq_brief)\""
  cs_herdr_run "$PANE" "$LAUNCH" >/dev/null
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
read -r MODE YOLO <<EOF
$("$CS_ROOT/bin/cs-project-mode.sh" "$PROJECT_NAME")
EOF

BRANCH="cs/$ID"
if git -C "$PROJ_ABS" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "error: branch '$BRANCH' already exists in $PROJ_ABS; a previous task '$ID' was not fully cleaned up" >&2
  exit 1
fi

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
  "mode=$MODE"
  "yolo=$YOLO"
)
[ "$HEADLESS" -eq 1 ] && META_LINES+=("headless=1")
[ -n "$ISSUE" ] && META_LINES+=("issue=$ISSUE")
cs_meta_write "$STATE/$ID.meta" "${META_LINES[@]}"

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
if [ "$HEADLESS" -eq 1 ]; then
  # Fire-and-forget scout: codex exec runs the brief non-interactively; the
  # launch line itself appends the terminal status event, so completion
  # surfaces through the watcher's ordinary signal path with no special
  # classification. No notify hook: process exit IS the turn end.
  sq_status=$(shell_quote "$STATE/$ID.status")
  LAUNCH="if codex exec $(model_flag)$(effort_flag)--dangerously-bypass-approvals-and-sandbox \"\$($sq_operational encode launch-brief < $sq_brief)\"; then echo 'done: headless scout finished; read the report' >> $sq_status; else echo \"failed: codex exec exited \$?\" >> $sq_status; fi"
else
  LAUNCH="codex $(model_flag)$(effort_flag)--dangerously-bypass-approvals-and-sandbox -c \"notify=[\\\"bash\\\",\\\"-c\\\",\\\"touch $sq_turnend\\\"]\" \"\$($sq_operational encode launch-brief < $sq_brief)\""
fi
cs_herdr_run "$PANE" "$LAUNCH" >/dev/null

HEADLESS_NOTE=""
[ "$HEADLESS" -eq 1 ] && HEADLESS_NOTE=" headless=1"
echo "spawned $ID kind=$KIND mode=$MODE yolo=$YOLO workspace=$WS pane=$PANE worktree=$WT_REAL$HEADLESS_NOTE"
