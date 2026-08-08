# shellcheck shell=bash
# cs-session-pid-lib.sh - the single owner of process identity: which process IS
# this consigliere session, and how a recorded pid proves it is still the SAME
# process rather than a recycled number.
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
# resolves no home, creates no directory, and takes no lock. That is why
# bin/cs-telemetry-lib.sh can pull it into every instrumented caller, and why
# cs_pid_identity lives here rather than in bin/cs-wake-lib.sh, which resolves a
# home and creates state/ on source.
#
#   cs_session_harness_names_in <path-ish> [words]  does a component name it?
#   cs_session_harness_process_is <comm> <args>     is that process the harness?
#   cs_session_harness_pid                          print the ancestry's harness pid
#   cs_pid_identity <pid>                           print a pid's reuse-proof identity
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

# cs_pid_identity <pid> - print a stable, machine-readable string that changes
# when the pid is reused by a different process. Callers persist it beside a
# recorded pid and compare on re-read, so a recycled number reads as a mismatch:
# bin/cs-wake-lib.sh's watcher-lock validation, bin/cs-procevent-lib.sh, and
# bin/cs-telemetry-lib.sh's per-session breadcrumb key all rely on that.
#
# The exact output is a persisted contract, not an internal detail: a live
# watcher's lock is rejected the moment this string renders differently than it
# did when the lock was written.
cs_pid_identity() {
  local pid=$1 out proc_root stat_line starttime cmdline_hex
  local -a stat_fields
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  proc_root=${CS_PROC_ROOT_OVERRIDE:-/proc}
  # Prefer /proc on Linux: stat field 22 (starttime, clock ticks since boot) is
  # immune to the wall-clock steps that re-render the ps lstart fallback's date
  # (observed as WSL2 btime drift) and would evict a live watcher; combining the
  # full NUL-separated cmdline keeps PID reuse a mismatch even on a tick collision.
  if [ "$(uname)" = Linux ] && [ -r "$proc_root/$pid/stat" ] && [ -r "$proc_root/$pid/cmdline" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    # After the final comm delimiter, array index 19 is proc stat field 22.
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in
      ''|*[!0-9]*) return 1 ;;
    esac
    cmdline_hex=$(od -An -v -tx1 "$proc_root/$pid/cmdline" 2>/dev/null | tr -d '[:space:]') || return 1
    [ -n "$cmdline_hex" ] || return 1
    printf 'linux-starttime=%s cmdline-hex=%s\n' "$starttime" "$cmdline_hex"
    return 0
  fi
  # Pin LC_ALL=C so lstart's date format is locale-invariant: the identity is
  # written under one locale but re-read under the machine's ambient locale, which
  # would otherwise mismatch on a non-C locale (e.g. ko_KR) and reject a live watcher.
  out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}
