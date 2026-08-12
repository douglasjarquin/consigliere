#!/usr/bin/env bash
# cs-exec-mode-lib.sh - the one owner of a ship task's execution-mode
# vocabulary. Sourced, never executed.
#
# Execution mode picks which harness-native rigor skill a ship brief names:
# `ultrawork` (default) embeds the literal word that self-activates the
# already-installed omo ultrawork hook on both harnesses; `plan-first` embeds
# an explicit plan-skill invocation for a large or architecture-scope task.
# Unlike delivery mode (cs-delivery-lib.sh), this has a stated default: it
# changes tactical approach only, never the definition of done or merge
# authority, so a silent default carries none of the niceuptime-590 drift risk
# that makes delivery mode's --mode required with no fallback. Nothing
# downstream reads it back, so there is no cross-check contract line here.

# shellcheck disable=SC2034  # consumed by the sourcing scripts' messages
CS_EXEC_MODES='ultrawork|plan-first'
CS_EXEC_MODE_DEFAULT=ultrawork

cs_exec_mode_valid() { # <mode> -> 0 iff it is one of the two execution modes
  case "${1:-}" in ultrawork|plan-first) return 0 ;; esac
  return 1
}
