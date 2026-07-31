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
# their script-dir variable differently (CS_AFK_START_DIR, CS_DAEMON_DIR, ...)
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

# DATA/STATE/CONFIG are set for the caller, not used within this library.
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
}
