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
# DATA/STATE/CONFIG are set for the caller, not used within this library.
# shellcheck disable=SC2034
cs_resolve_root() {
  local _cs_root_lib_dir
  _cs_root_lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  CS_ROOT="${CS_ROOT_OVERRIDE:-$(cd "$_cs_root_lib_dir/.." && pwd)}"
  CS_HOME="${CS_HOME:-${CS_ROOT_OVERRIDE:-$CS_ROOT}}"
  DATA="${CS_DATA_OVERRIDE:-$CS_HOME/data}"
  STATE="${CS_STATE_OVERRIDE:-$CS_HOME/state}"
  CONFIG="${CS_CONFIG_OVERRIDE:-$CS_HOME/config}"
}
