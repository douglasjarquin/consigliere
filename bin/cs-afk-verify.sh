#!/usr/bin/env bash
# bin/cs-afk-verify.sh - certify that away mode actually has a supervisor.
#
# MUST run as a SEPARATE step from bin/cs-afk-start.sh, in a later tool call.
# That separation is the entire point and is not a style preference:
#
#   cs-afk-start.sh launches the daemon from inside an agent's bounded tool
#   call. If the daemon dies with that call's process group - the failure that
#   cost five away sessions - it is still alive for every instant the launching
#   call can observe. A check that runs before that call returns therefore
#   certifies a daemon that is about to die. Only a check running AFTER the
#   launching group is gone can tell the difference, and the only way to be
#   after it is to be in a different call.
#
# bin/cs-detach.py now keeps the daemon out of that group in the first place,
# so this should pass. It stays because a fix that is only correct while its
# root cause is also fixed is not a check. It also catches the launch fallback
# (no python3), a daemon wedged off its loop, and a recycled pid.
#
# What it certifies, all three required:
#   - state/.afk is present (away mode is actually flagged);
#   - the daemon lock is held by a live pid that really is bin/cs-daemon.sh;
#   - its completed-pass counter (state/.subsuper-daemon-beat) ADVANCES while
#     this runs, which only a daemon coming back around its loop can do.
#
# On failure it stops the daemon, clears state/.afk, and exits non-zero, so the
# caller is never left believing an unattended fleet is being watched. Rolling
# back is the safe direction: ordinary supervision resumes, and the boss is told
# away mode is off rather than discovering it in the morning.
#
# Usage:
#   cs-afk-verify.sh            certify, or roll away mode back
#
# Env:
#   CS_AFK_VERIFY_TICKS   0.1s ticks to wait for the counter to advance
#                         (default 150; the daemon's own pass is ~1s, and its
#                         first can be slower on a large fleet)
set -eu

CS_AFK_VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/cs-root-lib.sh
. "$CS_AFK_VERIFY_DIR/cs-root-lib.sh"
cs_resolve_root

# cs-afk-start.sh owns the daemon lock/liveness/beat helpers; source it as a
# library (its BASH_SOURCE guard keeps main from running) rather than restating
# the contract here.
CS_AFK_START="${CS_AFK_START:-$CS_AFK_VERIFY_DIR/cs-afk-start.sh}"
# shellcheck source=bin/cs-afk-start.sh
. "$CS_AFK_START"

cs_afk_verify_usage() {
  sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

cs_afk_verify_rollback() {  # <reason>
  cs_afk_daemon_stop_uncertified
  rm -f "$CS_AFK_STATE/.afk"
  echo "error: away mode NOT armed - $1; rolled back, ordinary supervision applies (see $CS_AFK_STATE/.subsuper-daemon.err and $CS_AFK_STATE/.subsuper-daemon.log)" >&2
  return 1
}

cs_afk_verify_main() {
  case "${1:-}" in
    '' ) ;;
    -h|--help) cs_afk_verify_usage; return 0 ;;
    * ) echo "usage: $(basename "${BASH_SOURCE[0]}")" >&2; return 2 ;;
  esac

  if [ ! -e "$CS_AFK_STATE/.afk" ]; then
    echo "afk: away mode is not flagged; nothing to certify" >&2
    return 1
  fi

  cs_afk_daemon_alive \
    || cs_afk_verify_rollback "the daemon is gone (it did not survive the call that started it)"

  local first second i=0
  first=$(cs_afk_daemon_beat)
  while [ "$i" -lt "${CS_AFK_VERIFY_TICKS:-150}" ]; do
    second=$(cs_afk_daemon_beat)
    if [ -n "$second" ] && [ -n "$first" ] && [ "$second" != "$first" ]; then
      # Re-check liveness at the end: a counter can advance and the daemon can
      # still have died in the same window.
      cs_afk_daemon_alive \
        || cs_afk_verify_rollback "the daemon died during certification"
      echo "afk: away mode certified; daemon pid=$(cs_afk_daemon_lock_pid) has completed pass $second and owns supervision"
      return 0
    fi
    # The daemon writes its first counter only at the END of pass one, so an
    # empty reading here is "not yet", not "never".
    [ -n "$first" ] || first=$second
    cs_afk_daemon_alive \
      || cs_afk_verify_rollback "the daemon died before completing a supervision pass"
    sleep 0.1
    i=$((i + 1))
  done
  cs_afk_verify_rollback "the daemon is running but never completed a supervision pass"
}

# Run only when executed, not when sourced.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cs_afk_verify_main "$@"
fi
