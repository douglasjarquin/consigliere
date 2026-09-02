#!/usr/bin/env bash
# cs-context-pack.sh - deterministic context-pack composer and measurement
# tool for issue #151 phase 2.
#
# A "pack" is the bounded, role/workflow/harness-scoped context an agent
# actually receives, as opposed to AGENTS.md's always-loaded kernel (which is
# harness-invariant by construction - phase 1's whole point). This script
# does not invent a second generator: for role=root the pack IS the kernel
# (AGENTS.md), and for role=scout/ship/capo the pack IS exactly what
# bin/cs-brief.sh already deterministically renders for that role, workflow
# (delivery mode), harness, and exec-mode - already proven byte-identical for
# byte-identical inputs (see docs/context-budget-baseline.md). This script's
# job is the piece that did not exist yet: a closed-set validator, a named
# component/source-hash table, and machine-readable metadata (schema,
# byte/token counts, component hashes) persisted alongside the generated
# artifact.
#
# Usage:
#   cs-context-pack.sh <role> <workflow> <harness> [--exec-mode <ultrawork|plan-first>] [--issue <n>]
#   cs-context-pack.sh --list                        print every valid role/workflow/harness combination
#
# role      root | scout | ship | capo
# workflow  the delivery mode for role=ship (made|direct-PR|local-only);
#           `none` for root and capo (neither carries a delivery mode -
#           docs/configuration.md's state/<id>.meta schema is the source of
#           truth: kind=scout records no mode, kind=capo records mode=capo);
#           `report-only` for scout (the issue's own name for "produces a
#           report, never a PR").
#           A workflow value that does not match its role's closed set is
#           refused, not silently coerced.
# harness   codex | claude | grok | cursor (bin/cs-harness-lib.sh's set).
# --exec-mode is accepted only for role=ship (default ultrawork, same as
#           cs-brief.sh); refused for every other role since only a ship
#           brief has an execution-mode section.
# --issue is accepted only for role=ship or role=scout via cs-brief.sh's own
#           rules; when omitted, "issue-section" is recorded as an excluded
#           optional section in the pack metadata rather than silently
#           absent.
#
# Output: writes two files under a scratch directory keyed by
# role-workflow-harness-execmode (stable across repeated calls with the same
# arguments, since cs-brief.sh bakes its CS_HOME path into the rendered
# brief's report/status instructions - a random temp dir would make that
# embedded path differ run to run and silently break byte-identity) and
# prints their paths plus the metadata JSON to stdout:
#   pack.md    the composed pack content (byte-for-byte what an agent of that
#              role/workflow/harness/exec-mode would receive, task specifics
#              still unfilled - {TASK} for ship/scout, {CHARTER}-shaped for
#              capo)
#   pack.json  schema cs-context-pack.v1 metadata: role, workflow, harness,
#              exec_mode, the component table (id, source path relative to
#              CS_ROOT, its own sha256, its own byte count), the composed
#              pack's sha256 and byte count, a chars/4 token estimate (the
#              same deterministic proxy docs/context-budget-baseline.md
#              uses - no tokenizer or model dependency), and
#              excluded_optional_sections.
# Nothing here mutates real fleet state: cs-brief.sh is invoked with
# CS_DATA_OVERRIDE/CS_STATE_OVERRIDE pointed at this script's own scratch
# directory, never the caller's real data/ or state/.
#
# Determinism: run twice with identical arguments and pack.md and pack.json
# are byte-identical (task-id substituted out; see
# tests/cs-context-pack.test.sh).
#
# Fails closed (exit 1, no output files) on: an unknown role, an unknown
# workflow, a workflow that does not belong to the given role's closed set,
# an unknown harness, --exec-mode passed to a non-ship role, a missing
# component source file, a component source that resolves (after symlink
# resolution) outside CS_ROOT, or a component source over the size cap
# (CS_CONTEXT_PACK_MAX_COMPONENT_BYTES, default 300000).
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=bin/cs-root-lib.sh
. "$SCRIPT_DIR/cs-root-lib.sh"
# shellcheck source=bin/cs-harness-lib.sh
. "$SCRIPT_DIR/cs-harness-lib.sh"
# shellcheck source=bin/cs-delivery-lib.sh
. "$SCRIPT_DIR/cs-delivery-lib.sh"
# shellcheck source=bin/cs-exec-mode-lib.sh
. "$SCRIPT_DIR/cs-exec-mode-lib.sh"
# shellcheck source=bin/cs-context-pack-lib.sh
. "$SCRIPT_DIR/cs-context-pack-lib.sh"
cs_resolve_root

