# shellcheck shell=bash
# cs-timeout-lib.sh - the single owner of plain hard-bounded command execution.
#
# Sourced, never executed. Provides one bounded runner so no caller re-derives
# the coreutils/BSD/perl selection, and so every plain bounded call in this
# repo agrees on what "the bound was hit" means.
#
#   cs_timeout_mechanism
#       Prints the mechanism cs_run_timed will use on this host: "timeout",
#       "gtimeout", "perl", or "bash". Set CS_TIMEOUT_MECHANISM_OVERRIDE=bash
#       to force the dependency-free fallback (tests use this to exercise the
#       watchdog on hosts that ship the faster mechanisms).
#
#   cs_run_timed <seconds> <command> [args...]
#       Runs the command with a hard bound. Exit status is the command's own,
#       except 124, which means the bound was hit (GNU timeout's convention,
#       reproduced by the perl and bash fallbacks).
#
# A non-positive bound is not a bound: `timeout 0` and the perl fallback's
# `alarm 0` both disable the deadline, so callers must reject 0 before calling.
#
# All four mechanisms terminate the whole process GROUP, not just the direct
# child, so a hung grandchild (a git fetch inside a sweep, a vendor CLI inside
# a wrapper) cannot outlive the bound. GNU/BSD `timeout` does this by giving
# the command its own process group; the perl fallback does it explicitly with
# setpgrp plus a negative pid; the bash fallback uses monitor mode to give the
# bounded child its own group before signaling its negative pid. macOS ships
# none of coreutils by default, so the perl and bash tiers are what keep the
# bound real on a stock BSD userland.
#
# Two bounded runners in this repo deliberately do NOT route here, because
# they carry different contracts this primitive must not absorb:
#   - bin/cs-watch.sh run_check_process: an exec-replacement runner whose perl
#     tier forwards HUP/INT/TERM to the owned check process group, because
#     cs_active_check_stop stops a check from OUTSIDE mid-flight.
#   - bin/cs-daemon.sh wedge_alarm_run_bounded: a polling watchdog that records
#     the notifier pid so the daemon can stop it externally at shutdown.
# Any NEW plain "run this command with a deadline" call belongs here.
#
# No side effects on source. set -u / set -e safe.

# Idempotent guard: several libraries and scripts may source this in one shell.
if [ -n "${CS_TIMEOUT_LIB_SOURCED:-}" ]; then
  return 0
fi
CS_TIMEOUT_LIB_SOURCED=1

cs_timeout_mechanism() {
  if [ "${CS_TIMEOUT_MECHANISM_OVERRIDE:-}" = bash ]; then
    printf 'bash\n'
  elif command -v timeout >/dev/null 2>&1; then
    printf 'timeout\n'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout\n'
  elif command -v perl >/dev/null 2>&1; then
    printf 'perl\n'
  else
    printf 'bash\n'
  fi
}

# Dependency-free watchdog: run the command in its own process group (monitor
# mode) with a background deadline that TERM-then-KILLs the whole group. The
# command's own exit status is recorded through a file because `wait` on a
# group-killed child reports the signal, not the status the command chose.
cs_run_bash_timeout() {
  local seconds=$1 command_status deadline_status child_pid watchdog_pid command_rc recorded_rc monitor_was_on=0
  shift
  command_status=$(mktemp "${TMPDIR:-/tmp}/cs-bash-timeout-command.XXXXXX" 2>/dev/null) || return 124
  deadline_status="${command_status}.deadline"
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  (
    set +m
    "$@"
    command_rc=$?
    printf '%s\n' "$command_rc" > "$command_status"
    exit "$command_rc"
  ) &
  child_pid=$!
  (
    set +m
    sleep "$seconds"
    printf 'expired\n' > "$deadline_status"
    kill -TERM -- "-$child_pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL -- "-$child_pid" 2>/dev/null || true
    exit 124
  ) &
  watchdog_pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m

  if wait "$child_pid" 2>/dev/null; then
    command_rc=0
  else
    command_rc=$?
  fi
  if [ -s "$deadline_status" ]; then
    wait "$watchdog_pid" 2>/dev/null || true
    command_rc=124
  else
    kill -TERM -- "-$watchdog_pid" 2>/dev/null || kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    recorded_rc=$(cat "$command_status" 2>/dev/null || true)
    case "$recorded_rc" in ''|*[!0-9]*) ;; *) command_rc=$recorded_rc ;; esac
  fi
  rm -f "$command_status" "$deadline_status" 2>/dev/null || true
  return "$command_rc"
}

# External runner (timeout or gtimeout) with the command's own status captured
# through a file: a KILL escalation makes the runner report 137 even when the
# command had already chosen an exit status, so the recorded status wins and
# only a genuine deadline maps to 124.
cs_run_external_timeout() {
  local runner=$1 seconds=$2 status_file runner_rc command_rc
  shift 2
  status_file=$(mktemp "${TMPDIR:-/tmp}/cs-timeout-status.XXXXXX" 2>/dev/null) || return 124
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  if "$runner" -k 1 "$seconds" bash -c '
    status_file=$1
    shift
    "$@"
    command_rc=$?
    printf "%s\n" "$command_rc" > "$status_file"
    exit "$command_rc"
  ' _ "$status_file" "$@"; then
    runner_rc=0
  else
    runner_rc=$?
  fi
  command_rc=$(cat "$status_file" 2>/dev/null || true)
  rm -f "$status_file" 2>/dev/null || true
  case "$command_rc" in
    ''|*[!0-9]*) ;;
    *) [ "$command_rc" -le 255 ] && return "$command_rc" ;;
  esac
  case "$runner_rc" in
    124|137) return 124 ;;
    *) return "$runner_rc" ;;
  esac
}

cs_run_timed() {  # <seconds> <command...>
  local seconds=$1
  shift
  case "$(cs_timeout_mechanism)" in
    timeout) cs_run_external_timeout timeout "$seconds" "$@" ;;
    gtimeout) cs_run_external_timeout gtimeout "$seconds" "$@" ;;
    perl)
      perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' \
        "$seconds" "$@"
      ;;
    bash) cs_run_bash_timeout "$seconds" "$@" ;;
    *) return 124 ;;
  esac
}
