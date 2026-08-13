#!/usr/bin/env bash
# cs-made-run-lib.sh - the single owner of the made run ATTRIBUTION contract.
# Sourced, never executed.
#
# Two consumers must agree, byte for byte, on the same question: "does a
# made pipeline run belong to THIS worktree - its exact branch AND its
# current code identity?"
#   - bin/cs-crew-state.sh reads a soldier's current state from its run-step.
#   - bin/cs-teardown.sh concludes a task's parked run before it removes the
#     worktree, so an orphaned run cannot hold a fleet slot indefinitely.
# Forking the attribution rules into two copies would let a subtle head-identity
# check drift the moment only one side is edited, and a mis-attributed run is a
# safety failure in both directions: crew-state would read another branch's
# state, and teardown would abort another task's run. This library is that one
# owner; both consumers delegate here.
#
# The identity rules are owned here and referenced by bin/cs-crew-state.sh and
# bin/cs-teardown.sh:
#   - Branch name alone is NOT enough: a historical run on a reused branch whose
#     head was rewritten or diverged must not be attributed.
#   - A run matches when its head equals the worktree HEAD, or the worktree HEAD
#     is an ancestor of the run head (pipeline fix commits advanced the run on
#     the same line of history).
#   - Local work that advanced past the run head, or diverged from it,
#     invalidates attribution.
#
# Every function is a pure read plus a bounded `made` call; nothing here
# mutates a run. Teardown owns the one state-changing step (the abort) itself,
# because only teardown carries the discard authority for it.
#
# CLI-surface note (see bin/cs-made-lib.sh's own note, verified against
# made's source on 2026-08-13): `axi status`, `axi logs`, and the plain
# `runs` listing this file's TOON readers and cs_made_runs_status_for_branch
# parse are carried over verbatim from the predecessor tool's own CLI shape -
# made's CLI does not implement any of them yet. These are forward
# references, same as cs-made-lib.sh's cs_made_gate_init and cs_made_abort:
# each starts working the moment made's CLI grows the matching subcommand,
# with no caller-side change needed.

# Bounded execution routes through the shared owner (bin/cs-timeout-lib.sh),
# which selects timeout/gtimeout/perl/bash and kills the whole process group so
# a wedged made child cannot outlive the wait.
# shellcheck source=bin/cs-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cs-timeout-lib.sh"

cs_made_run_read() {
  local wt=$1 timeout=$2
  shift 2
  # Bounded external-process invocation only: `made` is called directly
  # rather than through cs-made-lib.sh's cs_made() wrapper, because
  # cs_run_timed's external-timeout and perl tiers exec the command in a
  # separate process image that would not see a sourced shell function -
  # only its bash-fallback tier runs the command in a subshell of this one.
  # Calling the `made` binary itself keeps the bounded contract identical
  # across all four cs_run_timed mechanisms.
  ( cd "$wt" && cs_run_timed "$timeout" made "$@" ) 2>/dev/null
}

# Bounded made call from inside a worktree; stdout only, never fails the
# caller. <wt> <timeout> <args...>
cs_made_run() {
  cs_made_run_read "$@" || true
}

# --- TOON parsing primitives (shared, pure) ---------------------------------

cs_made_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