SCHEMA=cs-context-pack.v1

usage() {
  cat <<'EOF'
usage: cs-context-pack.sh <role> <workflow> <harness> [--exec-mode <ultrawork|plan-first>] [--issue <n>]
       cs-context-pack.sh --list
role:     root | scout | ship | capo
workflow: made | direct-PR | local-only (ship only); none (root, capo); report-only (scout)
harness:  codex | claude | grok | cursor
EOF
}

if [ "${1:-}" = --list ]; then
  cat <<'EOF'
root none codex
root none claude
root none grok
root none cursor
scout report-only codex
scout report-only claude
scout report-only grok
scout report-only cursor
ship made codex
ship made claude
ship made grok
ship made cursor
ship direct-PR codex
ship direct-PR claude
ship direct-PR grok
ship direct-PR cursor
ship local-only codex
ship local-only claude
ship local-only grok
ship local-only cursor
capo none codex
capo none claude
capo none grok
capo none cursor
EOF
  exit 0
fi
[ "${1:-}" = -h ] || [ "${1:-}" = --help ] && { usage; exit 0; }

ROLE=${1:-}
WORKFLOW=${2:-}
HARNESS=${3:-}
[ -n "$ROLE" ] && [ -n "$WORKFLOW" ] && [ -n "$HARNESS" ] || { usage >&2; exit 1; }
shift 3

EXEC_MODE=
ISSUE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --exec-mode) EXEC_MODE=${2:?--exec-mode requires a value}; shift ;;
    --exec-mode=*) EXEC_MODE=${1#--exec-mode=} ;;
    --issue) ISSUE=${2:?--issue requires a value}; shift ;;
    --issue=*) ISSUE=${1#--issue=} ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

case "$ROLE" in root|scout|ship|capo) : ;; *) echo "error: unknown role: $ROLE" >&2; exit 1 ;; esac
cs_harness_valid "$HARNESS" || { echo "error: unknown harness: $HARNESS" >&2; exit 1; }
cs_pack_workflow_valid "$ROLE" "$WORKFLOW" || {
  echo "error: workflow '$WORKFLOW' is not valid for role '$ROLE'" >&2
  exit 1
}
if [ -n "$EXEC_MODE" ] && [ "$ROLE" != ship ]; then
  echo "error: --exec-mode is only valid for role=ship" >&2
  exit 1
fi
if [ "$ROLE" = ship ]; then
  EXEC_MODE=${EXEC_MODE:-$CS_EXEC_MODE_DEFAULT}
  cs_exec_mode_valid "$EXEC_MODE" || { echo "error: unknown exec-mode: $EXEC_MODE" >&2; exit 1; }
fi

COMPONENT_IDS=()
COMPONENT_PATHS=()
while IFS=' ' read -r cid cpath; do
  [ -n "$cid" ] || continue
  COMPONENT_IDS+=("$cid")
  COMPONENT_PATHS+=("$cpath")
done < <(cs_pack_components_for_role "$ROLE")

RESOLVED_PATHS=()
COMPONENT_HASHES=()
COMPONENT_BYTES=()
KERNEL_PATH=
i=0
while [ "$i" -lt "${#COMPONENT_IDS[@]}" ]; do
  rel=${COMPONENT_PATHS[$i]}
  resolved=$(cs_pack_resolve_component "$CS_ROOT" "$rel") || exit 1
  RESOLVED_PATHS+=("$resolved")
  [ "${COMPONENT_IDS[$i]}" = kernel ] && KERNEL_PATH=$resolved
  hash=$(cs_pack_sha256_of "$resolved") || { echo "error: no sha256 tool available (need shasum or sha256sum)" >&2; exit 1; }
  COMPONENT_HASHES+=("$hash")
  COMPONENT_BYTES+=("$(wc -c < "$resolved" | tr -d '[:space:]')")
  i=$((i + 1))
done

