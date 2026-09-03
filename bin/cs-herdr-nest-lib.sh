#!/usr/bin/env bash
# cs-herdr-nest-lib.sh - decides whether a new ship/scout task nests as a tab
# inside its capo's own live workspace instead of getting a dedicated
# workspace-per-task container (docs/herdr.md "Container shape"). Sourced,
# never executed.
#
# Requires cs-meta-lib.sh (cs_meta_get) and cs-herdr-lib.sh
# (cs_herdr_workspace_exists) already sourced; this file is deliberately kept
# out of cs-herdr-lib.sh itself, which stays pure herdr-protocol plumbing with
# no meta-file dependency.
#
# Only a CAPO home carries a durable "this is MY OWN workspace" record: its
# own spawn (bin/cs-spawn.sh's capo branch) writes workspace= into its own
# state/<id>.meta, keyed by its own task id (CS_TASK_ID inside its own
# session, set at launch by that same capo branch). An ordinary root session
# has no such self-record, so nesting never applies there - a root-spawned
# task keeps the existing workspace-per-task container unchanged.
#
# A stale or now-missing workspace record fails OPEN to the caller's existing
# dedicated-container path, never closed: nesting is a placement preference,
# not a correctness requirement, so refusing the whole spawn over a stale
# placement hint would be the wrong failure mode.

cs_herdr_nest_target_workspace() {  # <home-dir> <task-id> -> workspace_id; rc 1 not applicable
  local home=$1 task_id=$2 meta ws
  local marker="$home/.cs-capo-home"
  [ -n "$task_id" ] || return 1
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  meta="$home/state/$task_id.meta"
  ws=$(cs_meta_get "$meta" workspace 2>/dev/null) || return 1
  [ -n "$ws" ] || return 1
  cs_herdr_workspace_exists "$ws" || return 1
  printf '%s\n' "$ws"
}
