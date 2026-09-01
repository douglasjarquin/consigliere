#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the soldier keeps its pane,
# worktree, and loaded context; only the contract changes. Flips kind= to ship
# in state/<task-id>.meta so cs-teardown.sh applies the full ship-task teardown
# protection again, and records the delivery mode and yolo posture the promoted
# task will ship under.
# Before flipping the meta, writes data/<task-id>/ship-instructions.md: the
# scratch-inventory/clean-base/branch steps plus the mode-specific Definition
# of done rendered by bin/cs-dod-lib.sh - the same single owner cs-brief.sh
# scaffolds from, so a promoted scout receives the byte-identical contract a
# briefed ship worker gets, including the ask-user escalation rule and the
# --yes prohibition. The instructions default to ultrawork execution; edit
# that line to plan-first before sending when the task warrants it. Deliver
# them with the printed cs-send.sh command.
#
# --mode and --yolo are both REQUIRED. A scout carries no delivery posture at all
# (cs-spawn.sh records none for it, because a report has nothing to land), which
# is precisely why promotion is where the ship contract is first stated. There is
# nothing to inherit and nothing to default to.
# Usage: cs-promote.sh <task-id> --mode <made|direct-PR|local-only> --yolo <on|off>
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

# shellcheck source=bin/cs-delivery-lib.sh
. "$SCRIPT_DIR/cs-delivery-lib.sh"
# shellcheck source=bin/cs-dod-lib.sh
. "$SCRIPT_DIR/cs-dod-lib.sh"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
# Optional turn telemetry (off unless host/telemetry.conf enables it).
# shellcheck source=bin/cs-telemetry-lib.sh
. "$SCRIPT_DIR/cs-telemetry-lib.sh"

USAGE="usage: cs-promote.sh <task-id> --mode <$CS_DELIVERY_MODES> --yolo <$CS_DELIVERY_YOLOS>"
ID=
MODE=
YOLO=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) MODE=${2:?--mode requires a value}; shift ;;
    --yolo) YOLO=${2:?--yolo requires a value}; shift ;;
    -*) echo "error: unknown flag $1" >&2; echo "$USAGE" >&2; exit 2 ;;
    *)
      [ -z "$ID" ] || { echo "error: unexpected argument '$1'" >&2; echo "$USAGE" >&2; exit 2; }
      ID=$1 ;;
  esac
  shift
done
[ -n "$ID" ] || { echo "$USAGE" >&2; exit 2; }

# Validate the contract before touching the meta, so a refusal never leaves a
# half-promoted task behind.
if [ -z "$MODE" ]; then
  echo "error: promotion requires --mode <$CS_DELIVERY_MODES>; a scout carries no delivery posture to inherit" >&2
  exit 2
fi
if ! cs_delivery_mode_valid "$MODE"; then
  echo "error: --mode must be one of $CS_DELIVERY_MODES, got '$MODE'" >&2
  exit 2
fi
if [ -z "$YOLO" ]; then
  echo "error: promotion requires --yolo <$CS_DELIVERY_YOLOS>" >&2
  exit 2
fi
if ! cs_delivery_yolo_valid "$YOLO"; then
  echo "error: --yolo must be one of $CS_DELIVERY_YOLOS, got '$YOLO'" >&2
  exit 2
fi

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

# Publish the ship instructions BEFORE flipping the meta, so a failed write
# never leaves a promoted task with no delivered contract to follow.
INSTR="$DATA/$ID/ship-instructions.md"
if [ -e "$INSTR" ]; then
  echo "error: $INSTR already exists" >&2
  exit 1
fi
mkdir -p "$DATA/$ID"
DOD=$(cs_dod_render "$MODE" "$ID")
cat > "$INSTR" <<EOF
Your scout task is promoted to a ship task in place: same pane, same worktree, new contract.

# Promotion steps
1. Inventory your scratch state with \`git status\` and \`git log\`.
2. Return to a clean base on the current default branch; carry over only the intended fix changes. Scratch commits and debug edits never ride along, and a reproduced bug becomes the regression test.
3. Stay on branch \`cs/$ID\`.
4. Execution mode: ultrawork (plan obsessively, then implement with test-first RED-then-GREEN proof), unless consigliere's message says plan-first.
5. Your original brief's rules still apply, including its worktree isolation, status protocol, and rule 6: decisions that belong to a human, including ask-user findings, are escalated with \`needs-decision:\` and never answered by you.

$DOD

Delivery contract: mode=$MODE
EOF

TMP="$META.tmp"
{ grep -Ev '^(kind|mode|yolo)=' "$META" || true; } > "$TMP"
{
  echo "kind=ship"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
} >> "$TMP"
mv "$TMP" "$META"
# TELEMETRY, measurement only, recorded once the promotion is durable.
cs_telemetry_crumb promote "$MODE" || true

HOME_Q=$(printf '%q' "$CS_HOME")
INSTR_Q=$(printf '%q' "$INSTR")
echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)"
echo "ship instructions written: $INSTR (edit its execution-mode line to plan-first first when the task warrants it)"
echo "next: CS_HOME=$HOME_Q bin/cs-send.sh $ID 'Promoted to ship (mode=$MODE). Read and follow $INSTR_Q now.'"