cs_made_strip_quotes() {
  local s
  s=$(cs_made_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  cs_made_trim "$s"
}

# Scalar value of a TOON key in a captured run output. <toon> <key>
cs_made_field() {
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# Finding count from a findings[N]{...} table header; empty when none. <toon>
cs_made_findings_count() {
  printf '%s\n' "$1" | grep -oE 'findings\[[0-9]+\]' | head -1 | grep -oE '[0-9]+'
}

# Split the "<step>, <status>, <findings>, ..." row of an awaiting_approval /
# fix_review step into "step|status|findings". <toon>
cs_made_gate_step_row() {
  local toon=$1 row step rest status findings
  row=$(printf '%s\n' "$toon" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(cs_made_trim "$row")
  step=$(cs_made_trim "${row%%,*}")
  rest=${row#*,}
  status=$(cs_made_strip_quotes "$(cs_made_trim "${rest%%,*}")")
  rest=${rest#*,}
  findings=$(cs_made_trim "${rest%%,*}")
  printf '%s|%s|%s' "$step" "$status" "$findings"
}

cs_made_gate_status() {
  local toon=$1 s row
  s=$(printf '%s\n' "$toon" | grep -E '^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$' | head -1)
  if [ -n "$s" ]; then
    s=$(cs_made_strip_quotes "$(cs_made_trim "${s#*:}")")
    printf '%s' "$s"
    return
  fi
  row=$(cs_made_gate_step_row "$toon")
  [ -n "$row" ] && { row=${row#*|}; printf '%s' "${row%%|*}"; }
}

cs_made_has_gate() {
  printf '%s\n' "$1" | grep -Eq '^[[:space:]]*gate:[[:space:]]*'
}

cs_made_gate_line_name() {
  local toon=$1 gate step
  gate=$(cs_made_strip_quotes "$(cs_made_field "$toon" gate)")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  step=$(printf '%s\n' "$toon" | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' | head -1)
  step=$(cs_made_strip_quotes "$step")
  [ -n "$step" ] && printf '%s' "$step"
}

cs_made_gate_name() {
  local toon=$1 gate row
  gate=$(cs_made_gate_line_name "$toon")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  row=$(cs_made_gate_step_row "$toon")
  [ -n "$row" ] && printf '%s' "${row%%|*}"
}

cs_made_gate_findings_count() {
  local toon=$1 f row rest
  f=$(cs_made_findings_count "$toon")
  [ -n "$f" ] && { printf '%s' "$f"; return; }
  row=$(cs_made_gate_step_row "$toon")
  [ -n "$row" ] || return 0
  rest=${row#*|}
  rest=${rest#*|}
  rest=${rest%%|*}
  case "$rest" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$rest"
}

# --- the attribution contract -----------------------------------------------

# 0 if <run_head> names this worktree's code identity under the header rules:
# equal commits, or the worktree HEAD is an ancestor of the run head. A missing,
# unresolvable, or strictly-earlier / diverged head is not a match.
# <wt> <run_head>
cs_made_head_matches_worktree() {
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  if git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Coarse cross-branch attribution. The made `runs` listing (forward reference,
# see header) is plain, human-oriented text - newest-first, no run id, no
# quoting, columns "<status> <branch> <short-sha> <date> [<pr-url>]" separated
# by runs of spaces. Echoes the first (most recent) matching row's status word
# for <branch> whose short-sha still matches this worktree's head, or empty
# when the branch has no attributable run within <limit> rows.
# <wt> <branch> <limit> <timeout>
cs_made_runs_status_for_branch() {
  cs_made_runs_status_for_branch_read "$@" || true
}

cs_made_runs_status_for_branch_read() {
  local wt=$1 branch=$2 limit=$3 timeout=$4 out row st rest br sha
  out=$(cs_made_run_read "$wt" "$timeout" runs --limit "$limit") || return 1
  [ -n "$out" ] || return 0
  while IFS= read -r row; do
    row=$(cs_made_trim "$row")
    [ -n "$row" ] || continue
    st=${row%% *}
    rest=${row#* }
    rest=$(cs_made_trim "$rest")
    br=${rest%% *}
    rest=${rest#* }
    rest=$(cs_made_trim "$rest")
    sha=${rest%% *}
    if [ "$br" = "$branch" ]; then
      # Same code-identity rule as axi status: skip a same-branch row whose
      # short-sha does not match this worktree (rewritten or advanced tip).
      if ! cs_made_head_matches_worktree "$wt" "$sha"; then
        continue
      fi
      printf '%s' "$st"
      return 0
    fi
  done <<< "$out"
  return 0
}

# `made axi status` output for this worktree, bounded (forward reference, see
# header). <wt> <timeout>
cs_made_axi_status() {
  cs_made_run "$1" "$2" axi status
}

cs_made_axi_status_read() {
  cs_made_run_read "$1" "$2" axi status
}

cs_made_run_status_is_active() {
  case "${1:-}" in
    ''|completed|cancelled|failed|passed|done|success|terminal) return 1 ;;
    *) return 0 ;;
  esac
}

# 0 if <toon> is an `axi status` run attributed to <branch> at a matching head.
# This is the precise ownership gate teardown uses before it touches a run:
# branch field must equal <branch> AND the head field must bind to the worktree.
# <wt> <branch> <toon>
cs_made_status_is_attributed() {
  local wt=$1 branch=$2 toon=$3 run_branch run_head
  run_branch=$(cs_made_strip_quotes "$(cs_made_field "$toon" branch)")
  [ -n "$run_branch" ] && [ "$run_branch" = "$branch" ] || return 1
  run_head=$(cs_made_strip_quotes "$(cs_made_field "$toon" head)")
  cs_made_head_matches_worktree "$wt" "$run_head"
}

# 0 if <toon> describes a run parked at an approval / fix-review gate. A run
# with any terminal outcome is never parked. This is the single owner of the
# "parked at a gate" rule: crew-state maps it to state=parked, teardown treats
# it as a slot-holding run that must be concluded before cleanup. <toon>
cs_made_run_is_gate_parked() {
  local toon=$1 outcome awaiting status gate_status
  outcome=$(cs_made_strip_quotes "$(cs_made_field "$toon" outcome)")
  [ -z "$outcome" ] || return 1
  awaiting=$(printf '%s\n' "$toon" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
  status=$(cs_made_strip_quotes "$(cs_made_field "$toon" status)")
  gate_status=$(cs_made_gate_status "$toon")
  if [ -n "$awaiting" ] || [ "$status" = awaiting_approval ] || [ "$status" = fix_review ] \
     || [ -n "$gate_status" ] || cs_made_has_gate "$toon"; then
    return 0
  fi
  return 1
}
