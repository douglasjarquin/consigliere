#!/usr/bin/env bash
# cs-auto-decision-lib.sh - non-blocking, append-only ledger for bossless-mode
# auto-decisions.
#
# A sibling to bin/cs-decision-hold.sh, never a reuse of it: cs-decision-hold.sh
# creates blocking backlog captain-holds that require every routed task to
# exist and be blocked by the hold - the wrong shape for a passive record that
# must never block dependent work. This library never creates a backlog hold
# of any kind.
#
# SCHEMA-OWNER: auto-decision ledger fields - the one full statement; every
# other mention of these fields is a pointer only.
# Record location: data/<task_id>/auto-decisions.log, in whichever home
# currently owns <task_id> - resolved from this process's own $DATA (set by
# bin/cs-root-lib.sh's cs_resolve_root), so a capo's own data/ holds its own
# tasks' ledgers and main's data/ holds its own, matching the existing
# "task-scoped notes... survive teardown" placement already used for
# data/<id>/report.md.
# Each line is tab-separated:
#   <epoch>\tcategory=<tag>\tfinding=<summary>\trecommendation=<text>\trationale=<text>
# <tag> is one of: routine|contract-expanding|destructive|irreversible|security-sensitive,
# supplied by the caller - the LLM turn that just classified the finding under
# the unchanged ask-user-authority procedure - never inferred from the line's
# text by this library.
#
# Sourced by bin/cs-send.sh and bin/cs-watch.sh (via cs_bossless_active /
# cs_auto_decision_decide below). No side effects on source. set -u safe.
#
# cs_bossless_active and cs_auto_decision_decide (this file's other half):
# cs_bossless_active(task_id) is the one concrete, testable "is bossless
# active right now for this task" predicate, re-checked fresh on every call,
# never cached - away-mode can end and the acknowledgment/kill switch
# (bin/cs-afk-start.sh, Task 16) can change between one finding and the
# next. It fails closed (false) on any missing, unreadable, or malformed
# input to any of its checks, and returns true only when ALL of these hold:
#   1. state/<task_id>.meta's yolo= reads exactly "on"
#   2. this deciding home's own state/.afk exists
#   3. the task's recorded project reads "acknowledged" in the bossless-ack
#      file (bin/cs-afk-start.sh's cs_bossless_ack_status) - a later
#      "disabled" line (the kill switch) also fails this check, since it is
#      a DIFFERENT status than "acknowledged", never a special case here
# cs_auto_decision_decide(...) is the ONLY entry point that records and
# closes an auto-decision: it re-checks cs_bossless_active itself, so a
# stale caller belief that bossless is active can never bypass it, and a
# call site never records and closes via two separate calls.
_CS_AUTO_DECISION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _CS_AUTO_DECISION_LIB_DIR="."
# shellcheck source=bin/cs-meta-lib.sh
. "$_CS_AUTO_DECISION_LIB_DIR/cs-meta-lib.sh"
# cs-afk-start.sh sets `set -eu` at its own top level, which (unlike a
# function's locals) is NOT scoped to the sourced file - saving and
# restoring the caller's own shell options keeps a caller without strict
# mode (e.g. a test harness running under plain `set -u`) from silently
# gaining errexit just because this library reused that file's functions.
_cs_auto_decision_saved_opts=$(set +o)
# shellcheck source=bin/cs-afk-start.sh
. "$_CS_AUTO_DECISION_LIB_DIR/cs-afk-start.sh"
eval "$_cs_auto_decision_saved_opts"
unset _cs_auto_decision_saved_opts

CS_AUTO_DECISION_CATEGORIES='routine contract-expanding destructive irreversible security-sensitive'

# Severity rank for cs_auto_decision_render's most-severe-first ordering.
# Higher is more severe; unrecognized categories sort last.
cs_auto_decision_category_rank() {  # <category>
  case "$1" in
    security-sensitive) printf '4' ;;
    irreversible) printf '3' ;;
    destructive) printf '2' ;;
    contract-expanding) printf '1' ;;
    routine) printf '0' ;;
    *) printf '-1' ;;
  esac
}

cs_auto_decision_log_path() {  # <task_id>
  [ -n "${DATA:-}" ] || return 1
  printf '%s/%s/auto-decisions.log' "$DATA" "$1"
}

