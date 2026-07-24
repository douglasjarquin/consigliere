#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the soldier keeps its pane,
# worktree, and loaded context; only the contract changes. Flips kind= to ship
# in state/<task-id>.meta so cs-teardown.sh applies the full ship-task teardown
# protection again. After promoting, send the soldier its ship instructions via
# cs-send.sh (inventory scratch state, reset to a clean default-branch base,
# carry over only intended fix changes, stay on branch cs/<task-id>, implement,
# then report done according to the project's delivery mode).
# Usage: cs-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
ID=${1:?usage: cs-promote.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

TMP="$META.tmp"
grep -v '^kind=' "$META" > "$TMP"
echo "kind=ship" >> "$TMP"
mv "$TMP" "$META"

HOME_Q=$(printf '%q' "$CS_HOME")
echo "promoted $ID to ship (teardown protection restored)"
echo "next: CS_HOME=$HOME_Q bin/cs-send.sh $ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; stay on branch cs/$ID; implement; report done>'"
