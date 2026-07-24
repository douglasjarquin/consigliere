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
# shellcheck source=bin/cs-harness-lib.sh
. "$SCRIPT_DIR/cs-harness-lib.sh"

# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
mkdir -p "$STATE"

# A soldier/capo always inherits the ROOT session's harness. Resolved once here;
# persisted per-soldier as harness= in state/<id>.meta so the watcher, cs-send,
# and cs-crew-state read it back without re-detecting.
HARNESS=$(cs_harness_detect_root)

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
if ! cs_harness_effort_valid "$HARNESS" "$EFFORT"; then
  case "$EFFORT" in
    max) echo "error: $HARNESS does not accept effort=max; choose low|medium|high|xhigh" >&2 ;;
    *) echo "error: unknown effort '$EFFORT'" >&2 ;;
  esac
  exit 2
fi
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
    "harness=$HARNESS" \
    "home=$HOME_ABS"

  sq_brief=$(shell_quote "$BRIEF")
  sq_home=$(shell_quote "$HOME_ABS")
  LAUNCH=$(cs_harness_capo_launch "$HARNESS" "${MODEL:-default}" "${EFFORT:-default}" "$sq_operational" "$sq_brief" "$sq_home")
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
  "harness=$HARNESS"
)
[ "$HEADLESS" -eq 1 ] && META_LINES+=("headless=1")
[ -n "$ISSUE" ] && META_LINES+=("issue=$ISSUE")
cs_meta_write "$STATE/$ID.meta" "${META_LINES[@]}"

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
MODEL_ARG=${MODEL:-default}
EFFORT_ARG=${EFFORT:-default}
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
    cs_harness_claude_settings_json "$TURNEND" > "$SETTINGS_FILE"
    sq_settings=$(shell_quote "$SETTINGS_FILE")
    # Interactive claude blocks at the folder-trust dialog for a fresh worktree;
    # pre-trust it so the unattended soldier can take its first turn.
    cs_harness_claude_trust_dir "$WT_REAL" || abort_task "could not pre-trust claude worktree $WT_REAL"
  fi
  LAUNCH=$(cs_harness_soldier_launch "$HARNESS" "$MODEL_ARG" "$EFFORT_ARG" "$sq_operational" "$sq_brief" "$sq_turnend" "$sq_settings")
fi
cs_herdr_run "$PANE" "$LAUNCH" >/dev/null

HEADLESS_NOTE=""
[ "$HEADLESS" -eq 1 ] && HEADLESS_NOTE=" headless=1"
echo "spawned $ID kind=$KIND mode=$MODE yolo=$YOLO workspace=$WS pane=$PANE worktree=$WT_REAL$HEADLESS_NOTE"
