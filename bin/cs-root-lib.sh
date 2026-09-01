# shellcheck shell=bash
# cs-root-lib.sh - the single owner of CS_ROOT/CS_HOME/DATA/STATE/CONFIG resolution.
#
# The same root/home resolution pair was duplicated verbatim across ~28 scripts.
# This library makes it a single owner, matching the repo's "one owner" pattern
# for herdr (cs-herdr-lib.sh), harness facts (cs-harness-lib.sh), and meta
# (cs-meta-lib.sh). It reproduces the inline precedence byte-for-byte, so every
# override combination resolves to identical values before and after migration.
#
# Usage:
#   # shellcheck source=bin/cs-root-lib.sh
#   . "$SCRIPT_DIR/cs-root-lib.sh"   # or the caller's own <script>_DIR variant
#   cs_resolve_root
#
# cs_resolve_root computes the repo root from THIS library's own location
# (<lib dir>/..), not from any caller SCRIPT_DIR variable, so callers that name
# their script-dir variable differently (CS_AFK_START_DIR, CS_MONITOR_LIB_DIR, ...)
# resolve identically. The library lives in bin/, so <lib dir>/.. is the root.

# Idempotent guard: sourcing twice must not redefine the function.
if [ -n "${CS_ROOT_LIB_SOURCED:-}" ]; then
  return 0
fi
CS_ROOT_LIB_SOURCED=1

# cs_resolve_root - set CS_ROOT, CS_HOME, DATA, STATE, CONFIG from the override
# environment, preserving the exact inline precedence:
#
#   CS_ROOT   = ${CS_ROOT_OVERRIDE:-<repo root computed from this lib's dir>}
#   CS_HOME   = ${CS_HOME:-${CS_ROOT_OVERRIDE:-$CS_ROOT}}
#   DATA      = ${CS_DATA_OVERRIDE:-$CS_HOME/data}
#   STATE     = ${CS_STATE_OVERRIDE:-$CS_HOME/state}
#   CONFIG    = ${CS_CONFIG_OVERRIDE:-$CS_HOME/config}
#
# The CS_HOME default keeps the historical quirk that CS_ROOT_OVERRIDE wins over
# the computed CS_ROOT when CS_HOME itself is unset. Since CS_ROOT already folds
# CS_ROOT_OVERRIDE in, this is an equivalence in practice, but it is preserved
# verbatim so the resolution stays a pure extraction.
#
# Every resolved path is made ABSOLUTE before the caller sees it. These values
# do not stay inside one process: they are baked into durable soldier briefs and
# capo charters, and restated on launch lines and daemon handoffs that other
# processes run from a different working directory. A relative CS_HOME,
# CS_DATA_OVERRIDE, or CS_STATE_OVERRIDE would silently mean a DIFFERENT
# directory in each of those processes - a soldier writing its status and report
# somewhere consigliere never looks.
#
# Anchoring is deliberately all this does. An already-absolute path (the normal
# case) passes through byte-identical: no `cd`, no symlink canonicalization, no
# existence requirement. That keeps resolution a pure extraction for every real
# configuration, and it matters that DATA/STATE/CONFIG resolve fine before they
# have been created. Only a relative path changes, from "reinterpreted later" to
# "anchored at the process that resolved it".
cs_abs_path() {  # <path> -> the same path, guaranteed absolute; rc=1 if empty
  case "$1" in
    '') return 1 ;;
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

