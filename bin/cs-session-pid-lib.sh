# shellcheck shell=bash
# cs-session-pid-lib.sh - the single owner of "which process IS this consigliere
# session".
#
# A consigliere session is the harness (codex or claude) process that a shell
# finds by walking its own ancestry. That process lives as long as the session,
# unlike the transient subshell PID of any one tool call, which is dead moments
# after it is written. bin/cs-lock.sh uses it as the identity of the home lock
# holder, and bin/cs-telemetry-lib.sh uses the same identity to key one session's
# turn-scoped breadcrumbs so a second session in the same home cannot read, fold,
# or delete them.
#
# Pure function definitions with no side effects on source: sourcing this file
# resolves no home, creates no directory, and takes no lock.
#
#   cs_session_harness_names_in <path-ish> [words]  does a component name it?
#   cs_session_harness_process_is <comm> <args>     is that process the harness?
#   cs_session_harness_pid                          print the ancestry's harness pid
#
# Usage: . bin/cs-session-pid-lib.sh

if [ -n "${CS_SESSION_PID_LIB_SOURCED:-}" ]; then
  return 0
fi
CS_SESSION_PID_LIB_SOURCED=1

# The root session runs on one of the supported harnesses (codex or claude);
# either may hold a home's lock. The test harness may widen this to match its own
# shell. Read at call time, not at source time, so a caller that sources this lib
# early still honors an override set later.
cs_session_harness_re() {
  printf '%s\n' "${CS_LOCK_HARNESS_RE:-codex|claude}"
}

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
cs_session_harness_names_in() { # <path-ish string> [<split-on-spaces-too>]
  local s=$1 split_words=${2:-} part stripped rc=1 oldifs=$IFS re
  re=$(cs_session_harness_re)
  if [ -n "$split_words" ]; then IFS='/ 	'; else IFS='/'; fi
  # shellcheck disable=SC2086 # deliberate word splitting on the IFS set above
  set -- $s
  IFS=$oldifs
  for part in "$@"; do
    stripped=${part#-}
    [ -n "$stripped" ] || continue
    if printf '%s' "$stripped" | grep -qE "^(${re})$"; then rc=0; break; fi
  done
  return "$rc"
}

# True when this process's own identity names the harness. Both the executable
# path and argv[0] are consulted, because the two platforms disagree about which
# one carries the real name.
cs_session_harness_process_is() { # <comm> <args>
  local comm=$1 args=$2 argv0=${2%% *}
  cs_session_harness_names_in "$comm" && return 0
  cs_session_harness_names_in "$argv0" && return 0
  # Bare interpreter (e.g. node): the harness is named in the script path, which
  # is an argument rather than argv[0], so this one case reads the whole line.
  case "$comm" in
    *node*|*python*) cs_session_harness_names_in "$args" words && return 0 ;;
  esac
  return 1
}

# Sixteen hops, not eight: a hook-run session start (bin/cs-sessionstart-run.sh
# -> bounded parent -> timeout runner -> wrapper shell -> bounded child ->
# cs-lock) stacks four to five more shells between this walk and the harness
# than a directly invoked one.
#
# Up to sixteen `ps` calls, so a caller that needs this per event must cache the
# answer for the life of its process rather than resolve it repeatedly.
cs_session_harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if cs_session_harness_process_is "$comm" "$args"; then
      printf '%s\n' "$pid"; return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}