SCRATCH="${TMPDIR:-/tmp}/cs-context-pack/$ROLE-$WORKFLOW-$HARNESS-${EXEC_MODE:-none}"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/data" "$SCRATCH/state" || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

EXCLUDED='[]'
PACK_ID=pack

case "$ROLE" in
  root)
    cp "$KERNEL_PATH" "$SCRATCH/pack.md"
    ;;
  scout|ship|capo)
    briefargs=("$PACK_ID")
    case "$ROLE" in
      scout) briefargs+=(unused-repo --scout) ;;
      ship) briefargs+=(unused-repo --mode "$WORKFLOW" --exec-mode "$EXEC_MODE") ;;
      capo) briefargs=("$PACK_ID" --capo --no-projects) ;;
    esac
    if [ -n "$ISSUE" ] && [ "$ROLE" != capo ]; then
      briefargs+=(--issue "$ISSUE")
    elif [ "$ROLE" != capo ]; then
      EXCLUDED='["issue-section"]'
    fi
    if ! out=$(CS_HOME="$SCRATCH" CS_DATA_OVERRIDE="$SCRATCH/data" CS_STATE_OVERRIDE="$SCRATCH/state" \
        CS_HARNESS_OVERRIDE="$HARNESS" bash "$SCRIPT_DIR/cs-brief.sh" "${briefargs[@]}" 2>&1); then
      echo "error: cs-brief.sh failed composing the $ROLE/$WORKFLOW/$HARNESS pack:" >&2
      printf '%s\n' "$out" >&2
      exit 1
    fi
    cp "$SCRATCH/data/$PACK_ID/brief.md" "$SCRATCH/pack.md"
    ;;
esac

PACK_BYTES=$(wc -c < "$SCRATCH/pack.md" | tr -d '[:space:]')
PACK_SHA256=$(cs_pack_sha256_of "$SCRATCH/pack.md") || { echo "error: no sha256 tool available" >&2; exit 1; }
PACK_TOKENS=$((PACK_BYTES / 4))

json_str() { # escape a string for embedding in JSON
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

{
  printf '{\n'
  printf '  "schema": "%s",\n' "$SCHEMA"
  printf '  "role": "%s",\n' "$(json_str "$ROLE")"
  printf '  "workflow": "%s",\n' "$(json_str "$WORKFLOW")"
  printf '  "harness": "%s",\n' "$(json_str "$HARNESS")"
  if [ "$ROLE" = ship ]; then
    printf '  "exec_mode": "%s",\n' "$(json_str "$EXEC_MODE")"
  else
    printf '  "exec_mode": null,\n'
  fi
  printf '  "components": [\n'
  i=0
  n=${#COMPONENT_IDS[@]}
  while [ "$i" -lt "$n" ]; do
    printf '    {"id": "%s", "source": "%s", "sha256": "%s", "bytes": %s}' \
      "$(json_str "${COMPONENT_IDS[$i]}")" "$(json_str "${COMPONENT_PATHS[$i]}")" \
      "${COMPONENT_HASHES[$i]}" "${COMPONENT_BYTES[$i]}"
    i=$((i + 1))
    [ "$i" -lt "$n" ] && printf ',\n' || printf '\n'
  done
  printf '  ],\n'
  printf '  "pack_sha256": "%s",\n' "$PACK_SHA256"
  printf '  "pack_bytes": %s,\n' "$PACK_BYTES"
  printf '  "pack_tokens_estimate": %s,\n' "$PACK_TOKENS"
  printf '  "excluded_optional_sections": %s\n' "$EXCLUDED"
  printf '}\n'
} > "$SCRATCH/pack.json"

OUT_DIR=${CS_CONTEXT_PACK_OUT_DIR:-$SCRATCH}
if [ "$OUT_DIR" != "$SCRATCH" ]; then
  mkdir -p "$OUT_DIR"
  cp "$SCRATCH/pack.md" "$OUT_DIR/pack.md"
  cp "$SCRATCH/pack.json" "$OUT_DIR/pack.json"
fi
trap - EXIT
[ "$OUT_DIR" = "$SCRATCH" ] || rm -rf "$SCRATCH"

echo "pack: $OUT_DIR/pack.md"
echo "metadata: $OUT_DIR/pack.json"
cat "$OUT_DIR/pack.json"
