# shellcheck shell=bash
# cs-timing-lib.sh - the single owner of consigliere's elapsed-time records.
#
# WHY THIS EXISTS. The deferred network stage publishes one aggregate
# started/finished pair, so a run that takes a minute cannot be attributed to a
# phase, a host, or a clone without re-running it by hand under manual tracing.
# One record per owner, each carrying its start OFFSET from a single shared
# origin, turns that pair into a timeline: a reader can see which step began
# when, how long it held the stage, and which item inside it was slow.
#
# THE RECORD. One line per timed owner, appended when it finishes:
#
#   <offset-ms><TAB><elapsed-ms><TAB><step><TAB><detail>
#
# `offset-ms` counts from CS_TIMING_ORIGIN, the one origin every record in a run
# shares, so offsets are directly comparable and a nested record always falls
# inside its parent's window. `detail` is `-` when the step names no item.
# Records are appended in FINISH order, which is not start order once a step
# contains timed items; cs_timing_print sorts by offset, so the artifact reads as
# a timeline no matter which process wrote which line.
#
# IDENTITIES ONLY. `step` and `detail` are identifiers - a capo id, a project
# clone name - and a value carrying whitespace is REFUSED rather than cleaned up.
# Accepting it would let a command line, an environment dump, or a captured error
# message reach this file through a caller that passed the wrong variable, and a
# quietly sanitized value would hide that mistake instead of surfacing it. A
# refusal costs one record; a repaired one costs the file its meaning.
#
# INERT UNLESS ASKED. Every function is a no-op until a run calls cs_timing_begin,
# which is what exports CS_TIMING_FILE and CS_TIMING_ORIGIN into the process tree
# that run launches. Both must be set for anything to be recorded, so a stray
# CS_TIMING_FILE inherited from somewhere else cannot start recording against
# another run's origin. Sourcing this library costs nothing.
#
# FAILURE POLICY. cs_timed always returns the timed command's own exit status,
# and never touches its stdout, stderr, or side effects: instrumentation that can
# change what it measures is worse than no instrumentation. cs_timing_record is
# the one function that reports for itself, returning non-zero on a refused value
# or an unwritable file, because a caller that wants to assert the refusal needs a
# way to see it.
#
# Usage: . bin/cs-timing-lib.sh

# Idempotent guard: several scripts in one process tree may source this.
if [ -n "${CS_TIMING_LIB_SOURCED:-}" ]; then
  return 0
fi
CS_TIMING_LIB_SOURCED=1

# Milliseconds since the epoch. EPOCHREALTIME is the only sub-second clock that
# needs no external process, so a per-item record costs no fork; its fractional
# separator follows the locale, hence the `[.,]` match. A shell without it (a
# stock macOS bash 3.2) falls back to whole seconds rather than losing the record
# entirely - a coarse timeline still attributes a slow minute to a step.
cs_timing_now_ms() {
  local raw=${EPOCHREALTIME:-} sec frac
  case "$raw" in
    *[.,]*)
      sec=${raw%%[.,]*}
      frac=${raw#*[.,]}
      frac=${frac}000
      frac=${frac:0:3}
      case "$sec$frac" in
        ''|*[!0-9]*) ;;
        *) printf '%s\n' "$((10#$sec * 1000 + 10#$frac))"; return 0 ;;
      esac
      ;;
  esac
  sec=$(date +%s 2>/dev/null || true)
  case "$sec" in ''|*[!0-9]*) sec=0 ;; esac
  printf '%s\n' "$((sec * 1000))"
}

# Ask this run to record, into <file>, with NOW as the shared origin. Exported so
# every child process of this run records against the same origin; truncating the
# file here is what makes a record set speak for exactly one run.
cs_timing_begin() {  # <file>
  local file=${1:-}
  [ -n "$file" ] || return 1
  : > "$file" 2>/dev/null || return 1
  CS_TIMING_FILE=$file
  CS_TIMING_ORIGIN=$(cs_timing_now_ms)
  export CS_TIMING_FILE CS_TIMING_ORIGIN
}

cs_timing_active() {
  [ -n "${CS_TIMING_FILE:-}" ] && [ -n "${CS_TIMING_ORIGIN:-}" ]
}

# An identity, not free text: non-empty and free of whitespace. See the header.
cs_timing_identity() {  # <value>
  case "${1:-}" in
    '') return 1 ;;
    *[[:space:]]*) return 1 ;;
  esac
  return 0
}

cs_timing_record() {  # <step> <detail> <start-ms> <end-ms>
  local step=${1:-} detail=${2:-} start=${3:-} end=${4:-} offset elapsed
  cs_timing_active || return 0
  cs_timing_identity "$step" || return 1
  [ -z "$detail" ] || cs_timing_identity "$detail" || return 1
  case "$start$end$CS_TIMING_ORIGIN" in ''|*[!0-9]*) return 1 ;; esac
  # A clock that stepped backwards clamps to zero rather than emitting a negative
  # offset or a negative duration, neither of which any reader of this file can
  # act on.
  offset=$((start - CS_TIMING_ORIGIN))
  [ "$offset" -ge 0 ] || offset=0
  elapsed=$((end - start))
  [ "$elapsed" -ge 0 ] || elapsed=0
  printf '%s\t%s\t%s\t%s\n' "$offset" "$elapsed" "$step" "${detail:--}" \
    >> "$CS_TIMING_FILE" 2>/dev/null || return 1
}

# Run a command and record one elapsed-time record for it. The command runs in
# THIS shell, so a timed shell function keeps every side effect it had untimed.
cs_timed() {  # <step> <detail> <command> [<args>...]
  local step=$1 detail=$2 start rc=0
  shift 2
  if ! cs_timing_active; then
    "$@" || rc=$?
    return "$rc"
  fi
  start=$(cs_timing_now_ms)
  "$@" || rc=$?
  cs_timing_record "$step" "$detail" "$start" "$(cs_timing_now_ms)" || true
  return "$rc"
}

# The timeline: every record in <file>, earliest start first. Returns non-zero
# when there is nothing to print, so a caller can omit its heading.
cs_timing_print() {  # <file>
  local file=${1:-} offset elapsed step detail
  [ -n "$file" ] && [ -s "$file" ] || return 1
  while IFS=$'\t' read -r offset elapsed step detail; do
    [ -n "$step" ] || continue
    case "$offset$elapsed" in ''|*[!0-9]*) continue ;; esac
    case "${detail:--}" in
      -) printf '  +%sms  took %sms  %s\n' "$offset" "$elapsed" "$step" ;;
      *) printf '  +%sms  took %sms  %s %s\n' "$offset" "$elapsed" "$step" "$detail" ;;
    esac
  done < <(sort -n -k1,1 "$file" 2>/dev/null)
}
