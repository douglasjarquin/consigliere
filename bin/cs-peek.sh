#!/usr/bin/env bash
# Print the tail of a direct report's pane (bounded, for cheap diagnosis).
# Usage: cs-peek.sh <target> [lines=40]
#   <target> is an exact task id resolved through this home's state/<id>.meta,
#   or an explicit herdr pane id (w<N>:p<N>).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CS_ROOT="${CS_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CS_HOME="${CS_HOME:-${CS_ROOT_OVERRIDE:-$CS_ROOT}}"
STATE="${CS_STATE_OVERRIDE:-$CS_HOME/state}"

# shellcheck source=bin/cs-herdr-lib.sh
. "$SCRIPT_DIR/cs-herdr-lib.sh"
# shellcheck source=bin/cs-meta-lib.sh
. "$SCRIPT_DIR/cs-meta-lib.sh"

RAW=${1:?usage: cs-peek.sh <target> [lines]}
N=${2:-40}

case "$RAW" in
  w*[0-9]:p*[0-9]) PANE=$RAW ;;
  *)
    META="$STATE/$RAW.meta"
    [ -f "$META" ] || { echo "error: no task '$RAW' in this home (missing $META) and not an explicit pane id" >&2; exit 1; }
    PANE=$(cs_meta_get "$META" pane) || { echo "error: no pane recorded in $META" >&2; exit 1; }
    ;;
esac

cs_herdr_capture "$PANE" "$N" text
