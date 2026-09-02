#!/usr/bin/env bash
# cs-context-budget.sh - issue #151 phase 4: the one context-budget
# measurement and enforcement command. Measures the always-loaded kernel,
# every generated role/workflow/harness pack (bin/cs-context-pack.sh), and
# three representative session-start startup shapes (empty fleet,
# representative five-task, and a pathological fleet), against the hard
# ceilings issue #151 states. Exits nonzero and names every regression when
# any hard ceiling is breached; a preferred-ceiling miss is reported but never
# fails the run, matching the issue's own preferred-vs-hard distinction.
#
# Usage: cs-context-budget.sh [--json]
#   (default)  human-readable table plus a REGRESSIONS section naming any
#              hard-ceiling breach.
#   --json     schema cs-context-budget.v1: kernel, packs[], startup{},
#              regressions[]. Exit code is identical either way.
#
# Uses a deterministic byte-count/chars-4 token proxy throughout, the same
# one docs/context-budget-baseline.md and bin/cs-context-pack.sh use - no
# online tokenizer or model dependency is introduced merely to count tokens.
#
# The three startup fixtures are built fresh under a disposable temp CS_HOME
# per run (never the caller's real data/state/config) and torn down on exit,
# so running this is always safe from any checkout, locked or not.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
cs_resolve_root

SCHEMA=cs-context-budget.v1
JSON=0
case "${1:-}" in
  --json) JSON=1 ;;
  -h|--help)
    sed -n '2,/^set -u$/p' "$SCRIPT_DIR/cs-context-budget.sh" | sed 's/^# \{0,1\}//; $d'
    exit 0
    ;;
  '') ;;
  *) echo "error: unknown argument: $1" >&2; exit 2 ;;
esac

KERNEL_MAX=${CS_CONTEXT_BUDGET_KERNEL_MAX:-10240}
STARTUP_MAX=${CS_CONTEXT_BUDGET_STARTUP_MAX:-20480}
STARTUP_PREFERRED=${CS_CONTEXT_BUDGET_STARTUP_PREFERRED:-12288}

REGRESSIONS=()
regress() { REGRESSIONS+=("$1"); }  # <message> - one hard-ceiling breach

# --- kernel -------------------------------------------------------------
KERNEL_BYTES=$(wc -c < "$CS_ROOT/AGENTS.md" | tr -d '[:space:]')
KERNEL_TOKENS=$((KERNEL_BYTES / 4))
[ "$KERNEL_BYTES" -le "$KERNEL_MAX" ] ||
  regress "AGENTS.md kernel is $KERNEL_BYTES bytes, over the $KERNEL_MAX-byte hard ceiling"

# --- packs ----------------------------------------------------------------
PACK_ROWS=()
while IFS=' ' read -r role workflow harness; do
  [ -n "$role" ] || continue
  packdir=$(mktemp -d "${TMPDIR:-/tmp}/cs-context-budget-pack.XXXXXX") || exit 1
  if CS_CONTEXT_PACK_OUT_DIR="$packdir" "$SCRIPT_DIR/cs-context-pack.sh" "$role" "$workflow" "$harness" >/dev/null 2>&1 \
      && [ -f "$packdir/pack.json" ]; then
    bytes=$(sed -n 's/.*"pack_bytes": \([0-9]*\).*/\1/p' "$packdir/pack.json")
    tokens=$(sed -n 's/.*"pack_tokens_estimate": \([0-9]*\).*/\1/p' "$packdir/pack.json")
    PACK_ROWS+=("$role $workflow $harness ${bytes:-0} ${tokens:-0}")
  else
    PACK_ROWS+=("$role $workflow $harness ERROR ERROR")
    regress "pack composition failed for $role/$workflow/$harness"
  fi
  rm -rf "$packdir"
done < <("$SCRIPT_DIR/cs-context-pack.sh" --list)

# --- startup fixtures ------------------------------------------------------
BUDGET_TMP=$(mktemp -d "${TMPDIR:-/tmp}/cs-context-budget.XXXXXX") || exit 1
trap 'rm -rf "$BUDGET_TMP"' EXIT

seed_tasks() {  # <home> <count>
  local h=$1 n=$2 i
  i=1
  while [ "$i" -le "$n" ]; do
    cat > "$h/state/task$i.meta" <<EOF
workspace=w$i
pane=w$i:p1
worktree=/tmp/wt$i
project=/tmp/proj$i
kind=ship
mode=made
yolo=off
harness=codex
EOF
    i=$((i + 1))
  done
}

