#!/usr/bin/env bash
# cs-delivery-lib.sh - the one owner of a ship task's delivery-contract
# vocabulary. Sourced, never executed.
#
# A ship task's delivery mode and yolo posture are decided per task at intake and
# passed explicitly to cs-brief.sh, cs-spawn.sh, and cs-promote.sh. This library
# owns the three pieces those scripts must agree on:
#   - the closed mode and yolo sets, so one script cannot accept what another
#     rejects;
#   - the rigor order behind cs-spawn.sh's advisory registry-deviation notice;
#   - the exact machine-readable line cs-brief.sh writes into a ship brief and
#     cs-spawn.sh reads back to cross-check its own --mode. A writer and a reader
#     holding two copies of that format would drift silently, which is the whole
#     failure this cross-check exists to catch.
#
# data/projects.md records the boss's STANDING posture per project and is
# advisory; cs-project-mode.sh owns that registry parse and nothing here reads it.

# Human-facing spelling of each closed set, for usage and error messages.
# shellcheck disable=SC2034  # consumed by the sourcing scripts' messages
CS_DELIVERY_MODES='no-mistakes|direct-PR|local-only'
# shellcheck disable=SC2034  # consumed by the sourcing scripts' messages
CS_DELIVERY_YOLOS='on|off'

# The exact prefix of the ship brief's delivery-contract line. Written by
# cs-brief.sh, parsed by cs-spawn.sh, pinned by tests/cs-task-delivery.test.sh.
CS_DELIVERY_CONTRACT_PREFIX='Delivery contract: mode='

cs_delivery_mode_valid() { # <mode> -> 0 iff it is one of the three delivery modes
  case "${1:-}" in no-mistakes|direct-PR|local-only) return 0 ;; esac
  return 1
}

cs_delivery_yolo_valid() { # <yolo> -> 0 iff it is on or off
  case "${1:-}" in on|off) return 0 ;; esac
  return 1
}

# Rigor rank, most to least: no-mistakes, direct-PR, local-only. Used only to
# decide whether an explicit mode deviates DOWNWARD from a project's standing
# registry posture, which is a notice, never a refusal.
cs_delivery_mode_rigor() { # <mode> -> rank on stdout (0 for anything unknown)
  case "${1:-}" in
    no-mistakes) printf '3\n' ;;
    direct-PR)   printf '2\n' ;;
    local-only)  printf '1\n' ;;
    *)           printf '0\n' ;;
  esac
}

cs_delivery_contract_line() { # <mode> -> the exact line a ship brief carries
  printf '%s%s\n' "$CS_DELIVERY_CONTRACT_PREFIX" "$1"
}

# cs_delivery_brief_mode <brief-file> -> the mode recorded in the brief's
# delivery-contract line, or rc=1 when the brief carries none (scaffolded before
# the contract existed). The LAST occurrence wins, matching the meta convention.
cs_delivery_brief_mode() {
  local file=$1 val
  [ -f "$file" ] || return 1
  val=$(awk -v p="$CS_DELIVERY_CONTRACT_PREFIX" '
    index($0, p) == 1 { v = substr($0, length(p) + 1) }
    END { if (v != "") print v }
  ' "$file")
  [ -n "$val" ] || return 1
  printf '%s\n' "$val"
}
