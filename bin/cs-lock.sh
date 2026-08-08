#!/usr/bin/env bash
# Acquire or inspect the per-home consigliere session lock.
# Writes the harness (codex or claude) process PID found by walking the shell's
# ancestry, which lives as long as the consigliere session - unlike the
# transient subshell PID of any one tool call, which is dead moments after it is
# written. Harness identity is matched on whole path components of both the
# executable path and argv[0]; see harness_names_in below for why.
# Usage: cs-lock.sh           acquire; exit 1 if another live session holds it
#        cs-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# The root session runs on one of the supported harnesses (codex or claude);
# either may hold this home's lock. The test harness may widen this to match its
# own shell.
HARNESS_RE="${CS_LOCK_HARNESS_RE:-codex|claude}"

# Does any WHOLE path component of $1 name the harness?
#
# Reading only the basename is not enough. Claude Code's native installer names
# the per-session executable by version, so the process is
# .../share/claude/versions/2.1.220 and its basename ("2.1.220") identifies
# nothing - the harness is the `claude` DIRECTORY component. On Linux this is
# unconditional, because procps reports the kernel exec name and ignores
# argv[0]; macOS often still reports "claude" through argv[0], which is why
# this has not bitten every install.
#
# Scanning whole paths widens the surface, so matching only WHOLE components is
# what keeps it safe: `~/.claude/hooks/foo.sh` has no `claude` component (it has
# `.claude`), and a script named `cs-claude-guard.sh` is one component that is
# not `claude` either. An unanchored search would call both of those a harness.
#
# A leading dash is stripped per component because a login shell's argv[0] is
# "-zsh" by convention; the dash is not part of the name.
harness_names_in() { # <path-ish string> [<split-on-spaces-too>]
  local s=$1 split_words=${2:-} part stripped rc=1 oldifs=$IFS
  if [ -n "$split_words" ]; then IFS='/ 	'; else IFS='/'; fi
  # shellcheck disable=SC2086 # deliberate word splitting on the IFS set above
  set -- $s
  IFS=$oldifs
  for part in "$@"; do
    stripped=${part#-}
    [ -n "$stripped" ] || continue
    if printf '%s' "$stripped" | grep -qE "^(${HARNESS_RE})$"; then rc=0; break; fi
  done
  return "$rc"
}

# True when this process's own identity names the harness. Both the executable
# path and argv[0] are consulted, because the two platforms disagree about which
# one carries the real name.
harness_process_is() { # <comm> <args>
  local comm=$1 args=$2 argv0=${2%% *}
  harness_names_in "$comm" && return 0
  harness_names_in "$argv0" && return 0
  # Bare interpreter (e.g. node): the harness is named in the script path, which
  # is an argument rather than argv[0], so this one case reads the whole line.
  case "$comm" in
    *node*|*python*) harness_names_in "$args" words && return 0 ;;
  esac
  return 1
}

# Sixteen hops, not eight: a hook-run session start (bin/cs-sessionstart-run.sh
# -> bounded parent -> timeout runner -> wrapper shell -> bounded child ->
# cs-lock) stacks four to five more shells between this walk and the harness
# than a directly invoked one.
harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if harness_process_is "$comm" "$args"; then
      echo "$pid"; return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like the harness
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  # Deliberately the same predicate the ancestry walk uses. When these two
  # disagree, a live session's own lock can read as stale to a second session,
  # which then takes it - and two sessions mutate one fleet, the exact outcome
  # this lock exists to prevent.
  harness_process_is "$comm" "$args"
}

# Sourced rather than run: expose the predicates above and stop. Lets the tests
# drive harness identity against crafted strings directly, instead of only
# through a live process table they cannot control.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "error: another live consigliere session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
