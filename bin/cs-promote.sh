#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the soldier keeps its pane,
# worktree, and loaded context; only the contract changes. Flips kind= to ship
# in state/<task-id>.meta so cs-teardown.sh applies the full ship-task teardown
# protection again, and records the delivery mode and yolo posture the promoted
# task will ship under. After promoting, send the soldier its ship instructions
# via cs-send.sh (inventory scratch state, reset to a clean default-branch base,
# carry over only intended fix changes, stay on branch cs/<task-id>, implement,
# then report done according to the recorded delivery mode).
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
echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)"
echo "next: CS_HOME=$HOME_Q bin/cs-send.sh $ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; stay on branch cs/$ID; implement; report done per mode=$MODE; also state execution mode (ultrawork, or plan-first per bin/cs-brief.sh --help) in the instructions>'"
