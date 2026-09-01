#!/usr/bin/env bash
# cs-telemetry-emit.sh - the executable entry point for worker turn telemetry.
#
# A ship or scout soldier has no consigliere shell to source a library into: its
# turn end is a command line in the harness's own turn-end wiring (codex's
# `notify`, claude's launch-scoped Stop hook). That command is this script.
# bin/cs-telemetry-lib.sh remains the single owner of enablement, the storage
# path, the schema, and every rule; this file only routes one invocation into it.
#
# cs-spawn.sh adds this call to a soldier's turn-end wiring ONLY when telemetry
# is enabled at spawn time, so with telemetry off the launch line is byte
# identical to an uninstrumented one. bin/cs-telemetry-lib.sh's
# cs_telemetry_worker_hook_command builds the exact invocation.
#
# Usage:
#   cs-telemetry-emit.sh --worker --task <id> [--stdin]
#   cs-telemetry-emit.sh --help
#
# --stdin reads the harness Stop payload from standard input (claude, whose Stop
# hook feeds every hook command the payload). It is deliberately absent for codex,
# whose `notify` program receives an argument and no piped payload: reading stdin
# there would block a soldier's turn-end wiring forever.
#
# EXIT STATUS IS ALWAYS 0, and nothing is ever written to stdout or stderr. This
# script runs inside a soldier's turn-end path, where the load-bearing effect is
# the sibling `touch state/<id>.turn-ended` that supervision depends on. A
# telemetry failure must be indistinguishable from telemetry being off.
set -u

CS_TELEMETRY_EMIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0

case "${1:-}" in
  -h|--help)
    awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
    exit 0
    ;;
esac

MODE=
TASK=
READ_STDIN=0
# Every branch must consume at least one argument. `shift 2` with a single
# positional left shifts NOTHING and returns non-zero, so a trailing `--task`
# would spin this loop forever - and a hang here is worse than any error, because
# this runs inside a soldier's turn-end wiring, which would then never return.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --worker) MODE=worker; shift ;;
    --task) TASK=${2:-}; shift 2 || shift ;;
    --stdin) READ_STDIN=1; shift ;;
    *) shift ;;
  esac
done

[ "$MODE" = worker ] || exit 0
[ -n "$TASK" ] || exit 0

PAYLOAD=
if [ "$READ_STDIN" -eq 1 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
fi

# shellcheck source=bin/cs-telemetry-lib.sh
. "$CS_TELEMETRY_EMIT_DIR/cs-telemetry-lib.sh" 2>/dev/null || exit 0
cs_telemetry_worker_turn_end "$TASK" "$PAYLOAD" 2>/dev/null || true
exit 0
