#!/usr/bin/env bash
# cs-marker-lib.sh - compatibility entry point for legacy marker callers.
#
# bin/cs-operational-input.sh owns all marker bytes, construction, and
# classification. This file preserves the historical constants and function
# names for capos already carrying the labeled marker contract.
#
# Sourced by bin/cs-send.sh, bin/cs-brief.sh, and tests. No side effects on
# source. set -u / set -e safe.

_CS_MARKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _CS_MARKER_LIB_DIR="."
# shellcheck source=bin/cs-operational-input.sh
. "$_CS_MARKER_LIB_DIR/cs-operational-input.sh"

# cs_message_from_consigliere: 0 (true) if <message> carries the
# from-consigliere marker - it begins with the label immediately followed by
# U+2063 - and 1 otherwise. U+2063 has no normal keyboard keystroke, so
# boss-typed input, even when it starts with the visible label text alone, is
# never matched.
cs_message_from_consigliere() {  # <message>
  local kind
  cs_operational_input_kind "${1-}" kind 2>/dev/null || return 1
  [ "$kind" = from-consigliere ]
}

cs_message_mark_from_consigliere() {  # <message> <result-var>
  local message=${1-} result_var=${2-}
  [ -n "$result_var" ] || return 2
  cs_operational_input_construct from-consigliere "$message" "$result_var"
}
