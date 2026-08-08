#!/usr/bin/env bash
# Acquire or inspect the per-home consigliere session lock.
# Writes the harness (codex or claude) process PID found by walking the shell's
# ancestry, which lives as long as the consigliere session - unlike the
# transient subshell PID of any one tool call, which is dead moments after it is
# written. bin/cs-session-pid-lib.sh owns that walk and the harness identity test
# it rests on, because bin/cs-telemetry-lib.sh needs the same "which process IS
# this session" answer and must not duplicate it.
# Usage: cs-lock.sh           acquire; exit 1 if another live session holds it
#        cs-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
# shellcheck source=bin/cs-session-pid-lib.sh
. "$SCRIPT_DIR/cs-session-pid-lib.sh"
cs_resolve_root
LOCK="$STATE/.lock"
mkdir -p "$STATE"

holder_alive() {  # true if $1 is a live process that looks like the harness
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  # Deliberately the same predicate the ancestry walk uses. When these two
  # disagree, a live session's own lock can read as stale to a second session,
  # which then takes it - and two sessions mutate one fleet, the exact outcome
  # this lock exists to prevent.
  cs_session_harness_process_is "$comm" "$args"
}

# Sourced rather than run: expose holder_alive and stop, so a caller can ask
# about a recorded holder without taking the lock as a side effect. The harness
# identity predicates themselves live in bin/cs-session-pid-lib.sh, which the
# tests drive directly against crafted strings.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(cs_session_harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "error: another live consigliere session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