# cs_layout_pairs - the single owner of the config/-layout migration mapping.
# One "old<TAB>new" line per moved file, both relative to the resolved home
# (old under $DATA or $CONFIG, new under $CONFIG). bin/cs-migrate-config.sh
# renames along these pairs; cs_layout_gate refuses while any old name exists,
# so the two can never disagree about what "migrated" means.
cs_layout_pairs() {
  printf '%s\t%s\n' \
    "$CONFIG/backlog-backend"  "$CONFIG/backlog-backend.conf" \
    "$CONFIG/permission-mode"  "$CONFIG/permission-mode.conf" \
    "$CONFIG/upstream"         "$HOST_DIR/upstream.conf" \
    "$CONFIG/activation"       "$HOST_DIR/activation.conf" \
    "$CONFIG/wedge-alarm"      "$CONFIG/wedge-alarm.conf" \
    "$CONFIG/harness"          "$HOST_DIR/harness.conf" \
    "$DATA/boss.md"            "$CONFIG/boss.md" \
    "$DATA/boss-shared.md"     "$CONFIG/boss-shared.md" \
    "$DATA/learnings.md"       "$CONFIG/learnings.md" \
    "$DATA/projects.md"        "$CONFIG/projects.md" \
    "$DATA/boards.md"          "$CONFIG/boards.md" \
    "$DATA/backlog.md"         "$CONFIG/backlog.md" \
    "$DATA/done-archive.md"    "$CONFIG/done-archive.md" \
    "$DATA/note-archive.md"    "$CONFIG/note-archive.md" \
    "$DATA/capos.md"           "$HOST_DIR/capos.md" \
    "$DATA/charter.md"         "$CONFIG/charter.md"
}

# cs_layout_gate - fail closed while any pre-move path still exists.
# An old-name file (or dangling symlink) means this home has not migrated to
# the config/ userspace layout; running against it would read absent-but-legal
# defaults and silently ignore the boss's real files. The refusal names the
# migrator and EXITS: most scripts here run under set -u without set -e, so a
# returned failure would be silently ignored, which is the exact silent-loss
# mode this gate exists to prevent. CS_LAYOUT_GATE_SKIP=1 bypasses it for
# exactly three callers: bin/cs-migrate-config.sh (which must run against the
# unmigrated home), bin/cs-session-start.sh's lock-and-migrate step, and
# bin/cs-doctor.sh (checks-only; it reports migration state as a finding
# instead of dying on it).
cs_layout_gate() {
  [ "${CS_LAYOUT_GATE_SKIP:-}" = 1 ] && return 0
  local old
  while IFS=$'\t' read -r old _; do
    if [ -e "$old" ] || [ -L "$old" ]; then
      printf 'cs-root: %s exists; this home has not been migrated to the config/ layout - run bin/cs-migrate-config.sh\n' "$old" >&2
      exit 1
    fi
  done < <(cs_layout_pairs)
  return 0
}

# DATA/STATE/CONFIG/HOST_DIR are set for the caller, not used within this
# library. HOST_DIR is the machine-local tier: a top-level sibling of config/,
# never backed up, re-created per machine.
# shellcheck disable=SC2034
cs_resolve_root() {
  local _cs_root_lib_dir
  # CDPATH is inherited and would make an unqualified `cd` land elsewhere (and
  # print the destination), so clear it for these lookups.
  _cs_root_lib_dir=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  CS_ROOT="${CS_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$_cs_root_lib_dir/.." && pwd)}"
  CS_ROOT=$(cs_abs_path "$CS_ROOT") || {
    printf 'cs-root: CS_ROOT resolved empty; refusing to continue with an unanchored root\n' >&2
    return 1
  }
  CS_HOME="${CS_HOME:-${CS_ROOT_OVERRIDE:-$CS_ROOT}}"
  CS_HOME=$(cs_abs_path "$CS_HOME") || {
    printf 'cs-root: CS_HOME is set but empty; refusing to guess a home\n' >&2
    return 1
  }
  DATA=$(cs_abs_path "${CS_DATA_OVERRIDE:-$CS_HOME/data}") || return 1
  STATE=$(cs_abs_path "${CS_STATE_OVERRIDE:-$CS_HOME/state}") || return 1
  CONFIG=$(cs_abs_path "${CS_CONFIG_OVERRIDE:-$CS_HOME/config}") || return 1
  HOST_DIR=$(cs_abs_path "${CS_HOST_OVERRIDE:-$CS_HOME/host}") || return 1
  cs_layout_gate
}