measure_startup() {  # <label> <task-count> -> prints "<label> <bytes>"
  local label=$1 count=$2 h bytes
  h=$BUDGET_TMP/$label
  mkdir -p "$h/data" "$h/state" "$h/config"
  seed_tasks "$h" "$count"
  bytes=$(CS_HOME="$h" CS_LOCK_HARNESS_RE='bash|zsh|codex|claude|sleep' "$SCRIPT_DIR/cs-session-start.sh" 2>/dev/null | wc -c | tr -d '[:space:]')
  printf '%s %s\n' "$label" "$bytes"
}

STARTUP_EMPTY=$(measure_startup empty 0)
STARTUP_FIVE=$(measure_startup five 5)
STARTUP_PATHOLOGICAL=$(measure_startup pathological 200)

for row in "$STARTUP_EMPTY" "$STARTUP_FIVE" "$STARTUP_PATHOLOGICAL"; do
  label=${row%% *}
  bytes=${row#* }
  [ "$bytes" -le "$STARTUP_MAX" ] ||
    regress "startup fixture '$label' is $bytes bytes, over the $STARTUP_MAX-byte hard ceiling"
done

# --- report -----------------------------------------------------------------
if [ "$JSON" -eq 1 ]; then
  json_str() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }
  {
    printf '{\n  "schema": "%s",\n' "$SCHEMA"
    printf '  "kernel": {"bytes": %s, "tokens_estimate": %s, "max_bytes": %s},\n' \
      "$KERNEL_BYTES" "$KERNEL_TOKENS" "$KERNEL_MAX"
    printf '  "packs": [\n'
    n=${#PACK_ROWS[@]}
    i=0
    for row in "${PACK_ROWS[@]}"; do
      read -r r w h b t <<< "$row"
      i=$((i + 1))
      printf '    {"role": "%s", "workflow": "%s", "harness": "%s", "bytes": "%s", "tokens_estimate": "%s"}%s\n' \
        "$r" "$w" "$h" "$b" "$t" "$([ "$i" -lt "$n" ] && echo , )"
    done
    printf '  ],\n'
    printf '  "startup": {\n'
    printf '    "empty_bytes": %s, "five_task_bytes": %s, "pathological_bytes": %s,\n' \
      "${STARTUP_EMPTY#* }" "${STARTUP_FIVE#* }" "${STARTUP_PATHOLOGICAL#* }"
    printf '    "hard_max_bytes": %s, "preferred_max_bytes": %s\n' "$STARTUP_MAX" "$STARTUP_PREFERRED"
    printf '  },\n'
    printf '  "regressions": ['
    n=${#REGRESSIONS[@]}
    i=0
    for r in "${REGRESSIONS[@]}"; do
      i=$((i + 1))
      printf '"%s"%s' "$(json_str "$r")" "$([ "$i" -lt "$n" ] && echo , )"
    done
    printf ']\n}\n'
  }
else
  printf 'KERNEL\n'
  printf '  AGENTS.md: %s bytes (~%s tokens), hard ceiling %s\n' "$KERNEL_BYTES" "$KERNEL_TOKENS" "$KERNEL_MAX"
  printf '\nPACKS (role workflow harness bytes ~tokens)\n'
  for row in "${PACK_ROWS[@]}"; do printf '  %s\n' "$row"; done
  printf '\nSTARTUP (fixture bytes; hard ceiling %s, preferred %s)\n' "$STARTUP_MAX" "$STARTUP_PREFERRED"
  for row in "$STARTUP_EMPTY" "$STARTUP_FIVE" "$STARTUP_PATHOLOGICAL"; do
    label=${row%% *}
    bytes=${row#* }
    note=""
    [ "$bytes" -le "$STARTUP_PREFERRED" ] || note=" (over preferred target)"
    printf '  %s: %s bytes%s\n' "$label" "$bytes" "$note"
  done
  if [ "${#REGRESSIONS[@]}" -gt 0 ]; then
    printf '\nREGRESSIONS\n'
    for r in "${REGRESSIONS[@]}"; do printf '  - %s\n' "$r"; done
  fi
fi

[ "${#REGRESSIONS[@]}" -eq 0 ]
