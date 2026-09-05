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
# mutates a run. Teardown owns the one state-changing step (the cancel) itself,
# because only teardown carries the discard authority for it.
#
# CLI-surface note, verified against made's own source
# (~/github/douglasjarquin/made, HEAD ebc2fa0df816a14bdf2d17847d04a16fbca43576)
# on 2026-09-05: attribution resolves over made's real `made run list --json
# [--active]`, whose rows are full StatusReport JSON objects (branch,
# input_sha, output_sha, state, pr_url, pending_findings[], ...) - there is no
# TOON output, no `axi status`, and no plain-text `runs` listing anywhere in
# made's CLI. See docs/made.md for the full verified-facts record.

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

# cs_made_resolve_run <wt> <timeout> <branch>
# Prints the StatusReport JSON object (one line, compact) for the made run
# attributed to <branch> at a head cs_made_head_matches_worktree accepts for
# <wt>, or nothing (empty stdout, exit 1) if no such run exists. Tries the
# cheap --active listing first (the common in-flight case); falls back to the
# full (unfiltered) listing so a just-finished or failed run is still
# reported instead of "no run found". Prefers output_sha, falling back to
# input_sha, as the head to match - made run list --json rows are full
# StatusReports either way, so there is no "coarse" vs "full" split any more,
# unlike the TOON-based attribution this replaces.
cs_made_resolve_run() {
  local wt=$1 timeout=$2 branch=$3 out row
  [ -n "$branch" ] || return 1
  out=$(cs_made_run_read "$wt" "$timeout" run list --json --active) || true
  row=$(_cs_made_resolve_run_from_list "$wt" "$branch" "$out")
  if [ -n "$row" ]; then
    printf '%s\n' "$row"
    return 0
  fi
  out=$(cs_made_run_read "$wt" "$timeout" run list --json) || true
  row=$(_cs_made_resolve_run_from_list "$wt" "$branch" "$out")
  [ -n "$row" ] || return 1
  printf '%s\n' "$row"
}

# Internal helper, not part of the public contract. <wt> <branch>
# <run-list-json> - filters $3's .runs[] to <branch>, sorts newest-queued-
# first, and returns the first row whose head cs_made_head_matches_worktree
# accepts.
_cs_made_resolve_run_from_list() {
  local wt=$1 branch=$2 list=$3 row head
  [ -n "$list" ] || return 1
  printf '%s\n' "$list" | jq -e . >/dev/null 2>&1 || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    head=$(printf '%s' "$row" | jq -r '.output_sha // empty')
    [ -n "$head" ] || head=$(printf '%s' "$row" | jq -r '.input_sha // empty')
    if cs_made_head_matches_worktree "$wt" "$head"; then
      printf '%s\n' "$row"
      return 0
    fi
  done < <(printf '%s' "$list" | jq -c --arg b "$branch" \
    '[.runs[]? | select(.branch == $b)] | sort_by(.queued_at // "") | reverse | .[]')
  return 1
}