# Append one ledger entry, creating the file and its directory if absent.
# <category> must be one of CS_AUTO_DECISION_CATEGORIES. Creates no backlog
# hold of any kind and never blocks on anything.
cs_auto_decision_record() {  # <task_id> <category> <finding_summary> <recommendation> <rationale>
  local task_id=$1 category=$2 finding=$3 recommendation=$4 rationale=$5
  local log dir now
  [ -n "$task_id" ] || return 2
  case " $CS_AUTO_DECISION_CATEGORIES " in
    *" $category "*) ;;
    *) echo "cs-auto-decision: invalid category '$category'" >&2; return 2 ;;
  esac
  log=$(cs_auto_decision_log_path "$task_id") || return 1
  dir=$(dirname "$log")
  mkdir -p "$dir" || return 1
  now=$(date +%s)
  finding=$(printf '%s' "$finding" | tr '\t\r\n' '   ')
  recommendation=$(printf '%s' "$recommendation" | tr '\t\r\n' '   ')
  rationale=$(printf '%s' "$rationale" | tr '\t\r\n' '   ')
  printf '%s\tcategory=%s\tfinding=%s\trecommendation=%s\trationale=%s\n' \
    "$now" "$category" "$finding" "$recommendation" "$rationale" >> "$log"
}

# Render <task_id>'s ledger as a markdown block, one entry per line,
# most-severe category first (stable: original order preserved within a
# category). Empty (no heading, no body) when the ledger is absent or empty.
cs_auto_decision_render() {  # <task_id>
  local task_id=$1 log line rank sorted rest
  local category finding recommendation rationale
  log=$(cs_auto_decision_log_path "$task_id") || return 1
  [ -f "$log" ] || return 0
  sorted=$(
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      category=${line#*category=}
      category=${category%%$'\t'*}
      rank=$(cs_auto_decision_category_rank "$category")
      printf '%s\t%s\n' "$rank" "$line"
    done < "$log" | sort -t "$(printf '\t')" -k1,1rn -s
  )
  [ -n "$sorted" ] || return 0
  printf '## Auto-decisions (bossless mode)\n\n'
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    rest=${line#*$'\t'}
    IFS=$'\t' read -r _ category finding recommendation rationale <<EOF
$rest
EOF
    category=${category#category=}
    finding=${finding#finding=}
    recommendation=${recommendation#recommendation=}
    rationale=${rationale#rationale=}
    printf -- '- **[%s]** %s\n  - Recommendation: %s\n  - Rationale: %s\n' \
      "$category" "$finding" "$recommendation" "$rationale"
  done <<EOF
$sorted
EOF
}

# See this file's header for the full contract. Fails closed (false) on any
# missing, unreadable, or malformed input to any check; never cached.
cs_bossless_active() {  # <task_id>
  local task_id=$1 meta yolo project name
  [ -n "$task_id" ] || return 1
  [ -n "${STATE:-}" ] || return 1
  meta="$STATE/$task_id.meta"
  [ -f "$meta" ] || return 1
  yolo=$(cs_meta_get "$meta" yolo 2>/dev/null || true)
  [ "$yolo" = on ] || return 1
  [ -e "$STATE/.afk" ] || return 1
  project=$(cs_meta_get "$meta" project 2>/dev/null || true)
  [ -n "$project" ] || return 1
  name=$(basename "$project")
  [ "$(cs_bossless_ack_status "$name" 2>/dev/null || true)" = acknowledged ] || return 1
  return 0
}

# See this file's header for the full contract: the one entry point that
# records-then-closes a bossless auto-decision, in that order, and only when
# cs_bossless_active is true at the moment of THIS call.
cs_auto_decision_decide() {  # <task_id> <category> <finding_summary> <recommendation> <rationale> <resolve_key>
  local task_id=$1 category=$2 finding=$3 recommendation=$4 rationale=$5 resolve_key=$6
  local answer
  cs_bossless_active "$task_id" || return 1
  cs_auto_decision_record "$task_id" "$category" "$finding" "$recommendation" "$rationale" || return 1
  answer="auto-decided (bossless): ${recommendation} - ${rationale}"
  CS_HOME="$CS_HOME" CS_STATE_OVERRIDE="$STATE" \
    "$_CS_AUTO_DECISION_LIB_DIR/cs-send.sh" "$task_id" --resolve-key "$resolve_key" "$answer"
}
