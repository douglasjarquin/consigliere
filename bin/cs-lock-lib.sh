#!/usr/bin/env bash
# Shared "is this git lock file provably abandoned?" decision procedure.
#
# ONE owner for the staleness proof that cs-teardown.sh (a worktree index.lock)
# and cs-fleet-sync.sh (a clone's .git/packed-refs.lock) both rely on: a lock is
# provably stale iff ALL of the following hold -
#   1. the lock file still exists;
#   2. no live process holds the lock file open, and none holds a companion
#      directory (the worktree, or the repo's .git dir) open as cwd or an fd -
#      a live git process keeps its own lock open for the whole operation, so an
#      empty lsof result means the file was abandoned, not that no one held it;
#   3. its mtime age is at least a caller-supplied threshold - a freshly created
#      lock might belong to a process lsof has not yet reflected.
# ANY uncertainty - lsof missing, an lsof error, an unreadable mtime - returns
# non-zero (NOT stale): fail safe, never remove a lock that cannot be proven dead.
# Diagnostics print to stderr prefixed by ${CS_LOCK_LOG_PREFIX:-cs-lock} so each
# caller's output stays recognizable.

# Idempotent guard: several libraries source this leaf for cs_lock_path_mtime,
# and a caller may reach it through more than one of them.
if [ -n "${CS_LOCK_LIB_SOURCED:-}" ]; then
  return 0
fi
CS_LOCK_LIB_SOURCED=1

cs_lock_log() {
  echo "${CS_LOCK_LOG_PREFIX:-cs-lock}: $*" >&2
}

# Portable mtime in epoch seconds - THE one owner of the stat mtime read, which
# every other mtime helper in bin/ delegates to. macOS (BSD) stat spells it
# `stat -f %m`; GNU coreutils spells it `stat -c %Y`. NEVER collapse the two
# into `stat -f %m ... || stat -c %Y ...`: on GNU coreutils `-f` is *filesystem*
# stat, so it consumes the format string as a path, complains on stderr, prints
# a partial filesystem dump ("  File: ...") on stdout, and can still exit 0 -
# the fallback never runs and the caller's arithmetic evaluates garbage,
# aborting under `set -u`. The flavor is probed ONCE per process against this
# library file itself: the BSD form is trusted only when it produces a pure
# integer, and anything else selects the GNU form.
_cs_lock_stat_flavor_probe() {
  local probe
  if [ -z "${_CS_LOCK_STAT_FLAVOR:-}" ]; then
    probe=$(LC_ALL=C stat -f %m "${BASH_SOURCE[0]}" 2>/dev/null) || probe=
    case "$probe" in
      ''|*[!0-9]*) _CS_LOCK_STAT_FLAVOR=gnu ;;
      *) _CS_LOCK_STAT_FLAVOR=bsd ;;
    esac
  fi
}

# cs_lock_path_mtime <path>: pure-integer epoch mtime on stdout, or non-zero
# with NO output. A non-numeric stat result is a failure, never passed through,
# so a portability surprise degrades to the caller's own failure handling
# instead of corrupting downstream arithmetic.
cs_lock_path_mtime() {
  local m
  _cs_lock_stat_flavor_probe
  if [ "$_CS_LOCK_STAT_FLAVOR" = bsd ]; then
    m=$(LC_ALL=C stat -f %m "$1" 2>/dev/null) || return 1
  else
    m=$(LC_ALL=C stat -c %Y "$1" 2>/dev/null) || return 1
  fi
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$m"
}

# cs_lock_lsof_holder <target>: 0 a process holds it, 1 provably none, 2 lsof
# errored (cannot tell). Diagnostics print on the error path only.
cs_lock_lsof_holder() {
  local target=$1 output status
  if output=$(lsof -- "$target" 2>&1); then
    return 0
  else
    status=$?
  fi
  if [ "$status" -eq 1 ] && [ -z "$output" ]; then
    return 1
  fi
  if [ -n "$output" ]; then
    while IFS= read -r line; do
      cs_lock_log "lsof check failed: $line"
    done <<< "$output"
  else
    cs_lock_log "lsof check failed for $target with exit $status"
  fi
  return 2
}

# cs_lock_has_live_holder <lock> <dir>: 0 if a live process holds $lock or the
# companion $dir open, OR if the answer is uncertain - a missing lsof or an lsof
# error is treated as "cannot prove no holder" (fail safe: assume live). Returns
# 1 only when lsof reports provably no holder on both.
cs_lock_has_live_holder() {
  local lock=$1 dir=$2 status
  command -v lsof >/dev/null 2>&1 || return 0
  if [ -n "$lock" ]; then
    if cs_lock_lsof_holder "$lock"; then
      return 0
    else
      status=$?
      [ "$status" -eq 1 ] || return 0
    fi
  fi
  if [ -n "$dir" ]; then
    if cs_lock_lsof_holder "$dir"; then
      return 0
    else
      status=$?
      [ "$status" -eq 1 ] || return 0
    fi
  fi
  return 1
}

# cs_lock_age <lock>: prints the lock's mtime age in whole seconds, or fails.
cs_lock_age() {
  local lock=$1 m now
  m=$(cs_lock_path_mtime "$lock") || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$(( now - m ))"
}

# cs_lock_is_provably_stale <lock> <dir> <min_age_secs>: THE proof. Returns 0 iff
# the lock exists, has no live holder, and its mtime age is at least
# <min_age_secs>. Returns non-zero on any uncertainty - never remove a lock this
# returns non-zero for.
cs_lock_is_provably_stale() {
  local lock=$1 dir=$2 min_age=$3 age
  [ -n "$lock" ] && [ -e "$lock" ] || return 1
  cs_lock_has_live_holder "$lock" "$dir" && return 1
  if ! age=$(cs_lock_age "$lock"); then
    cs_lock_log "cannot read mtime for git lock $lock; leaving it in place"
    return 1
  fi
  [ "$age" -ge "$min_age" ]
}
