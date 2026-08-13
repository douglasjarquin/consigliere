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
# cs_auto_decision_decide, Task 14, added later in this same file). No side
# effects on source. set -u safe.

_CS_AUTO_DECISION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _CS_AUTO_DECISION_LIB_DIR="."

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
